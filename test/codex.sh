#!/usr/bin/env bash
# The review rule (scripts/agent/review.mjs: Codex verdict, evidence, sign-off) through its package export, as a
# launcher calls it, and the gate workflow's triggers and plan, against a stand-in.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap '{ kill $STUB; wait $STUB; } 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo; git init -q -b main "$R" && node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.1.0 >/dev/null
HEAD1=$(printf 'c%.0s' $(seq 40)) OLD=$(printf 'd%.0s' $(seq 40))
echo '{}' > "$T/state.json"
node test/stubs/codex-github.mjs "$T/port" "$T/state.json" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
echo '{"pull_request":{"number":7}}' > "$T/event.json"
# the job token's scopes, read from the workflow the repo runs (every case below uses them)
export WF_PERMS=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8").match(/^permissions:\n((?:  .*\n)+)/m)[1];console.log([...y.matchAll(/^  ([a-z-]+): (read|write)$/gm)].map((m)=>m[1]).join(" "))' "$R/.github/workflows/std-gate.yml")
iso() { node -e 'console.log(new Date(Date.now()-Number(process.argv[1])*60000).toISOString())' "$1"; }
# st <draft> <user> <ref> <summary-sha|none> <status> <pushed-min-ago> [threads-json] [recent-summary: yes|no]
st() {
  node -e '
    const [draft, user, ref, sha, status, ago, threads, recent] = process.argv.slice(1), bot = { login: "chatgpt-codex-connector[bot]", type: "Bot" };
    const sum = (s) => ({ user: bot, updated_at: process.env.SUMMARY_AT || new Date().toISOString(), body: "<!-- codex-pull-request-review-summary -->\n| Review | Status | Commit | Trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | " + status + " | `" + s.slice(0, 7) + "` | New commits |" });
    const when = new Date(Date.now() - Number(ago) * 60000).toISOString();
    console.log(JSON.stringify({ pr: { number: 7, draft: draft === "true", user: { login: user }, head: { sha: process.argv[9], ref }, created_at: when },
      comments: { 7: sha === "none" ? [] : [sum(sha)], 3: recent === "yes" ? [sum(process.argv[10])] : [] },
      recent: [{ number: 7 }, { number: 3 }], threads: JSON.parse(threads || "[]"), pushed: when, timeline: JSON.parse(process.env.TIMELINE || "[]"), noRuns: !!process.env.NORUNS, reviews: JSON.parse(process.env.REVIEWS || "[]"),
      files: { "scripts/agent/pack.json": { content: require("fs").readFileSync(process.env.PACK).toString("base64") } } }));
  ' "$@" > "$T/state.json"; }
export PACK=$R/scripts/agent/pack.json
rv() { GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_REPOSITORY=acme/demo node test/review-run.mjs "${1:-7}" 2>&1; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
OPEN='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"url":"https://github.com/acme/demo/pull/7#r1"}]}}]'
DONE='[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"url":"u"}]}}]'
r=""
chk() { local want=$1 needle=$2 out st; out=$(rv); st=$?; { [ $st -eq "$want" ] && has "$needle" "$out"; } || r="$r [$needle: exit $st: $out]"; }
st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 0 "verdict on ccccccc, no open findings"
st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$OPEN" yes "$HEAD1" "$HEAD1"; chk 1 "1 unresolved Codex thread"
# a summary completed before this head was pushed (same short SHA) does not count
SUMMARY_AT=$(iso 60) st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 1 "awaiting a Codex verdict for ccccccc"
st false alice feat "$OLD" '✅ **Completed** now' 5 "[]" yes "$HEAD1" "$OLD"; chk 1 "awaiting a Codex verdict for ccccccc"
# a base edit after the verdict (summary or full-SHA review) changes the diff: the verdict no longer counts
BASE='[{"event":"base_ref_changed","created_at":"'$(iso 1)'"}]'
TIMELINE=$BASE SUMMARY_AT=$(iso 2) st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 1 "awaiting a Codex verdict for ccccccc"
TIMELINE=$BASE REVIEWS='[{"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"commit_id":"'$HEAD1'","submitted_at":"'$(iso 2)'"}]' st false alice feat "$OLD" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$OLD"; chk 1 "awaiting a Codex verdict for ccccccc"
TIMELINE=$BASE REVIEWS='[{"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"commit_id":"'$HEAD1'","submitted_at":"'$(iso 0)'"}]' st false alice feat "$OLD" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$OLD"; chk 0 "verdict on ccccccc, no open findings"
st false alice feat "$HEAD1" '🔄 **Running** since' 5 "[]" yes "$HEAD1" "$OLD"; chk 1 "awaiting a Codex verdict"
st false alice feat "$OLD" '✅ **Completed** now' 30 "[]" yes "$HEAD1" "$OLD"; chk 1 "no Codex verdict for ccccccc after"
# a PR with no pull_request gate run (older than std-gate): the head commit and PR dates still start the 20 minutes
NORUNS=1 st false alice feat "$OLD" '✅ **Completed** now' 30 "[]" yes "$HEAD1" "$OLD"; chk 1 "no Codex verdict for ccccccc after"
st true alice feat none x 30 "[]" yes "$HEAD1" "$OLD"; chk 0 "not judged"
st false alice feat none x 30 "[]" no "$HEAD1" "$OLD"; chk 0 "no Codex reviews on this repo"
# a pack-sync fallback PR is reviewed like any other (anyone with write access can push to its branch)
st false 'example-sync[bot]' standards/v1.2.3 none x 30 "[]" yes "$HEAD1" "$OLD"; chk 1 "no Codex verdict for ccccccc"
if [ -z "$r" ]; then ok codex-verdict-required; else fail codex-verdict-required "$r"; fi


GWF="$R/.github/workflows/std-gate.yml"
gtrig=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("\non:"),y.indexOf("permissions:")).replace(/\s+/g," "))' "$GWF")
# gate-code-only: only code changes start gate (pull_request commits, the merge queue, a launcher dispatch); no
# comment, review, edit or push trigger, no re-run wrapper, and no step that reads the conversation
[ ! -e "$R/.github/workflows/std-gate-rerun.yml" ] || r="wrapper shipped"
for t in issue_comment pull_request_review pull_request_review_comment edited push:; do ! grep -q "$t" <<<"$gtrig" || r="$r trigger $t"; done
grep -q "types: \[opened, synchronize, reopened, ready_for_review\]" <<<"$gtrig" && grep -q merge_group <<<"$gtrig" && grep -q workflow_dispatch <<<"$gtrig" || r="$r triggers: $gtrig"
grep -qw "review" <<<"$(grep -E '^\s*(- name:|run:)' "$GWF")" && r="$r a review step: $(grep -nw review "$GWF")"
out=$(cd "$R" && node scripts/agent/gate.mjs review 2>&1); x=$?
[ $x -eq 2 ] || r="$r [gate.mjs review exits $x: $out]"
! grep -qE "review\.mjs|reviewThreads|codex" "$R/scripts/agent/gate.mjs" || r="$r gate.mjs reads the conversation"
[ ! -e "$R/scripts/agent/verdict-recheck" ] || r="$r verdict-recheck shipped"
if [ -z "${r:-}" ]; then ok gate-code-only; else fail gate-code-only "$r"; fi; r=""
# gate-no-push-regate: no push trigger at all (not main, staging, nor pack landings)
if ! grep -q "push" <<<"$gtrig"; then ok gate-no-push-regate; else fail gate-no-push-regate "$gtrig"; fi
# gate-ignores-body-edits: no edited trigger; a base change is re-gated by the launcher's dispatch of the merge ref
if ! grep -q edited <<<"$gtrig" && grep -q "refs/pull/{0}/merge" "$GWF"; then ok gate-ignores-body-edits; else fail gate-ignores-body-edits "$gtrig"; fi
API="http://127.0.0.1:$(cat "$T/port")"

