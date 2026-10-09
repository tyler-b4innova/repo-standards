#!/usr/bin/env bash
# The release check on every Worker: the full suite runs once on the merge commit, against staging, and posts the
# check-run `release-check`. Through apply, the offline check and the workflow file.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GH_TOKEN
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap '{ kill $STUB; wait $STUB; } 2>/dev/null; rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "$OV" --version 0.1.0 --target "$1"; }
check() { (cd "$1" && scripts/agent/setup.sh --check) 2>&1; }
WF=.github/workflows/std-release-check.yml
echo '{}' > "$T/state.json"
node test/stubs/codex-github.mjs "$T/port" "$T/state.json" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$T/port")"
STAGING=https://staging.preview.example.com/
# worker <name> [staging_url]: a Worker repository with the pack applied
worker() { local d=$T/$1; git init -q -b main "$d"; printf '{\n  "name": "site",\n  "main": "src/index.ts",\n}\n' >"$d/wrangler.jsonc"; apply "$d" >/dev/null
  [ -z "${2:-}" ] || { jset "$d/standards.json" "o.staging_url=\"$2\""; apply "$d" >/dev/null; }; echo "$d"; }

why=""
W=$(worker w "$STAGING"); N=$(worker nourl)
git init -q -b main "$T/plain"; apply "$T/plain" >/dev/null
# a Worker with a staging_url ships it (no browsers named); one without a staging_url, or with no Worker, does not
[ -f "$W/$WF" ] && grep -q "  $WF$" "$W/standards.lock" || why="not shipped to a Worker with staging_url"
[ ! -e "$N/$WF" ] || why="$why; shipped without staging_url"
[ ! -e "$T/plain/$WF" ] || why="$why; shipped without a Worker"
# "e2e": false is still the opt-out
O=$(worker off "$STAGING"); jset "$O/standards.json" 'o.e2e=false'; apply "$O" >/dev/null; [ ! -e "$O/$WF" ] || why="$why; shipped despite e2e false"
# the workflow: the job is the check-run, pushes to main and manual runs only, one run per commit, never scheduled
yml=$(cat "$W/$WF")
has "workflow_dispatch:" "$yml" && ! has "check_run" "$yml" && ! has pull_request "$yml" && ! grep -qE '^\s*(push:|schedule:|- cron:)' "$W/$WF" || why="$why; triggers"
has "ref: \${{ env.RELEASE_SHA }}" "$yml" || why="$why; does not check out the built commit"
has "gate.mjs release-report" "$yml" || why="$why; the verdict is not posted as release-check"
has "gate.mjs e2e" "$yml" && has "gate.local.sh" "$yml" || why="$why; not the full suite (e2e and repo checks)"
has "GATE_SELECT" "$yml" || why="$why; selection is not switched off"
if [ -z "$why" ]; then ok release-check-every-worker; else fail release-check-every-worker "$why"; fi

# check.mjs: the managed workflow passes; a repo-owned workflow that tests on push to main does not, whatever its name
why=""
commit "$W" init; out=$(check "$W") || why="managed release check rejected: $out"
for name in ci.yml release-check.yml; do
  R=$T/own-$name; cp -R "$W" "$R"
  printf 'name: own\non:\n  push:\n    branches: [main]\njobs:\n  t:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 10\n    steps:\n      - uses: actions/checkout@v4\n      - run: npm test\n' >"$R/.github/workflows/$name"
  commit "$R" own; out=$(check "$R") && why="$why; $name tests on push to main passed" || has "beside the one gate" "$out" || why="$why; $name: [$out]"
done
# a managed workflow edited by hand fails the lock
R=$T/edited; cp -R "$W" "$R"; echo "# edit" >>"$R/$WF"; commit "$R" edit; check "$R" >/dev/null && why="$why; edited managed workflow passed"
if [ -z "$why" ]; then ok release-check-managed-only; else fail release-check-managed-only "$why"; fi

