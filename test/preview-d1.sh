#!/usr/bin/env bash
# `release.mjs preview` migrates the D1 databases a `previews` block dedicates to Previews (neither a production nor a staging
# database of any declared Worker) before it deploys the Preview; it never migrates a staging database, and refuses a production one.
# The stub wrangler records every call and, for `d1` calls, the config it was given. Nothing here touches real Cloudflare.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GH_TOKEN GITHUB_TOKEN GITHUB_REPOSITORY GITHUB_EVENT_PATH GITHUB_EVENT_NAME OP_CLI OP_VAULT OP_SERVICE_ACCOUNT_TOKEN SENTRY_AUTH_TOKEN WRANGLER_CI_OVERRIDE_NAME WORKERS_CI_BRANCH
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"; chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
commit() { gc -C "$R" add -A && gc -C "$R" commit -qm "${1:-change}"; }
# calls: every wrangler call in order, the generated config's directory shown as <tmp>
calls() { node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(x=>x.args);console.log(l.map(x=>x.args.join(" ").replace(/--config \S*release-[A-Za-z0-9]+\/\S+/,"--config <tmp>")).join("\n"))' "$RELEASE_LOG"; }
# d1config: the config the migration call was given, as {binding: [database_name, database_id, migrations_dir]}
d1config() { node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(x=>x.d1config);const c=l[0]?.d1config??{};console.log(JSON.stringify({keys:Object.keys(c).sort(),account:c.account_id??null,d1:(c.d1_databases??[]).map(d=>[d.binding,d.database_name,d.database_id,d.migrations_dir])}))' "$RELEASE_LOG"; }
check() { (cd "$R" && scripts/agent/setup.sh --check 2>&1); echo "exit=$?"; }
D1P='"d1_databases": [{ "binding": "DB", "database_name": "app-prod", "database_id": "app-prod-id", "migrations_dir": "migrations" }]'
D1S='"d1_databases": [{ "binding": "DB", "database_name": "app-stg", "database_id": "app-stg-id", "migrations_dir": "migrations" }]'
D1X='"d1_databases": [{ "binding": "DB", "database_name": "app-pr", "database_id": "app-pr-id", "migrations_dir": "migrations" }]'
# repo <name> <previews block>: a root Worker with production and staging databases and migrations
repo() {
  R=$(cd "$T" && pwd -P)/$1; git init -q -b main "$R"; node bin/repo-standards.mjs apply --target "$R" --overlay "$ENGINE/examples/overlay.json" --version 0.8.9 >/dev/null
  export RELEASE_LOG=$T/$1.log; : >"$RELEASE_LOG"
  mkdir -p "$R/node_modules/.bin" "$R/src" "$R/migrations"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"; echo "select 1;" >"$R/migrations/0001.sql"
  printf '{ "name": "app", "main": "src/index.js", "account_id": "acct1", %s, "env": { "staging": { "routes": [], "workers_dev": true, %s } }, "previews": %s }\n' "$D1P" "$D1S" "$2" >"$R/wrangler.jsonc"
  printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"; commit fixture
}
preview() { (cd "$R" && WORKERS_CI_BRANCH=feat/x node scripts/agent/release.mjs preview "$@" 2>&1); echo "exit=$?"; }

# ---- a dedicated Preview database is migrated before the Preview deploys, through a config holding only that binding
why=""
repo dedicated "{ $D1X }"
out=$(preview)
want=$(printf 'd1 migrations apply DB --remote --config <tmp>\npreview --name feat-x')
has "exit=0" "$out" && [ "$(calls)" = "$want" ] || why="calls: $out // $(calls)"
[ "$(d1config)" = '{"keys":["account_id","d1_databases"],"account":"acct1","d1":[["DB","app-pr","app-pr-id","'"$R"'/migrations"]]}' ] || why="$why; config: $(d1config)"
out=$(check); has "exit=0" "$out" || why="$why; dedicated database fails --check: $out"
if [ -z "$why" ]; then ok release-preview-d1-dedicated; else fail release-preview-d1-dedicated "$why"; fi

# ---- a Preview sharing staging's database never migrates it (main does), and an existing previews == staging repository is unchanged
why=""
repo shared "{ $D1S }"
out=$(preview)
[ "$(calls)" = "preview --name feat-x" ] && has "exit=0" "$out" || why="shared: $out // $(calls)"
out=$(check); has "exit=0" "$out" || why="$why; shared database fails --check: $out"
# a repository with no env.staging deploys its staging Preview from this same block: that database is staging's too
repo legacy "{ $D1X }"; jset "$R/wrangler.jsonc" 'delete o.env'; commit legacy; : >"$RELEASE_LOG"
out=$(preview)
[ "$(calls)" = "preview --name feat-x" ] && has "exit=0" "$out" || why="$why; no env.staging: $out // $(calls)"
if [ -z "$why" ]; then ok release-preview-d1-shared-staging; else fail release-preview-d1-shared-staging "$why"; fi

# ---- a Preview bound to the production database is refused before any remote command, and --check refuses it
why=""
repo prod "{ $D1P }"
out=$(preview)
has "exit=1" "$out" && has "production" "$out" && [ -z "$(calls)" ] || why="prod: $out // $(calls)"
out=$(check); has "exit=1" "$out" && has "production" "$out" || why="$why; check: $out"
if [ -z "$why" ]; then ok release-preview-d1-production-refused; else fail release-preview-d1-production-refused "$why"; fi

# ---- a declared Worker's Preview migrates its dedicated database with the generated config, not its own --config, and a
# database that is another declared Worker's staging database is not migrated
why=""
repo decl "{ $D1X }"
mkdir -p "$R/workers/web/migrations"; echo "select 1;" >"$R/workers/web/migrations/0001.sql"
mv "$R/wrangler.jsonc" "$R/wrangler.api.jsonc"
printf '{ "name": "web", "main": "../../src/index.js", "d1_databases": [{ "binding": "WDB", "database_name": "web-prod", "database_id": "web-prod-id" }], "env": { "staging": { "routes": [], "workers_dev": true, "d1_databases": [{ "binding": "WDB", "database_name": "web-stg", "database_id": "web-stg-id" }] } }, "previews": { "d1_databases": [{ "binding": "WDB", "database_name": "web-pr", "database_id": "web-pr-id" }] } }\n' >"$R/workers/web/wrangler.jsonc"
jset "$R/standards.json" 'o.workers=["workers/web","wrangler.api.jsonc"]'; commit declared
: >"$RELEASE_LOG"; out=$(cd "$R" && WRANGLER_CI_OVERRIDE_NAME=web WORKERS_CI_BRANCH=feat/x node scripts/agent/release.mjs preview 2>&1; echo "exit=$?")
want=$(printf 'd1 migrations apply WDB --remote --config <tmp>\npreview --name feat-x --config workers/web/wrangler.jsonc')
has "exit=0" "$out" && [ "$(calls)" = "$want" ] || why="web: $out // $(calls)"
[ "$(d1config)" = '{"keys":["d1_databases"],"account":null,"d1":[["WDB","web-pr","web-pr-id","'"$R"'/workers/web/migrations"]]}' ] || why="$why; web config: $(d1config)"
sed -i.bak 's/"database_name": "web-pr", "database_id": "web-pr-id"/"database_name": "app-stg", "database_id": "app-stg-id"/' "$R/workers/web/wrangler.jsonc"; rm "$R/workers/web/wrangler.jsonc.bak"; commit other-staging
: >"$RELEASE_LOG"; out=$(cd "$R" && WRANGLER_CI_OVERRIDE_NAME=web WORKERS_CI_BRANCH=feat/x node scripts/agent/release.mjs preview 2>&1; echo "exit=$?")
[ "$(calls)" = "preview --name feat-x --config workers/web/wrangler.jsonc" ] && has "exit=0" "$out" || why="$why; another Worker's staging database: $out // $(calls)"
if [ -z "$why" ]; then ok release-preview-d1-declared; else fail release-preview-d1-declared "$why"; fi

done_cases
