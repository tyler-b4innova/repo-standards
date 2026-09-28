#!/usr/bin/env bash
# The review rule (scripts/agent/review.mjs: Codex verdict, evidence, sign-off) through gate and verdict-recheck, and
# the gate workflow's triggers and plan, against a stand-in.
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
      recent: [{ number: 7 }, { number: 3 }], threads: JSON.parse(threads || "[]"), pushed: when, timeline: JSON.parse(process.env.TIMELINE || "[]"), perms: (process.env.PERMS ?? process.env.WF_PERMS).split(" "), reviews: JSON.parse(process.env.REVIEWS || "[]") }));
  ' "$@" > "$T/state.json"; }
gate() { (cd "$R" && GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_GRAPHQL_URL="http://127.0.0.1:$(cat "$T/port")/graphql" GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_PATH="$T/event.json" node scripts/agent/gate.mjs review) 2>&1; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
OPEN='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"url":"https://github.com/acme/demo/pull/7#r1"}]}}]'
DONE='[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"url":"u"}]}}]'
r=""
chk() { local want=$1 needle=$2 out st; out=$(gate); st=$?; { [ $st -eq "$want" ] && has "$needle" "$out"; } || r="$r [$needle: exit $st: $out]"; }
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
st true alice feat none x 30 "[]" yes "$HEAD1" "$OLD"; chk 0 "draft or closed; not evaluated"
st false alice feat none x 30 "[]" no "$HEAD1" "$OLD"; chk 0 "no Codex reviews on this repo"
st false 'example-sync[bot]' standards/v1.2.3 none x 30 "[]" yes "$HEAD1" "$OLD"; chk 0 "pack sync pull request"
# without actions: read (a private repo) the run-list read fails: the stand-in grants only what std-gate.yml lists
PERMS="contents pull-requests issues" st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 1 "actions/runs?head_sha=$HEAD1&event=pull_request&per_page=100: 403"
if [ -z "$r" ]; then ok codex-verdict-required; else fail codex-verdict-required "$r"; fi


GWF="$R/.github/workflows/std-gate.yml"
gtrig=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("\non:"),y.indexOf("permissions:")).replace(/\s+/g," "))' "$GWF")
# gate-code-only: only code changes start gate (pull_request commits, the merge queue, a launcher dispatch); no
# comment, review, edit or push trigger, and no re-run wrapper; with the org App posting `review`, gate's review step
# evaluates nothing
[ ! -e "$R/.github/workflows/std-gate-rerun.yml" ] || r="wrapper shipped"
for t in issue_comment pull_request_review pull_request_review_comment edited push:; do ! grep -q "$t" <<<"$gtrig" || r="$r trigger $t"; done
grep -q "types: \[opened, synchronize, reopened, ready_for_review\]" <<<"$gtrig" && grep -q merge_group <<<"$gtrig" && grep -q workflow_dispatch <<<"$gtrig" || r="$r triggers: $gtrig"
cp "$R/scripts/agent/pack.json" "$T/pack.bak"; node -e 'const f=process.argv[1],p=require(f);p.review_status=true;require("fs").writeFileSync(f,JSON.stringify(p))' "$R/scripts/agent/pack.json"
st false alice feat "$OLD" '✅ **Completed** now' 30 "$OPEN" yes "$HEAD1" "$OLD"; out=$(gate); x=$?
# the switch is read from the base branch: a pull request that turns it on in its own checkout is still evaluated
put() { node -e 'const b={login:"chatgpt-codex-connector[bot]",type:"Bot"};require("fs").writeFileSync(process.argv[1],JSON.stringify(eval("("+process.argv[2]+")")))' "$T/state.json" "$1"; }
BASEPACK="{content:Buffer.from(require('fs').readFileSync('$T/pack.bak')).toString('base64')}"
OPEN=$OPEN put "{pr:{number:7,draft:false,user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'},base:{ref:'main'}},comments:{7:[{user:b,updated_at:new Date().toISOString(),body:'<!-- codex-pull-request-review-summary -->\\n| 📝 **Code Review** | ✅ **Completed** now | \`${HEAD1:0:7}\` | x |'}]},recent:[{number:7},{number:3}],threads:JSON.parse(process.env.OPEN),pushed:new Date(Date.now()-3600000).toISOString(),timeline:[],files:{'scripts/agent/pack.json@main':$BASEPACK},perms:process.env.WF_PERMS.split(' ')}"
self=$(gate); sx=$?
cp "$T/pack.bak" "$R/scripts/agent/pack.json"
[ $x -eq 0 ] && has "the org App posts the \`review\` status" "$out" || r="$r [review on: $x $out]"
[ $sx -eq 1 ] || r="$r [a PR's own switch skipped review: $sx $self]"
if [ -z "${r:-}" ]; then ok gate-code-only; else fail gate-code-only "$r"; fi; r=""
# gate-no-push-regate: no push trigger at all (not main, staging, nor pack landings)
if ! grep -q "push" <<<"$gtrig"; then ok gate-no-push-regate; else fail gate-no-push-regate "$gtrig"; fi
# gate-ignores-body-edits: no edited trigger; a base change is re-gated by the launcher's dispatch of the merge ref
if ! grep -q edited <<<"$gtrig" && grep -q "refs/pull/{0}/merge" "$GWF"; then ok gate-ignores-body-edits; else fail gate-ignores-body-edits "$gtrig"; fi
# skip-never-greens-gate: no job-level if; a dispatch re-gate evaluates the pull request, never "not a pull request"
jobif=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(/^ {4}if:/m.test(y.slice(y.indexOf("jobs:"))))' "$GWF")
st false alice feat "$HEAD1" '🔄 **Running** since' 5 "[]" yes "$HEAD1" "$HEAD1"
echo '{"inputs":{"pr":"7"}}' > "$T/dev.json"
API="http://127.0.0.1:$(cat "$T/port")"
dg=$(cd "$R" && GITHUB_API_URL=$API GITHUB_GRAPHQL_URL=$API/graphql GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="$T/dev.json" node scripts/agent/gate.mjs review 2>&1); dx=$?
if [ "$jobif" = false ] && [ $dx -eq 1 ] && has "awaiting a Codex verdict" "$dg"; then ok skip-never-greens-gate; else fail skip-never-greens-gate "jobif=$jobif dispatch=$dx $dg"; fi

