#!/usr/bin/env bash
# A production release: a Workers Builds preview build of the branch release/<sha> (WORKERS_CI_BRANCH) promotes that commit, and the
# settings a version upload never applies, through release.mjs with the stub wrangler against a Cloudflare API stand-in and real git
# remotes. There is no GitHub token anywhere. Nothing here touches real Cloudflare.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap '{ [ -n "${WORLD_PID:-}" ] && kill $WORLD_PID; } 2>/dev/null; rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GH_TOKEN GITHUB_TOKEN GITHUB_REPOSITORY GITHUB_EVENT_PATH GITHUB_EVENT_NAME OP_CLI OP_VAULT OP_SERVICE_ACCOUNT_TOKEN SENTRY_AUTH_TOKEN
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"; chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
echo '{}' >"$T/state.json"
node test/stubs/promote-world.mjs "$T/port" "$T/state.json" & WORLD_PID=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$T/port")"
export CLOUDFLARE_API_BASE=$BASE/cf CLOUDFLARE_API_TOKEN=t CLOUDFLARE_ACCOUNT_ID=acct
VERS='{}'
world() { node -e 'const s=JSON.parse(process.argv[1]);s.versions=JSON.parse(process.argv[2]);require("fs").writeFileSync(process.argv[3],JSON.stringify(s))' "$1" "$VERS" "$T/state.json"; }
STAGING='"env": { "staging": { "routes": [], "workers_dev": true } }'
# repo <name> <primary-extra-json>: a git repo with the pack applied, a primary Worker "app" and a supporting Worker "runtime"
repo() {
  R=$T/$1; git init -q -b main "$R"; node bin/repo-standards.mjs apply --target "$R" --overlay "$ENGINE/examples/overlay.json" --version 0.8.3 >/dev/null
  export RELEASE_LOG=$T/$1.log; : >"$RELEASE_LOG"
  mkdir -p "$R/node_modules/.bin" "$R/workers/runtime" "$R/src" "$R/migrations"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"
  printf '{ "name": "app", "main": "src/index.js"%s, %s }\n' "${2:-}" "$STAGING" >"$R/wrangler.jsonc"
  printf '{ "name": "runtime", "main": "../../src/index.js", %s }\n' "$STAGING" >"$R/workers/runtime/wrangler.jsonc"
  node -e 'const fs=require("fs"),o=JSON.parse(fs.readFileSync(process.argv[1]));o.release_workers=["workers/runtime/wrangler.jsonc"];fs.writeFileSync(process.argv[1],JSON.stringify(o,null,2))' "$R/standards.json"
  printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"; echo "select 1;" >"$R/migrations/0001.sql"; commit fixture
  git init -q --bare "$T/$1.git"; gc -C "$R" remote add origin "$T/$1.git"; gc -C "$R" push -q origin main # main's history, as the build's checkout has it
}
commit() { gc -C "$R" add -A && gc -C "$R" commit -qm "${1:-change}"; }
land() { gc -C "$R" push -q origin main; } # a commit main has
sha() { git -C "$R" rev-parse HEAD; }
calls() { node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(x=>x.args);console.log(l.map(x=>x.args.join(" ")).join("\n"))' "$RELEASE_LOG"; }
# every Wrangler call that changes production: not a dry run, a version list or a secret list
changes() { calls | grep -vE -- '--dry-run|^versions list|^secret list|^versions upload' ; }
uploads() { calls | grep -c '^versions upload'; }
versions() { # versions <sha>: the versions main uploaded for it, for both Workers (as the Cloudflare API returns them)
  VERS=$(printf '{"runtime":[{"id":"vr","annotations":{"workers/tag":"%s"}}],"app":[{"id":"va","annotations":{"workers/tag":"%s"}}]}' "$1" "$1")
  world "$(cat "$T/state.json")"
}
runtime_only() { # runtime_only <sha>: main uploaded a version for the supporting Worker only (the primary deploys in full)
  VERS=$(printf '{"runtime":[{"id":"vr","annotations":{"workers/tag":"%s"}}]}' "$1"); world "$(cat "$T/state.json")"
}
# the portal's release branch: WORKERS_CI_BRANCH release/<sha>, built at <sha> (the second argument overrides the built commit)
prom() { (cd "$R" && WORKERS_CI_BRANCH=release/$1 WORKERS_CI_COMMIT_SHA=${2:-$1} node scripts/agent/release.mjs preview 2>&1); echo "exit=$?"; }
main() { (cd "$R" && WORKERS_CI_COMMIT_SHA=$1 node scripts/agent/release.mjs main 2>&1); echo "exit=$?"; }
unset D1_PENDING FAIL_DRYRUN

# ---- an approved commit promotes from the release branch: D1 migrations first, then supporting Workers before the primary
why=""
repo approved ', "d1_databases": [{ "binding": "DB", "database_name": "d", "database_id": "x" }]'
S=$(sha); versions "$S"; world '{"scripts":[{"id":"app"},{"id":"runtime"}]}'
: >"$RELEASE_LOG"; out=$(prom "$S")
node -e 'const l=process.argv[1].split("\n"),i=(p)=>l.findIndex((x)=>x.startsWith(p));const d=i("d1 migrations apply DB"),r=i("versions deploy vr@100%"),a=i("versions deploy va@100%");process.exit(d>=0&&r>d&&a>r?0:1)' "$(changes)" || why="order: $(changes)"
has "exit=0" "$out" && has "promoted ${S:0:7}" "$out" || why="$why; $out"
# the build needs no GitHub token (none is set above), and an ordinary branch is still just a Preview
: >"$RELEASE_LOG"; out=$(cd "$R" && WORKERS_CI_BRANCH=feat/x WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs preview 2>&1)
calls | grep -q "^preview --name feat-x" && ! calls | grep -q "versions deploy" || why="$why; ordinary branch: $out $(calls)"
# a branch that only looks like a release branch is a Preview too
: >"$RELEASE_LOG"; out=$(cd "$R" && WORKERS_CI_BRANCH=release/${S:0:12} WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs preview 2>&1)
calls | grep -q "^preview --name release-" && [ -z "$(changes | grep -v '^preview')" ] || why="$why; lookalike branch: $out $(calls)"
if [ -z "$why" ]; then ok promote-approved-sha; else fail promote-approved-sha "$why"; fi

# ---- refused before any remote change: a build of another commit than the branch names, a commit main never released (no uploaded
# version), and, where every Worker deploys in full, a commit that is not in main's history in the checkout
why=""
: >"$RELEASE_LOG"; out=$(prom "$S" "0000000000000000000000000000000000000000")
has "exit=1" "$out" && has "the release branch names ${S:0:7}" "$out" && [ -z "$(changes)" ] || why="wrong commit: $out $(changes)"
versions "0000000000000000000000000000000000000000"; : >"$RELEASE_LOG"; out=$(prom "$S")
has "exit=1" "$out" && has "has no uploaded version for ${S:0:7}" "$out" && [ -z "$(changes)" ] || why="$why; no upload: $out $(changes)"
repo allfull ', "exports": { "A": { "type": "durable-object", "storage": "sqlite" } }'
printf '{ "name": "runtime", "main": "../../src/index.js", "exports": { "B": { "type": "durable-object", "storage": "sqlite" } }, %s }\n' "$STAGING" >"$R/workers/runtime/wrangler.jsonc"; commit full
world '{"scripts":[{"id":"app"},{"id":"runtime"}]}'
echo "export default { local: true };" >"$R/src/index.js"; commit unlanded; U=$(sha)
: >"$RELEASE_LOG"; out=$(prom "$U")
has "exit=1" "$out" && has "cannot prove ${U:0:7} came from main" "$out" && has "it is not in main's history" "$out" && [ -z "$(changes)" ] || why="$why; not main: $out $(changes)"
land; : >"$RELEASE_LOG"; out=$(prom "$U")
has "exit=0" "$out" && calls | grep -qE "^deploy --config .*/workers/runtime/wrangler.jsonc --name runtime --tag $U " && calls | grep -qE "^deploy --name app --tag $U " || why="$why; main's history: $out $(calls)"
# the Builds checkout is a shallow clone of the release commit, and main has moved on since: main's history is fetched in full
echo "export default { moved: 1 };" >"$R/src/index.js"; commit moved; land
git -C "$T/allfull.git" config uploadpack.allowAnySHA1InWant true
SH=$T/shallow; git init -q "$SH"; gc -C "$SH" remote add origin "file://$T/allfull.git"; gc -C "$SH" fetch -q --depth 1 origin "$U"; gc -C "$SH" checkout -q "$U"
mkdir -p "$SH/node_modules/.bin"; touch "$SH/node_modules/.bin/wrangler"
[ "$(gc -C "$SH" rev-parse --is-shallow-repository)" = true ] || why="$why; fixture is not shallow"
: >"$RELEASE_LOG"; out=$(cd "$SH" && WORKERS_CI_BRANCH=release/$U WORKERS_CI_COMMIT_SHA=$U node scripts/agent/release.mjs preview 2>&1)
has "promoted ${U:0:7}" "$out" || why="$why; shallow checkout: $out"
repo noremote ', "exports": { "A": { "type": "durable-object", "storage": "sqlite" } }'
printf '{ "name": "runtime", "main": "../../src/index.js", "exports": { "B": { "type": "durable-object", "storage": "sqlite" } }, %s }\n' "$STAGING" >"$R/workers/runtime/wrangler.jsonc"; commit full
gc -C "$R" remote remove origin; world '{"scripts":[{"id":"app"},{"id":"runtime"}]}'; : >"$RELEASE_LOG"; out=$(prom "$(sha)")
has "exit=1" "$out" && has "main's history is not in the build's checkout" "$out" && [ -z "$(changes)" ] || why="$why; no remote: $out $(changes)"
if [ -z "$why" ]; then ok promote-refusals; else fail promote-refusals "$why"; fi

# ---- Durable Object lifecycle is decided against production's live state: main uploads no version for a Worker whose declared
# migration is not live (or which declares DO exports), and promote deploys the approved commit in full
why=""
MIG='"migrations": [{ "tag": "v1", "new_sqlite_classes": ["A"] }, { "tag": "v2", "new_sqlite_classes": ["B"] }]'
repo lifecycle ", $MIG"; M1=$(sha)
world '{"scripts":[{"id":"app","migration_tag":"v1"},{"id":"runtime"}]}'; : >"$RELEASE_LOG"; out=$(main "$M1")
has "exit=0" "$out" && has "no production version uploaded for app: migration v2 is not applied in production (live: v1)" "$out" && [ "$(uploads)" = 1 ] || why="skipped migration: $out $(calls)"
# a later ordinary commit while v2 is still unapplied: still nothing uploaded for app; promoting it deploys that commit with the migration
echo "export default { later: true };" >"$R/src/index.js"; commit later; M2=$(sha)
: >"$RELEASE_LOG"; out=$(main "$M2"); [ "$(uploads)" = 1 ] || why="$why; newer commit uploaded for app: $out"
runtime_only "$M2"
: >"$RELEASE_LOG"; out=$(prom "$M2")
has "exit=0" "$out" && has "full wrangler deploy of ${M2:0:7} (migration v2 is not applied in production (live: v1))" "$out" && calls | grep -q "^versions deploy vr@100%" \
  && calls | grep -qE "^deploy --name app --tag $M2 " && ! calls | grep -q "^versions deploy .*--name app" || why="$why; newer approval: $out $(calls)"
# once production has v2, the next commit uploads as usual
world '{"scripts":[{"id":"app","migration_tag":"v2"},{"id":"runtime"}]}'; : >"$RELEASE_LOG"; out=$(main "$M2"); [ "$(uploads)" = 2 ] || why="$why; applied migration still skipped: $out"
# a rename or transfer is a migration entry like any other: it differs from live, so no upload and a full deploy
printf '{ "name": "app", "main": "src/index.js", "migrations": [{ "tag": "v1", "new_sqlite_classes": ["A"] }, { "tag": "v2", "new_sqlite_classes": ["B"] }, { "tag": "v3", "renamed_classes": [{ "from": "A", "to": "C" }] }], %s }\n' "$STAGING" >"$R/wrangler.jsonc"
commit rename; M3=$(sha); : >"$RELEASE_LOG"; out=$(main "$M3")
has "migration v3 is not applied in production (live: v2)" "$out" && [ "$(uploads)" = 1 ] || why="$why; rename: $out"
# DO exports are never uploaded as a version, even unchanged
repo exports ', "exports": { "A": { "type": "durable-object", "storage": "sqlite" } }'; E1=$(sha)
world '{"scripts":[{"id":"app"},{"id":"runtime"}]}'; : >"$RELEASE_LOG"; out=$(main "$E1")
has "no production version uploaded for app: it declares Durable Object exports" "$out" && [ "$(uploads)" = 1 ] || why="$why; exports upload: $out"
runtime_only "$E1"; : >"$RELEASE_LOG"; out=$(prom "$E1")
has "exit=0" "$out" && calls | grep -qE "^deploy --name app --tag $E1 " || why="$why; exports promote: $out $(calls)"
# a bundle that does not validate on a supporting Worker deploys nothing, not even the primary
: >"$RELEASE_LOG"; out=$(FAIL_DRYRUN=runtime prom "$E1")
has "exit=1" "$out" && has "runtime does not bundle" "$out" && [ -z "$(changes)" ] || why="$why; dry-run failure: $out $(changes)"
# unreadable live state refuses (never taken for "none")
repo unreadable ", $MIG"; U1=$(sha); versions "$U1"; world '{"scriptsFail":true}'; : >"$RELEASE_LOG"; out=$(prom "$U1")
has "exit=1" "$out" && has "Cloudflare API GET /accounts/acct/workers/scripts: 500" "$out" && [ -z "$(changes)" ] || why="$why; unreadable: $out $(changes)"
if [ -z "$why" ]; then ok promote-do-lifecycle; else fail promote-do-lifecycle "$why"; fi

# ---- declared settings that differ from live are applied after the version deploy and reported; equal ones are a no-op
why=""
SET=', "triggers": { "crons": ["0 * * * *"] }, "routes": [{ "pattern": "app.example.com", "custom_domain": true }], "queues": { "consumers": [{ "queue": "jobs" }] }, "observability": { "enabled": true }'
repo settings "$SET"; S=$(sha); versions "$S"
Q='"queues":[{"queue_id":"q1","queue_name":"jobs"}]'
world '{"scripts":[{"id":"app"},{"id":"runtime"}],'"$Q"',"consumers":{"q1":[]},"live":{"app":{"crons":[],"domains":[],"settings":{"observability":{"enabled":false}}}}}'
: >"$RELEASE_LOG"; out=$(prom "$S")
has "exit=0" "$out" && has "cron triggers [] -> [0 * * * *]" "$out" && has "custom domains [] -> [app.example.com]" "$out" && has "queue consumer for jobs is not registered" "$out" && has "observability enabled=false -> true" "$out" \
  && calls | grep -q "^triggers deploy --name app" && ! calls | grep -q "^triggers deploy --name runtime" \
  && node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])).patches;process.exit(p&&p.length===1&&p[0].name==="app"&&p[0].body.observability.enabled===true?0:1)' "$T/state.json" || why="differs: $out $(calls)"
