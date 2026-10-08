#!/usr/bin/env bash
# The release check: a repository's extra browsers run on main, against its staging Preview, after the main build and
# before anyone deploys the uploaded production version. Through apply, the offline check and gate.mjs release, against
# a GitHub stand-in.
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
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "${OVERLAY:-$OV}" --version 0.1.0 --target "$1"; }
check() { (cd "$1" && scripts/agent/setup.sh --check) 2>&1; }
WF=.github/workflows/std-release-check.yml
SHA=$(printf 'e%.0s' $(seq 40))
echo '{}' > "$T/state.json"
node test/stubs/codex-github.mjs "$T/port" "$T/state.json" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$T/port")"
put() { printf '%s' "$1" > "$T/state.json"; }
rel() { (cd "$1" && GATE_CANCEL_WAIT_S=0 GATE_FORCE_WAIT_S=0 GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t RELEASE_SHA=$SHA GATE_PREVIEW_WAIT_S=0 GITHUB_OUTPUT= node scripts/agent/gate.mjs release 2>&1); echo "exit=$?"; }
why=""

O=$T/ov.json; node -e 'const o=require(process.argv[1]);o.e2e={release_browsers:["webkit"]};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$O"
# shipped (and locked) only where extra browsers are named: the repository's e2e.browsers, or the overlay's
R=$T/plain; git init -q -b main "$R"; apply "$R" >/dev/null; [ ! -e "$R/$WF" ] || why="shipped with no browsers"
R=$T/site; git init -q -b main "$R"; apply "$R" >/dev/null
jset "$R/standards.json" 'o.e2e={browsers:["firefox","webkit"]}'; apply "$R" >/dev/null
[ -f "$R/$WF" ] && grep -q "  $WF$" "$R/standards.lock" || why="$why; not shipped with e2e.browsers"
# "e2e": false opts out of the release check too, whatever browsers the repository or the org names
R3=$T/optout; git init -q -b main "$R3"; apply "$R3" >/dev/null; jset "$R3/standards.json" 'o.e2e=false'; OVERLAY=$O apply "$R3" >/dev/null
[ ! -e "$R3/$WF" ] || why="$why; shipped despite e2e false"
commit "$R3"; out=$(check "$R3") || why="$why; e2e false still required staging_url: $out"
commit "$R"; out=$(check "$R"); has "standards.json staging_url" "$out" || why="$why; browsers without staging_url passed: $out"
jset "$R/standards.json" 'o.staging_url="http://staging.example.com"'; commit "$R"; out=$(check "$R"); has "standards.json staging_url" "$out" || why="$why; http staging_url passed"
jset "$R/standards.json" 'o.staging_url="https://staging.preview.example.com/"'; commit "$R"; out=$(check "$R") || why="$why; check failed: $out"
R2=$T/org; git init -q -b main "$R2"; OVERLAY=$O apply "$R2" >/dev/null; [ -f "$R2/$WF" ] || why="$why; overlay release_browsers did not ship it"
node -e 'const o=require(process.argv[1]);o.e2e={promotion_browsers:["webkit"]};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$O"
out=$(OVERLAY=$O apply "$T/x" 2>&1) && why="$why; promotion_browsers accepted"; has "e2e.promotion_browsers is gone" "$out" || why="$why; [$out]"

# the workflow: Workers Builds completions on the default branch and manual runs only; install and e2e take the release step's browsers and URL
trig=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("\non:"),y.indexOf("\npermissions:")))' "$R/$WF")
has "check_run:" "$trig" && has "types: [completed]" "$trig" && has "workflow_dispatch" "$trig" && ! has pull_request "$trig" && ! has "push:" "$trig" && ! has "schedule" "$trig" || why="$why; triggers: $trig"
grep -q 'fetch-depth: 0' "$R/$WF" || why="$why; checkout too shallow to read the parent and the later commits"
grep -q 'ref: ${{ env.RELEASE_SHA }}' "$R/$WF" && grep -q 'RELEASE_SHA: ${{ github.event.check_run.head_sha || inputs.sha }}' "$R/$WF" || why="$why; the suite does not test the built commit"
grep -q "github.event.check_run.check_suite.app.slug == 'cloudflare-workers-and-pages' && startsWith(github.event.check_run.name, 'Workers Builds') && github.event.check_run.check_suite.head_branch == github.event.repository.default_branch" "$R/$WF" || why="$why; job not limited to default-branch Workers Builds completions"
grep -q 'GATE_BROWSERS: ${{ steps.release.outputs.browsers }}' "$R/$WF" && grep -q 'GATE_PREVIEW_URL: ${{ steps.release.outputs.url }}' "$R/$WF" || why="$why; e2e not wired to the release step"