# --check says why a repository has no release check
why=""
commit "$N" init; out=$(check "$N") || why="no staging_url failed: $out"
has "no release check: standards.json has no staging_url" "$out" || why="$why; no staging_url notice: [$out]"
commit "$T/plain" init; out=$(check "$T/plain") || why="$why; no Worker failed: $out"
has "no release check: no Worker" "$out" || why="$why; no Worker notice: [$out]"
out=$(check "$W"); ! has "no release check" "$out" || why="$why; notice despite a release check: $out"
if [ -z "$why" ]; then ok release-check-notice; else fail release-check-notice "$why"; fi

# every production version carries the full commit sha as its tag; --check warns where a repo file uploads without one
why=""
R=$T/tagless; cp -R "$W" "$R"; jset "$R/package.json" 'o.scripts={deploy:"wrangler versions upload"}' 2>/dev/null || echo '{"scripts":{"deploy":"wrangler versions upload"}}' >"$R/package.json"; commit "$R" tagless
out=$(check "$R"); has "wrangler versions upload without --tag" "$out" || why="no tag warning: [$out]"
echo '{"scripts":{"deploy":"wrangler versions upload --tag \"$WORKERS_CI_COMMIT_SHA\""}}' >"$R/package.json"; commit "$R" tagged
out=$(check "$R"); ! has "without --tag" "$out" || why="$why; tagged upload warned"
grep -q 'WORKERS_CI_COMMIT_SHA || env.GITHUB_SHA' template/scripts/agent/release.mjs && grep -q '"--tag", sha' template/scripts/agent/release.mjs || why="$why; release.mjs does not tag with the commit"
if [ -z "$why" ]; then ok release-version-tagged; else fail release-version-tagged "$why"; fi

