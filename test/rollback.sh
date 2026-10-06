#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent CI=true
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME ROLLBACK_BASE ROLLBACK_DRAFT
ENGINE=$PWD T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
repo() {
  R=$T/$1; git init -q -b main "$R"
  mkdir -p "$R/db" "$R/src"
  echo 'export class Counter {}' > "$R/src/index.js"
  echo 'CREATE TABLE users (id INTEGER, old TEXT);' > "$R/db/0001.sql"
  cat > "$R/wrangler.jsonc" <<'CFG'
{"name":"app","main":"src/index.js","d1_databases":[{"binding":"DB","database_id":"db-prod","migrations_dir":"db"}],"durable_objects":{"bindings":[{"name":"COUNTER","class_name":"Counter"}]},"migrations":[{"tag":"v1","new_classes":["Counter"]}],"env":{"staging":{"routes":[],"d1_databases":[{"binding":"DB","database_id":"db-stage"}],"durable_objects":{"bindings":[{"name":"COUNTER","class_name":"Counter"}]} }},"previews":{"d1_databases":[{"binding":"DB","database_id":"db-stage"}]}}
CFG
  node "$ENGINE/bin/repo-standards.mjs" apply --target "$R" --overlay "$ENGINE/examples/overlay.json" --version 0.1.0 >/dev/null
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
check() { (cd "$R" && ROLLBACK_BASE=$BASE scripts/agent/setup.sh --check) 2>&1; }
casecheck() {
  local id=$1 expected=$2 needle=$3 out rc
  git -C "$R" add -A
  out=$(check); rc=$?
  if [ "$rc" -eq "$expected" ] && [[ "$out" == *"$needle"* ]]; then ok "$id"; else fail "$id" "$out (exit=$rc)"; fi
}
# Missing comparison bases: exercise the real setup entry under rollback-hazards.
repo scratch-base
BASE=1111111111111111111111111111111111111111
# A git-init repository has no upstream history for the stale explicit base.
casecheck rollback-hazards 0 'NOTE: rollback: no comparison base (no remotes); skipped'
# No explicit or inferred base in a scratch checkout with NO remote.
git -C "$R" checkout -q --detach; git -C "$R" branch -D main >/dev/null
BASE=
casecheck rollback-hazards 0 'NOTE: rollback: no comparison base (no remotes); skipped'
# The same empty-base shape with any remote must fail, even in draft mode.
git -C "$R" remote add upstream "file://$T/absent.git"
export ROLLBACK_DRAFT=true
casecheck rollback-push-base 1 'origin remote is unavailable'
git -C "$R" remote rename upstream origin
casecheck rollback-push-base 1 'git fetch --no-tags --depth=1 origin HEAD:'
unset ROLLBACK_DRAFT

repo shallow-source
SOURCE=$R
# Give the selected base a parent, so a depth-one fetch cannot bring full history.
echo 'base fixture' > "$R/base.txt"
git -C "$R" add -A; git -C "$R" commit -qm comparison-base
BASE=$(git -C "$R" rev-parse HEAD)
git -C "$R" tag base-tag "$BASE"
# The comparison base must be absent from the depth-one clone.
echo 'ALTER TABLE users ADD COLUMN extra TEXT;' > "$R/db/0002.sql"
git -C "$R" add -A; git -C "$R" commit -qm expand
R=$T/shallow-base
git clone -q --no-local --depth=1 "file://$SOURCE" "$R"
if git -C "$R" cat-file -e "$BASE^{commit}" 2>/dev/null; then fail rollback-hazards 'shallow fixture already has base'; fi
out=$(check); rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *'rollback-safe ok'* ]] && [[ "$out" != *'no comparison base'* ]]; then
  ok rollback-hazards
else fail rollback-hazards "safe shallow comparison: $out (exit=$rc)"; fi
grep -qx "$BASE" "$R/.git/shallow" || fail rollback-hazards 'fetch did not keep base at depth one'
if git -C "$R" rev-parse --verify refs/tags/base-tag >/dev/null 2>&1; then fail rollback-hazards 'fetch brought a tag'; fi
git -C "$R" cat-file -e "$BASE^{commit}" 2>/dev/null || fail rollback-hazards 'missing base was not fetched'
# A second fresh clone must fetch and still reject a destructive migration.
R=$T/shallow-hazard
git clone -q --no-local --depth=1 "file://$SOURCE" "$R"
echo 'DROP TABLE users;' > "$R/db/0002.sql"
casecheck rollback-hazards 1 'DROP TABLE users'
git -C "$R" cat-file -e "$BASE^{commit}" 2>/dev/null || fail rollback-hazards 'hazard base was not fetched'
# A successfully recovered base keeps the existing draft hazard warning policy.
R=$T/shallow-draft
git clone -q --no-local --depth=1 "file://$SOURCE" "$R"
echo 'DROP TABLE users;' > "$R/db/0002.sql"
export ROLLBACK_DRAFT=true
casecheck rollback-hazards 0 'WARN: rollback'
unset ROLLBACK_DRAFT
git -C "$R" cat-file -e "$BASE^{commit}" 2>/dev/null || fail rollback-hazards 'draft base was not fetched'

