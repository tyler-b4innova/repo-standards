#!/usr/bin/env bash
# Declared Workers (standards.json "workers"): several Wrangler configs in one repository, each released by its own Workers Builds
# trigger from the repository root, through release.mjs with the stub wrangler. Nothing here touches real Cloudflare.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap '{ [ -n "${WORLD_PID:-}" ] && kill $WORLD_PID; } 2>/dev/null; rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GH_TOKEN GITHUB_TOKEN GITHUB_REPOSITORY GITHUB_EVENT_PATH GITHUB_EVENT_NAME OP_CLI OP_VAULT OP_SERVICE_ACCOUNT_TOKEN SENTRY_AUTH_TOKEN WRANGLER_CI_OVERRIDE_NAME WORKERS_CI_BRANCH
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"; chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
STAGING='"env": { "staging": { "routes": [], "workers_dev": true } }, "previews": {}'
commit() { gc -C "$R" add -A && gc -C "$R" commit -qm "${1:-change}"; }
sha() { git -C "$R" rev-parse HEAD; }
calls() { node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(x=>x.args);console.log(l.map(x=>x.args.join(" ").split(process.argv[2]+"/").join("")).join("\n"))' "$RELEASE_LOG" "$R"; }
# names <first-arg> [second-arg]: the Worker each call of that kind targeted, in order
names() { node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(x=>x.args&&x.args[0]===process.argv[2]&&(!process.argv[3]||x.args[1]===process.argv[3]));console.log(l.map(x=>x.name).join(","))' "$RELEASE_LOG" "$1" "${2:-}"; }
# repo <name>: a git repo with the pack applied and three Worker configs: wrangler.api.jsonc (a named file at the root) with the supporting
# Worker workers/jobs, and workers/web (a directory). Only what standards.json "workers" declares is a primary.
repo() {
  R=$T/$1; git init -q -b main "$R"; node bin/repo-standards.mjs apply --target "$R" --overlay "$ENGINE/examples/overlay.json" --version 0.8.3 >/dev/null
  export RELEASE_LOG=$T/$1.log; : >"$RELEASE_LOG"
  mkdir -p "$R/node_modules/.bin" "$R/workers/web" "$R/workers/jobs" "$R/src"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"
  printf '{ "name": "api", "main": "src/index.js", %s }\n' "$STAGING" >"$R/wrangler.api.jsonc"
  printf '{ "name": "web", "main": "../../src/index.js", %s }\n' "$STAGING" >"$R/workers/web/wrangler.jsonc"
  printf '{ "name": "jobs", "main": "../../src/index.js", %s }\n' "$STAGING" >"$R/workers/jobs/wrangler.jsonc"
  jset "$R/standards.json" 'o.workers=["workers/web",{config:"wrangler.api.jsonc",release_workers:["workers/jobs/wrangler.jsonc"]}]'
  printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"; commit fixture
}
main() { (cd "$R" && WORKERS_CI_COMMIT_SHA=$(sha) node scripts/agent/release.mjs main "$@" 2>&1); echo "exit=$?"; }

# ---- each declared Worker releases on its own trigger: WRANGLER_CI_OVERRIDE_NAME (the Worker's name, set in every Workers Builds build)
# selects it; its supporting Workers go first, then it; the other declared Worker is not touched
why=""
repo two
: >"$RELEASE_LOG"; out=$(WRANGLER_CI_OVERRIDE_NAME=api main)
[ "$(names deploy)" = "jobs-staging,api-staging" ] && [ "$(names versions upload)" = "jobs,api" ] && has "exit=0" "$out" || why="api: deploys=$(names deploy) uploads=$(names versions upload): $out"
# the named root-level file is passed explicitly to the primary's upload, and nothing named web ran
calls | grep -q '^versions upload --config wrangler.api.jsonc' && ! calls | grep -q 'web' || why="$why; api upload config: $(calls)"
: >"$RELEASE_LOG"; out=$(WRANGLER_CI_OVERRIDE_NAME=web main)
[ "$(names deploy)" = "web-staging" ] && [ "$(names versions upload)" = "web" ] && has "exit=0" "$out" || why="$why; web: deploys=$(names deploy) uploads=$(names versions upload): $out"
calls | grep -q '^versions upload --config workers/web/wrangler.jsonc' && ! calls | grep -qE 'api|jobs' || why="$why; web upload config: $(calls)"
if [ -z "$why" ]; then ok release-declared-workers; else fail release-declared-workers "$why"; fi

# ---- a build must know which declared Worker it is for: no match, no name at all, or a --worker that disagrees refuses before any
# remote command; a local run names the Worker with --worker
why=""
: >"$RELEASE_LOG"; out=$(WRANGLER_CI_OVERRIDE_NAME=nope main)
has "exit=1" "$out" && has "nope" "$out" && [ -z "$(calls)" ] || why="unknown name: $out $(calls)"
: >"$RELEASE_LOG"; out=$(main)
has "exit=1" "$out" && has "--worker" "$out" && has "WRANGLER_CI_OVERRIDE_NAME" "$out" && [ -z "$(calls)" ] || why="$why; no name: $out $(calls)"
: >"$RELEASE_LOG"; out=$(WRANGLER_CI_OVERRIDE_NAME=api main --worker web)
has "exit=1" "$out" && [ -z "$(calls)" ] || why="$why; disagreement: $out $(calls)"
: >"$RELEASE_LOG"; out=$(main --worker web)
[ "$(names deploy)" = "web-staging" ] && has "exit=0" "$out" || why="$why; --worker: $out $(calls)"
# an undeclared config is never a primary, even one named like a Worker, and a name two declared Workers share is refused when declaring
: >"$RELEASE_LOG"; out=$(WRANGLER_CI_OVERRIDE_NAME=jobs main)
has "exit=1" "$out" && [ -z "$(calls)" ] || why="$why; a supporting Worker was selected as a primary: $out $(calls)"
if [ -z "$why" ]; then ok release-declared-selection; else fail release-declared-selection "$why"; fi

# ---- the release/<sha> path works per declared Worker with the same provenance check and steps; production D1 migrations run there
# only, never in the main build (whose D1 migrations are staging's own databases)
why=""
echo '{}' >"$T/state.json"
node test/stubs/promote-world.mjs "$T/port" "$T/state.json" & WORLD_PID=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
export CLOUDFLARE_API_BASE="http://127.0.0.1:$(cat "$T/port")/cf" CLOUDFLARE_API_TOKEN=t CLOUDFLARE_ACCOUNT_ID=acct
repo rel
D1='"d1_databases": [{ "binding": "DB", "database_name": "d", "database_id": "x", "migrations_dir": "migrations" }]'
D1S='"d1_databases": [{ "binding": "DB", "database_name": "d-staging", "database_id": "y", "migrations_dir": "migrations" }]'
printf '{ "name": "web", "main": "../../src/index.js", %s, "env": { "staging": { "routes": [], "workers_dev": true, %s } }, "previews": { %s } }\n' "$D1" "$D1S" "$D1S" >"$R/workers/web/wrangler.jsonc"
mkdir -p "$R/workers/web/migrations"; echo "select 1;" >"$R/workers/web/migrations/0001.sql"; commit d1
git init -q --bare "$T/rel.git"; gc -C "$R" remote add origin "$T/rel.git"; gc -C "$R" push -q origin main
S=$(sha)
node -e 'const s=JSON.parse(process.argv[2]);const v=(id)=>[{id,annotations:{"workers/tag":process.argv[1]}}];require("fs").writeFileSync(process.argv[3],JSON.stringify({scripts:[{id:"api"},{id:"jobs"},{id:"web"}],versions:{api:v("va"),jobs:v("vj"),web:v("vw")}}))' "$S" '{}' "$T/state.json"
: >"$RELEASE_LOG"; out=$(WRANGLER_CI_OVERRIDE_NAME=web main)
! calls | grep '^d1 ' | grep -vq -- '--env staging' && calls | grep -q '^d1 migrations apply DB --env staging' || why="main build touched production D1: $out // $(calls)"
prom() { (cd "$R" && WRANGLER_CI_OVERRIDE_NAME=$1 WORKERS_CI_BRANCH=release/$S WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs preview 2>&1); echo "exit=$?"; }
: >"$RELEASE_LOG"; out=$(prom web)
changes=$(calls | grep -vE -- '--dry-run|^versions list|^secret list')
has "exit=0" "$out" && has "promoted ${S:0:7}" "$out" && [ "$(printf '%s\n' "$changes" | cut -d' ' -f1-3 | tr '\n' ',')" = "d1 migrations apply,versions deploy vw@100%," ] \
  && printf '%s\n' "$changes" | grep -q -- '^d1 migrations apply DB --config .*workers/web/wrangler.jsonc --remote$' && ! calls | grep -qE 'api|jobs' || why="$why; web: $out // $changes"
: >"$RELEASE_LOG"; out=$(prom api)
changes=$(calls | grep -vE -- '--dry-run|^versions list|^secret list')
has "exit=0" "$out" && [ "$(printf '%s\n' "$changes" | cut -d' ' -f1-3 | tr '\n' ',')" = "versions deploy vj@100%,versions deploy va@100%," ] && ! calls | grep -qE '^d1 |web' || why="$why; api: $out // $changes"
# an unknown name promotes nothing
: >"$RELEASE_LOG"; out=$(prom nope)
has "exit=1" "$out" && [ -z "$(calls)" ] || why="$why; unknown: $out // $(calls)"
if [ -z "$why" ]; then ok release-declared-promote; else fail release-declared-promote "$why"; fi

done_cases