# staging serves the newest build that deployed: any later commit on the default branch (each one, so a change and its
# revert count) whose staging build is running or succeeded supersedes the run, before or after the suite. Superseded and
# nothing-to-certify runs cancel (force-cancel next) and fail closed if the runner is never interrupted; they never pass.
why=""
SHA=$(git -C "$W" rev-parse HEAD); MID=$(printf 'a%.0s' $(seq 40)); REV=$(printf 'b%.0s' $(seq 40)); DOC=$(printf 'c%.0s' $(seq 40))
st() { printf '%s' "$1" > "$T/state.json"; }
verify() { (cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t RELEASE_SHA=$SHA GITHUB_SHA=$(printf 'd%.0s' $(seq 40)) GITHUB_RUN_ID=77 GATE_CANCEL_WAIT_S=0 GATE_FORCE_WAIT_S=0 GATE_PREVIEW_WAIT_S=${WAIT:-0} GITHUB_OUTPUT= node scripts/agent/gate.mjs "$@" 2>&1); echo "exit=$?"; }
OKB='{"name":"Workers Builds: demo","status":"completed","conclusion":"success"}'
RUNB='{"name":"Workers Builds: demo","status":"in_progress"}'
SKIPB='{"name":"Workers Builds: demo","status":"completed","conclusion":"skipped"}'
# the head is this commit: nothing after it
st "{\"checks\":[$OKB]}"
o=$(verify release-verify); has "exit=0" "$o" && ! grep -q cancelled "$T/state.json" || why="current: $o"
# a change then its revert after this commit: the net diff is empty but each deploys (the revert's build is running)
st "{\"compareCommits\":[\"$MID\",\"$REV\"],\"checksBy\":{\"$MID\":[$OKB],\"$REV\":[$RUNB]}}"
o=$(verify release-verify); has "superseded during the suite: aaaaaaa" "$o" && grep -q '"cancelled":\[77\]' "$T/state.json" || why="$why; change then revert certified: $o"
# the change's build was skipped by Cloudflare but the revert's build is running: the revert alone supersedes
st "{\"compareCommits\":[\"$MID\",\"$REV\"],\"checksBy\":{\"$MID\":[$SKIPB],\"$REV\":[$RUNB]}}"
o=$(verify release-verify); has "superseded during the suite: bbbbbbb" "$o" || why="$why; the revert's build did not supersede: $o"
# the same history seen before the suite: this commit's own build is done, a later one is deploying
st "{\"checksBy\":{\"$SHA\":[$OKB],\"$MID\":[$OKB]},\"compareCommits\":[\"$MID\"]}"
o=$(verify release); has "superseded: aaaaaaa" "$o" && has "skip=true" "$o" && ! has "browsers=chromium" "$o" || why="$why; superseded before the suite: $o"
# later commits whose builds Cloudflare skipped (docs) deploy nothing
st "{\"compareCommits\":[\"$DOC\"],\"checksBy\":{\"$DOC\":[$SKIPB]}}"
o=$(verify release-verify); has "exit=0" "$o" && ! grep -q cancelled "$T/state.json" || why="$why; a skipped later build superseded: $o"
# check-runs come 100 to a page: an in-progress own build on page 2 is waited for, a superseding later build on page 2 is seen
FILL=$(node -e 'console.log(JSON.stringify(Array.from({length:100},(_, i)=>({name:"other-"+i,status:"completed",conclusion:"success"}))).slice(1,-1))')
st "{\"checksBy\":{\"$SHA\":[$FILL,$RUNB]}}"
o=$(verify release); has "exit=1" "$o" && has "still running" "$o" || why="$why; an own build on page 2 was not waited for: $o"
st "{\"checksBy\":{\"$SHA\":[$OKB],\"$MID\":[$FILL,$RUNB]},\"compareCommits\":[\"$MID\"]}"
o=$(verify release-verify); has "superseded during the suite: aaaaaaa" "$o" || why="$why; a superseding build on page 2 was missed: $o"
# a later build that FAILED may already have deployed staging (release.mjs deploys staging, then fails in a later step)
FAILB='{"name":"Workers Builds: demo","status":"completed","conclusion":"failure"}'
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$FAILB]}}"
o=$(verify release-verify); has "superseded during the suite: aaaaaaa" "$o" || why="$why; a later failed build did not supersede: $o"
NEUB='{"name":"Workers Builds: demo","status":"completed","conclusion":"neutral"}'
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$NEUB]}}"
o=$(verify release-verify); has "exit=0" "$o" || why="$why; a neutral build superseded: $o"
# provenance: a same-named check from another App is no deployment evidence (later commits, or this one)
FOREIGN='{"name":"Workers Builds: demo","status":"completed","conclusion":"success","app":{"slug":"some-other-app"}}'
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$FOREIGN]}}"
o=$(verify release-verify); has "exit=0" "$o" && ! grep -q cancelled "$T/state.json" || why="$why; a foreign App's build superseded: $o"
st "{\"checks\":[$FOREIGN]}"
o=$(verify release); has "exit=1" "$o" && has "no \"Workers Builds\" check on ${SHA:0:7}" "$o" || why="$why; a foreign App's success certified the commit: $o"
# cancel accepted but the runner is never interrupted: force-cancel, then fail closed, never green
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$OKB]}}"
o=$(verify release-verify); has "exit=1" "$o" && has "not interrupted after cancel and force-cancel" "$o" && grep -q '"forced":\[77\]' "$T/state.json" || why="$why; uninterrupted cancel did not fail closed: $o"
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$OKB]},\"forceFail\":true}"
o=$(verify release-verify); has "exit=1" "$o" && has "force-cancel failed" "$o" || why="$why; failed force-cancel passed: $o"
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$OKB]},\"cancelFail\":true}"
o=$(verify release-verify); has "exit=1" "$o" && has "could not cancel" "$o" || why="$why; failed cancel passed: $o"
# the post-suite step runs after a failing suite (a failure caused by a newer deploy cancels); never after a cancel
yml=$(cat "$W/$WF"); has "if: \${{ needs.suite.result == 'success' || needs.suite.result == 'failure' }}" "$yml" && has "gate.mjs release-verify" "$yml" || why="$why; still-staging step skipped after a failing suite"
# the repo checks and the suite both see the staging URL
blk=$(awk '/- name: repo checks/{f=1} f' "$W/$WF")
for v in BASE_URL PLAYWRIGHT_BASE_URL GATE_PREVIEW_URL; do has "$v: \${{ needs.pre.outputs.url }}" "$blk" || why="$why; repo checks lack $v"; done
has "actions: write" "$yml" && has "checks: write" "$yml" || why="$why; cannot cancel or post"
if [ -z "$why" ]; then ok release-check-staging-superseded; else fail release-check-staging-superseded "$why"; fi