# Push events carry no PR or merge-group base. Clone only the feature branch,
# leaving no origin/HEAD, origin/main or main and no base commit locally.
git -C "$SOURCE" checkout -qb feature
# Commit the hazard on the feature branch; origin's default stays safe main.
echo 'DROP TABLE users;' > "$SOURCE/db/0003.sql"
git -C "$SOURCE" add -A; git -C "$SOURCE" commit -qm destructive
# Restore the remote default branch without changing the feature commit.
git -C "$SOURCE" checkout -q main
R=$T/shallow-push
git clone -q --no-local --depth=1 --single-branch --branch feature "file://$SOURCE" "$R"
for ref in origin/HEAD origin/main main; do
  git -C "$R" rev-parse --verify "$ref" >/dev/null 2>&1 && fail rollback-push-base "fixture has $ref"
done
PUSH_BASE=$(git -C "$SOURCE" rev-parse main)
git -C "$R" cat-file -e "$PUSH_BASE^{commit}" 2>/dev/null && fail rollback-push-base 'fixture already has default base'
echo '{"ref":"refs/heads/feature"}' > "$T/push.json"
export GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$T/push.json"
BASE=
out=$(check); rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *'DROP TABLE users'* ]] && [[ "$out" != *'no comparison base'* ]] && [[ "$out" != *'NOTE: rollback'* ]]; then
  ok rollback-push-base
else fail rollback-push-base "push hazard skipped: $out (exit=$rc)"; fi
git -C "$R" cat-file -e "$PUSH_BASE^{commit}" 2>/dev/null || fail rollback-push-base 'default base was not fetched'
unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH

# Event bases are scoped to the real workflow checkout. Use a foreign SHA absent from the target.
repo event-scope
BASE=
git -C "$R" remote add origin "file://$SOURCE"
printf '{"pull_request":{"base":{"sha":"%s"}}}' 1111111111111111111111111111111111111111 > "$T/event.json"
export GITHUB_ACTIONS=true GITHUB_EVENT_PATH="$T/event.json" GITHUB_EVENT_NAME=pull_request GITHUB_WORKSPACE="$ENGINE" GITHUB_REPOSITORY=example-org/engine
casecheck rollback-push-base 0 'rollback-safe ok'
# Canonical workspace paths allow the checkout's own event; setup also accepts subdirectory callers.
ln -s "$R" "$T/workspace-link"
export GITHUB_WORKSPACE="$T/workspace-link"
casecheck rollback-hazards 1 'cannot fetch comparison base 1111111111111111111111111111111111111111 from origin:'
# A parsed origin with a different identity rejects the event even in the same workspace.
for url in https://example.com/example-org/target.git git@example.com:example-org/target.git ssh://git@example.com/example-org/target.git; do
  git -C "$R" remote set-url origin "$url"
  casecheck rollback-push-base 0 'rollback-safe ok'
done
export GITHUB_REPOSITORY=example-org/target
EVENT_BASE=$(git -C "$R" rev-parse HEAD)
echo 'DROP TABLE users;' > "$R/db/0002.sql"
git -C "$R" add -A; git -C "$R" commit -qm destructive
printf '{"pull_request":{"base":{"sha":"%s"}}}' "$EVENT_BASE" > "$T/event.json"
out=$(cd "$R/src" && ROLLBACK_BASE= ../scripts/agent/setup.sh --check 2>&1); rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *'DROP TABLE users'* ]]; then ok rollback-hazards; else fail rollback-hazards "own checkout subdirectory: $out"; fi
printf '{"merge_group":{"base_sha":"%s"}}' "$EVENT_BASE" > "$T/event.json"
casecheck rollback-hazards 1 'DROP TABLE users'
export GITHUB_WORKSPACE="$ENGINE"
casecheck rollback-push-base 0 'rollback-safe ok'
unset GITHUB_ACTIONS GITHUB_EVENT_PATH GITHUB_EVENT_NAME GITHUB_WORKSPACE GITHUB_REPOSITORY