world '{"scripts":[{"id":"app"},{"id":"runtime"}],'"$Q"',"consumers":{"q1":[{"script":"app"}]},"live":{"app":{"crons":["0 * * * *"],"domains":["app.example.com"],"settings":{"observability":{"enabled":true}}}}}'
: >"$RELEASE_LOG"; out=$(prom "$S")
has "exit=0" "$out" && has "app: settings already match" "$out" && ! calls | grep -q "^triggers deploy" && ! grep -q patches "$T/state.json" || why="$why; equal: $out $(calls)"
if [ -z "$why" ]; then ok promote-settings-applied; else fail promote-settings-applied "$why"; fi

# ---- the main release warns where live production differs from the declared settings (read-only), and says nothing where it matches
why=""
repo drift ', "triggers": { "crons": ["0 * * * *"] }, "observability": { "enabled": true }'; S=$(sha)
world '{"scripts":[{"id":"app"},{"id":"runtime"}],"live":{"app":{"crons":[],"settings":{"observability":{"enabled":false}}}}}'
: >"$RELEASE_LOG"; out=$(main "$S")
has "exit=0" "$out" && has "::warning::production app differs from its config: cron triggers [] -> [0 * * * *]" "$out" && has "observability enabled=false -> true" "$out" || why="differs: $out"
world '{"scripts":[{"id":"app"},{"id":"runtime"}],"live":{"app":{"crons":["0 * * * *"],"settings":{"observability":{"enabled":true}}}}}'
: >"$RELEASE_LOG"; out=$(main "$S"); has "exit=0" "$out" && ! has "differs from its config" "$out" || why="$why; equal: $out"
if [ -z "$why" ]; then ok release-settings-drift-warning; else fail release-settings-drift-warning "$why"; fi
done_cases
