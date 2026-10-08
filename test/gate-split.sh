#!/usr/bin/env bash
# The required `gate` job aggregates the checks job and the one test job: through apply (the rendered workflow) and
# gate.mjs verdict (the gate job's one step), with the job results GitHub passes it.
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
# the workflow: gate needs every job, always runs, and every other job takes the timeout
shape=$(node -e '
const y=require("fs").readFileSync(process.argv[1],"utf8"),out=[],body=(j)=>{const i=y.indexOf("\n  "+j+":\n");const r=y.slice(i+1).split("\n").slice(1);const e=r.findIndex(l=>/^  \S/.test(l));return (e<0?r:r.slice(0,e)).join("\n")};
const g=body("gate");
if(!/needs: \[checks, test\]/.test(g))out.push("gate needs");
for(const j of ["test","gate"])if(!/ref: \$\{\{ needs\.checks\.outputs\.sha \}\}/.test(body(j)))out.push(j+" not pinned to the checked tree");
if(!/actions\/setup-node/.test(g))out.push("gate job sets up no node");
if(!/^    if: \$\{\{ always\(\) && !cancelled\(\) && github\.event\.pull_request\.draft != true \}\}$/m.test(g)||!/^    name: .*\|\| 'gate' \}\}$/m.test(g)||!/gate\.mjs verdict/.test(g))out.push("gate job: "+g);
for(const j of ["checks","test"]){const b=body(j);if(!/^    timeout-minutes: 30$/m.test(b))out.push(j+" timeout");if(j!=="checks"&&(!/needs: checks/.test(b)||!/if: needs\.checks\.outputs\.mode == .full./.test(b)))out.push(j+" not a tail job")}
for(const [j,s] of [["test","run typecheck"],["test","run build"],["test","gate.mjs preview"],["test","gate.mjs e2e"],["test","gate.local.sh"],["checks","setup.sh --check"],["checks","gate.mjs instructions"],["checks","gate.mjs secrets"]])if(!body(j).includes(s))out.push(j+" lacks "+s);
console.log(out.join("; ")||"ok")' "$WF")
[ "$shape" = ok ] || why="shape: $shape"
GT=$T/ov.json; node -e 'const o=require(process.argv[1]);o.gate={timeout_minutes:45};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$GT"
node bin/repo-standards.mjs apply --overlay "$GT" --version 0.1.0 --target "$R" >/dev/null
[ "$(grep -c '^    timeout-minutes: 45$' "$WF")" = 2 ] || why="$why; overlay timeout not on every job: $(grep -n timeout-minutes "$WF")"
# the verdict
v() { (cd "$R" && NEEDS="$1" node scripts/agent/gate.mjs verdict 2>&1); echo "exit=$?"; }
j() { printf '{"checks":{"result":"%s","outputs":{"mode":"%s"}},"test":{"result":"%s"}}' "$@"; }
o=$(v "$(j success full success)"); has "exit=0" "$o" || why="$why; all green: $o"
o=$(v "$(j success cheap skipped)"); has "exit=1" "$o" && has "draft head" "$o" || why="$why; cheap draft: $o"
# draft-head-never-passes-gate: even an all-green full plan fails when the live draft flag was set, and a skipped checks job (a draft push) fails
o=$(v '{"checks":{"result":"success","outputs":{"mode":"full","rollback_draft":"true"}},"test":{"result":"success"}}'); has "exit=1" "$o" && has "draft head" "$o" || why="$why; full-plan draft: $o"
o=$(v '{"checks":{"result":"skipped","outputs":{}},"test":{"result":"skipped"}}'); has "exit=1" "$o" && has "draft head" "$o" || why="$why; draft push: $o"
o=$(v '{"checks":{"result":"success","outputs":{"mode":"full","rollback_draft":"false"}},"test":{"result":"success"}}'); has "exit=0" "$o" || why="$why; ready: $o"
if [ -z "$why" ]; then ok draft-head-never-passes-gate; else fail draft-head-never-passes-gate "$why"; fi; why=""
for c in "success full failure" "success full cancelled" "success full skipped" "failure full skipped" "failure cheap skipped" "success cheap failure"; do
  o=$(v "$(j $c)"); has "exit=1" "$o" && has "::error::gate:" "$o" || why="$why; [$c] passed: $o"
done
o=$(v '{"checks":{"result":"success","outputs":{"mode":"full"}}}'); has "test: missing" "$o" || why="$why; missing job: $o"
o=$(v ''); has "exit=1" "$o" || why="$why; no NEEDS: $o"
if [ -z "$why" ]; then ok gate-parallel-tail; else fail gate-parallel-tail "$why"; fi
done_cases