# ---- gate plan: drafts cheap, ready full
put() { node -e 'const b={login:"chatgpt-codex-connector[bot]",type:"Bot"};require("fs").writeFileSync(process.argv[1],JSON.stringify(eval("("+process.argv[2]+")")))' "$T/state.json" "$1"; }
pl() { echo "$2" > "$T/pev.json"; (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=$1 GITHUB_EVENT_PATH="$T/pev.json" GITHUB_OUTPUT= node scripts/agent/gate.mjs plan 2>&1) | sed -n 's/^mode=//p'; }
PRE='{"pull_request":{"number":7}}'
put "{pr:{number:7,draft:true,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}}}"; d1=$(pl pull_request "$PRE")
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}}}"; d2=$(pl pull_request "$PRE")
if [ "$d1 $d2" = "cheap full" ] && grep -q "if: steps.plan.outputs.mode == 'cheap'" "$GWF"; then ok draft-cheap-ready-full; else fail draft-cheap-ready-full "draft=$d1 ready=$d2"; fi

# ---- the head's Workers Builds preview: a failed Cloudflare build fails gate; the URL comes from the bot comment
CF='{user:{login:"cloudflare-workers-and-pages[bot]"},body:"## Deploying\n### Preview URL: https://feat.preview.example.test, https://feat-demo.example.test (commit '"${HEAD1:0:7}"')\n"}'
pv() { (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$T/event.json" GATE_PREVIEW_WAIT_S=0 GITHUB_OUTPUT= node scripts/agent/gate.mjs preview 2>&1); }
PERMS_JS="perms:process.env.WF_PERMS.split(' ')"
put "{$PERMS_JS,pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[{name:\"Workers Builds: demo\",status:\"completed\",conclusion:\"success\"}],comments:{7:[$CF]}}"; p1=$(pv); x1=$?
put "{$PERMS_JS,pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[{name:\"Workers Builds: demo\",status:\"completed\",conclusion:\"failure\",details_url:\"https://dash.example\"}],comments:{7:[$CF]}}"; p2=$(pv); x2=$?
put "{pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[],comments:{7:[]}}"; p3=$(pv); x3=$?
if [ $x1 -eq 0 ] && has "url=https://feat.preview.example.test" "$p1" && [ $x2 -eq 1 ] && has "Cloudflare build failed" "$p2" && [ $x3 -eq 0 ] && has "e2e runs locally" "$p3"
then ok e2e-uses-preview-url; else fail e2e-uses-preview-url "ok=$x1 red=$x2 none=$x3: $p1 | $p2 | $p3"; fi

# ---- review-status-posted: verdict-recheck posts `review` on the head from the same rule (the launcher imports
# reviewStatus); nothing while the pack leaves review to gate; a token that cannot post fails loudly
vr() { (cd "$R" && GITHUB_API_URL=$API GITHUB_GRAPHQL_URL=$API/graphql GITHUB_REPOSITORY=acme/demo GH_TOKEN=t scripts/agent/verdict-recheck "$@" 2>&1); }
SUM="{user:b,updated_at:new Date().toISOString(),body:'<!-- codex-pull-request-review-summary -->\\n| 📝 **Code Review** | ✅ **Completed** now | \`${HEAD1:0:7}\` | x |'}"
base="pr:{number:7,draft:false,state:'open',html_url:'https://github.com/acme/demo/pull/7',user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'},base:{ref:'main'}},comments:{7:[$SUM]},recent:[],pushed:new Date(Date.now()-300000).toISOString(),timeline:[]"
PACKFILE="{content:Buffer.from(JSON.stringify({...require('$R/scripts/agent/pack.json'),review_status:true})).toString('base64')}"
put "{$base,threads:[],files:{'scripts/agent/pack.json':$PACKFILE}}"; v1=$(vr 7); y1=$?; s1=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.context+"="+x.state+"@"+x.sha.slice(0,7)))' "$T/state.json")
OPEN=$OPEN put "{$base,threads:JSON.parse(process.env.OPEN),files:{'scripts/agent/pack.json':$PACKFILE}}"; v2=$(OPEN=$OPEN vr 7); s2=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.state+":"+x.description))' "$T/state.json")
put "{$base,threads:[]}"; v3=$(vr 7); s3=$(node -p 'JSON.stringify(require(process.argv[1]).statuses??[])' "$T/state.json")
put "{$base,threads:[],statusForbidden:true,files:{'scripts/agent/pack.json':$PACKFILE}}"; v4=$(vr 7); y4=$?
# a pull request cut before the release (its head's pack has no review_status) is judged by the base branch's pack
OLDPACK="{content:Buffer.from(JSON.stringify(require('$R/scripts/agent/pack.json'))).toString('base64')}"
put "{$base,threads:[],files:{'scripts/agent/pack.json@main':$PACKFILE,'scripts/agent/pack.json@feat':$OLDPACK}}"; v6=$(vr 7); s6=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.context+"="+x.state))' "$T/state.json")
# retargeted during the run (the base read at the end differs from the one judged): nothing is posted
put "{$base,threads:[],files:{'scripts/agent/pack.json':$PACKFILE}}"
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.retargetAfter=2;require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
v8=$(vr 7); s8=$(node -p 'JSON.stringify(require(process.argv[1]).statuses??[])' "$T/state.json")
put "{$base,threads:[],files:{'scripts/agent/pack.json':$PACKFILE}}"
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.pr.base.sha="e".repeat(40);s.retargetAfter=2;s.advance=true;require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
v9=$(vr 7); s9=$(node -p 'JSON.stringify(require(process.argv[1]).statuses??[])' "$T/state.json")
# a sibling on the same head retargeted mid-run blocks the post too
put "{$base,threads:[],files:{'scripts/agent/pack.json':$PACKFILE},open:[{number:7,head:{sha:'$HEAD1'}},{number:8,head:{sha:'$HEAD1'}}],prs:{8:{number:8,state:'open',draft:false,html_url:'u8',user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'},base:{ref:'other'}}},prFiles:{8:[]},moveSibling:8}"
v10=$(vr 7); s10=$(node -p 'JSON.stringify(require(process.argv[1]).statuses??[])' "$T/state.json")
# ... also one whose own base leaves review off (judged null), in case the retarget makes it need review
put "{$base,threads:[],files:{'scripts/agent/pack.json@main':$PACKFILE,'scripts/agent/pack.json@other':$OLDPACK},open:[{number:7,head:{sha:'$HEAD1'}},{number:8,head:{sha:'$HEAD1'},base:{ref:'other'}}],prs:{8:{number:8,state:'open',draft:false,html_url:'u8',user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'},base:{ref:'other'}}},prFiles:{8:[]},moveSibling:8}"
v11=$(vr 7); s11=$(node -p 'JSON.stringify(require(process.argv[1]).statuses??[])' "$T/state.json")
# the PR itself retargeted before it was judged, to a base where review is off: both passes agree it is null there,
# so nothing is posted (a status on the commit is not required for that base)
put "{$base,threads:[],files:{'scripts/agent/pack.json@main':$OLDPACK}}"
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.retargetAfter=1;require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
v12=$(vr 7); s12=$(node -p 'JSON.stringify(require(process.argv[1]).statuses??[])' "$T/state.json")
# the PR moved to another head mid-run: both the judged head and the new one go pending
put "{$base,threads:[],files:{'scripts/agent/pack.json':$PACKFILE}}"
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.retargetAfter=2;s.newHead="a".repeat(40);require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
v13=$(vr 7); s13=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.state+"@"+x.sha.slice(0,7)).sort())' "$T/state.json")
# judged null (review off on its base) and moved to another head and base: both heads go pending
put "{$base,threads:[],files:{'scripts/agent/pack.json@main':$OLDPACK}}"
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.retargetAfter=2;s.newHead="b".repeat(40);require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
v14=$(vr 7); s14=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.state+"@"+x.sha.slice(0,7)).sort())' "$T/state.json")
# the PR asked about is judged null (review off on its base), but a sibling on its head targets a base where review is
# on: the sibling is judged and its failure posted
put "{$base,threads:[],files:{'scripts/agent/pack.json@main':$OLDPACK,'scripts/agent/pack.json@other':$PACKFILE},open:[{number:7,head:{sha:'$HEAD1'},base:{ref:'main'}},{number:8,head:{sha:'$HEAD1'},base:{ref:'other'}}],prs:{8:{number:8,state:'open',draft:false,html_url:'u8',user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'},base:{ref:'other'}}},prFiles:{8:[{filename:'src/app.css'}]}}"
v15=$(vr 7); s15=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.state))' "$T/state.json")
# the thread query fails: pending replaces any earlier success, and the run reports it
put "{$base,threads:[],graphqlFail:true,files:{'scripts/agent/pack.json':$PACKFILE}}"; v16=$(vr 7); y16=$?; s16=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.state))' "$T/state.json")
# a thread opened between the two passes: they disagree, so pending (the next run posts the failure), never success
OPEN=$OPEN put "{$base,threads:[],threadsLater:JSON.parse(process.env.OPEN),files:{'scripts/agent/pack.json':$PACKFILE}}"; v17=$(vr 7); s17=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.state))' "$T/state.json")
# two open PRs on one head share its commit status: the worse verdict (the sibling's missing evidence) is posted
put "{$base,threads:[],files:{'scripts/agent/pack.json':$PACKFILE},open:[{number:7,head:{sha:'$HEAD1'}},{number:8,head:{sha:'$HEAD1'}}],prs:{8:{number:8,state:'open',draft:false,html_url:'u8',user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'},base:{ref:'other'}}},prFiles:{8:[{filename:'src/app.css'}]}}"; v7=$(vr 7); s7=$(node -p 'JSON.stringify((require(process.argv[1]).statuses??[]).map(x=>x.state+":"+x.description))' "$T/state.json")
put "{$base,threads:[],files:{'scripts/agent/pack.json':$PACKFILE}}"; v5=$(vr 7 --dry-run); s5=$(node -p 'JSON.stringify(require(process.argv[1]).statuses??[])' "$T/state.json")
if [ $y1 -eq 0 ] && [ "$s1" = '["review=success@'"${HEAD1:0:7}"'"]' ] && has "failure:1 unresolved Codex thread" "$s2" && [ "$s3" = "[]" ] && has "nothing to post" "$v3" \
  && [ $y4 -eq 1 ] && has "must be the org App's token" "$v4" && [ "$s5" = "[]" ] && has "dry run" "$v5" && [ "$s6" = '["review=success"]' ] && has "failure:#8: UI paths changed" "$s7" && has '"state":"pending"' "$s8" && has "changed while being judged" "$v8" && has '"state":"pending"' "$s9" && has '"state":"pending"' "$s10" && has "#8 changed while being judged" "$v10" && has '"state":"pending"' "$s11" && has "#8 changed while being judged" "$v11" && [ "$s12" = "[]" ] && [ "$s13" = '["pending@aaaaaaa","pending@ccccccc"]' ] && [ "$s14" = '["pending@bbbbbbb","pending@ccccccc"]' ] && [ "$s15" = '["failure"]' ] && [ $y16 -eq 1 ] && [ "$s16" = '["pending"]' ] && has "could not be evaluated" "$v16" && [ "$s17" = '["pending"]' ]
then ok review-status-posted; else fail review-status-posted "posted=$s1 | red=$s2 | off=$s3 | forbidden=$y4 | dry=$s5 | old-head=$s6 | shared=$s7 | retarget=$s8 | base-moved=$s9 | sibling-moved=$s10 | null-sibling-moved=$s11 | null-self-moved=$s12 | head-moved=$s13 | null-head-moved=$s14 | null-primary-sibling=$s15 | error=$y16 $s16 | late-thread=$s17 :: $v1 | $v2 | $v3 | $v4 | $v5 | $v6"; fi
done_cases