# gate.mjs release: waits for this commit's Workers Builds, then names the extra browsers and the staging URL
put '{"checks":[{"name":"Workers Builds: demo","status":"completed","conclusion":"success"}]}'
o=$(rel "$R"); has "exit=0" "$o" && has "browsers=chromium,firefox,webkit" "$o" && has "url=https://staging.preview.example.com/" "$o" || why="$why; release: $o"
put '{"checks":[{"name":"Workers Builds: demo","status":"completed","conclusion":"failure","details_url":"u"}]}'
o=$(rel "$R"); has "exit=1" "$o" && has "Cloudflare build failed for eeeeeee" "$o" || why="$why; failed build: $o"
put '{"checks":[{"name":"Workers Builds: demo","status":"in_progress"}]}'
o=$(rel "$R"); has "exit=1" "$o" && has "still running" "$o" || why="$why; running build: $o"
# the run starts from a completed Workers Builds check, so none on the commit is an error (never a guess, never green)
P=$(git -C "$R" rev-parse HEAD); gc -C "$R" commit -q --allow-empty -m next; SHA=$(git -C "$R" rev-parse HEAD)
put '{"checks":[]}'
o=$(rel "$R"); has "exit=1" "$o" && has "no \"Workers Builds\" check on ${SHA:0:7}" "$o" || why="$why; no builds certified: $o"
# several Workers: every Workers Builds check on the commit is waited for, then the suite is named
put '{"checks":[{"name":"Workers Builds: a","status":"completed","conclusion":"success"},{"name":"Workers Builds: b","status":"in_progress"}]}'
( sleep 2; printf '%s' '{"checks":[{"name":"Workers Builds: a","status":"completed","conclusion":"success"},{"name":"Workers Builds: b","status":"completed","conclusion":"success"}]}' > "$T/state.json" ) & LATE=$!
o=$( (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t RELEASE_SHA=$SHA GATE_POLL_S=1 GITHUB_OUTPUT= node scripts/agent/gate.mjs release 2>&1); echo "exit=$?"); wait $LATE
has "exit=0" "$o" && has "browsers=chromium,firefox,webkit" "$o" || why="$why; waiting for the last Worker's build: $o"
if [ -z "$why" ]; then ok release-browsers-on-main; else fail release-browsers-on-main "$why"; fi

# what there is to certify comes only from the authenticated Builds results on the commit, never from its paths: a commit
# whose builds Cloudflare skipped has nothing to certify (cancelled); a push whose last commit is README-only but whose
# build succeeded (source then docs, deployed together) is certified
why=""
echo "notes" >"$R/README.md"; mkdir -p "$R/docs" && echo "guide" >"$R/docs/guide.md"; commit "$R" docs; SHA=$(git -C "$R" rev-parse HEAD)
put '{"checks":[{"name":"Workers Builds: demo","status":"completed","conclusion":"skipped"}]}'
o=$(rel "$R"); has "nothing to certify: Cloudflare deployed nothing" "$o" && has "skip=true" "$o" && has "exit=1" "$o" && grep -q cancelled "$T/state.json" || why="$why; skipped build: $o"
mkdir -p "$R/src" && echo "export {};" >"$R/src/index.ts"; commit "$R" code; echo "more" >>"$R/README.md"; commit "$R" docs-last; SHA=$(git -C "$R" rev-parse HEAD)
put '{"checks":[{"name":"Workers Builds: demo","status":"completed","conclusion":"success"}]}'
o=$(rel "$R"); has "exit=0" "$o" && ! has "skip=true" "$o" && has "browsers=chromium,firefox,webkit" "$o" || why="$why; source-then-docs push with a successful build: $o"
for step in install e2e; do
  blk=$(awk -v s="- name: $step" 'index($0,s){f=1;next} f&&/- name:/{exit} f' "$R/$WF")
  has "if: steps.release.outputs.skip != 'true'" "$blk" || why="$why; $step step not skipped: $blk"
done
if [ -z "$why" ]; then ok release-check-skips-docs; else fail release-check-skips-docs "$why"; fi
done_cases