# ---- gate plan: drafts cheap, ready full
put() { node -e 'const b={login:"chatgpt-codex-connector[bot]",type:"Bot"};require("fs").writeFileSync(process.argv[1],JSON.stringify(eval("("+process.argv[2]+")")))' "$T/state.json" "$1"; }
pl() { echo "$2" > "$T/pev.json"; (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=$1 GITHUB_EVENT_PATH="$T/pev.json" GITHUB_OUTPUT= node scripts/agent/gate.mjs plan 2>&1) | sed -n 's/^mode=//p'; }
PRE='{"pull_request":{"number":7}}'
put "{pr:{number:7,draft:true,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}}}"; d1=$(pl pull_request "$PRE")
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}}}"; d2=$(pl pull_request "$PRE")
if [ "$d1 $d2" = "cheap full" ] && grep -q "if: steps.plan.outputs.mode == 'cheap'" "$GWF"; then ok draft-cheap-ready-full; else fail draft-cheap-ready-full "draft=$d1 ready=$d2"; fi
# skip-never-greens-gate: no job-level if; a dispatch re-gate plans the pull request it names, never "not a pull request"
jobif=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(/^ {4}if:/m.test(y.slice(y.indexOf("jobs:"))))' "$GWF")
dg=$(pl workflow_dispatch '{"inputs":{"pr":"7"}}')
if [ "$jobif" = false ] && [ "$dg" = full ]; then ok skip-never-greens-gate; else fail skip-never-greens-gate "jobif=$jobif dispatch-mode=$dg"; fi
# e2e-chromium-default: a pull request from the default branch into main is no promotion: gate plans Chromium only,
# whatever browsers the repository names (those run on main, before release)
cp "$R/standards.json" "$T/std.plan"; node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f));o.e2e={browsers:["firefox"]};require("fs").writeFileSync(f,JSON.stringify(o))' "$R/standards.json"
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"staging\",repo:{full_name:\"acme/demo\"}},base:{ref:\"main\"}},info:{default_branch:\"staging\",custom_properties:{flow:\"staged\"}}}"
echo "$PRE" > "$T/pev.json"; pb=$( (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$T/pev.json" GITHUB_OUTPUT= node scripts/agent/gate.mjs plan 2>&1) | sed -n 's/^browsers=//p')
cp "$T/std.plan" "$R/standards.json"
if [ "$pb" = chromium ]; then ok e2e-chromium-default; else fail e2e-chromium-default "default-branch PR planned browsers=$pb"; fi

# ---- the head's Workers Builds preview: a failed Cloudflare build fails gate; the URL comes from the bot comment
CF='{user:{login:"cloudflare-workers-and-pages[bot]"},body:"## Deploying\n### Preview URL: https://feat.preview.example.test, https://feat-demo.example.test (commit '"${HEAD1:0:7}"')\n"}'
pv() { (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$T/event.json" GATE_PREVIEW_WAIT_S=0 GITHUB_OUTPUT= node scripts/agent/gate.mjs preview 2>&1); }
PERMS_JS="perms:process.env.WF_PERMS.split(' ')"
put "{$PERMS_JS,pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[{name:\"Workers Builds: demo\",status:\"completed\",conclusion:\"success\"}],comments:{7:[$CF]}}"; p1=$(pv); x1=$?
put "{$PERMS_JS,pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[{name:\"Workers Builds: demo\",status:\"completed\",conclusion:\"failure\",details_url:\"https://dash.example\"}],comments:{7:[$CF]}}"; p2=$(pv); x2=$?
put "{pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[],comments:{7:[]}}"; p3=$(pv); x3=$?
if [ $x1 -eq 0 ] && has "url=https://feat.preview.example.test" "$p1" && [ $x2 -eq 1 ] && has "Cloudflare build failed" "$p2" && [ $x3 -eq 0 ] && has "e2e runs locally" "$p3"
then ok e2e-uses-preview-url; else fail e2e-uses-preview-url "ok=$x1 red=$x2 none=$x3: $p1 | $p2 | $p3"; fi
# preview-must-pass: where the repository has Workers Builds (its base tip carries the check), a missing, unfinished
# or failed build on the head fails gate; a build Cloudflare skipped passes without a preview
BASE_TIP=$(printf 'e%.0s' $(seq 40)); WB='{name:"Workers Builds: demo",status:"completed",conclusion:"success"}'
pb() { put "{$PERMS_JS,pr:{number:7,head:{sha:\"$HEAD1\"},base:{ref:\"main\"}},branchHeads:{main:\"$BASE_TIP\"},checksBy:{\"$BASE_TIP\":[$WB],\"$HEAD1\":$1},comments:{7:[${2-$CF}]}}"; pv; }
q1=$(pb '[]'); y1=$?
q2=$(pb '[{name:"Workers Builds: demo",status:"in_progress",conclusion:null}]'); y2=$?
q3=$(pb '[{name:"Workers Builds: demo",status:"completed",conclusion:"cancelled",details_url:"https://dash.example"}]'); y3=$?
q4=$(pb '[{name:"Workers Builds: demo",status:"completed",conclusion:"skipped"}]'); y4=$?
q5=$(pb "[$WB]"); y5=$?
q6=$(pb "[$WB]" ""); y6=$? # passed, but the Cloudflare comment has no URL for this commit: fail, never local
if [ $y1 -eq 1 ] && has "no \"Workers Builds\" check on ${HEAD1:0:7}" "$q1" && [ $y2 -eq 1 ] && has "still running" "$q2" && [ $y3 -eq 1 ] && has "Cloudflare build failed" "$q3" \
  && [ $y4 -eq 0 ] && has "skipped the build" "$q4" && [ $y5 -eq 0 ] && has "url=https://feat.preview.example.test" "$q5" && [ $y6 -eq 1 ] && has "no preview URL for ${HEAD1:0:7}" "$q6" && ! has "runs locally" "$q6"
then ok preview-must-pass; else fail preview-must-pass "missing=$y1 running=$y2 cancelled=$y3 skipped=$y4 ok=$y5 no-url=$y6: $q1 | $q2 | $q3 | $q4 | $q5 | $q6"; fi

# preview-url-from-bot-table: the URL is the Preview URL (or Deployment URL) cell of the bot's table row for the head,
# read by its header; never the build's dashboard link; "No Preview URL", a table without the column and a row for
# another commit are all "none" (gate fails, never a local run). Bodies: test/fixtures/cf-comments (real comments, made
# neutral: the dashboard host is {dash}; builds-preview-column.md is the Workers Builds table with its Preview URL
# column, built from the real production rows since no org's repositories have one yet).
DASH=$(node -e 'console.log(["dash","cloudflare","com"].join("."))')
# cfc <fixture> [from=to]...: a bot comment (JS object literal for the stand-in) with the fixture's commits renamed
cfc() { node -e 'const fs=require("fs"),[f,dash,...m]=process.argv.slice(1);let b=fs.readFileSync("test/fixtures/cf-comments/"+f,"utf8").replaceAll("{dash}",dash);
  for(const x of m){const [a,c]=x.split("=");b=b.replaceAll(a,c);} console.log(JSON.stringify({user:{login:"cloudflare-workers-and-pages[bot]"},body:b}))' "$@"; }
H7=${HEAD1:0:7} H8=${HEAD1:0:8}
u1=$(pb "[$WB]" "$(cfc builds-production.md "$DASH" ee8f57d6=$H8)"); z1=$?
u2=$(pb "[$WB]" "$(cfc preview-html.html "$DASH" 1172353=$H7 776c540=fffffff)"); z2=$?
u3=$(pb "[$WB]" "$(cfc preview-html.html "$DASH" 1172353=fffffff 776c540=$H7)"); z3=$?
u4=$(pb "[$WB]" "$(cfc preview-html-failed.html "$DASH")"); z4=$?
u5=$(pb "[$WB]" "$(cfc builds-preview-column.md "$DASH" ee8f57d6=$H8 1a2b3c4d=dddddddd)"); z5=$?
u6=$(pb "[$WB]" "$(cfc builds-preview-column.md "$DASH" ee8f57d6=dddddddd 1a2b3c4d=$H8)"); z6=$?
u7=$(pb "[$WB]" "$(cfc builds-preview-column.md "$DASH" ee8f57d6=dddddddd 1a2b3c4d=eeeeeeee)"); z7=$?
u8=$(pb "[$WB]" "$(cfc builds-preview-column.md "$DASH" ee8f57d6=$H8 1a2b3c4d=dddddddd),$(cfc builds-production.md "$DASH" ee8f57d6=$H8)"); z8=$? # the newest comment is last
bad=""
for o in "$u1" "$u4" "$u6" "$u7"; do has "$DASH" "$o" && bad="$bad dashboard-link-leaked"; done
if [ $z1 -eq 1 ] && has "no preview URL for $H7" "$u1" && ! has "url=https" "$u1" \
  && [ $z2 -eq 0 ] && has "url=https://29eb2a3c-demo-site.preview.example.com" "$u2" \
  && [ $z3 -eq 0 ] && has "url=https://9d5c3a3b-demo-site.preview.example.com" "$u3" \
  && [ $z4 -eq 1 ] && has "no preview URL for $H7" "$u4" \
  && [ $z5 -eq 0 ] && has "url=https://$H8-demo-site.preview.example.com" "$u5" \
  && [ $z6 -eq 1 ] && has "no preview URL for $H7" "$u6" && [ $z7 -eq 1 ] && [ $z8 -eq 0 ] && has "url=https://$H8-demo-site.preview.example.com" "$u8" && [ -z "$bad" ]
then ok preview-url-from-bot-table
else fail preview-url-from-bot-table "production=$z1 html-latest=$z2 html-older=$z3 html-failed=$z4 column=$z5 no-preview-url=$z6 other-commit=$z7 newest-last=$z8 bad=[$bad] u2=$u1 | $u2 | $u3 | $u4 | $u5 | $u6 | $u7 | $u8"; fi
# e2e-false-skips-preview: "e2e": false skips the preview step (Builds on every PR, no previews, no e2e suite)
cp "$R/standards.json" "$T/std.keep"; node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));o.e2e=false;fs.writeFileSync(f,JSON.stringify(o))' "$R/standards.json"
w1=$(pb '[]' ""); w2=$?
cp "$T/std.keep" "$R/standards.json"; w3=$(pb '[]' ""); w4=$?
if [ $w2 -eq 0 ] && has "preview: none" "$w1" && ! has "Workers Builds" "$w1" && [ $w4 -eq 1 ] && has "no \"Workers Builds\" check on $H7" "$w3"; then ok e2e-false-skips-preview
else fail e2e-false-skips-preview "e2e-false=$w2 (want 0) still-gated=$w4 (want 1): $w1 | $w3"; fi

# ---- review-rule-reads-base: the rule and its settings come from the current base branch (a PR cannot bring its own),
# even when the head is this repository's default branch (there are no promotions); a stale pull.base.sha is resolved
# through the branch. A null verdict here: no pack at the ref read.
SUM="{user:b,updated_at:new Date().toISOString(),body:'<!-- codex-pull-request-review-summary -->\\n| 📝 **Code Review** | ✅ **Completed** now | \`${HEAD1:0:7}\` | x |'}"
base="pr:{number:7,draft:false,state:'open',html_url:'https://github.com/acme/demo/pull/7',user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'},base:{ref:'main'}},comments:{7:[$SUM]},recent:[],pushed:new Date(Date.now()-300000).toISOString(),timeline:[],threads:[]"
PACKFILE="{content:Buffer.from(require('fs').readFileSync('$PACK')).toString('base64')}"
put "{$base,files:{'scripts/agent/pack.json@feat':$PACKFILE,'scripts/agent/pack.json@$HEAD1':$PACKFILE}}"; rb1=$(rv)
PROMO="pr:{number:7,draft:false,state:'open',html_url:'u',user:{login:'launcher[bot]'},head:{sha:'$HEAD1',ref:'staging',repo:{full_name:'acme/demo'}},base:{ref:'main'}},info:{default_branch:'staging'},comments:{7:[$SUM]},recent:[],pushed:new Date(Date.now()-300000).toISOString(),timeline:[],threads:[]"
put "{$PROMO,files:{'scripts/agent/pack.json@$HEAD1':$PACKFILE}}"; rb2=$(rv)
put "{${PROMO/acme\/demo/someone\/demo},files:{'scripts/agent/pack.json@$HEAD1':$PACKFILE}}"; rb3=$(rv)
put "{$base,branchHeads:{main:'$HEAD1'},files:{'scripts/agent/pack.json@$HEAD1':$PACKFILE}}"
node -e 'const f=process.argv[1],s=require(f);s.pr.base.sha=process.argv[2];require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json" "$OLD"; rb4=$(rv)
if has "not judged" "$rb1" && has "not judged" "$rb2" && has "not judged" "$rb3" && has "review success" "$rb4"; then ok review-rule-reads-base
else fail review-rule-reads-base "head-pack-only=$rb1 | default-branch-head=$rb2 | fork=$rb3 | stale-base-sha=$rb4"; fi
done_cases