repo unfetchable-base
BASE=1111111111111111111111111111111111111111
git -C "$R" remote add origin "file://$SOURCE"
out=$(check); rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *"rollback: cannot fetch comparison base $BASE from origin:"* ]] && [[ "$out" == *'not our ref'* ]]; then
  ok rollback-hazards
else fail rollback-hazards "unfetchable base: $out (exit=$rc)"; fi
# Draft hazard warnings must not turn a failed fetch into a pass.
export ROLLBACK_DRAFT=true
casecheck rollback-hazards 1 "cannot fetch comparison base $BASE from origin:"
unset ROLLBACK_DRAFT
# A remote other than origin must also fail closed.
git -C "$R" remote rename origin upstream
casecheck rollback-hazards 1 "comparison base $BASE missing locally and origin remote is unavailable"
# Git must treat a malformed comparison base as data, never as a fetch option.
git -C "$R" remote rename upstream origin
BASE="--upload-pack=touch $T/upload-pack-ran"
casecheck rollback-hazards 1 'cannot fetch comparison base'
[ ! -e "$T/upload-pack-ran" ] || fail rollback-hazards 'base was executed as a fetch option'

repo expand
printf '%s\n' '-- DROP TABLE users; ignored' 'AlTeR /* comment */ TABLE "users" ADD COLUMN extra TEXT;' "INSERT INTO users (extra) VALUES ('semi; DROP COLUMN old');" 'UPDATE users SET extra = old;' > "$R/db/0002.sql"
casecheck rollback-expand 0 'rollback-safe ok'
repo renamed-history
why=""
for table in users people; do
  printf '%s\n' 'CREATE TABLE users(id INTEGER, old TEXT);' 'ALTER TABLE users RENAME COLUMN old TO current;' > "$R/db/0001.sql"
  [ "$table" = users ] || echo 'ALTER TABLE users RENAME TO people;' >> "$R/db/0001.sql"
  git -C "$R" add -A; git -C "$R" commit -qm renamed; BASE=$(git -C "$R" rev-parse HEAD)
  for sql in "CREATE TABLE IF NOT EXISTS $table(id INTEGER, current TEXT); UPDATE $table SET current=NULL;" "CREATE TABLE $table(id INTEGER, unknown TEXT); UPDATE $table SET unknown=NULL;" "ALTER TABLE $table ADD COLUMN current TEXT; UPDATE $table SET current=NULL;"; do
    echo "$sql" > "$R/db/0002.sql"
    out=$(check); rc=$?
    [ "$rc" -eq 1 ] && [[ "$out" == *'UPDATE data rewrite'* ]] || why="$why; renamed history permitted rewrite: $out"
  done
  echo "ALTER TABLE $table ADD COLUMN extra TEXT; UPDATE $table SET extra=NULL;" > "$R/db/0002.sql"
  out=$(check); [ "$?" -eq 0 ] || why="$why; fresh column blocked: $out"
  rm "$R/db/0002.sql"
done
if [ -z "$why" ]; then ok rollback-renamed-history; else fail rollback-renamed-history "$why"; fi
repo schema-replace
why=""
for schema in 'CREATE TABLE settings(key TEXT PRIMARY KEY ON CONFLICT REPLACE, value TEXT);' 'CREATE TABLE settings(key TEXT, value TEXT, CONSTRAINT unique_key UNIQUE(key) ON CONFLICT REPLACE);' 'CREATE TABLE settings(key TEXT); ALTER TABLE settings ADD COLUMN value TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 1;' 'CREATE TABLE settings(key TEXT); ALTER TABLE settings RENAME TO archived_settings; CREATE TABLE settings(key TEXT PRIMARY KEY ON CONFLICT REPLACE, value TEXT);' 'CREATE TABLE settings(key TEXT); DROP TABLE settings; CREATE TABLE settings(key TEXT, value TEXT, UNIQUE(key) ON CONFLICT REPLACE);'; do
  echo "$schema ALTER TABLE settings RENAME TO preferences;" > "$R/db/0001.sql"
  git -C "$R" add -A; git -C "$R" commit -qm policy; BASE=$(git -C "$R" rev-parse HEAD)
  echo "INSERT INTO preferences VALUES('theme','default');" > "$R/db/0002.sql"
  out=$(check); rc=$?
  [ "$rc" -eq 1 ] && [[ "$out" == *'ON CONFLICT REPLACE data rewrite preferences'* ]] || why="$why; inherited replacement passed: $out"
  printf '%s\n' '-- contract: previous release retired preferences; issue #123' "INSERT INTO preferences VALUES('theme','default');" > "$R/db/0002.sql"
  echo '{"db/0002.sql":["preferences"]}' > "$R/rollback-contracts.json"
  out=$(check); [ "$?" -eq 0 ] && [[ "$out" == *'NOTE: contract'* ]] || why="$why; replacement contract blocked: $out"
  rm "$R/rollback-contracts.json"
  for policy in IGNORE ABORT FAIL ROLLBACK; do
    echo "INSERT OR $policy INTO preferences VALUES('theme','default');" > "$R/db/0002.sql"
    out=$(check); [ "$?" -eq 0 ] || why="$why; explicit $policy blocked: $out"
  done
  rm "$R/db/0002.sql"