why=""
# the commit under test is the dispatched sha, never GITHUB_SHA (the ref's tip, a newer commit here):
# its builds are the ones waited for, and the verdict is posted on it
TIP=$(printf 'd%.0s' $(seq 40))
st "{\"checksBy\":{\"$SHA\":[$OKB],\"$TIP\":[$RUNB]}}"
o=$(verify release); has "exit=0" "$o" && has "browsers=chromium" "$o" && has "(${SHA:0:7})" "$o" || why="$why; tested the tip's build, not head_sha: $o"
# the workflow is dispatch-only: no check_run, push, pull_request or schedule trigger and no job condition, so it can
# start only when something promoting a version dispatches it with that version's commit
trigger=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("\non:"),y.indexOf("\npermissions:")))' "$W/$WF")
has "workflow_dispatch:" "$trigger" && has "sha:" "$trigger" && has "required: true" "$trigger" && ! has check_run "$trigger" && ! has "push:" "$trigger" && ! has pull_request "$trigger" && ! has schedule "$trigger" || why="$why; triggers: $trigger"
python3 -c 'import sys,yaml; j=yaml.safe_load(open(sys.argv[1]))["jobs"]; sys.exit(1 if "if" in j["pre"] else 0)' "$W/$WF" || why="$why; the pre job has a condition"
# one run per commit: a second dispatch for the same commit cancels the first
has 'group: std-release-check-${{ inputs.sha }}' "$yml" && has "cancel-in-progress: true" "$yml" && grep -qE '^concurrency:' "$W/$WF" || why="$why; concurrency is not per commit"
! grep -q GATE_BUILD_GRACE_S template/scripts/agent/gate.mjs || why="$why; a runtime grace remains"
if [ -z "$why" ]; then ok release-check-trigger; else fail release-check-trigger "$why"; fi

# the dispatch contract the portal relies on: (a) sha is a required exact 40-hex input, failing fast and plainly; (b) the
# job checks out exactly that sha and it must be reachable from the default branch; (c) the verdict check-run is created
# in_progress at the start and completed once, never green when superseded; (d) run-name carries the sha
why=""
git -C "$W" update-ref refs/remotes/origin/main "$(git -C "$W" rev-parse HEAD)"
SIDE=$(git -C "$W" commit-tree "$(git -C "$W" hash-object -t tree /dev/null)" -m side)
cstart() { (cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_RUN_ID=77 RELEASE_SHA=$1 GITHUB_OUTPUT= GITHUB_ENV=$T/ghenv node scripts/agent/gate.mjs release-start 2>&1); echo "exit=$?"; }
cdo() { local id=$1 suite=$2 verify=$3; shift 3; (cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t RELEASE_SHA=$SHA RELEASE_CHECK_ID=$id RELEASE_PRE=${PRE:-success} RELEASE_SUITE=$suite RELEASE_VERIFY=$verify node scripts/agent/gate.mjs "$@" 2>&1); }
run0() { node -e 'const st=require(process.argv[1]);const r=st.runs?.[Number(process.argv[2])];console.log(r?[r.name,r.head_sha,r.status,r.conclusion??"-"].join(" "):"none")' "$T/state.json" "${1:-0}"; }
# (d) and (b): run-name, and the checkout is exactly the dispatched sha
has "run-name: release-check \${{ inputs.sha }}" "$(cat "$W/$WF")" || why="$why; no run-name carrying the sha"
has 'ref: ${{ env.RELEASE_SHA }}' "$(cat "$W/$WF")" || why="$why; the checkout is not the dispatched sha"
# (a) the workflow's own first step rejects anything but 40 lowercase hex, plainly
check_step=$(awk '/- name: sha$/{f=1;next} f&&/^      - /{exit} f&&/^        run: \|/{r=1;next} f&&r' "$W/$WF" | sed 's/^          //')
for bad in "" abc "$(printf 'A%.0s' $(seq 40))" "${SHA:0:39}" "${SHA}0" "main"; do
  out=$(RELEASE_SHA=$bad bash -c "$check_step" 2>&1) && why="$why; sha '$bad' accepted" || has "full 40-character lowercase hex commit sha" "$out" || why="$why; sha '$bad': [$out]"
