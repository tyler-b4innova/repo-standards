#!/usr/bin/env bash
# The Codex-verdict step of gate (Tyler's rule: every bot finding is answered before merge), against a stand-in.
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
gate() { (cd "$R" && GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_GRAPHQL_URL="http://127.0.0.1:$(cat "$T/port")/graphql" GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_PATH="$T/event.json" node scripts/agent/gate.mjs codex) 2>&1; }
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
st false alice feat "$OLD" '✅ **Completed** now' 30 "[]" yes "$HEAD1" "$OLD"; chk 1 "no Codex verdict for $HEAD1"
st true alice feat none x 30 "[]" yes "$HEAD1" "$OLD"; chk 0 "draft, not evaluated"
st false alice feat none x 30 "[]" no "$HEAD1" "$OLD"; chk 0 "no Codex reviews on this repo"
st false 'example-sync[bot]' standards/v1.2.3 none x 30 "[]" yes "$HEAD1" "$OLD"; chk 0 "pack-sync fallback PR"
# without actions: read (a private repo) the run-list read fails: the stand-in grants only what std-gate.yml lists
PERMS="contents pull-requests issues" st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 1 "/actions/runs?head_sha=$HEAD1&event=pull_request&per_page=100: 403"
if [ -z "$r" ]; then ok codex-verdict-required; else fail codex-verdict-required "$r"; fi

# std-gate-rerun, run against a stand-in gh: only a person's approval or dismissal, or a base change, reaches its step
# (comments, review comments and bots start nothing); an approval re-runs a finished gate run once and never waits
# for one in flight; a lost race counts as done; a base change dispatches std-gate for the PR's fresh merge ref.
WF="$R/.github/workflows/std-gate-rerun.yml" GWF="$R/.github/workflows/std-gate.yml"
node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");require("fs").writeFileSync(process.argv[2],y.match(/- run: \|\n((?: {10}.*\n?)+)/)[1].replace(/^ {10}/gm,""))' "$WF" "$T/rerun.sh"
rr() { # rr <event> <run-status> [race]: prints "<exit> <reruns> <sleeps> <dispatches>"
  printf '{"sha":"%s","run":{"id":42,"status":"%s","run_started_at":"2026-01-01T00:00:00Z"}%s}\n' "$HEAD1" "$2" "${3:+,\"raceOnce\":true}" > "$T/gh.json"; : > "$T/gh.log"
  EVENT=$1 HEAD_REF=feat PATH="$PWD/test/stubs/fake-bin:$PATH" FAKE_GH_STATE="$T/gh.json" FAKE_GH_LOG="$T/gh.log" GITHUB_REPOSITORY=acme/demo PR=7 bash "$T/rerun.sh" > "$T/rr.out" 2>&1; local x=$?
  echo "$x $(node -e 'const s=require(process.argv[1]);console.log((s.reruns??0)+" "+(s.sleeps??0)+" "+(s.dispatches??0))' "$T/gh.json")"; }