done
if [ -z "$why" ]; then ok rollback-schema-replace; else fail rollback-schema-replace "$why"; fi
repo seeds
why=""
for definition in 'id INTEGER PRIMARY KEY, old TEXT' 'id INTEGER PRIMARY KEY ON CONFLICT REPLACE, old TEXT' 'id INTEGER PRIMARY KEY, old TEXT UNIQUE ON CONFLICT REPLACE'; do
  echo "CREATE TABLE users($definition);" > "$R/db/0001.sql"
  git -C "$R" add -A; git -C "$R" commit -qm seeds; BASE=$(git -C "$R" rev-parse HEAD)
  for clause in 'ON CONFLICT(id) DO NOTHING' 'ON CONFLICT DO NOTHING'; do
    echo "INSERT INTO users(id,old) VALUES(1,'seed') $clause;" > "$R/db/0002.sql"
    out=$(check); rc=$?
    if [[ "$definition" == *REPLACE* ]]; then
      [ "$rc" -eq 1 ] && [[ "$out" == *'ON CONFLICT REPLACE data rewrite users'* ]] || why="$why; replacing seed passed: $out"
    else
      [ "$rc" -eq 0 ] && [[ "$out" == *'rollback-safe ok'* ]] || why="$why; safe seed blocked: $out"
    fi
  done
  echo "INSERT INTO users(id,old) VALUES(1,'seed') ON CONFLICT(id) DO UPDATE SET old='seed';" > "$R/db/0002.sql"
  out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'rollback:'* ]] || why="$why; updating seed passed: $out"
  rm "$R/db/0002.sql"
