#!/usr/bin/env bash
# Sync, fleet, credential-expiry and overlay-module cases. Offline: local bare repositories are the
# remotes (force pushes refused), stub GitHub and error-tracker APIs log every request.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$(node -p 'require("./package.json").version')
T=$(mktemp -d)
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
G() { git -c user.name=t -c user.email=t@t "$@"; }
R=$T/remotes
seed() { # seed <owner/name> [standards.json text]
  local bare=$R/$1.git w=$T/seed/$1
  mkdir -p "$w" "$bare"
  git init -q --bare "$bare" && git --git-dir "$bare" config receive.denyNonFastForwards true && git --git-dir "$bare" symbolic-ref HEAD refs/heads/main
  git init -q "$w" && echo "# $1" >"$w/README.md"
  [ -z "${2:-}" ] || printf '%s\n' "$2" >"$w/standards.json"
  G -C "$w" add -A && G -C "$w" commit -qm init && git -C "$w" push -q "$bare" HEAD:refs/heads/main
}
std() { printf '{"pack":"%s","version":"0.1.0","profile":"%s","dispatch":"manual","sensitive":false}' "$1" "$2"; }
seed acme/alpha "$(std example internal)"
seed acme/beta "$(std example client)"
seed acme/boot
seed acme/other "$(std rival internal)"
seed acme/old "$(std example internal)"
seed acme/plain
seed acme/skipme "$(std example internal)"
seed rival/x "$(std example internal)"
cat >"$T/stub.json" <<JSON
{ "remotes": "$R",
  "repos": [{"full_name":"acme/alpha"},{"full_name":"acme/beta"},{"full_name":"acme/boot"},{"full_name":"acme/other"},
            {"full_name":"acme/old","archived":true},{"full_name":"acme/plain"},{"full_name":"acme/skipme"},{"full_name":"acme/standards"},{"full_name":"rival/x"}],
  "rules": {"acme/alpha": [{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"gate"}]}}]},
  "variables": {"acme/standards": {"APP_KEY_ISSUED": "2000-01-01"}},
  "files": {"acme/filer": {"projects.json": "{}\n"}} }
JSON
start() { # start <stub> <port-file> <log> args...
  local s=$1 pf=$2 log=$3 i=0
  shift 3
  : >"$log"
  node "test/stubs/$s" "$pf" "$log" "$@" >/dev/null 2>&1 &
  PIDS="$PIDS $!"
  while [ ! -s "$pf" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
}
LOG=$T/gh.log SLOG=$T/tracker.log
start sync-github.mjs "$T/gh.port" "$LOG" "$T/stub.json"
start sync-sentry.mjs "$T/tr.port" "$SLOG" acme "issues bridge"
GP=$(cat "$T/gh.port") SP=$(cat "$T/tr.port")
OV=$T/overlay.json
overlay() { # overlay [block line]: the test org's overlay, pinned to this engine
  node -e '
    const [src, out, engine, sp, line] = process.argv.slice(1), o = JSON.parse(require("fs").readFileSync(src, "utf8"));
    Object.assign(o, { engine, org: "acme", standards_repo: "acme/standards", modules: { error_tracker: true, deploy: true },
      fleet: { mode: "discover", include: [{ repo: "acme/boot", profile: "client" }, { repo: "rival/x", profile: "internal" }], exclude: ["acme/skipme"] },
      expiring_credentials: [{ name: "App private key", issued_var: "APP_KEY_ISSUED", max_days: 300 }] });
    o.accounts.error_tracker = { kind: "sentry", org: "acme", api_base: `http://127.0.0.1:${sp}`, filer_repo: "acme/filer", alert_workflow: "issues bridge", credential_item: "Tracker token" };
    if (line) o.profiles.internal.block_lines = [line];
    require("fs").writeFileSync(out, JSON.stringify(o, null, 2));' examples/overlay.json "$OV" "$ENGINE" "$SP" "${1:-}"
}
overlay
API=http://127.0.0.1:$GP
sync() { env -u GITHUB_GRAPHQL_URL GH_TOKEN=test-token GITHUB_API_URL=$API SYNC_GIT_BASE=file://$R node bin/repo-standards.mjs sync --overlay "$OV" "$@" 2>&1; }
mark() { wc -l <"$LOG" | tr -d ' '; }
writes_since() { tail -n +"$(($1 + 1))" "$LOG" | grep -v '"method":"GET"' || true; }
q() { # q <repo> <js expression over s = {items, comments, files}>
  curl -s "$API/repos/$1/_state" | node -e 'const s = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(eval(process.argv[1]))' "$2"
}
heads() { git --git-dir "$R/$1.git" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' '; }
open_prs='s.items.filter(i => i.pull && i.state === "open").map(i => i.head).join(",")'

# Run 1: release 0.1.0 across the fleet.
m1=$(mark)
out1=$(sync --version 0.1.0); rc1=$?

# Run 2: release 0.2.0 supersedes 0.1.0.
m2=$(mark)
out2=$(sync --version 0.2.0); rc2=$?
lock=$(git --git-dir "$R/acme/alpha.git" show chore/standards-v0.2.0:standards.lock 2>&1 | head -1)
body=$(q acme/alpha 's.items.find(i => i.pull && i.head === "chore/standards-v0.2.0")?.body')
bad_engine=$(node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f));o.engine="0.0.1";require("fs").writeFileSync(f+".old",JSON.stringify(o))' "$OV"
  env -u GITHUB_GRAPHQL_URL GH_TOKEN=test-token GITHUB_API_URL=$API SYNC_GIT_BASE=file://$R node bin/repo-standards.mjs sync --overlay "$OV.old" --version 0.3.0 2>&1; echo "rc=$?")
no_ver=$(sync; echo "rc=$?")

# sync-applies-release
if [ $rc2 -eq 0 ] && [ "$lock" = "# example v0.2.0 internal engine $ENGINE" ] && [ -n "$(printf '%s' "$body" | grep "v0.2.0 with engine $ENGINE")" ] \
  && [ -n "$(printf '%s' "$bad_engine" | grep 'rc=1')" ] && [ -n "$(printf '%s' "$no_ver" | grep 'rc=1')" ] && [ -z "$(heads acme/alpha | grep v0.3.0)" ]; then
  ok sync-applies-release
else fail sync-applies-release "rc=$rc2 lock=$lock body=$body engine-mismatch: $bad_engine no-version: $no_ver"; fi

# sync-automerge-requires-gate: alpha requires gate, beta does not.
armed=$(writes_since "$m2" | grep enablePullRequestAutoMerge | wc -l | tr -d ' ')
issue='s.items.find(i => !i.pull && i.title === "Standards compliance")'
if [ "$armed" = 1 ] && [ "$(q acme/alpha 's.items.find(i => i.state === "open").auto_merge?.merge_method')" = SQUASH ] && [ "$(q acme/beta 's.items.find(i => i.state === "open").auto_merge')" = null ] \
  && [ -n "$(q acme/standards "$issue.body" | grep '^| acme/beta | client | 0.1.0 | .*auto-merge not armed: gate is not a required check on main')" ]; then
  ok sync-automerge-requires-gate
else fail sync-automerge-requires-gate "armed=$armed $(q acme/standards "$issue.body")"; fi

done_cases
