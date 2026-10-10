#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap '{ [ -n "${WORLD_PID:-}" ] && kill $WORLD_PID; } 2>/dev/null; rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME OP_CLI OP_VAULT OP_SERVICE_ACCOUNT_TOKEN
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"
chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
# production's live Durable Object migration state (the secondary Worker's migration v1 is live)
echo '{"scripts":[{"id":"runtime","migration_tag":"v1"}]}' >"$T/world.json"
node test/stubs/promote-world.mjs "$T/port" "$T/world.json" & WORLD_PID=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
export CLOUDFLARE_API_BASE="http://127.0.0.1:$(cat "$T/port")/cf" CLOUDFLARE_API_TOKEN=t
export RELEASE_SECRET_LIST=$T/secrets.json
printf '%s\n' '{"runtime-staging":["RUNTIME_KEY"],"runtime":["RUNTIME_KEY"]}' > "$RELEASE_SECRET_LIST"
release() { (cd "$R" && node scripts/agent/release.mjs main) > "$T/out" 2>&1; }
no_remote() { node --input-type=module - "$RELEASE_LOG" <<'JS'
import {existsSync, readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const rows = existsSync(process.argv[2]) ? readFileSync(process.argv[2], 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
assert.ok(rows.every(row => !row.args), 'cross-account config reached Wrangler');
JS
}
why=""
for mode in staging secondary secondary-staging generated same inherited missing-root; do
  R=$T/$mode
  git init -q -b main "$R"
  cp -R test/fixtures/release-astro/. "$R/"
  cp -R test/fixtures/release-secondary/. "$R/"
  node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.3 >/dev/null
  mkdir -p "$R/node_modules/.bin" "$R/migrations"
  touch "$R/node_modules/.bin/wrangler"
  printf 'node_modules/\ndist/\n.wrangler/\n' >> "$R/.gitignore"
  node --input-type=module - "$R" "$mode" <<'JS'
import {readFileSync, writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const [dir, mode] = process.argv.slice(2), account = () => randomUUID().replaceAll('-', '');
const primary = `${dir}/wrangler.jsonc`, secondary = `${dir}/workers/runtime/wrangler.jsonc`;
const cfg = JSON.parse(readFileSync(primary)), extra = JSON.parse(readFileSync(secondary));
cfg.account_id = account();
extra.account_id = cfg.account_id;
cfg.env.staging.account_id = cfg.account_id;
extra.env.staging.account_id = cfg.account_id;
if (mode === 'staging' || mode === 'missing-root') cfg.env.staging.account_id = account();
if (mode === 'missing-root') { delete cfg.account_id; delete extra.account_id; delete extra.env.staging.account_id; }
if (mode === 'secondary') extra.account_id = extra.env.staging.account_id = account();
if (mode === 'secondary-staging') extra.env.staging.account_id = account();
if (mode === 'inherited') { delete cfg.env.staging.account_id; delete extra.env.staging.account_id; }
writeFileSync(primary, JSON.stringify(cfg));
writeFileSync(secondary, JSON.stringify(extra));
const path = `${dir}/standards.json`, std = JSON.parse(readFileSync(path));
std.release_workers = ['workers/runtime/wrangler.jsonc'];
writeFileSync(path, JSON.stringify(std));
if (mode === 'generated') {
  // Only the adapter output changes account; source configs remain safe.
  const build = `${dir}/build.mjs`;
  writeFileSync(build, readFileSync(build, 'utf8').replace('delete cfg.env;', 'if (staging) cfg.account_id = '+JSON.stringify(account())+';\ndelete cfg.env;'));
}
JS
  git -C "$R" add -A && git -C "$R" commit -qm fixture
  export RELEASE_LOG=$T/$mode.log
  if [ "$mode" = same ] || [ "$mode" = inherited ]; then
    release || why="$why; $mode release rejected"
    (cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1 || why="$why; $mode check rejected"
  else
    if release; then why="$why; $mode release accepted";
    elif ! grep -q "cross-account staging isn't supported yet" "$T/out" || ! no_remote; then why="$why; $mode release wrong failure"; fi
    # Generated --check probes the adapter output only after a redirect exists.
    if [ "$mode" = generated ]; then (cd "$R" && node build.mjs); fi
    if (cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1; then why="$why; $mode check accepted";
    elif ! grep -q "cross-account staging isn't supported yet" "$T/out"; then why="$why; $mode check wrong failure"; fi
  fi
done
if [ -z "$why" ]; then ok release-cross-account-refused; else fail release-cross-account-refused "$why"; fi
done_cases
