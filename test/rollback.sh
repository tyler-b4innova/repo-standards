#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent CI=true
unset GITHUB_EVENT_PATH ROLLBACK_BASE ROLLBACK_DRAFT
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
repo expand
printf '%s\n' '-- DROP TABLE users; ignored' 'AlTeR /* comment */ TABLE "users" ADD COLUMN extra TEXT;' "INSERT INTO users (extra) VALUES ('semi; DROP COLUMN old');" 'UPDATE users SET extra = old;' > "$R/db/0002.sql"
casecheck rollback-expand 0 'rollback-safe ok'
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