done
RELEASE_SHA=$SHA bash -c "$check_step" >/dev/null 2>&1 || why="$why; a full sha rejected"
st '{}'; o=$(cstart abc); has "exit=1" "$o" && has "full 40-character commit sha" "$o" && [ "$(run0)" = none ] || why="$why; release-start accepted a short sha or created a check: $o"
# (b) a sha main does not contain: plain error, no verdict created
st '{}'; o=$(cstart "$SIDE"); has "exit=1" "$o" && has "is not on the default branch" "$o" && [ "$(run0)" = none ] || why="$why; an off-main sha was accepted: $o"
# (c) the verdict is created in_progress on the sha, with its id handed to the later steps
st '{}'; rm -f "$T/ghenv"; o=$(cstart "$SHA"); has "exit=0" "$o" && [ "$(run0)" = "release-check $SHA in_progress -" ] && grep -q "RELEASE_CHECK_ID=1" "$T/ghenv" || why="$why; no in_progress verdict on the sha: $o $(run0)"
cdo 1 success success release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed success" ] || why="$why; success not completed: $(run0)"
st '{}'; cstart "$SHA" >/dev/null; cdo 1 failure success release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed failure" ] || why="$why; failure not completed: $(run0)"
st '{}'; cstart "$SHA" >/dev/null; cdo 1 cancelled cancelled release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed cancelled" ] || why="$why; cancel not completed: $(run0)"
# the verdict is computed at report time: success only if pre, the suite and the supersession check all succeeded
st "{\"compareFail\":true}"; o=$( (cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t RELEASE_SHA=$SHA GATE_CANCEL_WAIT_S=0 node scripts/agent/gate.mjs release-verify 2>&1); echo "exit=$?")
has "exit=1" "$o" && has "503" "$o" || why="$why; release-verify did not fail on an API 503: $o"
st '{}'; cstart "$SHA" >/dev/null; cdo 1 success failure release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed failure" ] || why="$why; suite green but verify failed was not failure: $(run0)"
st '{}'; cstart "$SHA" >/dev/null; cdo 1 skipped skipped release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed failure" ] || why="$why; suite skipped was not failure: $(run0)"
st '{}'; cstart "$SHA" >/dev/null; PRE=failure cdo 1 skipped skipped release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed failure" ] || why="$why; pre failure was not failure: $(run0)"
st '{}'; cstart "$SHA" >/dev/null; cdo 1 cancelled skipped release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed cancelled" ] || why="$why; suite cancelled was not cancelled: $(run0)"
st '{}'; cstart "$SHA" >/dev/null; node -e 'const r=require(process.argv[1]).runs[0];process.exit(r.external_id==="77"&&r.details_url.endsWith("/actions/runs/77")?0:1)' "$T/state.json" || why="$why; the check-run does not carry the workflow run id as external_id"
# superseded: completed as neutral with the reason, never green; the report step then leaves it alone
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$OKB]}}"; cstart "$SHA" >/dev/null
o=$( (cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_RUN_ID=77 GATE_CANCEL_WAIT_S=0 GATE_FORCE_WAIT_S=0 RELEASE_SHA=$SHA RELEASE_CHECK_ID=1 GITHUB_OUTPUT= node scripts/agent/gate.mjs release-verify 2>&1); echo "exit=$?")
[ "$(run0)" = "release-check $SHA completed neutral" ] && node -e 'const r=require(process.argv[1]).runs[0];process.exit(/superseded during the suite/.test(r.output.summary)&&/not a pass/.test(r.output.summary)?0:1)' "$T/state.json" || why="$why; superseded run not neutral with a reason: $(run0) $o"
cdo 1 success success release-report >/dev/null; [ "$(run0)" = "release-check $SHA completed neutral" ] || why="$why; a neutral verdict was overwritten: $(run0)"
if [ -z "$why" ]; then ok release-check-dispatch-contract; else fail release-check-dispatch-contract "$why"; fi