got="$(rr pull_request_review completed) | $(rr pull_request_review in_progress) | $(rr pull_request_review completed race) | $(rr pull_request completed)"
disp=$(grep DISPATCH "$T/gh.log")
triggers=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("on:"),y.indexOf("permissions:")).match(/^  [a-z_]+:/gm).map(s=>s.trim()).join(" "))' "$WF")
gtrig=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("on:"),y.indexOf("permissions:")).replace(/\s+/g," "))' "$GWF")
cond=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");const i=y.match(/if: >-\n((?: {6}.*\n)+)/)[1];console.log(/sender\.type != .Bot./.test(i)&&/review\.state == .approved./.test(i)&&/changes\.base/.test(i))' "$WF")
# gate-rerun-never-cancelled: no concurrency group, so a burst of events leaves no cancelled check runs (clean PRs read UNSTABLE)
if ! grep -qE '^(concurrency|  cancel-in-progress)' "$WF" && [ "$got" = "0 1 0 0 | 0 0 0 0 | 0 0 0 0 | 0 0 0 1" ] && grep -q "\-f pr=7" <<<"$disp" && grep -q -- "--ref feat" <<<"$disp"
then ok gate-rerun-never-cancelled; else fail gate-rerun-never-cancelled "got=$got disp=$disp $(cat "$T/rr.out")"; fi
# rerun-ignores-noise-senders: no comment triggers at all; reviews only from people, and only approvals or dismissals
if [ "$triggers" = "pull_request_review: pull_request:" ] && [ "$cond" = true ]; then ok rerun-ignores-noise-senders; else fail rerun-ignores-noise-senders "triggers=$triggers cond=$cond"; fi
# rerun-never-polls: an approval during a gate run exits at once; the job is capped at 2 minutes and has no sleep
if [ "${got#*| }" != "" ] && [ "$(echo "$got" | cut -d'|' -f2 | xargs)" = "0 0 0 0" ] && grep -q "timeout-minutes: 2" "$WF" && ! grep -q sleep "$T/rerun.sh"
then ok rerun-never-polls; else fail rerun-never-polls "got=$got"; fi
# gate-ignores-body-edits: std-gate has no edited trigger; only a base change (changes.base) re-gates, by dispatch
if ! grep -q edited <<<"$gtrig" && grep -q "workflow_dispatch" <<<"$gtrig" && [ "$cond" = true ] && grep -q "refs/pull/{0}/merge" "$GWF"
then ok gate-ignores-body-edits; else fail gate-ignores-body-edits "$gtrig"; fi
# gate-no-push-regate: pushes to main or staging start no gate run; standards/v* does
if grep -q 'branches: \["standards/v\*"\]' "$GWF" && ! grep -qE 'branches: \[.*(main|staging)' "$GWF"; then ok gate-no-push-regate; else fail gate-no-push-regate "$gtrig"; fi

# ---- gate plan: full, cheap or reuse, against the stand-in
put() { node -e 'const b={login:"chatgpt-codex-connector[bot]",type:"Bot"};require("fs").writeFileSync(process.argv[1],JSON.stringify(eval("("+process.argv[2]+")")))' "$T/state.json" "$1"; }
API="http://127.0.0.1:$(cat "$T/port")"
pl() { # pl <event-name> <event-json> [attempt] [ref]: prints the mode
  echo "$2" > "$T/pev.json"
  (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=$1 GITHUB_EVENT_PATH="$T/pev.json" GITHUB_RUN_ID=900 GITHUB_RUN_ATTEMPT=${3:-1} GITHUB_REF_NAME=${4:-feat} GITHUB_OUTPUT= \
    node scripts/agent/gate.mjs plan 2>&1) | sed -n 's/^mode=//p'; }
