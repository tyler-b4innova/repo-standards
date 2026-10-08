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
has "check_run:" "$yml" && has "types: [completed]" "$yml" && has "workflow_dispatch" "$yml" && ! has pull_request "$yml" && ! grep -qE '^\s*(push:|schedule:|- cron:)' "$W/$WF" || why="$why; triggers"
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
# cancel accepted but the runner is never interrupted: force-cancel, then fail closed, never green
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$OKB]}}"
o=$(verify release-verify); has "exit=1" "$o" && has "not interrupted after cancel and force-cancel" "$o" && grep -q '"forced":\[77\]' "$T/state.json" || why="$why; uninterrupted cancel did not fail closed: $o"
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$OKB]},\"forceFail\":true}"
o=$(verify release-verify); has "exit=1" "$o" && has "force-cancel failed" "$o" || why="$why; failed force-cancel passed: $o"
st "{\"compareCommits\":[\"$MID\"],\"checksBy\":{\"$MID\":[$OKB]},\"cancelFail\":true}"
o=$(verify release-verify); has "exit=1" "$o" && has "could not cancel" "$o" || why="$why; failed cancel passed: $o"
# the post-suite step runs after a failing suite (a failure caused by a newer deploy cancels); never after a cancel
yml=$(cat "$W/$WF"); has 'if: ${{ !cancelled() && steps.release.outputs.skip != '"'"'true'"'"' }}' "$yml" && has "gate.mjs release-verify" "$yml" || why="$why; still-staging step skipped after a failing suite"
# the repo checks and the suite both see the staging URL
blk=$(awk '/- name: repo checks/{f=1} f' "$W/$WF")
for v in BASE_URL PLAYWRIGHT_BASE_URL GATE_PREVIEW_URL; do has "$v: \${{ steps.release.outputs.url }}" "$blk" || why="$why; repo checks lack $v"; done
has "actions: write" "$yml" && has "checks: write" "$yml" || why="$why; cannot cancel or post"
if [ -z "$why" ]; then ok release-check-staging-superseded; else fail release-check-staging-superseded "$why"; fi

why=""
# the commit under test is the check-run's head_sha, never GITHUB_SHA (the default branch's tip, a newer commit here):
# its builds are the ones waited for, and the verdict is posted on it
TIP=$(printf 'd%.0s' $(seq 40))
st "{\"checksBy\":{\"$SHA\":[$OKB],\"$TIP\":[$RUNB]}}"
o=$(verify release); has "exit=0" "$o" && has "browsers=chromium" "$o" && has "(${SHA:0:7})" "$o" || why="$why; tested the tip's build, not head_sha: $o"
st '{}'; o2=$(cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t RELEASE_SHA=$SHA GITHUB_SHA=$TIP RELEASE_JOB_STATUS=success node scripts/agent/gate.mjs release-report 2>&1)
node -e 'const st=require(process.argv[1]);const p=st.posted?.[0];process.exit(p&&p.name==="release-check"&&p.head_sha===process.argv[2]&&p.conclusion==="success"?0:1)' "$T/state.json" "$SHA" || why="$why; success not posted on head_sha: $o2"
st '{}'; (cd "$W" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t RELEASE_SHA=$SHA GITHUB_SHA=$TIP RELEASE_JOB_STATUS=failure node scripts/agent/gate.mjs release-report >/dev/null 2>&1)
node -e 'const p=require(process.argv[1]).posted?.[0];process.exit(p&&p.head_sha===process.argv[2]&&p.conclusion==="failure"?0:1)' "$T/state.json" "$SHA" || why="$why; failure not posted on head_sha"
# the job condition (evaluated as GitHub does) starts a job only for a default-branch Workers Builds completion or a manual run
cond=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");const m=y.match(/^    if: \$\{\{ (.*) \}\}$/m);console.log(m[1])' "$W/$WF")
runs() { node -e '
const [cond, event, name, branch] = process.argv.slice(1);
const startsWith = (a, b) => String(a ?? "").toLowerCase().startsWith(String(b).toLowerCase());
const github = { event_name: event, event: { check_run: { name, head_branch: branch }, repository: { default_branch: "main" } } };
console.log(new Function("github", "startsWith", "return (" + cond + ")")(github, startsWith) ? "job" : "no job")' "$cond" "$@"; }
[ "$(runs check_run 'Workers Builds: site' main)" = job ] || why="$why; a default-branch Workers Builds completion starts no job"
[ "$(runs check_run 'gate' main)" = "no job" ] || why="$why; a non-Builds check-run started a job"
[ "$(runs check_run 'release-check' main)" = "no job" ] || why="$why; the verdict check-run restarts the release check"
[ "$(runs check_run 'Workers Builds: site' feat/x)" = "no job" ] || why="$why; a non-default-branch build started a job"
[ "$(runs workflow_dispatch '' '')" = job ] || why="$why; a manual run starts no job"
# several Workers finish at different times: one group per commit, the last completion's run cancels earlier ones
has 'group: std-release-check-${{ github.event.check_run.head_sha || inputs.sha }}' "$yml" && has "cancel-in-progress: true" "$yml" && grep -qE '^    concurrency:' "$W/$WF" && ! grep -qE '^concurrency:' "$W/$WF" || why="$why; concurrency is not per commit at job level"
! grep -q GATE_BUILD_GRACE_S template/scripts/agent/gate.mjs || why="$why; a runtime grace remains"
if [ -z "$why" ]; then ok release-check-trigger; else fail release-check-trigger "$why"; fi

# the @a11y contract: RELEASE_CHECK=1 reaches the suite only through the release check
why=""
R=$T/a11y; cp -R "$W" "$R"; echo '{"scripts":{"test:e2e":"[ \"$RELEASE_CHECK\" != 1 ]"}}' >"$R/package.json"; commit "$R" a11y
e2e() { (cd "$R" && env "$@" GITHUB_OUTPUT= node scripts/agent/gate.mjs "${E2E_ARGS[@]}" 2>&1); echo "exit=$?"; }
E2E_ARGS=(e2e --release); o=$(e2e RELEASE_CHECK=1); has "exit=1" "$o" || why="a failing @a11y test passed the release run: $o"
E2E_ARGS=(e2e); o=$(e2e RELEASE_CHECK=1); has "exit=0" "$o" || why="$why; the PR gate ran @a11y tests: $o"
E2E_ARGS=(e2e --release); o=$(e2e); has "exit=0" "$o" || why="$why; release run without the flag still set it: $o"
for f in "$W/$WF"; do blk=$(awk '/- name: e2e/{f=1} f' "$f"); has 'RELEASE_CHECK: "1"' "$blk" && has "gate.mjs e2e --release" "$blk" || why="$why; release e2e step lacks the contract"; done
rc=$(awk '/- name: repo checks/{f=1} /- name: still staging/{f=0} f' "$W/$WF"); has 'RELEASE_CHECK: "1"' "$rc" || why="$why; repo checks lack RELEASE_CHECK"
grep -q "env -u RELEASE_CHECK bash scripts/agent/gate.local.sh" "$W/.github/workflows/std-gate.yml" || why="$why; PR gate repo checks do not clear RELEASE_CHECK"
if [ -z "$why" ]; then ok release-check-a11y-contract; else fail release-check-a11y-contract "$why"; fi
done_cases