done
if [ -z "$why" ]; then ok rollback-seed-do-nothing; else fail rollback-seed-do-nothing "$why"; fi
repo bootstrap
# Real Corepack/pnpm, with only system tools and Node/npm on PATH (no global pnpm/yarn).
mkdir -p "$T/clean-bin" "$R/dependency"
for tool in node npm npx; do ln -s "$(command -v "$tool")" "$T/clean-bin/$tool"; done
CLEAN_PATH="$T/clean-bin:/usr/bin:/bin"
cat > "$R/package.json" <<'PKG'
{"private":true,"packageManager":"pnpm@10.0.0","dependencies":{"local-dependency":"file:./dependency"},"scripts":{"build":"node build.mjs"}}
PKG
echo '{"name":"local-dependency","version":"1.0.0","main":"index.js"}' > "$R/dependency/package.json"
echo 'module.exports = 1;' > "$R/dependency/index.js"
cat > "$R/build.mjs" <<'JS'
import { appendFileSync, existsSync } from 'node:fs';
import dependency from 'local-dependency';
if (dependency !== 1 || !existsSync(process.env.COREPACK_HOME)) throw new Error('bootstrap environment lost');
appendFileSync(process.env.ROLLBACK_BUILD_LOG, `${process.cwd()}|${process.env.COREPACK_HOME}\n`);
JS
printf 'node_modules/\n' >> "$R/.gitignore"
(cd "$R" && PATH="$CLEAN_PATH" COREPACK_ENABLE_AUTO_PIN=0 npx --yes --package corepack@0.34.6 corepack pnpm install --lockfile-only) > "$T/lock.log" 2>&1 || fail rollback-build-bootstrap "cannot generate real lockfile: $(cat "$T/lock.log")"
node - "$R/standards.json" <<'JS'
const fs = require('node:fs'), file = process.argv[2];
const std = JSON.parse(fs.readFileSync(file));
std.build = 'pnpm run build';
fs.writeFileSync(file, JSON.stringify(std));
JS
git -C "$R" add -A; git -C "$R" commit -qm bootstrap; BASE=$(git -C "$R" rev-parse HEAD)
export ROLLBACK_BUILD_LOG="$T/builds.log"
out=$(PATH="$CLEAN_PATH" check); rc=$?
why=""
[ "$rc" -eq 0 ] && [[ "$out" == *'rollback-safe ok'* ]] || why="clean PATH comparison failed: $out"
node - "$ROLLBACK_BUILD_LOG" "$R" <<'JS'
const fs=require('node:fs'), assert=require('node:assert/strict');
const rows=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(s=>s.split('|'));
assert.equal(rows.length,2); assert.equal(rows[0][0],fs.realpathSync(process.argv[3])); assert.notEqual(rows[1][0],rows[0][0]);
assert.equal(rows[0][1],rows[1][1]); assert.ok(!fs.existsSync(rows[0][1]), 'temporary Corepack environment must be cleaned');
JS
[ "$?" -eq 0 ] || why="$why; both revision builds did not retain the bootstrap environment"
if [ -z "$why" ]; then ok rollback-build-bootstrap; else fail rollback-build-bootstrap "$why"; fi
unset ROLLBACK_BUILD_LOG
repo nested-update
echo "ALTER TABLE users ADD COLUMN extra TEXT; UPDATE users SET extra = (SELECT 'new' WHERE 1), old = NULL;" > "$R/db/0002.sql"
casecheck rollback-nested-update 1 'UPDATE data rewrite'
repo persistent-sql
why=""
for spec in 'legacy_users|DROP VIEW legacy_users;' 'users|CREATE UNIQUE INDEX unique_old ON users(old);' 'users|CREATE TRIGGER erase AFTER INSERT ON users BEGIN DELETE FROM users; END;' 'users|REINDEX users;' 'users|CREATE TABLE trigger (begin TEXT); DROP TABLE users;' 'users|CREATE VIEW trigger AS SELECT 1 AS begin; DELETE FROM users;' 'users|CREATE TABLE things (begin TEXT); CREATE TRIGGER begin AFTER INSERT ON things WHEN new.begin = 1 BEGIN UPDATE things SET begin = 2; END; DROP TABLE users;' 'users|CREATE TABLE things (begin TEXT); CREATE TRIGGER erase AFTER INSERT ON things WHEN new.begin = 1 BEGIN DELETE FROM users; END;'; do
  object=${spec%%|*}; sql=${spec#*|}
  echo "$sql" > "$R/db/0002.sql"; git -C "$R" add -A
  out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'contract requires'* ]] || why="$why; unsafe SQL passed: $sql"
  printf '%s\n' '-- contract: previous release retired object; issue #123' "$sql" > "$R/db/0002.sql"
  printf '{"db/0002.sql":["%s"]}\n' "$object" > "$R/rollback-contracts.json"
  out=$(check); [ "$?" -eq 0 ] && [[ "$out" == *'NOTE: contract'* ]] || why="$why; listed contract failed: $out"
  rm "$R/rollback-contracts.json"
