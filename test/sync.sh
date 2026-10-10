#!/usr/bin/env bash
# Sync cases. Offline: local bare repositories are the remotes (non-fast-forward pushes refused), and a stub GitHub
# logs every request. A pack landing runs no gate: sync checks the tree offline and fast-forwards the default branch.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$(node -p 'require("./package.json").version')
T=$(mktemp -d)
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
G() { git -c user.name=t -c user.email=t@t "$@"; }
R=$T/remotes
seed() { # seed <owner/name> [standards.json text] [default branch]; main always exists
  local bare=$R/$1.git w=$T/seed/$1 def=${3:-main}
  mkdir -p "$w" "$bare"
  git init -q --bare "$bare" && git --git-dir "$bare" config receive.denyNonFastForwards true
  git init -q "$w" && echo "# $1" >"$w/README.md"
  [ -z "${2:-}" ] || printf '%s\n' "$2" >"$w/standards.json"
  G -C "$w" add -A && G -C "$w" commit -qm init && git -C "$w" push -q "$bare" HEAD:refs/heads/main
  [ "$def" = main ] || git -C "$w" push -q "$bare" HEAD:refs/heads/"$def"
  git --git-dir "$bare" symbolic-ref HEAD refs/heads/"$def"
}
std() { printf '{"pack":"%s","version":"0.1.0","profile":"%s","dispatch":"manual","sensitive":false}' "$1" "$2"; }
seed acme/alpha "$(std example internal)" staging
seed acme/beta "$(std example client)"
seed acme/boot
seed acme/gamma '{"pack":"example","version":"0.1.0","profile":"internal","dispatch":"manual","sensitive":false,"flow":"staged"}'
seed acme/other "$(std rival internal)"
seed acme/old "$(std example internal)"
seed acme/plain
seed acme/delta "$(std example internal)"
seed acme/skipme "$(std example internal)"
seed acme/standards "$(std example internal)"
seed rival/x "$(std example internal)"
cat >"$T/stub.json" <<JSON
{ "remotes": "$R",
  "repos": [{"full_name":"acme/alpha"},{"full_name":"acme/beta"},{"full_name":"acme/boot"},{"full_name":"acme/gamma"},{"full_name":"acme/other"},
            {"full_name":"acme/old","archived":true},{"full_name":"acme/plain"},{"full_name":"acme/delta","custom_properties":{"flow":"staged"}},{"full_name":"acme/skipme"},{"full_name":"acme/standards"},{"full_name":"rival/x"}],
  "gate": {"acme/beta": "failure", "acme/boot": ["failure", "success"]},
  "move": {"acme/alpha": "standards/v0.2.0"},
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
sync() { env -u GITHUB_GRAPHQL_URL GH_TOKEN=test-token GITHUB_API_URL=$API SYNC_GIT_BASE=file://$R node bin/repo-standards.mjs sync --overlay "$OV" $([ "$(node -p 'require("./package.json").breaking===true')" = true ] && ! printf '%s\n' "$@" | grep -qx -- --dry-run && echo --proven) "$@" 2>&1; }
has_text() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
mark() { wc -l <"$LOG" | tr -d ' '; }
between() { sed -n "$(($1 + 1)),$2p" "$LOG"; } # log lines after mark $1 up to mark $2
writes_since() { tail -n +"$(($1 + 1))" "$LOG" | grep -v '"method":"GET"' || true; }
count() { printf '%s\n' "$1" | grep -c "$2" || true; }
dispatches() { count "$1" "\"path\":\"/repos/$2/gate-start\""; } # gate runs started (push or re-run)
q() { # q <repo> <js expression over s = {items, comments, files, runs}>
  curl -s "$API/repos/$1/_state" | node -e 'const s = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(eval(process.argv[1]))' "$2"
}
heads() { git --git-dir "$R/$1.git" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' '; }
sha() { git --git-dir "$R/$1.git" rev-parse "$2"; }
anc() { git --git-dir "$R/$1.git" merge-base --is-ancestor "$2" "$3" && echo yes || echo no; }
row() { q acme/standards 's.items.find(i => !i.pull && i.title === "Standards compliance").body' | grep "^| $1 |" || true; }
prs='s.items.filter(i => i.pull)'
RELEASE="https://github.com/tyler-b4innova/repo-standards/releases/tag/v$ENGINE"

# beta tracks a root .mcp.json, so its applied tree fails the offline check
BW=$T/beta-work; git clone -q "$R/acme/beta.git" "$BW" && echo '{}' > "$BW/.mcp.json" && G -C "$BW" add -A && G -C "$BW" commit -qm mcp && git -C "$BW" push -q origin HEAD:main

# Run 1: release 0.1.0 across the fleet. alpha (default branch staging) and boot land; beta fails its offline check.
a0=$(sha acme/alpha staging) am=$(sha acme/alpha main) b0=$(sha acme/beta main) o0=$(sha acme/boot main)
m1=$(mark)
out1=$(sync --version 0.1.0); rc1=$?
e1=$(mark)
a1=$(sha acme/alpha staging) b1=$(sha acme/beta main) o1=$(sha acme/boot main)
alpha_row1=$(row acme/alpha) beta_row1=$(row acme/beta) boot_row1=$(row acme/boot)
msg1=$(git --git-dir "$R/acme/alpha.git" log -1 --format=%B staging)
beta_pr1=$(q acme/beta "JSON.stringify($prs.map(p => [p.number, p.state, p.head, p.title, p.auto_merge]))")
beta_body1=$(q acme/beta "$prs[0]?.body")
# the fix path in the body works as written from an existing clone that has not fetched since sync pushed
fixc=$(printf '%s' "$beta_body1" | grep -o 'git fetch origin [^`]*FETCH_HEAD')
git clone -q "$R/acme/beta.git" "$T/beta-old" && git -C "$T/beta-old" update-ref -d refs/remotes/origin/standards/v0.1.0 # stale: fetched before sync pushed
fixed=$(cd "$T/beta-old" && git fetch -q origin main && eval "$fixc" 2>&1 && git rev-parse HEAD) fixwant=$(git --git-dir "$R/acme/beta.git" rev-parse standards/v0.1.0)

# Run 2: release 0.2.0; someone lands on alpha's staging between sync's clone and its push, so sync re-applies once.
m2=$(mark)
out2=$(sync --version 0.2.0); rc2=$?
e2=$(mark)
a2=$(sha acme/alpha staging) moved=$(git --git-dir "$R/acme/alpha.git" log --format=%H --grep='someone else landed first' staging)
lock=$(git --git-dir "$R/acme/alpha.git" show staging:standards.lock 2>&1 | head -1)
alpha_row2=$(row acme/alpha) beta_row2=$(row acme/beta)
bad_engine=$(node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f));o.engine="0.0.1";require("fs").writeFileSync(f+".old",JSON.stringify(o))' "$OV"
  env -u GITHUB_GRAPHQL_URL GH_TOKEN=test-token GITHUB_API_URL=$API SYNC_GIT_BASE=file://$R node bin/repo-standards.mjs sync --overlay "$OV.old" --version 0.3.0 2>&1; echo "rc=$?")
no_ver=$(sync; echo "rc=$?")
m3=$(mark)
dry=$(sync --version 0.3.0 --dry-run; echo "rc=$?")
dry_writes=$(writes_since "$m3")

# sync-applies-release
if [ $rc2 -eq 0 ] && [ "$lock" = "# example v0.2.0 internal engine $ENGINE" ] && [ -n "$(printf '%s' "$bad_engine" | grep 'rc=1')" ] \
  && [ -n "$(printf '%s' "$no_ver" | grep 'rc=1')" ] && [ -z "$(heads acme/alpha | grep v0.3.0)" ] \
  && [ -n "$(printf '%s' "$dry" | grep 'rc=0')" ] && [ -n "$(printf '%s' "$dry" | grep '^\[dry-run\] commit .* on staging')" ] && [ -z "$dry_writes" ]; then
  ok sync-applies-release
else fail sync-applies-release "rc=$rc2 lock=$lock engine-mismatch: $bad_engine no-version: $no_ver dry: $dry writes: $dry_writes"; fi

# sync-lands-without-gate: run 1 fast-forwards alpha's default branch (staging; main untouched) and boot's main with a
# commit whose only parent is the previous head, starts and waits for no gate run, and creates no branch or PR; run 2
# finds staging moved after its clone, re-applies once on the new head and lands.
gates=$(between "$m1" "$e2" | grep -c -E '"path":"[^"]*(gate-start|/actions/runs)' || true) # request paths only (a compliance body links the run)
if [ $rc1 -eq 0 ] && [ "$gates" = 0 ] && [ "$(git --git-dir "$R/acme/alpha.git" rev-parse "$a1^")" = "$a0" ] && [ "$(sha acme/alpha main)" = "$am" ] \
  && [ "$(printf '%s\n' "$msg1" | head -1)" = "chore: standards v0.1.0" ] && [ -n "$(printf '%s' "$msg1" | grep -F "$RELEASE")" ] \
  && [ -n "$(printf '%s' "$alpha_row1" | grep -F "| landed $(printf '%.7s' "$a1") |")" ] && [ -z "$(heads acme/alpha | grep standards/)" ] && [ "$(q acme/alpha "$prs.length")" = 0 ] \
  && [ "$(git --git-dir "$R/acme/boot.git" rev-parse "$o1^")" = "$o0" ] && [ -n "$(printf '%s' "$boot_row1" | grep -F "| landed $(printf '%.7s' "$o1") |")" ] \
  && [ -n "$moved" ] && [ "$(anc acme/alpha "$moved" "$a2")" = yes ] && [ "$(anc acme/alpha "$a1" "$a2")" = yes ] && [ -n "$(printf '%s' "$alpha_row2" | grep -F "| landed $(printf '%.7s' "$a2") |")" ] \
  && [ -n "$(printf '%s\n' "$out1" | grep -E "^acme/alpha: landed $(printf '%.7s' "$a1")")" ] && [ -n "$(printf '%s\n' "$out2" | grep 're-applying v0.2.0')" ]; then
  ok sync-lands-without-gate
else fail sync-lands-without-gate "rc=$rc1 gates=$gates a0=$a0 a1=$a1 a2=$a2 moved=$moved rows: $alpha_row1 / $alpha_row2 / boot $boot_row1 out: $out1 $out2"; fi

# sync-lists-off-fleet: a repository with no standards.json gets a row (and nothing written to it); excluded,
# archived, other-pack and other-org repositories stay off the table.
plain_row=$(row acme/plain) rest=$(for r in acme/skipme acme/old acme/other rival/x; do row "$r"; done)
plain_writes=$(between "$m1" "$e1" | grep -v '"method":"GET"' | grep -c '/repos/acme/plain/' || true)
if [ "$plain_row" = "| acme/plain | - | none | not in fleet: no standards.json |" ] && [ -z "$rest" ] && [ "$plain_writes" = 0 ] && [ "$(sha acme/plain main)" = "$(git -C "$T/seed/acme/plain" rev-parse HEAD)" ]; then ok sync-lists-off-fleet
else fail sync-lists-off-fleet "plain=$plain_row rest=$rest writes=$plain_writes"; fi

# sync-includes-standards-repo: the overlay's own repository gets its pack from sync like every other repository (no
# exception; a pin pull request there changes only the overlay and the sync App lands the managed files)
srow=$(row acme/standards)
if [ -n "$(printf '%s' "$srow" | grep -F '| landed ')" ] && git --git-dir "$R/acme/standards.git" ls-tree -r --name-only main | grep -qx 'AGENTS.md' && git --git-dir "$R/acme/standards.git" ls-tree -r --name-only main | grep -qx 'standards.lock'; then ok sync-includes-standards-repo
else fail sync-includes-standards-repo "row=$srow"; fi

# A repository still on the retired staged flow gets no landing: its offline check names the migration, so a person
# gets the PR (sync knows no integration branch).
g_row=$(q acme/standards 's.items.find(i => !i.pull && i.title === "Standards compliance")?.body' | grep '^| acme/gamma ')
g_body=$(q acme/gamma 's.items.filter(i => i.pull).map(p => p.body).join(" ")')
if [ -n "$(printf '%s' "$g_row" | grep 'offline check failed')" ] && has_text 'flow "staged" is retired' "$g_body" && [ "$(git --git-dir "$R/acme/gamma.git" rev-list --count main)" = 1 ]; then ok sync-lands-without-gate
else fail sync-lands-without-gate "staged repo: row=$g_row body=$g_body"; fi

# ... and so does one whose org `flow` property still says staged, though its standards.json names no flow
d_row=$(q acme/standards 's.items.find(i => !i.pull && i.title === "Standards compliance")?.body' | grep '^| acme/delta ')
d_body=$(q acme/delta 's.items.filter(i => i.pull).map(p => p.body).join(" ")')
if [ -n "$(printf '%s' "$d_row" | grep 'still on the staged flow')" ] && has_text 'org property flow is "staged"' "$d_body" && [ "$(git --git-dir "$R/acme/delta.git" rev-list --count main)" = 1 ]; then ok sync-lands-without-gate
else fail sync-lands-without-gate "staged by property: row=$d_row body=$d_body"; fi

# sync-opens-pr-when-red: beta's applied tree fails the offline check, so one PR for a person naming the failure, no
# auto-merge, beta's main untouched; the next release supersedes it; a PR a person closed is not reopened.
n2=$(q acme/beta "$prs.find(p => p.head === 'standards/v0.2.0')?.number")
curl -s -X PATCH -d '{"state":"closed"}' "$API/repos/acme/beta/pulls/$n2" >/dev/null
m4=$(mark)
out4=$(sync --version 0.2.0 --repo acme/beta); rc4=$?
w4=$(writes_since "$m4")
if [ "$b1" = "$b0" ] && [ "$beta_pr1" = '[[1,"open","standards/v0.1.0","chore: standards v0.1.0 (needs a person)",null]]' ] \
  && [ -n "$(printf '%s' "$beta_body1" | grep 'offline check failed')" ] && has_text 'leave AGENTS.md' "$beta_body1" && has_text '`gate` accepts' "$beta_body1"  && [ -n "$(printf '%s' "$beta_body1" | grep -F '.mcp.json is committed')" ] && [ -n "$fixc" ] && [ "$(printf '%s' "$fixed" | tail -1)" = "$fixwant" ] \
  && [ -z "$(grep enablePullRequestAutoMerge "$LOG")" ] && [ -n "$(printf '%s' "$beta_row1" | grep -F '| PR #1: offline check failed |')" ] \
  && [ "$(q acme/beta "JSON.stringify($prs.map(p => [p.number, p.state, p.head]))")" = '[[1,"closed","standards/v0.1.0"],[2,"closed","standards/v0.2.0"]]' ] \
  && [ -n "$(printf '%s' "$beta_row2" | grep -F '| PR #2: offline check failed |')" ] && [ "$(sha acme/beta main)" = "$b0" ] \
  && [ $rc4 -eq 0 ] && [ "$(count "$w4" '/pulls"')" = 0 ] && [ -n "$(row acme/beta | grep 'closed by a person in #2; not reopened')" ]; then
  ok sync-opens-pr-when-red
else fail sync-opens-pr-when-red "b0=$b0 b1=$b1 prs1=$beta_pr1 body1=$beta_body1 row1=$beta_row1 row2=$beta_row2 prs=$(q acme/beta "JSON.stringify($prs.map(p => [p.number, p.state, p.head]))") out4=$out4 w4=$w4"; fi

# A push the default branch refuses for any other reason (here a server hook) also ends in one PR for a person.
seed acme/locked "$(std example internal)"
printf '#!/bin/sh\nwhile read old new ref; do [ "$ref" = refs/heads/main ] && { echo "denied: main is locked" >&2; exit 1; }; done\nexit 0\n' > "$R/acme/locked.git/hooks/pre-receive" && chmod +x "$R/acme/locked.git/hooks/pre-receive"
lk=$(sync --version 0.2.0 --repo acme/locked); lr=$(row acme/locked)
if [ -n "$(printf '%s' "$lr" | grep -F 'PR #1: push to main failed')" ] && [ "$(q acme/locked "$prs.length")" = 1 ] && [ -n "$(q acme/locked "$prs[0]?.body" | grep 'denied: main is locked')" ]; then ok sync-opens-pr-when-red
else fail sync-opens-pr-when-red "locked: row=$lr out=$lk"; fi

# breaking-release-proves-first: an engine release marked breaking refuses the fleet; it lands on one repository
# (--repo), and on the fleet only with --proven. (A copy of this engine with "breaking": true.)
EB=$T/engine-breaking; mkdir -p "$EB" && cp -R bin lib template modules org defaults.json package.json "$EB/"
node -e 'const f=process.argv[1],p=JSON.parse(require("fs").readFileSync(f,"utf8"));p.breaking=true;p.version="9.9.9";require("fs").writeFileSync(f,JSON.stringify(p))' "$EB/package.json"
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.engine="9.9.9";require("fs").writeFileSync(f+".9",JSON.stringify(o))' "$OV"
bsync() { env -u GITHUB_GRAPHQL_URL GH_TOKEN=test-token GITHUB_API_URL=$API SYNC_GIT_BASE=file://$R node "$EB/bin/repo-standards.mjs" sync --overlay "$OV.9" --version 0.9.0 "$@" 2>&1; }
k0=$(mark); br1=$(bsync); bx1=$?; kw=$(writes_since "$k0")
br2=$(bsync --repo acme/boot); bx2=$?
k2=$(mark); br4=$(bsync); bx4=$?; kw4=$(writes_since "$k2") # landing on one repo is not proof
br3=$(bsync --proven); bx3=$?
br5=$(bsync); bx5=$? # the scheduled sync after the proof rolls without the flag
if [ $bx1 -eq 0 ] && [ -n "$(printf '%s' "$br1" | grep 'is marked breaking and not proven')" ] && [ -z "$kw" ] && [ $bx2 -eq 0 ] && [ -n "$(printf '%s' "$br2" | grep '^acme/boot: landed')" ] \
  && [ $bx4 -eq 0 ] && [ -z "$kw4" ] && [ $bx3 -eq 0 ] && [ -n "$(printf '%s' "$br3" | grep '^acme/alpha: landed')" ] && [ -n "$(q acme/standards 's.items.find(i => !i.pull && i.title === "Standards compliance")?.body' | grep 'std:proven engine=9.9.9')" ] \
  && [ $bx5 -eq 0 ] && [ -n "$(printf '%s' "$br5" | grep '^acme/alpha: current')" ]
then ok breaking-release-proves-first; else fail breaking-release-proves-first "unproven=$bx1 one=$bx2 again=$bx4 proven=$bx3 after=$bx5 writes=$kw/$kw4 :: $br1 :: $br2 :: $br4 :: $br3 :: $br5"; fi

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
  ok error-tracker-rerun-safe
else fail error-tracker-rerun-safe "dry=$dry_ok real=$real_ok again=$again_ok filed=$filed
$d
$r1
$r2"; fi


# A closed mapping PR leaves its branch behind, possibly with someone's later work: a rerun never deletes it; it opens
# a new PR from the next free name (…-2), and a further rerun sees that open PR.
n=$(q acme/filer 's.items.find(i => i.pull && i.state === "open")?.number')
curl -s -X PATCH -d '{"state":"closed"}' "$API/repos/acme/filer/pulls/$n" >/dev/null
g2=$(mark); r3=$(setup); rc=$?; r4=$(setup)
prs=$(q acme/filer 's.items.filter(i => i.pull).map(i => i.state + ":" + i.head).join(" ")')
if [ $rc -eq 0 ] && [ "$prs" = "closed:chore/sentry-project-web open:chore/sentry-project-retry/web/2" ] && [ -n "$(printf '%s' "$r3" | grep 'mapping PR')" ] \
  && [ -z "$(writes_since "$g2" | grep DELETE)" ] && [ -n "$(printf '%s' "$r4" | grep 'mapping PR already open')" ]; then ok error-tracker-rerun-safe
else fail error-tracker-rerun-safe "rc=$rc prs=$prs deletes=$(writes_since "$g2" | grep DELETE) $r3 | $r4"; fi

done_cases
