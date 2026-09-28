#!/usr/bin/env bash
# Sync cases. Offline: local bare repositories are the remotes (non-fast-forward pushes refused), a stub GitHub
# runs each repository's gate (started by the push, re-run on retry; fast-forward-only ref updates) and logs every request.
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
seed acme/skipme "$(std example internal)"
seed rival/x "$(std example internal)"
cat >"$T/stub.json" <<JSON
{ "remotes": "$R",
  "repos": [{"full_name":"acme/alpha"},{"full_name":"acme/beta"},{"full_name":"acme/boot"},{"full_name":"acme/gamma"},{"full_name":"acme/other"},
            {"full_name":"acme/old","archived":true},{"full_name":"acme/plain"},{"full_name":"acme/skipme"},{"full_name":"acme/standards"},{"full_name":"rival/x"}],
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
sync() { env -u GITHUB_GRAPHQL_URL GH_TOKEN=test-token GITHUB_API_URL=$API SYNC_GIT_BASE=file://$R SYNC_POLL_MS=20 node bin/repo-standards.mjs sync --overlay "$OV" "$@" 2>&1; }
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

# Run 1: release 0.1.0 across the fleet. alpha (default branch staging) is green; beta's gate is red; boot's is red once.
a0=$(sha acme/alpha staging) am=$(sha acme/alpha main) b0=$(sha acme/beta main) o0=$(sha acme/boot main)
m1=$(mark)
out1=$(sync --version 0.1.0); rc1=$?
e1=$(mark)
a1=$(sha acme/alpha staging) b1=$(sha acme/beta main) o1=$(sha acme/boot main)
alpha_row1=$(row acme/alpha) beta_row1=$(row acme/beta) boot_row1=$(row acme/boot)
msg1=$(git --git-dir "$R/acme/alpha.git" log -1 --format=%B staging)
patch1=$(between "$m1" "$e1" | grep '"method":"PATCH","path":"/repos/acme/alpha/git/refs/heads/staging"' || true)
beta_pr1=$(q acme/beta "JSON.stringify($prs.map(p => [p.number, p.state, p.head, p.title, p.auto_merge]))")
beta_body1=$(q acme/beta "$prs[0]?.body")
# the fix path in the body works as written from an existing clone that has not fetched since sync pushed
fixc=$(printf '%s' "$beta_body1" | grep -o 'git fetch origin [^`]*FETCH_HEAD')
git clone -q "$R/acme/beta.git" "$T/beta-old" && git -C "$T/beta-old" update-ref -d refs/remotes/origin/standards/v0.1.0 # stale: fetched before sync pushed
fixed=$(cd "$T/beta-old" && git fetch -q origin main && eval "$fixc" 2>&1 && git rev-parse HEAD) fixwant=$(git --git-dir "$R/acme/beta.git" rev-parse standards/v0.1.0)

# Run 2: release 0.2.0; someone lands on alpha's staging while its gate runs, so sync re-applies once.
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

# sync-lands-direct-when-green: run 1 lands on alpha's default branch (staging), main untouched; run 2 finds staging
# moved after its first green gate, re-applies once on the new head, runs gate again and lands. boot's first gate is
# red and its second green: it lands after one retry, reading the new run and not the old one.
d1=$(dispatches "$(between "$m1" "$e1")" acme/alpha) d2=$(dispatches "$(between "$m2" "$e2")" acme/alpha) do=$(dispatches "$(between "$m1" "$e1")" acme/boot)
if [ $rc1 -eq 0 ] && [ "$d1" = 1 ] && [ "$a1" != "$a0" ] && [ "$(anc acme/alpha "$a0" "$a1")" = yes ] && [ "$(sha acme/alpha main)" = "$am" ] \
  && [ -n "$(printf '%s' "$patch1" | grep "\"sha\":\"$a1\",\"force\":false")" ] \
  && [ "$(printf '%s\n' "$msg1" | head -1)" = "chore: standards v0.1.0" ] && [ -n "$(printf '%s' "$msg1" | grep -F "$RELEASE")" ] \
  && [ -n "$(printf '%s' "$alpha_row1" | grep -F "| landed $(printf '%.7s' "$a1") (gate https://github.com/acme/alpha/actions/runs/")" ] \
  && [ "$d2" = 2 ] && [ -n "$moved" ] && [ "$(anc acme/alpha "$moved" "$a2")" = yes ] && [ "$(anc acme/alpha "$a1" "$a2")" = yes ] \
  && [ -n "$(printf '%s' "$alpha_row2" | grep -F "| landed $(printf '%.7s' "$a2") (gate ")" ] \
  && [ -z "$(heads acme/alpha | grep standards/)" ] && [ "$(q acme/alpha "$prs.length")" = 0 ] && [ -n "$(heads acme/boot | grep main)" ] \
  && [ -z "$(heads acme/boot | grep standards/)" ] && [ "$do" = 2 ] && [ "$(anc acme/boot "$o0" "$o1")" = yes ] && [ "$o1" != "$o0" ] \
  && [ -n "$(printf '%s' "$boot_row1" | grep -F "| landed $(printf '%.7s' "$o1") (gate ")" ] && [ "$(q acme/boot "$prs.length")" = 0 ] \
  && [ -n "$(printf '%s\n' "$out1" | grep -E "^acme/alpha: landed $(printf '%.7s' "$a1") ")" ] && [ -n "$(printf '%s\n' "$out1" | grep -E '^acme/boot: landed ')" ]; then
  ok sync-lands-direct-when-green
else fail sync-lands-direct-when-green "rc=$rc1 dispatches=$d1/$d2 a0=$a0 a1=$a1 a2=$a2 moved=$moved heads=$(heads acme/alpha) patch=$patch1 msg=$msg1 rows: $alpha_row1 / $alpha_row2 / boot $do $boot_row1 out: $out1 $out2"; fi

# A staged repository whose default branch is main never takes a direct landing, even with gate green.
g_main=$(git --git-dir "$R/acme/gamma.git" rev-parse main)
g_row=$(q acme/standards 's.items.find(i => !i.pull && i.title === "Standards compliance")?.body' | grep '^| acme/gamma ')
g_prs=$(q acme/gamma 's.items.filter(i => i.pull).length')
if [ -n "$(printf '%s' "$g_row" | grep 'staged repo defaults to main')" ] && [ "$g_prs" -ge 1 ] && [ "$(git --git-dir "$R/acme/gamma.git" rev-list --count main)" = 1 ]; then ok sync-lands-direct-when-green
else fail sync-lands-direct-when-green "staged repo on main: row=$g_row prs=$g_prs main=$g_main"; fi

# sync-opens-pr-when-red: beta's gate fails twice (the second after one re-apply), so one PR for a person, no
# auto-merge; the next release supersedes it; a PR a person closed is not reopened for the same content.
db=$(dispatches "$(between "$m1" "$e1")" acme/beta)
n2=$(q acme/beta "$prs.find(p => p.head === 'standards/v0.2.0')?.number")
curl -s -X PATCH -d '{"state":"closed"}' "$API/repos/acme/beta/pulls/$n2" >/dev/null
m4=$(mark)
out4=$(sync --version 0.2.0 --repo acme/beta); rc4=$?
w4=$(writes_since "$m4")
if [ "$db" = 2 ] && [ "$b1" = "$b0" ] && [ "$beta_pr1" = '[[1,"open","standards/v0.1.0","chore: standards v0.1.0 (needs a person)",null]]' ] \
  && [ -n "$(printf '%s' "$beta_body1" | grep -F "gate run: https://github.com/acme/beta/actions/runs/")" ] && [ -n "$(printf '%s' "$beta_body1" | grep 'gate red')" ] && [ -n "$fixc" ] && [ "$(printf '%s' "$fixed" | tail -1)" = "$fixwant" ] \
  && [ -z "$(grep enablePullRequestAutoMerge "$LOG")" ] && [ -n "$(printf '%s' "$beta_row1" | grep -F '| PR #1: gate red |')" ] \
  && [ "$(q acme/beta "JSON.stringify($prs.map(p => [p.number, p.state, p.head]))")" = '[[1,"closed","standards/v0.1.0"],[2,"closed","standards/v0.2.0"]]' ] \
  && [ -n "$(printf '%s' "$beta_row2" | grep -F '| PR #2: gate red |')" ] && [ "$(sha acme/beta main)" = "$b0" ] \
  && [ $rc4 -eq 0 ] && [ "$(dispatches "$w4" acme/beta)" = 0 ] && [ "$(count "$w4" '/pulls"')" = 0 ] && [ -n "$(row acme/beta | grep 'closed by a person in #2; not reopened')" ]; then
  ok sync-opens-pr-when-red
else fail sync-opens-pr-when-red "dispatches=$db b0=$b0 b1=$b1 prs1=$beta_pr1 body1=$beta_body1 row1=$beta_row1 row2=$beta_row2 prs=$(q acme/beta "JSON.stringify($prs.map(p => [p.number, p.state, p.head]))") out4=$out4 w4=$w4"; fi

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

# pack-landing-cheap-except-canary (sync side): each profile's canary lands first; a red canary stops the fleet
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.gate={canary:{client:"beta"}};require("fs").writeFileSync(f,JSON.stringify(o))' "$OV"
k0=$(mark); cr1=$(sync --version 0.4.0); ck1=$?; wait_row=$(row acme/alpha)
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.gate={canary:{internal:"alpha"}};require("fs").writeFileSync(f,JSON.stringify(o))' "$OV"
cr3=$(sync --version 0.5.0 --dry-run); ck3=$?
cr2=$(sync --version 0.5.0); ck2=$?
first=$(printf '%s\n' "$cr2" | grep -E '^acme/[a-z]+: ' | head -1)
if [ $ck1 -eq 1 ] && [ -n "$(printf "%s" "$cr1" | grep "canary acme/beta")" ] && [ -z "$(heads acme/alpha | grep v0.4.0)" ] && [ -z "$(printf '%s' "$cr1" | grep '^acme/alpha: ')" ] \
  && [ -n "$(printf '%s' "$wait_row" | grep 'waiting: canary acme/beta')" ] && [ "${first%%:*}" = acme/alpha ] && [ -n "$(printf '%s\n' "$cr2" | grep '^acme/boot: ')" ] && [ $ck3 -eq 0 ] && [ -n "$(printf '%s\n' "$cr3" | grep '^\[dry-run\] acme/boot: ')" ]
then ok pack-landing-cheap-except-canary; else fail pack-landing-cheap-except-canary "red=$ck1 green=$ck2 dry=$ck3 first=$first :: $cr1 :: $cr2 :: $cr3"; fi
overlay
done_cases