OKS='["standards","secrets","install","typecheck","build","e2e","repo checks"].map((name)=>({name,conclusion:"success"}))'
SKIPPED='["standards","secrets"].map((name)=>({name,conclusion:"success"})).concat(["install","typecheck","build","e2e","repo checks"].map((name)=>({name,conclusion:"skipped"})))'
PRE='{"pull_request":{"number":7}}'
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}},attempts:{1:$OKS}}"
r1=$(pl pull_request "$PRE" 1) r2=$(pl pull_request "$PRE" 2)
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}},attempts:{1:$SKIPPED}}"; r3=$(pl pull_request "$PRE" 2)
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}},attempts:{1:$OKS,2:$SKIPPED}}"; r4=$(pl pull_request "$PRE" 3)
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}},attempts:{1:$OKS.map((s)=>s.name==='standards'?{...s,conclusion:'failure'}:s)}}"; r5=$(pl pull_request "$PRE" 2)
# rerun-reuses-build: a re-run reuses a head's passed build (also through a reuse attempt); a cheap or failed-standards attempt does not qualify
if [ "$r1 $r2 $r3 $r4 $r5" = "full reuse full reuse full" ] && ! grep -A3 "name: codex review" "$GWF" | grep -q "mode" && ! grep -A3 "name: evidence" "$GWF" | grep -q "mode"
then ok rerun-reuses-build; else fail rerun-reuses-build "first/second/after-cheap/after-reuse/standards-failed: $r1 $r2 $r3 $r4 $r5"; fi
put "{pr:{number:7,draft:true,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}}}"; d1=$(pl pull_request "$PRE" 1)
put "{pr:{number:7,draft:false,head:{sha:\"$HEAD1\",ref:\"feat\"},base:{ref:\"main\"}}}"; d2=$(pl pull_request "$PRE" 1)
if [ "$d1 $d2" = "cheap full" ] && grep -q "ready_for_review" "$GWF"; then ok draft-cheap-ready-full; else fail draft-cheap-ready-full "draft=$d1 ready=$d2"; fi
LAND='{"sender":{"login":"example-sync[bot]"},"repository":{"default_branch":"main"}}'
c1=$(pl push "$LAND" 1 standards/v1.2.3)
cp "$R/scripts/agent/pack.json" "$T/pack.bak"; node -e 'const f=process.argv[1],p=require(f);p.gate_canary=["demo"];require("fs").writeFileSync(f,JSON.stringify(p))' "$R/scripts/agent/pack.json"
c2=$(pl push "$LAND" 1 standards/v1.2.3); cp "$T/pack.bak" "$R/scripts/agent/pack.json"
# pack-landing-cheap-except-canary: pack-only landings run cheap except on the profile canary (the evidence step still
# refuses a landing that changes anything outside the pack's paths)
if [ "$c1 $c2" = "cheap full" ] && grep -q "if: steps.plan.outputs.mode == 'cheap'" "$GWF"; then ok pack-landing-cheap-except-canary; else fail pack-landing-cheap-except-canary "landing=$c1 canary=$c2"; fi
# skip-never-greens-gate: the gate job has no job-level if; a workflow_dispatch re-gate evaluates the PR's Codex verdict
# (never "not a pull request"); evidence and codex run after a failed build step
jobif=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(/^ {4}if:/m.test(y.slice(y.indexOf("jobs:"))))' "$GWF")
st false alice feat "$HEAD1" '🔄 **Running** since' 5 "[]" yes "$HEAD1" "$HEAD1"
echo '{"inputs":{"pr":"7"}}' > "$T/dev.json"
dg=$(cd "$R" && GITHUB_API_URL=$API GITHUB_GRAPHQL_URL=$API/graphql GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="$T/dev.json" node scripts/agent/gate.mjs codex 2>&1); dx=$?
if [ "$jobif" = false ] && [ $dx -eq 1 ] && has "awaiting a Codex verdict" "$dg" && grep -A1 "name: codex review" "$GWF" | grep -q '!cancelled()'
then ok skip-never-greens-gate; else fail skip-never-greens-gate "jobif=$jobif dispatch=$dx $dg"; fi

