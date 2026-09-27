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

# sync-idle-without-credentials
m=$(mark)
out=$(env -u GH_TOKEN GITHUB_API_URL="$API" node bin/repo-standards.mjs sync --overlay "$OV" --version 0.1.0 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && [ -n "$(printf '%s' "$out" | grep notice)" ] && [ "$(mark)" = "$m" ]; then
  ok sync-idle-without-credentials
else fail sync-idle-without-credentials "rc=$rc requests=$(($(mark) - m)) out=$out"; fi

# Run 1: release 0.1.0 across the fleet.
m1=$(mark)
out1=$(sync --version 0.1.0); rc1=$?

# sync-discovers-fleet
got=""
for r in alpha beta boot other old plain skipme standards; do
  [ -z "$(q acme/$r "$open_prs")" ] || got="$got acme/$r"
done
[ -z "$(q rival/x "$open_prs")" ] || got="$got rival/x"
if [ $rc1 -eq 0 ] && [ "$got" = " acme/alpha acme/beta acme/boot" ] && [ "$(heads acme/boot)" = "chore/standards-v0.1.0 main " ]; then
  ok sync-discovers-fleet
else fail sync-discovers-fleet "rc=$rc1 repos with PRs:$got; $out1"; fi

# sync-org-isolated: also when named explicitly.
iso=$(sync --version 0.1.0 --repo acme/other; sync --version 0.1.0 --repo rival/x)
bad=$(writes_since "$m1" | grep -E 'acme/other|rival/' || true)
if [ -z "$bad" ] && [ "$(heads acme/other)$(heads rival/x)" = "main main " ] && [ -n "$(printf '%s' "$iso" | grep 'rival/x: owned by another org')" ] && [ -n "$(printf '%s' "$iso" | grep 'acme/other: standards.json names pack')" ]; then
  ok sync-org-isolated
else fail sync-org-isolated "writes: $bad heads: $(heads acme/other)/$(heads rival/x) out: $iso"; fi

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

# sync-supersedes-old-versions
old=$(q acme/alpha 's.items.find(i => i.head === "chore/standards-v0.1.0").state + " " + JSON.stringify(s.comments)')
if [ "$(q acme/alpha "$open_prs")" = chore/standards-v0.2.0 ] && [ -n "$(printf '%s' "$old" | grep '^closed.*Superseded by v0.2.0')" ] && [ "$(heads acme/alpha)" = "chore/standards-v0.2.0 main " ]; then
  ok sync-supersedes-old-versions
else fail sync-supersedes-old-versions "open: $(q acme/alpha "$open_prs") old: $old heads: $(heads acme/alpha)"; fi

# sync-automerge-requires-gate: alpha requires gate, beta does not.
armed=$(writes_since "$m2" | grep enablePullRequestAutoMerge | wc -l | tr -d ' ')
issue='s.items.find(i => !i.pull && i.title === "Standards compliance")'
if [ "$armed" = 1 ] && [ "$(q acme/alpha 's.items.find(i => i.state === "open").auto_merge?.merge_method')" = SQUASH ] && [ "$(q acme/beta 's.items.find(i => i.state === "open").auto_merge')" = null ] \
  && [ -n "$(q acme/standards "$issue.body" | grep '^| acme/beta | client | 0.1.0 | .*auto-merge not armed: gate is not a required check on main')" ]; then
  ok sync-automerge-requires-gate
else fail sync-automerge-requires-gate "armed=$armed $(q acme/standards "$issue.body")"; fi

# sync-compliance-issue: one pinned issue, one row per synced repo; a --repo run keeps the other rows.
single=$(sync --version 0.2.0 --repo acme/beta)
rows=$(q acme/standards "$issue.body" | grep '^| acme/')
count=$(q acme/standards 's.items.filter(i => !i.pull && i.title === "Standards compliance").length')
if [ "$count" = 1 ] && [ "$(q acme/standards "$issue.pinned")" = true ] && [ "$(printf '%s\n' "$rows" | cut -d' ' -f2-6 | tr '\n' ';')" = "acme/alpha | internal | 0.1.0;acme/beta | client | 0.1.0;acme/boot | client | none;" ]; then
  ok sync-compliance-issue
else fail sync-compliance-issue "issues=$count rows: $rows $single"; fi

# sync-never-force-pushes: new overlay content at the same release refreshes the existing branch.
h1=$(git --git-dir "$R/acme/alpha.git" rev-parse chore/standards-v0.2.0)
overlay "- A refreshed line."
out3=$(sync --version 0.2.0); rc3=$?
h2=$(git --git-dir "$R/acme/alpha.git" rev-parse chore/standards-v0.2.0)
if [ $rc3 -eq 0 ] && [ "$h1" != "$h2" ] && git --git-dir "$R/acme/alpha.git" merge-base --is-ancestor "$h1" "$h2" \
  && [ -n "$(git --git-dir "$R/acme/alpha.git" show "$h2:AGENTS.md" | grep 'A refreshed line')" ] && [ "$(q acme/alpha "$open_prs")" = chore/standards-v0.2.0 ]; then
  ok sync-never-force-pushes
else fail sync-never-force-pushes "rc=$rc3 $h1 -> $h2; $out3"; fi

# sync-respects-closed-pr: a person closes the PR; the next run does not push or reopen it.
n=$(q acme/alpha 's.items.find(i => i.state === "open").number')
curl -s -X PATCH -d '{"state":"closed"}' "$API/repos/acme/alpha/pulls/$n" >/dev/null
m4=$(mark)
out4=$(sync --version 0.2.0); rc4=$?
if [ $rc4 -eq 0 ] && [ "$(git --git-dir "$R/acme/alpha.git" rev-parse chore/standards-v0.2.0)" = "$h2" ] && [ -z "$(writes_since "$m4" | grep '"path":"/repos/acme/alpha/')" ] \
  && [ -n "$(q acme/standards "$issue.body" | grep "acme/alpha | .*closed by a person in #$n")" ]; then
  ok sync-respects-closed-pr
else fail sync-respects-closed-pr "rc=$rc4 writes: $(writes_since "$m4" | grep '"path":"/repos/acme/alpha/') $out4"; fi

# credential-expiry-sentinel: stale → exactly one human-decision issue (twice); renewed → closed with a comment.
expiry() { GH_TOKEN=test-token GITHUB_API_URL=$API node bin/repo-standards.mjs expiry --overlay "$OV" 2>&1; }
e1=$(expiry; expiry)
exp='s.items.filter(i => i.title === "Credential expiry: App private key" && i.labels.some(l => l.name === "human-decision"))'
stale=$(q acme/standards "$exp.map(i => i.state).join()")
today=$(node -p 'new Date().toISOString().slice(0, 10)')
curl -s -X PATCH -d "{\"value\":\"$today\"}" "$API/repos/acme/standards/actions/variables/APP_KEY_ISSUED" >/dev/null
e2=$(expiry)
after=$(q acme/standards "$exp.map(i => i.state + ' ' + (s.comments['acme/standards#' + i.number] ?? []).map(c => c.body).join()).join()")
if [ "$stale" = open ] && [ -n "$(printf '%s' "$after" | grep "^closed Clear as of $today")" ]; then
  ok credential-expiry-sentinel
else fail credential-expiry-sentinel "while stale: $stale; after: $after; $e1 $e2"; fi

# error-tracker-setup: dry run writes nothing; real run creates, attaches, files and writes the DSN; rerun is all done.
W=$T/web
mkdir -p "$W" && git init -q "$W" && git -C "$W" remote add origin https://github.com/acme/web.git
node bin/repo-standards.mjs apply --target "$W" --overlay "$OV" --profile client --version 0.2.0 >/dev/null
printf '{ "vars": { "SENTRY_DSN": "set-by-sentry-setup" } }\n' >"$W/wrangler.jsonc"
G -C "$W" add -A && G -C "$W" commit -qm init
setup() { (cd "$W" && GH_TOKEN=test-token SENTRY_INTEGRATION_TOKEN=tracker-token GITHUB_API_URL=$API scripts/agent/sentry-setup "$@" 2>&1); }
nonget() { grep -v '"method":"GET"' "$1" | wc -l | tr -d ' '; }
g0=$(mark)
d=$(setup --dry-run); drc=$?
dry_ok=$([ $drc -eq 0 ] && [ "$(nonget "$SLOG")" = 0 ] && [ -z "$(writes_since "$g0")" ] && [ -z "$(git -C "$W" status --porcelain)" ] && [ -n "$(printf '%s' "$d" | grep 'would create project web')" ] && echo y)
r1=$(setup); rc=$?
filed=$(q acme/filer 'JSON.stringify(JSON.parse(s.files["acme/filer@chore/sentry-project-web"]["projects.json"]).web) + " " + s.items.filter(i => i.pull).length')
real_ok=$([ $rc -eq 0 ] && [ -n "$(grep '"method":"POST","path":"/api/0/teams/acme/acme/projects/"' "$SLOG")" ] && [ -n "$(grep '"method":"PUT".*"detectorIds":\["d-other","d100"\]' "$SLOG")" ] \
  && [ "$filed" = '{"repo":"acme/web","labels":["human-decision"]} 1' ] && [ -n "$(grep 'ingest.example.com/100' "$W/wrangler.jsonc")" ] && echo y)
s0=$(nonget "$SLOG") g1=$(mark)
r2=$(setup); rc=$?
again_ok=$([ $rc -eq 0 ] && [ "$(nonget "$SLOG")" = "$s0" ] && [ -z "$(writes_since "$g1")" ] && [ -z "$(printf '%s\n' "$r2" | grep -vE 'exists|already|^SENTRY_DSN=')" ] && echo y)
if [ -n "$dry_ok" ] && [ -n "$real_ok" ] && [ -n "$again_ok" ] && scripts_help=$("$W/scripts/agent/sentry-setup" --help) && [ -n "$scripts_help" ]; then
  ok error-tracker-setup
else fail error-tracker-setup "dry=$dry_ok real=$real_ok again=$again_ok filed=$filed
$d
$r1
$r2"; fi

# deploy-release-tagging: release is the SHA; source maps upload only with every tracker setting.
mkdir -p "$T/bin" && printf '#!/bin/sh\necho "SENTRY_URL=${SENTRY_URL:-} $*" >>"%s"\n' "$T/npx.log" >"$T/bin/npx" && chmod +x "$T/bin/npx"
sha=$(git -C "$W" rev-parse HEAD)
dep() { env -u GITHUB_SHA -u WORKERS_CI_COMMIT_SHA -u SENTRY_AUTH_TOKEN -u SENTRY_ORG -u SENTRY_PROJECT -u SENTRY_URL PATH="$T/bin:$PATH" "$@" "$W/scripts/agent/deploy.sh" --env production 2>&1; }
: >"$T/npx.log"
o1=$(dep env SENTRY_AUTH_TOKEN=x SENTRY_ORG=acme); l1=$(cat "$T/npx.log")
: >"$T/npx.log"
o2=$(dep env SENTRY_AUTH_TOKEN=x SENTRY_ORG=acme SENTRY_PROJECT=web); l2=$(cat "$T/npx.log")
if [ -n "$(printf '%s' "$l1" | grep -- "wrangler deploy .*--var SENTRY_RELEASE:$sha --env production")" ] && [ -n "$(printf '%s' "$o1" | grep 'source-map upload skipped')" ] && [ -z "$(printf '%s' "$l1" | grep sentry/cli)" ] \
  && [ -n "$(printf '%s' "$l2" | grep "^SENTRY_URL=http://127.0.0.1:$SP --yes @sentry/cli@[0-9.]* sourcemaps upload --release $sha")" ] && [ -n "$(printf '%s' "$l2" | grep "releases finalize $sha")" ]; then
  ok deploy-release-tagging
else fail deploy-release-tagging "without: $o1 / $l1
with: $o2 / $l2"; fi
done_cases
