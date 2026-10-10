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
# production's live Durable Object migration state (the fixtures' secondary Worker declares migration v1, which is live)
echo '{"scripts":[{"id":"runtime","migration_tag":"v1"}]}' >"$T/world.json"
node test/stubs/promote-world.mjs "$T/port" "$T/world.json" & WORLD_PID=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
export CLOUDFLARE_API_BASE="http://127.0.0.1:$(cat "$T/port")/cf" CLOUDFLARE_API_TOKEN=t
export RELEASE_SECRET_LIST=$T/secret-list.json
printf '%s\n' '{"runtime-staging":["RUNTIME_KEY"],"runtime":["RUNTIME_KEY"]}' > "$RELEASE_SECRET_LIST"
repo() {
  R=$T/$1
  git init -q -b main "$R"
  cp -R "test/fixtures/release-$2/." "$R/"
  node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
  mkdir -p "$R/node_modules/.bin" "$R/migrations"
  touch "$R/node_modules/.bin/wrangler"
  printf 'CREATE TABLE fixture(id INTEGER);\n' > "$R/migrations/0001.sql"
  printf 'node_modules/\ndist/\n.wrangler/\n' >> "$R/.gitignore"
  git -C "$R" add -A && git -C "$R" commit -qm fixture
  export RELEASE_LOG=$T/$1.log
}
extra() {
  cp -R test/fixtures/release-secondary/. "$R/"
  node -e 'const fs=require("fs"),f=process.argv[1]+"/standards.json",cfg=JSON.parse(fs.readFileSync(f));cfg.release_workers=["workers/runtime/wrangler.jsonc"];fs.writeFileSync(f,JSON.stringify(cfg))' "$R"
}
release() { (cd "$R" && node scripts/agent/release.mjs main) > "$T/out" 2>&1; }
no_remote() {
  node --input-type=module - "$RELEASE_LOG" <<'JS'
import { existsSync, readFileSync } from "node:fs";
import assert from "node:assert/strict";
const text = existsSync(process.argv[2]) ? readFileSync(process.argv[2], "utf8").trim() : "";
const rows = text ? text.split("\n").map(JSON.parse) : [];
assert.ok(rows.every((row) => !row.args), "no Wrangler command before all isolation checks pass");
JS
}
repo shared astro
why=""
if GENERATED_RESOURCE=1 release; then why="shared generated production D1 was deployed";
elif ! grep -q 'unsafe staging resources.*generated-production' "$T/out" || ! no_remote; then why="wrong failure: $(cat "$T/out")"; fi
# The same guard applies to --check and retains production artifacts after its probe.
(cd "$R" && GENERATED_RESOURCE=1 node build.mjs)
if (cd "$R" && GENERATED_RESOURCE=1 scripts/agent/setup.sh --check) > "$T/out" 2>&1; then why="$why; shared generated binding passed --check";
elif ! grep -q 'unsafe staging resources.*generated-production' "$T/out"; then why="$why; check wrong failure: $(cat "$T/out")"; fi
: > "$RELEASE_LOG"
if GENERATED_RESOURCE=1 ISOLATE_GENERATED_RESOURCE=1 release; then
  node --input-type=module - "$RELEASE_LOG" <<'JS'
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const rows = readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse);
assert.deepEqual(rows.filter((row) => "build" in row).map((row) => row.build), [null, "staging", null]);
assert.deepEqual(rows.filter((row) => row.args).map((row) => row.args[0]), ["d1", "deploy", "versions"]);
assert.equal(rows.find((row) => row.args?.[0] === "d1").configName, "site-staging");
assert.equal(rows.at(-2).build, null);
assert.deepEqual(rows.at(-1).args, ["versions", "upload"]);
JS
  [ $? = 0 ] || why="$why; isolated build ordering failed"