# the verdict is written only by trusted steps: no code from the dispatched commit holds a write token. pre and post run
# the default branch's workflow and scripts; the suite job (the only one that checks out the sha) holds contents: read only,
# and the sha is shown to be on the default branch in plain shell before it is ever checked out
why=""
cat >"$T/wfcheck.py" <<'PY'
import sys, yaml
y = yaml.safe_load(open(sys.argv[1])); jobs = y["jobs"]; bad = []
if set(jobs) != {"pre", "suite", "post"}: bad.append("jobs " + ",".join(jobs))
if y["permissions"] != {"contents": "read"}: bad.append("workflow permissions are not contents: read")
if jobs["suite"]["permissions"] != {"contents": "read"}: bad.append("the suite job holds more than contents: read")
for n in ("pre", "post"):
    p = jobs[n]["permissions"]
    if p.get("checks") != "write": bad.append(n + " cannot write the verdict")
steps = jobs["suite"]["steps"]
text = yaml.safe_dump(steps)
for needle in ("github.token", "GITHUB_TOKEN", "secrets.", "checks: write", "actions: write"):
    if needle in text: bad.append("suite step mentions " + needle)
sha_checkout = lambda st: str(st.get("with", {}).get("ref", "")).startswith("${{ env.RELEASE_SHA")
if not sha_checkout(steps[0]): bad.append("the suite does not check out exactly the sha first")
for n in ("pre", "post"):
    if any(sha_checkout(st) for st in jobs[n]["steps"]): bad.append(n + " checks out the sha")
    co = [st for st in jobs[n]["steps"] if "checkout" in str(st.get("uses", ""))]
    if not co or "default_branch" not in str(co[0]["with"]["ref"]): bad.append(n + " does not check out the default branch")
pre = jobs["pre"]["steps"]; names = [st.get("name", st.get("uses", "")) for st in pre]
ancestry = [i for i, st in enumerate(pre) if "merge-base --is-ancestor" in str(st.get("run", ""))]
node_runs = [i for i, st in enumerate(pre) if "node scripts/agent" in str(st.get("run", ""))]
if not ancestry or not node_runs or ancestry[0] > min(node_runs): bad.append("the default-branch check does not come before any script")
if bad: print("; ".join(bad)); sys.exit(1)
PY
out=$(python3 "$T/wfcheck.py" "$W/$WF" 2>&1) || why="$why; workflow structure: $out"
# an off-main sha is refused by that shell step alone, before any code of the sha runs
anc=$(python3 -c 'import sys,yaml; print([s["run"] for s in yaml.safe_load(open(sys.argv[1]))["jobs"]["pre"]["steps"] if "merge-base" in str(s.get("run",""))][0])' "$W/$WF")
G=$T/anc; git init -q -b main "$G"; gc -C "$G" commit -q --allow-empty -m main1; MAIN=$(git -C "$G" rev-parse HEAD)
gc -C "$G" checkout -q -b side; gc -C "$G" commit -q --allow-empty -m side; OFF=$(git -C "$G" rev-parse HEAD); gc -C "$G" checkout -q main
git -C "$G" update-ref refs/remotes/origin/main main
out=$(cd "$G" && RELEASE_SHA=$OFF DEFAULT_BRANCH=main bash -c "$anc" 2>&1) && why="$why; an off-main sha passed the shell check" || has "is not on the default branch" "$out" || why="$why; off-main: [$out]"
(cd "$G" && RELEASE_SHA=$MAIN DEFAULT_BRANCH=main bash -c "$anc" >/dev/null 2>&1) || why="$why; a main sha was refused by the shell check"
if [ -z "$why" ]; then ok release-check-trusted-steps; else fail release-check-trusted-steps "$why"; fi

