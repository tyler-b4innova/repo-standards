#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"
chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
repo() {
  R=$T/$1
  git init -q -b main "$R"
  cp -R "test/fixtures/release-$2/." "$R/"
  node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
  mkdir -p "$R/node_modules/.bin"
  touch "$R/node_modules/.bin/wrangler"
  printf 'node_modules/\ndist/\n.wrangler/\n' >> "$R/.gitignore"
  git -C "$R" add -A && git -C "$R" commit -qm fixture
  export RELEASE_LOG=$T/$1.log
}
release() { (cd "$R" && node scripts/agent/release.mjs main) > "$T/out" 2>&1; }
proof() { node --input-type=module - "$RELEASE_LOG" "$1" <<'JS'
import { existsSync, readFileSync } from "node:fs";
import assert from "node:assert/strict";
const lines = existsSync(process.argv[2]) ? readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse) : [];
const kind = process.argv[3];
if (kind === "astro") {
  assert.equal(lines.length, 4);
  assert.deepEqual(lines[0], { build: "staging", name: "site-staging" });
  assert.equal(lines[1].args[0], "deploy");
  assert.equal(lines[1].name, "site-staging");
  assert.equal(lines[1].configName, "site-staging");
  assert.ok(!lines[1].args.includes("--config"));
  assert.deepEqual(lines[1].routes, []);
  assert.deepEqual(lines[2], { build: null, name: "site" });
  assert.deepEqual(lines[3].args.slice(0, 2), ["versions", "upload"]);
  assert.equal(lines[3].configName, "site");
  assert.equal(lines[3].env, null);
} else if (kind === "migrations") {
  assert.equal(lines.length, 5);
  assert.equal(lines[0].build, "staging");
  assert.deepEqual(lines[1].args.slice(0, 4), ["d1", "migrations", "apply", "DB"]);
  assert.ok(!lines[1].args.includes("--config"));
  assert.equal(lines[1].configName, "site-staging");
  assert.equal(lines[2].args[0], "deploy");
  assert.equal(lines[2].name, "site-staging");
  assert.equal(lines[3].build, null);
  assert.deepEqual(lines[4].args, ["versions", "upload"]);
} else if (kind === "abort") {
  assert.ok(lines.every((line) => !line.args), "no Wrangler command before guard passes");
} else if (kind === "output") {
  assert.equal(lines.filter((line) => line.args).length, 1);
  assert.equal(lines.find((line) => line.args).args[0], "deploy");
} else {
  assert.equal(lines.length, 2);
  assert.equal(lines[0].args[0], "deploy");
  assert.equal(lines[0].name, "site-staging");
  assert.deepEqual(lines[0].routes, []);
  assert.deepEqual(lines[1].args, ["versions", "upload"]);
  assert.equal(lines[1].name, "site");
  assert.ok(lines[0].args.includes("--name"));
  assert.ok(lines[0].args.includes("--config"));
}
JS
}
repo astro astro
if CLOUDFLARE_ENV=accidental WRANGLER_CI_OVERRIDE_NAME=site release && proof astro; then
  repo db astro
  mkdir -p "$R/migrations"
  node -e 'const fs=require("fs"),p=process.argv[1]+"/wrangler.jsonc",o=JSON.parse(fs.readFileSync(p));o.env.staging.d1_databases=[{binding:"DB",database_name:"site-db-staging",database_id:"d1-staging"}];fs.writeFileSync(p,JSON.stringify(o))' "$R"
  if release && proof migrations; then
    repo custom astro
    node -e 'const fs=require("fs"),p=process.argv[1]+"/standards.json",o=JSON.parse(fs.readFileSync(p));o.build="node build.mjs";fs.writeFileSync(p,JSON.stringify(o));fs.writeFileSync(process.argv[1]+"/package.json",JSON.stringify({type:"module"}))' "$R"
    if release && proof astro; then ok release-generated-builds; else fail release-generated-builds "standards build: $(cat "$T/out")"; fi
  else fail release-generated-builds "generated migrations: $(cat "$T/out")"; fi
else fail release-generated-builds "$(cat "$T/out")"; fi
repo bad astro
if IGNORE_SELECTION=1 release; then fail release-generated-guard "unsafe build passed";
elif grep -q 'unsafe staging target.*expected site-staging' "$T/out" && proof abort; then ok release-generated-guard; else fail release-generated-guard "$(cat "$T/out")"; fi
repo routes astro
if PRODUCTION_ROUTE=1 release; then fail release-production-route-guard "production route passed";
elif grep -q 'unsafe staging route/custom domain' "$T/out" && proof abort; then
  repo singular plain
  python3 - "$R/wrangler.jsonc" <<'PYTEST'
import sys
p=sys.argv[1]
s=open(p).read().replace('{\n', '{\n  "route": "site.example.com/*",\n', 1)
open(p,'w').write(s)
PYTEST
  if release; then fail release-production-route-guard "inherited singular route passed";
  elif grep -q 'unsafe staging route/custom domain' "$T/out" && proof abort; then ok release-production-route-guard;
  else fail release-production-route-guard "$(cat "$T/out")"; fi
else fail release-production-route-guard "$(cat "$T/out")"; fi
repo output astro
if WRONG_OUTPUT=1 release; then fail release-staging-output "wrong output passed";
elif grep -q 'staging deploy output did not confirm' "$T/out" && proof output; then ok release-staging-output; else fail release-staging-output "$(cat "$T/out")"; fi
repo plain plain
if release && proof plain; then ok release-plain-config; else fail release-plain-config "$(cat "$T/out")"; fi
repo check astro
(cd "$R" && node build.mjs)
if (cd "$R" && IGNORE_SELECTION=1 scripts/agent/setup.sh --check) > "$T/out" 2>&1; then fail release-generated-check "unsupported build passed";
elif grep -q 'generated Wrangler config.*unsafe staging target' "$T/out" && grep -q 'honor CLOUDFLARE_ENV=staging' "$T/out"; then
  if (cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1; then
    # A fresh gate checkout has no redirect until its build entry point generates it.
    (cd "$R" && node -e 'require("fs").rmSync(".wrangler",{recursive:true})')
    if (cd "$R" && IGNORE_SELECTION=1 node scripts/agent/gate.mjs run build) > "$T/out" 2>&1; then fail release-generated-check "clean CI build passed unsupported selection";
    elif grep -q 'generated Wrangler config.*unsafe staging target' "$T/out" && (cd "$R" && node scripts/agent/gate.mjs run build) > "$T/out" 2>&1; then ok release-generated-check;
    else fail release-generated-check "CI build: $(cat "$T/out")"; fi
  else fail release-generated-check "supported build: $(cat "$T/out")"; fi
else fail release-generated-check "$(cat "$T/out")"; fi
done_cases