done
# A trigger on a fresh table still needs a contract for existing data touched by its body.
printf '%s\n' '-- contract: previous release retired things; issue #123' 'CREATE TABLE things (id INTEGER); CREATE TRIGGER erase AFTER INSERT ON things BEGIN DELETE FROM users; END;' > "$R/db/0002.sql"
echo '{"db/0002.sql":["things"]}' > "$R/rollback-contracts.json"
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'DELETE data rewrite users'* ]] || why="$why; trigger body target skipped: $out"
echo '{"db/0002.sql":["things","users"]}' > "$R/rollback-contracts.json"
out=$(check); [ "$?" -eq 0 ] && [[ "$out" == *'NOTE: contract'* ]] || why="$why; complete trigger contract failed: $out"
printf '%s\n' 'CREATE TABLE things (id INTEGER); CREATE UNIQUE INDEX unique_id ON things(id); CREATE TRIGGER fill AFTER INSERT ON things BEGIN UPDATE things SET id = 1; END;' > "$R/db/0002.sql"
rm "$R/rollback-contracts.json"
out=$(check); [ "$?" -eq 0 ] || why="$why; new-table constraints failed: $out"
if [ -z "$why" ]; then ok rollback-persistent-sql; else fail rollback-persistent-sql "$why"; fi
repo generated
cp "$ENGINE/test/fixtures/release-astro/"{build.mjs,package.json,wrangler.jsonc} "$R/"
mv "$R/db" "$R/migrations"
printf 'dist/\n.wrangler/\nnode_modules/\n' >> "$R/.gitignore"
export RELEASE_LOG=$T/generated.log GENERATED_RESOURCE=1 ISOLATE_GENERATED_RESOURCE=1
git -C "$R" add -A; git -C "$R" commit -qm generated; BASE=$(git -C "$R" rev-parse HEAD)
echo 'DROP TABLE users;' > "$R/migrations/0002.sql"
casecheck rollback-generated-production 1 'DROP TABLE users'
out=$(cd "$R" && ROLLBACK_BASE=$BASE node scripts/agent/gate.mjs run build 2>&1); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *'DROP TABLE users'* ]] || fail rollback-generated-production "gate build skipped comparison: $out (exit=$rc)"
rm "$R/migrations/0002.sql"
# Removing a build-only binding must compare against the base build, even without a redirect at entry.
sed '/if (process.env.GENERATED_RESOURCE)/s/process.env.GENERATED_RESOURCE/false/' "$R/build.mjs" > "$T/build"; cp "$T/build" "$R/build.mjs"
rm -rf "$R/dist" "$R/.wrangler"
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'removed production binding d1_databases GENERATED_DB'* ]] || fail rollback-generated-production "base build binding skipped: $out"
# Build-emitted SQL must retain base history as well as expose new destructive files.
git -C "$R" checkout "$BASE" -- build.mjs
node - "$R/build.mjs" <<'JS'
const fs=require('fs'), f=process.argv[2];
let s=fs.readFileSync(f,'utf8');
s='import { cpSync } from "node:fs";\n'+s;
s=s.replace('writeFileSync("dist/server/wrangler.json",', 'cpSync("migrations", "dist/server/db", { recursive: true }); for (const db of cfg.d1_databases ?? []) db.migrations_dir = "db";\nwriteFileSync("dist/server/wrangler.json",');
fs.writeFileSync(f,s);
JS
git -C "$R" add -A; git -C "$R" commit -qm emitted; BASE=$(git -C "$R" rev-parse HEAD)
echo 'DROP TABLE users;' > "$R/migrations/0002.sql"
out=$(check); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *'dist/server/db/0002.sql: DROP TABLE users'* ]] || fail rollback-generated-production "emitted SQL skipped: $out (exit=$rc)"
echo 'UPDATE users SET old = NULL;' > "$R/migrations/0002.sql"
out=$(check); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *'UPDATE data rewrite'* ]] || fail rollback-generated-production "emitted base history skipped: $out (exit=$rc)"
unset GENERATED_RESOURCE ISOLATE_GENERATED_RESOURCE RELEASE_LOG
repo cross-worker
mkdir -p "$R/workers"
cat > "$R/workers/host.jsonc" <<'CFG'
{"name":"host","main":"../src/index.js","migrations":[{"tag":"v1","new_classes":["Counter"]}],"previews":{},"env":{"staging":{"routes":[]}}}
CFG
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.release_workers=["workers/host.jsonc"];fs.writeFileSync(f,JSON.stringify(o))' "$R/standards.json"
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.durable_objects.bindings[0].script_name="host";o.env.staging.durable_objects.bindings[0].script_name="host-staging";fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc"
git -C "$R" add -A; git -C "$R" commit -qm dependency; BASE=$(git -C "$R" rev-parse HEAD)
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.durable_objects.bindings[0].class_name="NewCounter";o.env.staging.durable_objects.bindings[0].class_name="NewCounter";fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc"
echo 'export class NewCounter {}' > "$R/src/index.js"
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.migrations.push({tag:"v2",deleted_classes:["Counter"]});fs.writeFileSync(f,JSON.stringify(o))' "$R/workers/host.jsonc"
casecheck rollback-cross-worker-do 1 'removed or renamed Durable Object class Counter'
# Namespace migrations must fail even if the previous class export is retained.
echo 'export class Counter {}; export class NewCounter {}' > "$R/src/index.js"
for migration in '{"tag":"v2","deleted_classes":["Counter"]}' '{"tag":"v2","renamed_classes":[{"from":"Counter","to":"NewCounter"}]}'; do
  node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.migrations[1]=JSON.parse(process.argv[2]);fs.writeFileSync(f,JSON.stringify(o))' "$R/workers/host.jsonc" "$migration"
  out=$(check); rc=$?
  [ "$rc" -eq 1 ] && [[ "$out" == *'Counter deleted_classes/renamed_classes'* ]] || fail rollback-cross-worker-do "host namespace migration passed: $out (exit=$rc)"
