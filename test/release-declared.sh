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

# ---- a declared primary's Preview never binds production resources, its own or another declared Worker's: the preview trigger refuses
# before any remote command, and setup --check refuses the same configuration; a clean one deploys with its own --config
why=""
repo prev
D1='"d1_databases": [{ "binding": "DB", "database_name": "web-prod", "database_id": "web-prod-id" }]'
AUTH='"d1_databases": [{ "binding": "AUTH", "database_name": "auth-stg", "database_id": "auth-stg-id" }]'
printf '{ "name": "api", "main": "src/index.js", "d1_databases": [{ "binding": "AUTH", "database_name": "auth-prod", "database_id": "auth-prod-id" }], "env": { "staging": { "routes": [], "workers_dev": true, %s } }, "previews": { %s } }\n' "$AUTH" "$AUTH" >"$R/wrangler.api.jsonc"
prev() { # prev <previews block for web>: web's config with that previews block
  printf '{ "name": "web", "main": "../../src/index.js", %s, "env": { "staging": { "routes": [], "workers_dev": true, "d1_databases": [{ "binding": "DB", "database_name": "web-stg", "database_id": "web-stg-id" }] } }, "previews": %s }\n' "$D1" "$1" >"$R/workers/web/wrangler.jsonc"; }
preview() { (cd "$R" && WRANGLER_CI_OVERRIDE_NAME=web WORKERS_CI_BRANCH=feat/x node scripts/agent/release.mjs preview 2>&1); echo "exit=$?"; }
check() { (cd "$R" && scripts/agent/setup.sh --check 2>&1); echo "exit=$?"; }
prev '{ "d1_databases": [{ "binding": "DB", "database_name": "web-stg", "database_id": "web-stg-id" }] }'; commit clean
: >"$RELEASE_LOG"; out=$(preview)
has "exit=0" "$out" && [ "$(calls)" = "preview --name feat-x --config workers/web/wrangler.jsonc" ] || why="clean preview: $out // $(calls)"
out=$(check); has "exit=0" "$out" || why="$why; clean check: $out"
for bad in '{ "d1_databases": [{ "binding": "DB", "database_name": "web-prod", "database_id": "web-prod-id" }] }' \
           '{ "d1_databases": [{ "binding": "DB", "database_name": "web-stg", "database_id": "web-stg-id" }, { "binding": "AUTH", "database_name": "auth-prod", "database_id": "auth-prod-id" }] }'; do
  prev "$bad"; commit bad
  : >"$RELEASE_LOG"; out=$(preview)
  has "exit=1" "$out" && has "names the production resource" "$out" && [ -z "$(calls)" ] || why="$why; preview with $bad: $out // $(calls)"
  out=$(check); has "exit=1" "$out" && has "names the production resource" "$out" || why="$why; check with $bad: $out"
done
if [ -z "$why" ]; then ok release-declared-preview-isolation; else fail release-declared-preview-isolation "$why"; fi

# ---- setup --check validates the declaration: an invalid entry (a supporting Worker that is missing, outside the repo, or a duplicate name,
# a directory with no config, an undeclared key), workers beside the top-level release_workers, or a repository-wide secrets.required all fail
# it; the valid declaration passes
why=""
repo chk
out=$(check); has "exit=0" "$out" || why="valid declaration: $out"
bad() { # bad <label> <jset script> <expected text>: the declaration with that change fails --check and says why
  cp "$R/standards.json" "$T/standards.keep"; jset "$R/standards.json" "$2"; out=$(check)
  has "exit=1" "$out" && has "$3" "$out" || why="$why; $1 passed or said nothing useful: $out"
  cp "$T/standards.keep" "$R/standards.json"
}
bad "missing supporting Worker" 'o.workers[1].release_workers=["workers/none/wrangler.jsonc"]' "none"
bad "supporting Worker outside the repo" 'o.workers[1].release_workers=["../elsewhere/wrangler.jsonc"]' "release_workers"
bad "supporting Worker named like a primary" 'o.workers[1].release_workers=["workers/web/wrangler.jsonc"]' "release_workers"
bad "directory with no config" 'o.workers=["workers"]' "exactly one of"
bad "missing primary" 'o.workers=["workers/none"]' "does not exist"
bad "the same config twice" 'o.workers=["workers/web","workers/web/wrangler.jsonc"]' "duplicate"
bad "unknown key" 'o.workers[1].main="x"' "unknown key"
bad "empty list" 'o.workers=[]' "non-empty"
bad "top-level release_workers" 'o.release_workers=["workers/jobs/wrangler.jsonc"]' "release_workers"
bad "repository-wide secrets" 'o.secrets={required:["TOKEN"]}' "secrets.required"
# a config that is not declared is not a primary: a repository with a fixture-only config in a subdirectory and no declaration is not checked for it
repo fixture; rm -f "$R/wrangler.api.jsonc"; jset "$R/standards.json" 'delete o.workers'; printf '{ "name": "fx", "main": "../../src/index.js" }\n' >"$R/workers/web/wrangler.jsonc"; commit fx
out=$(check); has "exit=0" "$out" && ! has "fx" "$out" || why="$why; fixture-only repo: $out"
if [ -z "$why" ]; then ok release-declared-check; else fail release-declared-check "$why"; fi

# ---- apply ships the release check and the Preview clean-up only to a repository with a root primary or declared primaries: a
# fixture-only repository (a config in a subdirectory, nothing declared) gets neither; a declared one gets both
why=""
OVL=$T/overlay.json; cp "$ENGINE/examples/overlay.json" "$OVL"
applied() { node bin/repo-standards.mjs apply --target "$1" --overlay "$OVL" --version 0.8.3 2>&1; }
git_repo() { git init -q -b main "$1"; }
for kind in fixture declared root none; do
  d=$T/apply-$kind; git_repo "$d"; mkdir -p "$d/workers/web"
  printf '{ "name": "web", "main": "x.js", "env": { "staging": {} } }\n' >"$d/workers/web/wrangler.jsonc"
  printf '{ "pack": "example", "version": "0.8.3", "profile": "internal", "staging_url": "https://staging.example.com"%s }\n' "$([ $kind = declared ] && echo ', "workers": ["workers/web"]')" >"$d/standards.json"
  [ $kind = root ] && printf '{ "name": "root", "main": "x.js", "env": { "staging": {} } }\n' >"$d/wrangler.jsonc"
  [ $kind = none ] && rm -rf "$d/workers"
  out=$(applied "$d"); rc=$?
  cleanup=$([ -f "$d/.github/workflows/std-preview-cleanup.yml" ] && echo yes || echo no); rcheck=$([ -f "$d/.github/workflows/std-release-check.yml" ] && echo yes || echo no)
  want=$([ $kind = declared ] || [ $kind = root ] && echo yes || echo no)
  [ $rc -eq 0 ] && [ "$cleanup" = "$want" ] && [ "$rcheck" = "$want" ] || why="$why; $kind: exit $rc cleanup=$cleanup release-check=$rcheck (want $want): $out"
done
# an invalid declaration stops apply before it writes anything
d=$T/apply-invalid; git_repo "$d"; printf '{ "pack": "example", "version": "0.8.3", "profile": "internal", "workers": ["workers/missing"] }\n' >"$d/standards.json"
out=$(applied "$d"); rc=$?
[ $rc -ne 0 ] && has "workers/missing" "$out" && [ ! -d "$d/.github" ] || why="$why; invalid declaration applied (exit $rc): $out"
if [ -z "$why" ]; then ok release-declared-apply; else fail release-declared-apply "$why"; fi

done_cases