# ---- the head's Workers Builds preview: a failed Cloudflare build fails gate; the URL comes from the bot comment
CF='{user:{login:"cloudflare-workers-and-pages[bot]"},body:"## Deploying\n### Preview URL: https://feat.preview.example.test, https://feat-demo.example.test (commit '"${HEAD1:0:7}"')\n"}'
pv() { (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$T/event.json" GATE_PREVIEW_WAIT_S=0 GITHUB_OUTPUT= node scripts/agent/gate.mjs preview 2>&1); }
put "{pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[{name:\"Workers Builds: demo\",status:\"completed\",conclusion:\"success\"}],comments:{7:[$CF]}}"; p1=$(pv); x1=$?
put "{pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[{name:\"Workers Builds: demo\",status:\"completed\",conclusion:\"failure\",details_url:\"https://dash.example\"}],comments:{7:[$CF]}}"; p2=$(pv); x2=$?
put "{pr:{number:7,head:{sha:\"$HEAD1\"}},checks:[],comments:{7:[]}}"; p3=$(pv); x3=$?
if [ $x1 -eq 0 ] && has "url=https://feat.preview.example.test" "$p1" && [ $x2 -eq 1 ] && has "Cloudflare build failed" "$p2" && [ $x3 -eq 0 ] && has "e2e runs locally" "$p3"
then ok e2e-uses-preview-url; else fail e2e-uses-preview-url "ok=$x1 red=$x2 none=$x3: $p1 | $p2 | $p3"; fi

# ---- verdict-recheck: re-runs the head's gate run only when that can change the result; status mode posts codex-verdict
vr() { (cd "$R" && GITHUB_API_URL=$API GITHUB_GRAPHQL_URL=$API/graphql GITHUB_REPOSITORY=acme/demo GH_TOKEN=t VERDICT_POLL_MS=10 scripts/agent/verdict-recheck 7 "$@" 2>&1); }
SUM="{user:b,updated_at:new Date().toISOString(),body:'<!-- codex-pull-request-review-summary -->\\n| 📝 **Code Review** | ✅ **Completed** now | \`${HEAD1:0:7}\` | x |'}"
base="pr:{number:7,draft:false,user:{login:'alice'},head:{sha:'$HEAD1',ref:'feat'}},comments:{7:[$SUM]},recent:[],threads:[],pushed:new Date(Date.now()-300000).toISOString(),timeline:[]"
steps() { echo "[{name:'standards',conclusion:'success'},{name:'evidence',conclusion:'$1'},{name:'codex review',conclusion:'$2'},{name:'build',conclusion:'$3'}]"; }
put "{$base,gateRuns:[{id:41,event:'pull_request',status:'completed',conclusion:'failure',run_attempt:1}],attempts:{1:$(steps success failure success)}}"; v1=$(vr); y1=$?; n1=$(node -p 'require(process.argv[1]).reruns?.length??0' "$T/state.json")
put "{$base,gateRuns:[{id:41,event:'pull_request',status:'completed',conclusion:'failure',run_attempt:1}],attempts:{1:$(steps success failure failure)}}"; v2=$(vr); y2=$?; n2=$(node -p 'require(process.argv[1]).reruns?.length??0' "$T/state.json")
put "{$base,gateRuns:[{id:41,event:'pull_request',status:'completed',conclusion:'failure',run_attempt:1}],attempts:{1:$(steps failure success success)}}"; v3=$(vr); n3=$(node -p 'require(process.argv[1]).reruns?.length??0' "$T/state.json"); v4=$(vr --evidence); n4=$(node -p 'require(process.argv[1]).reruns?.length??0' "$T/state.json")
put "{$base,gateRuns:[{id:41,event:'pull_request',status:'completed',conclusion:'success',run_attempt:1}],attempts:{1:$(steps success success success)}}"; v5=$(vr); n5=$(node -p 'require(process.argv[1]).reruns?.length??0' "$T/state.json")
if [ "$y1 $n1 | $y2 $n2 | $n3 $n4 | $n5" = "0 1 | 1 0 | 0 1 | 0" ] && has "failed only on codex review" "$v1" && has "needs a push" "$v2" && has "no new evidence" "$v3" && has "passed; nothing to re-check" "$v5"
then ok rerun-reuses-build; else fail rerun-reuses-build "verdict-recheck: $y1 $n1 | $y2 $n2 | $n3 $n4 | $n5 :: $v1 | $v2 | $v3 | $v4 | $v5"; fi
cp "$R/scripts/agent/pack.json" "$T/pack.bak"; node -e 'const f=process.argv[1],p=require(f);p.codex_verdict="status";require("fs").writeFileSync(f,JSON.stringify(p))' "$R/scripts/agent/pack.json"
put "{$base,gateRuns:[{id:41,event:'pull_request',status:'completed',conclusion:'success',run_attempt:1}],attempts:{1:$(steps success success success)}}"; s1=$(vr); sx=$?
posted=$(node -p 'const s=require(process.argv[1]).statuses??[];s.map(x=>x.context+"="+x.state+"@"+x.sha.slice(0,7)).join(",")' "$T/state.json")
gs=$(cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_PATH="$T/event.json" node scripts/agent/gate.mjs codex 2>&1)
put "{$base,statusForbidden:true,gateRuns:[]}"; s2=$(vr); s2x=$?
cp "$T/pack.bak" "$R/scripts/agent/pack.json"
# codex-verdict-status: in status mode verdict-recheck posts codex-verdict on the head (a token that cannot post fails loudly)
# and gate's codex step defers to that status
if [ $sx -eq 0 ] && [ "$posted" = "codex-verdict=success@${HEAD1:0:7}" ] && has "codex-verdict commit status" "$gs" && [ $s2x -eq 1 ] && has "needs the org App's token" "$s2"
then ok codex-verdict-status; else fail codex-verdict-status "posted=$posted exit=$sx/$s2x :: $s1 | $gs | $s2"; fi
done_cases