done
# An unnamed env.production host resolves as <name>-production.
git -C "$R" checkout "$BASE" -- workers/host.jsonc wrangler.jsonc src/index.js
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.env.production={};fs.writeFileSync(f,JSON.stringify(o))' "$R/workers/host.jsonc"
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.durable_objects.bindings[0].script_name="host-production";fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc"
git -C "$R" add -A; git -C "$R" commit -qm environment; BASE=$(git -C "$R" rev-parse HEAD)
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.env.production.migrations=[...o.migrations,{tag:"v2",deleted_classes:["Counter"]}];fs.writeFileSync(f,JSON.stringify(o))' "$R/workers/host.jsonc"
out=$(check); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *'Counter deleted_classes/renamed_classes'* ]] || fail rollback-cross-worker-do "production environment dependency skipped: $out (exit=$rc)"
repo drop
echo 'ALTER TABLE users ADD COLUMN extra TEXT; aLtEr TABLE [users] DROP /* x */ COLUMN `old`;' > "$R/db/0002.sql"
casecheck rollback-drop-column 1 'split into expand now, contract in a later release'
repo rename
echo 'ALTER TABLE users RENAME COLUMN old TO newer; ALTER TABLE users RENAME TO people;' > "$R/db/0002.sql"
casecheck rollback-rename 1 'RENAME'
repo contract
printf '%s\n' '-- contract: previous release retired users.old; issue #123' 'ALTER TABLE users DROP COLUMN old;' > "$R/db/0002.sql"
echo '{"db/0002.sql":["users.old"]}' > "$R/rollback-contracts.json"
casecheck rollback-contract 0 'NOTE: contract'
# Missing link or object declaration must not grant the exception.
sed 's/issue #123/no link/' "$R/db/0002.sql" > "$T/no-link"; cp "$T/no-link" "$R/db/0002.sql"
out=$(check); rc=$?
if [ "$rc" -ne 1 ]; then fail rollback-contract 'contract without link passed'; fi
repo do
echo 'export class Other {}' > "$R/src/index.js"
casecheck rollback-do-removal 1 'Durable Object class Counter'
repo binding
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));delete o.d1_databases;fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc"
casecheck rollback-production-binding 1 'production binding d1_databases DB'
repo draft
echo 'DROP TABLE users;' > "$R/db/0002.sql"
export ROLLBACK_DRAFT=true
casecheck rollback-draft 0 'WARN: rollback'
unset ROLLBACK_DRAFT
# The checks job carries plan context into the same real offline entry point.
if ! rg -q 'ROLLBACK_BASE:.*steps.plan.outputs.rollback_base' "$R/.github/workflows/std-gate.yml"; then fail rollback-draft 'checks job lacks PR context'; fi
why=""
repo hazards
for sql in 'WITH ids AS (SELECT 1 AS id) INSERT OR REPLACE INTO users (id, old) SELECT id, 2 FROM ids;' 'ALTER TABLE users ADD COLUMN "default" TEXT NOT NULL;' 'INSERT OR REPLACE INTO users (id, old) VALUES (1, 2);' 'DROP TABLE users;' 'UPDATE users SET old = id;' 'DELETE FROM users;' 'ALTER TABLE users ALTER COLUMN old TYPE INTEGER;' 'ALTER TABLE users ADD COLUMN required TEXT NOT NULL;' 'ALTER TABLE users ADD COLUMN required TEXT NOT NULL DEFAULT NULL;' 'WITH ids AS (SELECT id FROM users) UPDATE users SET old = id;' 'CREATE TABLE IF NOT EXISTS users (id INTEGER, old TEXT); UPDATE users SET old = id;'; do
  printf '%s\n' "$sql" > "$R/db/0002.sql"; git -C "$R" add -A
  out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'rollback:'* ]] || why="$why; unsafe SQL passed: $sql $out"