# a consumer's proof (release.mjs verify-release-check): the check-run's external_id is a real workflow run of this workflow,
# dispatched on the default branch, titled for this sha, and successful; a forged check-run pointing at another sha's run is refused
why=""
OTHER=$(printf '9%.0s' $(seq 40))
vrc() { (cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t node scripts/agent/release.mjs verify-release-check "$1" 2>&1); echo "exit=$?"; }
GOOD="{\"id\":9,\"name\":\"release-check\",\"status\":\"completed\",\"conclusion\":\"success\",\"completed_at\":\"2026-10-09T00:00:00Z\",\"app\":{\"slug\":\"github-actions\"},\"external_id\":\"501\"}"
run() { printf '{"id":501,"path":".github/workflows/std-release-check.yml","event":"workflow_dispatch","head_branch":"main","status":"completed","conclusion":"success","display_title":"release-check %s",%s}' "$1" "${2:-\"x\":1}"; }
st "{\"checksBy\":{\"$SHA\":[$GOOD]},\"gateRuns\":[$(run "$SHA")]}"; o=$(vrc "$SHA"); has "exit=0" "$o" && has "verified" "$o" || why="a genuine release-check was refused: $o"
st "{\"checksBy\":{\"$SHA\":[$GOOD]},\"gateRuns\":[$(run "$OTHER")]}"; o=$(vrc "$SHA"); has "exit=1" "$o" && has "another commit" "$o" || why="$why; a forged check-run pointing at another sha's run was accepted: $o"
st "{\"checksBy\":{\"$SHA\":[$GOOD]},\"gateRuns\":[$(run "$SHA" '"event":"push"')]}"; o=$(vrc "$SHA"); has "exit=1" "$o" && has "not a workflow_dispatch" "$o" || why="$why; a push-event run was accepted: $o"
st "{\"checksBy\":{\"$SHA\":[$GOOD]},\"gateRuns\":[$(run "$SHA" '"head_branch":"feat/x"')]}"; o=$(vrc "$SHA"); has "exit=1" "$o" && has "not the default branch" "$o" || why="$why; a feature-branch run was accepted: $o"
st "{\"checksBy\":{\"$SHA\":[$GOOD]},\"gateRuns\":[$(run "$SHA" '"path":".github/workflows/other.yml"')]}"; o=$(vrc "$SHA"); has "exit=1" "$o" || why="$why; another workflow's run was accepted: $o"
st "{\"checksBy\":{\"$SHA\":[$GOOD]},\"gateRuns\":[$(run "$SHA" '"conclusion":"failure"')]}"; o=$(vrc "$SHA"); has "exit=1" "$o" || why="$why; an unsuccessful run was accepted: $o"
st "{\"checksBy\":{\"$SHA\":[{\"id\":9,\"name\":\"release-check\",\"status\":\"completed\",\"conclusion\":\"success\",\"app\":{\"slug\":\"some-other-app\"},\"external_id\":\"501\"}]},\"gateRuns\":[$(run "$SHA")]}"; o=$(vrc "$SHA"); has "exit=1" "$o" || why="$why; another App's check-run was accepted: $o"
st "{\"checksBy\":{\"$SHA\":[{\"id\":9,\"name\":\"release-check\",\"status\":\"completed\",\"conclusion\":\"success\",\"app\":{\"slug\":\"github-actions\"}}]},\"gateRuns\":[$(run "$SHA")]}"; o=$(vrc "$SHA"); has "exit=1" "$o" || why="$why; a check-run with no run id was accepted: $o"
st "{\"checksBy\":{\"$SHA\":[]},\"gateRuns\":[]}"; o=$(vrc "$SHA"); has "exit=1" "$o" || why="$why; no release-check was accepted: $o"
o=$(vrc abc); has "exit=1" "$o" || why="$why; a short sha was accepted"
# pre refuses a dispatch from any ref but the default branch's
refstep=$(python3 -c 'import sys,yaml; print([s["run"] for s in yaml.safe_load(open(sys.argv[1]))["jobs"]["pre"]["steps"] if s.get("name")=="ref"][0])' "$W/$WF")
out=$(GITHUB_REF=refs/heads/feat/x DEFAULT_REF=refs/heads/main bash -c "$refstep" 2>&1) && why="$why; a dispatch from a feature branch passed the ref step" || has "only from the default branch" "$out" || why="$why; [$out]"
GITHUB_REF=refs/heads/main DEFAULT_REF=refs/heads/main bash -c "$refstep" >/dev/null 2>&1 || why="$why; a dispatch from the default branch was refused"
if [ -z "$why" ]; then ok release-check-provenance; else fail release-check-provenance "$why"; fi

