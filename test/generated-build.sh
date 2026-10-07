#!/usr/bin/env bash
# Extend release-generated-check with the clean runner's real package-manager bootstrap.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset ROLLBACK_BASE ROLLBACK_DRAFT GITHUB_EVENT_NAME GITHUB_EVENT_PATH
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
R=$T/site
mkdir -p "$T/bin"
for tool in node npm npx; do ln -s "$(command -v "$tool")" "$T/bin/$tool"; done
CLEAN_PATH="$T/bin:/usr/bin:/bin"
git init -q -b main "$R"
cp -R test/fixtures/release-astro/. "$R/"
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.7 >/dev/null
printf 'node_modules/\ndist/\n.wrangler/\n' >> "$R/.gitignore"
node - "$R" <<'JS'
const fs = require('node:fs'), dir = process.argv[2];
const cfg=JSON.parse(fs.readFileSync(`${dir}/wrangler.jsonc`));
cfg.secrets={required:['DSN']}; cfg.env.staging.secrets={required:['DSN','STAGE_DSN']};
fs.writeFileSync(`${dir}/wrangler.jsonc`,JSON.stringify(cfg));
const pkg = JSON.parse(fs.readFileSync(`${dir}/package.json`));
pkg.packageManager = 'pnpm@10.0.0';
fs.writeFileSync(`${dir}/package.json`, JSON.stringify(pkg));
const build = fs.readFileSync(`${dir}/build.mjs`, 'utf8');
fs.writeFileSync(`${dir}/build.mjs`, `
import { existsSync } from 'node:fs';
if (process.env.BOOTSTRAP_LOG) {
  if (!existsSync(process.env.COREPACK_HOME ?? '')) throw new Error('bootstrap environment lost');
  appendFileSync(process.env.BOOTSTRAP_LOG, JSON.stringify({cwd:process.cwd(),home:process.env.COREPACK_HOME,stage:process.env.CLOUDFLARE_ENV ?? null,ci:process.env.CI ?? null})+'\\n');
}
if (process.env.BUILD_FAILURE && process.env.CLOUDFLARE_ENV === 'staging') {
  for (let i=0; i<40; i++) console.error('diagnostic-line-'+i);
  console.log('DATABASE_URL=postgres://u:secretpass@h/db');
  console.error('DATABASE_URL=postgres://u:secretpass@h/db');
  console.error('real adapter error '+process.env.TEST_BUILD_TOKEN+' '+process.env.DSN+' '+process.env.STAGE_DSN);
  process.exit(42);
}
` + build);
JS
export RELEASE_LOG=$T/release.log
(cd "$R" && PATH="$CLEAN_PATH" COREPACK_ENABLE_AUTO_PIN=0 npx --yes --package corepack@0.34.6 corepack pnpm install --lockfile-only) > "$T/lock.log" 2>&1 || { fail release-generated-check "lockfile: $(cat "$T/lock.log")"; exit 1; }
# Seed the adapter redirect just as rollback's first production build does on a fresh runner.
(cd "$R" && node build.mjs)
git -C "$R" add -A; git -C "$R" commit -qm fixture
why=""
for mode in normal ci custom; do
  : > "$T/bootstrap.log"
  if [ "$mode" = custom ]; then
    node - "$R/standards.json" <<'JS'
const fs=require('node:fs'), file=process.argv[2], std=JSON.parse(fs.readFileSync(file));
std.build='pnpm run build'; fs.writeFileSync(file,JSON.stringify(std));
JS
  fi
  ci=""; actions=""; [ "$mode" = normal ] || { ci=true; actions=true; }
  (cd "$R" && PATH="$CLEAN_PATH" CI="$ci" GITHUB_ACTIONS="$actions" BOOTSTRAP_LOG="$T/bootstrap.log" scripts/agent/setup.sh --check) > "$T/out" 2>&1 || { why="$why; $mode: $(cat "$T/out")"; continue; }
  node - "$T/bootstrap.log" "$R" "$ci" <<'JS'
const fs=require('node:fs'), assert=require('node:assert/strict');
const rows=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(JSON.parse);
assert.equal(rows.length,5);
assert.deepEqual(rows.map(r=>r.stage),[null,null,null,'staging',null]);
const repo=fs.realpathSync(process.argv[3]);
assert.deepEqual(rows.map(r=>r.cwd===repo),[true,false,true,true,true]);
assert.equal(rows[0].home,rows[1].home);
assert.ok(rows.slice(2).every(r=>r.home===rows[2].home));
assert.notEqual(rows[0].home,rows[2].home);
assert.ok(rows.every(r=>!fs.existsSync(r.home)), 'private bootstrap must be cleaned');
assert.ok(rows.every(r=>r.ci===process.argv[4]));
const cfg=JSON.parse(fs.readFileSync(`${repo}/dist/server/wrangler.json`));
assert.equal(cfg.name,'site');
JS
  [ "$?" -eq 0 ] || { why="$mode: build sequence, environment, cleanup or production restore failed"; break; }
done
if [ -z "$why" ]; then
  : > "$T/bootstrap.log"
  token="fixture-secret-value"
  if (cd "$R" && PATH="$CLEAN_PATH" CI=true GITHUB_ACTIONS=true BUILD_FAILURE=1 TEST_BUILD_TOKEN="$token" DSN="fixture-wrangler-secret" STAGE_DSN="fixture-staging-secret" BOOTSTRAP_LOG="$T/bootstrap.log" scripts/agent/setup.sh --check) > "$T/out" 2>&1; then why="failing adapter passed";
  elif ! grep -q 'staging build failed (exit 42)' "$T/out" || ! grep -q "Corepack-bootstrapped package manager: CLOUDFLARE_ENV=staging sh -c 'pnpm run build'" "$T/out" || grep -qE "$token|fixture-wrangler-secret|fixture-staging-secret|secretpass|DATABASE_URL|real adapter error|diagnostic-line" "$T/out"; then why="missing reproduction command or leaked build output: $(cat "$T/out")";
  else
    node - "$T/bootstrap.log" "$R" <<'JS'
const fs=require('node:fs'), assert=require('node:assert/strict');
const rows=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(JSON.parse);
assert.deepEqual(rows.map(r=>r.stage),[null,null,null,'staging',null]);
assert.ok(rows.every(r=>!fs.existsSync(r.home)));
assert.equal(JSON.parse(fs.readFileSync(`${process.argv[3]}/dist/server/wrangler.json`)).name,'site');
JS
    [ "$?" -eq 0 ] || why="failed staging probe did not restore production or clean bootstrap"
  fi
fi
if [ -z "$why" ]; then ok release-generated-check; else fail release-generated-check "$why"; fi
done_cases
