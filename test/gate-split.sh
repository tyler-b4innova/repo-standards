#!/usr/bin/env bash
# The required `gate` job is one job: through apply (the rendered workflow) and gate.mjs verdict (the job's last step),
# with the step outcomes GitHub gives it (the checks part's last step and the test part's last step).
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
R=$T/r; git init -q -b main "$R"; node bin/repo-standards.mjs apply --overlay "$OV" --version 0.1.0 --target "$R" >/dev/null
WF=$R/.github/workflows/std-gate.yml
why=""
# the workflow: one job named gate, skipped only for a draft, with the overlay's one timeout; its steps run in order, the
# test steps only for a full plan on a ready head, and the verdict last
shape=$(node -e '
const y=require("fs").readFileSync(process.argv[1],"utf8"),out=[];
const jobs=y.slice(y.indexOf("\njobs:")).split(/^  ([\w-]+):\s*$/m);
const names=[];for(let i=1;i<jobs.length;i+=2)names.push(jobs[i]);
if(names.join()!=="gate")out.push("jobs: "+names.join());
const g=jobs[jobs.indexOf("gate")+1]??"";
if(!/^    name: \$\{\{ github\.event\.pull_request\.draft == true && .draft \(not gated\). \|\| .gate. \}\}$/m.test(g))out.push("name");
if(!/^    if: github\.event\.pull_request\.draft != true$/m.test(g))out.push("job if");
if(!/^    timeout-minutes: 30$/m.test(g))out.push("timeout");
if(/needs/.test(g))out.push("needs: the one job reads no other job");
const steps=g.split(/^      - /m).slice(1), at=(re)=>steps.findIndex((s)=>re.test(s));
const order=[/^name: standards$/m,/^name: secrets$/m,/^name: syntax$/m,/^name: install$/m,/^name: typecheck$/m,/^name: build$/m,/^name: repo checks$/m,/^name: preview$/m,/^name: e2e$/m,/^name: verdict$/m].map(at);
if(order.some((n)=>n<0)||order.some((n,i)=>i&&n<=order[i-1]))out.push("step order: "+order);
const testNames=["dependency cache","install","playwright","browser cache","browsers","typecheck","build","repo checks","preview","e2e"];
for(const s of steps){const n=(s.match(/^name: (.*)$/m)||[])[1];if(testNames.includes(n)&&!/if: steps\.plan\.outputs\.mode == .full. && steps\.plan\.outputs\.rollback_draft != .true./.test(s))out.push(n+" is not gated on a full plan")}
const v=steps[at(/^name: verdict$/m)]??"";
if(!/if: \$\{\{ !cancelled\(\) \}\}/.test(v)||!/gate\.mjs verdict/.test(v))out.push("verdict step: "+v);
for(const s of ["setup.sh --check","gate.mjs instructions","gate.mjs secrets","gate.local.sh","gate.mjs e2e"])if(!g.includes(s))out.push("lacks "+s);
console.log(out.join("; ")||"ok")' "$WF")
[ "$shape" = ok ] || why="shape: $shape"
GT=$T/ov.json; node -e 'const o=require(process.argv[1]);o.gate={timeout_minutes:45};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$GT"
node bin/repo-standards.mjs apply --overlay "$GT" --version 0.1.0 --target "$R" >/dev/null
[ "$(grep -c '^    timeout-minutes: 45$' "$WF")" = 1 ] || why="$why; overlay timeout not on the job: $(grep -n timeout-minutes "$WF")"
tail_why=$why why="" # the workflow's shape is gate-parallel-tail's, reported with the verdict cases below
# the verdict: MODE and LIVE_DRAFT are the plan's outputs, CHECKS and TEST the outcomes of the checks part and the test part
v() { (cd "$R" && env MODE="$1" LIVE_DRAFT="$2" CHECKS="$3" TEST="$4" node scripts/agent/gate.mjs verdict 2>&1); echo "exit=$?"; }
o=$(v full false success success); has "exit=0" "$o" || why="$why; all green: $o"
o=$(v cheap false success skipped); has "exit=1" "$o" && has "draft head" "$o" || why="$why; cheap draft: $o"
# draft-head-never-passes-gate: even an all-green full plan fails when the live draft flag was set
o=$(v full true success success); has "exit=1" "$o" && has "draft head" "$o" || why="$why; full-plan draft: $o"
o=$(v full false success success); has "exit=0" "$o" || why="$why; ready: $o"
if [ -z "$why" ]; then ok draft-head-never-passes-gate; else fail draft-head-never-passes-gate "$why"; fi; why=""
# a failed, skipped or cancelled checks part fails; a failed, skipped or cancelled test part fails a full plan
for c in "failure success" "skipped success" "cancelled success" "" "success failure" "success skipped" "success cancelled" "success "; do
  read -r a b <<<"$c"; o=$(v full false "$a" "${b:-}"); has "exit=1" "$o" && has "::error::gate:" "$o" || why="$why; [checks=$a test=${b:-}] passed: $o"
done
o=$(v full false success ""); has "test: not run" "$o" || why="$why; a test part that never ran: $o"
o=$(v "" false success success); has "exit=1" "$o" || why="$why; no plan result: $o"
why="$tail_why$why"
if [ -z "$why" ]; then ok gate-parallel-tail; else fail gate-parallel-tail "$why"; fi
done_cases