else why="$why; isolated generated binding failed: $(cat "$T/out")"; fi
# The primary's generated production database must also protect a secondary staging target.
repo shared-secondary astro
extra
node -e 'const fs=require("fs"),f=process.argv[1]+"/workers/runtime/wrangler.jsonc",cfg=JSON.parse(fs.readFileSync(f));cfg.env.staging.d1_databases=[{binding:"CROSS_DB",database_id:"generated-production",database_name:"generated-production"}];fs.writeFileSync(f,JSON.stringify(cfg))' "$R"
if GENERATED_RESOURCE=1 ISOLATE_GENERATED_RESOURCE=1 release; then why="$why; secondary used primary generated production D1";
elif ! grep -q 'unsafe staging resources.*generated-production' "$T/out" || ! no_remote; then why="$why; secondary wrong failure: $(cat "$T/out")"; fi
# Legacy staging Previews need the same generated-production inventory before their remote call.
repo legacy-shared astro
node -e 'const fs=require("fs"),f=process.argv[1]+"/wrangler.jsonc",cfg=JSON.parse(fs.readFileSync(f));delete cfg.env;cfg.previews={d1_databases:[{binding:"DB",database_id:"generated-production",database_name:"generated-production"}]};fs.writeFileSync(f,JSON.stringify(cfg))' "$R"
if GENERATED_RESOURCE=1 release; then why="$why; legacy Preview used generated production D1";
elif ! grep -q 'unsafe staging Preview resources.*generated-production' "$T/out" || ! no_remote; then why="$why; legacy Preview wrong failure: $(cat "$T/out")"; fi
if [ -z "$why" ]; then ok release-generated-production-inventory; else fail release-generated-production-inventory "$why"; fi
why=""
for mode in primary secondary generated malformed-object malformed-array malformed-source malformed-class malformed-migrations malformed-new malformed-sqlite malformed-deleted malformed-renamed malformed-unknown; do
  repo "transfer-$mode" astro
  extra
  node --input-type=module - "$R" "$mode" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
const dir = process.argv[2], mode = process.argv[3];
if (mode === "generated") process.exit(0);
const file = mode === "primary" ? `${dir}/wrangler.jsonc` : `${dir}/workers/runtime/wrangler.jsonc`;
const cfg = JSON.parse(readFileSync(file, "utf8"));
let transfers = [{ from_script: "site", from: "Session", to: "Runtime" }];
if (mode === "malformed-object") transfers = [null];
if (mode === "malformed-array") transfers = { from_script: "site", from: "Session", to: "Runtime" };
if (mode === "malformed-source") transfers = [{ from_script: 42, from: "Session", to: "Runtime" }];
if (mode === "malformed-class") transfers = [{ from_script: "source-staging", to: "Runtime" }];
// Top-level migrations are inherited by env.staging; generated fixtures flatten them too.
cfg.migrations = mode === "malformed-migrations" ? {} : [{ tag: "transfer", transferred_classes: transfers }];
if (mode.startsWith("malformed-") && ["new", "sqlite", "deleted", "renamed", "unknown"].includes(mode.slice(10))) {
  cfg.migrations[0].transferred_classes = [{ from_script: "source-staging", from: "Runtime", to: "Runtime" }];
  const fields = { new: ["new_classes", "Bad"], sqlite: ["new_sqlite_classes", [42]], deleted: ["deleted_classes", [null]], renamed: ["renamed_classes", [{ from: "Old" }]], unknown: ["unknown", true] };
  const [key, value] = fields[mode.slice(10)]; cfg.migrations[0][key] = value;
}
writeFileSync(file, JSON.stringify(cfg));
JS
  generated=""
  [ "$mode" != generated ] || generated=1
  if GENERATED_TRANSFER=$generated release; then why="$why; $mode transfer passed";
  elif ! grep -Eq 'unsafe staging resources.*(transfers Durable Objects from a production Worker|cannot safely read)' "$T/out" || ! no_remote; then why="$why; $mode wrong failure: $(cat "$T/out")"; fi
done
repo isolated-transfer plain
extra
node -e 'const fs=require("fs"),f=process.argv[1]+"/workers/runtime/wrangler.jsonc",cfg=JSON.parse(fs.readFileSync(f));cfg.migrations=[{tag:"transfer",transferred_classes:[{from_script:"source-staging",from:"Session",to:"Runtime"}]}];fs.writeFileSync(f,JSON.stringify(cfg))' "$R"
echo '{"scripts":[{"id":"runtime","migration_tag":"transfer"}]}' >"$T/world.json"
release || why="$why; isolated transfer blocked: $(cat "$T/out")"
echo '{"scripts":[{"id":"runtime","migration_tag":"v1"}]}' >"$T/world.json"
repo isolated-generated-transfer astro
extra
GENERATED_TRANSFER=source-staging release || why="$why; isolated generated transfer blocked: $(cat "$T/out")"
if [ -z "$why" ]; then ok release-durable-object-transfer-guard; else fail release-durable-object-transfer-guard "$why"; fi
done_cases