done
printf '%s\n' 'CREATE TABLE things (id INTEGER); UPDATE things SET id = 1; ALTER TABLE users ADD COLUMN required TEXT NOT NULL DEFAULT "value";' > "$R/db/0002.sql"
out=$(check); [ "$?" -eq 0 ] || why="$why; new schema failed: $out"
printf '%s\n' '-- contract: retired; #123' 'ALTER TABLE users DROP COLUMN old;' > "$R/db/0002.sql"
echo '{"db/0002.sql":["users.id"]}' > "$R/rollback-contracts.json"
out=$(check); [ "$?" -eq 1 ] || why="$why; unlisted contract passed"
printf '%s\n' '-- contract: #123' 'DROP TABLE users;' > "$R/db/0002.sql"
echo '{"db/0002.sql":["users"]}' > "$R/rollback-contracts.json"
out=$(check); [ "$?" -eq 1 ] || why="$why; reasonless contract passed"
rm "$R/db/0002.sql" "$R/rollback-contracts.json"
for migration in '{"tag":"v2","deleted_classes":["Counter"]}' '{"tag":"v2","renamed_classes":[{"from":"Counter","to":"NewCounter"}]}'; do
  git -C "$R" checkout "$BASE" -- wrangler.jsonc
  node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.migrations.push(JSON.parse(process.argv[2]));fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc" "$migration"
  out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'Durable Object class Counter'* ]] || why="$why; DO contract passed: $out"
done
for kind in kv_namespaces r2_buckets queues.producers services durable_objects.bindings; do
  git -C "$R" checkout "$BASE" -- wrangler.jsonc
  node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f)),k=process.argv[2].split(".");let p=o;for(const x of k.slice(0,-1))p=p[x]??={};p[k.at(-1)]=[{binding:"OLD",name:"OLD",class_name:"Counter"}];fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc" "$kind"
  git -C "$R" add -A; git -C "$R" commit -qm binding; BASE=$(git -C "$R" rev-parse HEAD)
  node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f)),k=process.argv[2].split(".");let p=o;for(const x of k.slice(0,-1))p=p[x];p[k.at(-1)]=[];fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc" "$kind"
  out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *"removed production binding $kind"* ]] || why="$why; binding passed: $kind $out"
done
repo exports
printf '%s\n' 'export const Counter = class {};' > "$R/src/index.js"
git -C "$R" add -A; git -C "$R" commit -qm exports; BASE=$(git -C "$R" rev-parse HEAD)
printf '%s\n' 'export const Other = class {};' > "$R/src/index.js"
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'Durable Object class Counter'* ]] || why="$why; expression class removal passed: $out"
repo star
printf '%s\n' "export * from './counter.js';" > "$R/src/index.js"
printf '%s\n' 'export class Counter {}' > "$R/src/counter.js"
git -C "$R" add -A; git -C "$R" commit -qm star; BASE=$(git -C "$R" rev-parse HEAD)
printf '%s\n' 'export class Other {}' > "$R/src/counter.js"
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'Durable Object class Counter'* ]] || why="$why; star class removal passed: $out"
repo history
rm "$R/db/0001.sql"; git -C "$R" add -A
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'historical D1 migration removed'* ]] || why="$why; history removal passed: $out"
repo staging
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.env.staging.d1_databases[0].database_id="another-stage";o.previews.d1_databases[0].database_id="another-stage";fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc"
out=$(check); [ "$?" -eq 0 ] || why="$why; staging-only binding change failed: $out"
repo defaults
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));delete o.d1_databases[0].migrations_dir;fs.writeFileSync(f,JSON.stringify(o));fs.renameSync(process.argv[2]+"/db",process.argv[2]+"/migrations")' "$R/wrangler.jsonc" "$R"
git -C "$R" add -A; git -C "$R" commit -qm defaults; BASE=$(git -C "$R" rev-parse HEAD)
printf '%s\n' 'DROP TABLE users;' > "$R/migrations/0002.sql"
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'DROP TABLE users'* ]] || why="$why; default migrations directory skipped: $out"
repo secondary
mv "$R/wrangler.jsonc" "$R/worker.config.jsonc"
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.release_workers=["worker.config.jsonc"];fs.writeFileSync(f,JSON.stringify(o))' "$R/standards.json"
git -C "$R" add -A; git -C "$R" commit -qm secondary; BASE=$(git -C "$R" rev-parse HEAD)
printf '%s\n' 'DROP TABLE users;' > "$R/db/0002.sql"
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'DROP TABLE users'* ]] || why="$why; secondary migrations skipped: $out"
repo production
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));o.env.production={d1_databases:o.d1_databases};fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc"
git -C "$R" add -A; git -C "$R" commit -qm production; BASE=$(git -C "$R" rev-parse HEAD)
node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));delete o.d1_databases;fs.writeFileSync(f,JSON.stringify(o))' "$R/wrangler.jsonc"
out=$(check); [ "$?" -eq 1 ] && [[ "$out" == *'removed production binding d1_databases'* ]] || why="$why; root binding hidden by env.production: $out"
if [ -z "$why" ]; then ok rollback-hazards; else fail rollback-hazards "$why"; fi
done_cases
