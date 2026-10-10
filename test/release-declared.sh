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

done_cases