# the @a11y contract: RELEASE_CHECK=1 reaches the suite only through the release check
why=""
R=$T/a11y; cp -R "$W" "$R"; echo '{"scripts":{"test:e2e":"[ \"$RELEASE_CHECK\" != 1 ]"}}' >"$R/package.json"; commit "$R" a11y
e2e() { (cd "$R" && env "$@" GITHUB_OUTPUT= node scripts/agent/gate.mjs "${E2E_ARGS[@]}" 2>&1); echo "exit=$?"; }
E2E_ARGS=(e2e --release); o=$(e2e RELEASE_CHECK=1); has "exit=1" "$o" || why="a failing @a11y test passed the release run: $o"
E2E_ARGS=(e2e); o=$(e2e RELEASE_CHECK=1); has "exit=0" "$o" || why="$why; the PR gate ran @a11y tests: $o"
E2E_ARGS=(e2e --release); o=$(e2e); has "exit=0" "$o" || why="$why; release run without the flag still set it: $o"
for f in "$W/$WF"; do blk=$(awk '/- name: e2e/{f=1} f' "$f"); has 'RELEASE_CHECK: "1"' "$blk" && has "gate.mjs e2e --release" "$blk" || why="$why; release e2e step lacks the contract"; done
rc=$(awk '/- name: repo checks/{f=1} /^  post:/{f=0} f' "$W/$WF"); has 'RELEASE_CHECK: "1"' "$rc" || why="$why; repo checks lack RELEASE_CHECK"
grep -q "env -u RELEASE_CHECK bash scripts/agent/gate.local.sh" "$W/.github/workflows/std-gate.yml" || why="$why; PR gate repo checks do not clear RELEASE_CHECK"
if [ -z "$why" ]; then ok release-check-a11y-contract; else fail release-check-a11y-contract "$why"; fi

# a release run is the whole suite: every Playwright project (a non-browser one included), no file filter, no time cap;
# the pull-request gate (no GATE_SELECT=full) runs Chromium only
why=""
R=$T/full; cp -R "$W" "$R"; echo '{"scripts":{}}' >"$R/package.json"; mkdir -p "$R/node_modules/.bin" "$R/tests/e2e"
printf 'export default { projects: [{ name: "chromium" }, { name: "api" }] };\n' >"$R/playwright.config.ts"; echo "// spec" >"$R/tests/e2e/a.spec.ts"
printf '#!/bin/sh\necho "PLAYWRIGHT $* PW_GLOBAL_TIMEOUT=${PW_GLOBAL_TIMEOUT:-none}"\n' >"$R/node_modules/.bin/playwright"; chmod +x "$R/node_modules/.bin/playwright"; commit "$R" full
rune2e() { (cd "$R" && env "$@" GITHUB_OUTPUT= node scripts/agent/gate.mjs e2e --release 2>&1); }
o=$(rune2e GATE_SELECT=full RELEASE_CHECK=1 GATE_BROWSERS=chromium,firefox)
has "PLAYWRIGHT test" "$o" && ! has "--project" "$o" && has "PW_GLOBAL_TIMEOUT=none" "$o" && ! has "budget" "$o" || why="release run: $o"
o=$(rune2e GATE_BROWSERS=chromium)
has "--project=chromium" "$o" && ! has "--project=api" "$o" || why="$why; the PR gate did not stay on Chromium: $o"
grep -q "timeout:" <(sed -n '/cmd === "e2e"/,/cmd === "secrets"/p' template/scripts/agent/gate.mjs | grep spawnSync) && why="$why; the e2e child has a time cap"
if [ -z "$why" ]; then ok release-check-full-suite; else fail release-check-full-suite "$why"; fi
done_cases
