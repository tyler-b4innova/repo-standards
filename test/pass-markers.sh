#!/usr/bin/env bash
# gate-pass-markers: the gate job restores this pull request's pass-marker directory before its repo checks, exposes it
# as STD_PASS_DIR and saves it after them; a merge queue run, the release check and a cache-warm get no marker. Read from
# the workflow apply renders, the one a repository runs.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
R=$T/r
ENGINE=$PWD
git init -q -b main "$R"
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version "$(node -p 'require("./package.json").version')" >/dev/null
WF=$R/.github/workflows/std-gate.yml
# the gate job's steps: each `- ` at six spaces starts one; name, if, uses and run are read from the step's lines
steps() { node -e '
const y=require("fs").readFileSync(process.argv[1],"utf8").split("\n"),out=[];let cur=null,inJob=false;
for(const l of y){ if(/^  \S/.test(l)){inJob=/^  gate:$/.test(l);continue} if(!inJob)continue;
  if(/^      - /.test(l)){cur={lines:[]};out.push(cur)} if(cur)cur.lines.push(l)}
console.log(JSON.stringify(out.map((s)=>{const t=s.lines.join("\n");const g=(re)=>{const m=t.match(re);return m?m[1]:null};
  return {name:g(/^      - name: (.*)$/m),if:g(/^        if: (.*)$/m),uses:g(/uses: (.*)$/m),run:g(/^        run: (.*)$/m),text:t}})))' "$1"; }
steps "$WF" > "$T/steps.json"
why=""
st() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const f=s.find((x)=>x.name===process.argv[2]);if(!f){process.exit(3)}console.log(process.argv[3]==="if"?(f.if||""):process.argv[3]==="uses"?(f.uses||""):process.argv[3]==="text"?f.text:(f.run||""))' "$T/steps.json" "$1" "$2" 2>/dev/null; }
idx() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(s.findIndex((x)=>x.name===process.argv[2]))' "$T/steps.json" "$1"; }
KEY='std-pass-${{ github.event.pull_request.number || inputs.pr }}-${{ github.run_id }}'
RK='std-pass-${{ github.event.pull_request.number || inputs.pr }}-'
COND="github.event_name == 'pull_request' || inputs.pr"
for n in "pass markers" "pass markers dir" "pass markers save"; do [ -n "$(st "$n" if)" ] || why="$why; $n: no if"; done
# restore before the repo checks, save after them, the directory made in between
[ "$(idx "pass markers")" -ge 0 ] && [ "$(idx "pass markers")" -lt "$(idx "pass markers dir")" ] && [ "$(idx "pass markers dir")" -lt "$(idx "repo checks")" ] && [ "$(idx "repo checks")" -lt "$(idx "pass markers save")" ] || why="$why; order"
st "pass markers" uses | grep -Eq '^actions/cache/restore@[0-9a-f]{40} # v' || why="$why; restore not SHA-pinned"
st "pass markers save" uses | grep -Eq '^actions/cache/save@[0-9a-f]{40} # v' || why="$why; save not SHA-pinned"
st "pass markers" text | grep -qF "path: \${{ runner.temp }}/std-pass" || why="$why; restore path"
st "pass markers" text | grep -qF "key: $KEY" || why="$why; restore key"
st "pass markers" text | grep -qF "restore-keys: $RK" || why="$why; restore-keys"
st "pass markers save" text | grep -qF "path: \${{ runner.temp }}/std-pass" || why="$why; save path"
st "pass markers save" text | grep -qF "key: $KEY" || why="$why; save key"
st "pass markers save" if | grep -qF "always()" || why="$why; save not always()"
st "pass markers save" text | grep -q "continue-on-error: true" || why="$why; save can fail the gate"
for n in "pass markers" "pass markers dir" "pass markers save"; do
  st "$n" if | grep -qF "steps.plan.outputs.mode == 'full'" && st "$n" if | grep -qF "$COND" || why="$why; $n not for a full pull request or re-gate"
  st "$n" if | grep -Eq 'merge_group|GATE_SELECT' && why="$why; $n runs for a merge queue or full selection"
done
# the directory is exposed through GITHUB_ENV, and the repo checks read nothing else
st "pass markers dir" run | grep -qF 'echo "STD_PASS_DIR=$RUNNER_TEMP/std-pass" >>"$GITHUB_ENV"' || why="$why; dir not exposed"
st "repo checks" text | grep -q "STD_PASS" && why="$why; repo checks set STD_PASS_DIR"
# the rendered step itself, run with a runner temp and a GITHUB_ENV file: the directory exists and the variable is written
RT=$T/rt; mkdir -p "$RT"; : > "$T/github-env"
(export RUNNER_TEMP="$RT" GITHUB_ENV="$T/github-env"; bash -c "$(st "pass markers dir" run)") || why="$why; dir step failed"
grep -qx "STD_PASS_DIR=$RT/std-pass" "$T/github-env" && [ -d "$RT/std-pass" ] || why="$why; dir step wrote [$(cat "$T/github-env")]"
# the only cache save in the gate is the marker save; the dependency and browser restores stay restores
[ "$(grep -c 'actions/cache/save@' "$WF")" = 1 ] || why="$why; gate saves $(grep -c 'actions/cache/save@' "$WF") caches"
grep -Eq 'uses: actions/cache@' "$WF" && why="$why; gate uses a bare actions/cache"
grep -q 'STD_PASS\|std-pass' "$ENGINE/template/.github/workflows/std-release-check.yml" && why="$why; release check names a marker"
# std-cache-warm: main only, never a pull request's code, and the only one that writes the dependency and browser caches
cw=$R/.github/workflows/std-cache-warm.yml
grep -Eq 'uses: actions/cache@[0-9a-f]{40}' "$cw" || why="$why; warm saves nothing"
grep -Eq 'pull_request|workflow_dispatch|^\s+ref:' "$cw" && why="$why; warm can run or check out pull request code"
grep -Eq '^    branches: \[main\]' "$cw" || why="$why; warm not main-only"
if [ -z "$why" ]; then ok gate-pass-markers; else fail gate-pass-markers "${why#; }"; fi
