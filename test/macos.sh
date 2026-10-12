#!/usr/bin/env bash
# macOS suites (standards.json "macos"): the offline check accepts and refuses declarations; gate.mjs plan (against a
# GitHub stand-in) plans a declared suite only for a ready pull request's full gate that changes a file under its paths,
# and decides the same on a re-gate's merge ref; the verdict requires the macos job only when the plan did; the rendered
# workflow runs it on the declared runner beside the test job, through `gate.mjs macos <name>`.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME ROLLBACK_BASE ROLLBACK_DRAFT GATE_PLATFORM
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
T=$(mktemp -d) STUB=""
trap '{ [ -z "$STUB" ] || { kill "$STUB"; wait "$STUB"; }; } 2>/dev/null; rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
R=$T/repo; git init -q -b main "$R"
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$R/standards.json" "$1"; }
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.1.0 >/dev/null
mkdir -p "$R/apps/tv" "$R/web"
echo 'struct App {}' > "$R/apps/tv/App.swift"; echo 'export {};' > "$R/web/index.mjs"
printf '#!/usr/bin/env bash\necho "tv suite ran in $PWD" > tv-ran.txt\n' > "$R/apps/tv/test.sh"
printf 'tv-ran.txt\n' > "$R/.gitignore"
TV='{name:"tv",paths:["apps/tv/**"],runner:"xcode-27",command:"bash apps/tv/test.sh"}'
jset "o.macos=[$TV]"
git -C "$R" add -A; git -C "$R" commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
why=""

# ---- --check: a well-formed declaration passes; each malformed one fails with a fix
chk() { (cd "$R" && scripts/agent/setup.sh --check) 2>&1; }
out=$(chk); st=$?
[ $st -eq 0 ] || why="well-formed declaration refused (exit $st): $(grep -E '^FAIL' <<<"$out")"
while IFS='|' read -r bad needle; do
  jset "o.macos=$bad"; out=$(chk); st=$?
  line=$(grep -E '^FAIL: standards.json macos' <<<"$out")
  [ $st -eq 1 ] && has "$needle" "$line" && has "| fix: " "$line" || why="$why; [$bad] exit=$st: ${line:-$(grep -E '^FAIL' <<<"$out" | head -2)}"
done <<EOF
[]|non-empty list
"tv"|non-empty list
[$TV,$TV]|repeated
["tv"]|must be an object
[{name:"tv",paths:["apps/tv/**"],runner:"xcode-27",command:"x",label:"y"}]|unknown key label
[{paths:["apps/tv/**"],runner:"xcode-27",command:"x"}]|name
[{name:" ",paths:["apps/tv/**"],runner:"xcode-27",command:"x"}]|name
[{name:"tv",paths:["apps/tv/**"],command:"x"}]|runner
[{name:"tv",paths:["apps/tv/**"],runner:"xcode-27",command:""}]|command
[{name:"tv",paths:[],runner:"xcode-27",command:"x"}]|paths
[{name:"tv",paths:"apps/tv/**",runner:"xcode-27",command:"x"}]|paths
[{name:"tv",paths:[""],runner:"xcode-27",command:"x"}]|paths
EOF
jset "o.macos=[$TV]"

# ---- plan: the pull request's changed files decide; [] for drafts, the merge queue and other paths
echo '{}' > "$T/state.json"
node test/stubs/codex-github.mjs "$T/port" "$T/state.json" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$T/port")"
git -C "$R" checkout -q -b tv; echo 'struct App { let v = 2 }' > "$R/apps/tv/App.swift"; git -C "$R" commit -qam tv; TVH=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b web main; echo 'export const v = 2;' > "$R/web/index.mjs"; git -C "$R" commit -qam web; WEBH=$(git -C "$R" rev-parse HEAD)
# plan <event name> <event json> <draft> <head>: the stand-in serves pull request 7 with that draft flag and head
plan() {
  printf '{"pr":{"number":7,"draft":%s,"head":{"sha":"%s","ref":"feat"},"base":{"ref":"main","sha":"%s"}}}' "$3" "$4" "$BASE" > "$T/state.json"
  printf '%s' "$2" > "$T/ev.json"
  (cd "$R" && GITHUB_API_URL=$API GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_NAME=$1 GITHUB_EVENT_PATH="$T/ev.json" GITHUB_OUTPUT= node scripts/agent/gate.mjs plan 2>&1)
}
mac() { sed -n 's/^macos=//p' <<<"$1"; }
ev() { printf '{"pull_request":{"number":7,"draft":%s,"head":{"sha":"%s"},"base":{"sha":"%s"}}}' "$1" "$2" "${3:-$BASE}"; }
TVPLAN='[{"name":"tv","runner":"xcode-27"}]'
git -C "$R" checkout -q --detach "$TVH"; p=$(plan pull_request "$(ev false "$TVH")" false "$TVH")
[ "$(mac "$p")" = "$TVPLAN" ] && has "apps/tv/App.swift" "$p" || why="$why; ready PR changing apps/tv: $p"
p=$(plan pull_request "$(ev true "$TVH")" true "$TVH")
[ "$(mac "$p")" = "[]" ] && [ "$(sed -n 's/^mode=//p' <<<"$p")" = cheap ] || why="$why; draft PR changing apps/tv: $p"
p=$(plan pull_request "$(ev false "$TVH" 1111111111111111111111111111111111111111)" false "$TVH")
[ "$(mac "$p")" = "$TVPLAN" ] && has "cannot be found" "$p" || why="$why; unknown base (every suite runs): $p"
git -C "$R" checkout -q --detach "$WEBH"; p=$(plan pull_request "$(ev false "$WEBH")" false "$WEBH")
[ "$(mac "$p")" = "[]" ] && [ "$(sed -n 's/^mode=//p' <<<"$p")" = full ] && has "apps/tv/**" "$p" || why="$why; ready PR changing web only: $p"
# a re-gate (workflow_dispatch) checks out the pull request's merge ref: its first parent is the base
for h in "$TVH" "$WEBH"; do
  git -C "$R" checkout -q --detach main; git -C "$R" merge -q --no-ff -m "merge $h" "$h"
  p=$(plan workflow_dispatch '{"inputs":{"pr":"7"}}' false "$h"); want="[]"; [ "$h" = "$TVH" ] && want=$TVPLAN
  [ "$(mac "$p")" = "$want" ] || why="$why; re-gate of $( [ "$h" = "$TVH" ] && echo tv || echo web ): $p"
done
git -C "$R" checkout -q --detach "$TVH"
p=$(plan merge_group "{\"merge_group\":{\"base_sha\":\"$BASE\",\"head_sha\":\"$TVH\"}}" false "$TVH")
[ "$(mac "$p")" = "[]" ] || why="$why; merge queue: $p"
# no declaration: the same plan as before, and no macOS suite
jset 'delete o.macos'; p=$(plan pull_request "$(ev false "$TVH")" false "$TVH")
[ "$(mac "$p")" = "[]" ] && ! has "plan: macos" "$p" || why="$why; no declaration: $p"
jset 'o.macos=[]'; p=$(plan pull_request "$(ev false "$TVH")" false "$TVH"); st=$?
[ $st -ne 0 ] && has "standards.json macos" "$p" || why="$why; malformed declaration planned: $p"
git -C "$R" checkout -q -- standards.json

# ---- the workflow: a macos job beside test, on the declared runner, skipped unless the plan listed a suite
WF=$R/.github/workflows/std-gate.yml
shape=$(node -e '
const y=require("fs").readFileSync(process.argv[1],"utf8"),out=[],body=(j)=>{const i=y.indexOf("\n  "+j+":\n");if(i<0)return "";const r=y.slice(i+1).split("\n").slice(1);const e=r.findIndex(l=>/^  \S/.test(l));return (e<0?r:r.slice(0,e)).join("\n")};
const m=body("macos"),c=body("checks");
if(!m)out.push("no macos job");
if(!/^      macos: \$\{\{ steps\.plan\.outputs\.macos \}\}$/m.test(c))out.push("checks does not pass the plan on");
if(!/^    needs: checks$/m.test(m))out.push("macos needs");
if(!/^    if: needs\.checks\.outputs\.mode == .full. && needs\.checks\.outputs\.rollback_draft != .true. && startsWith\(needs\.checks\.outputs\.macos, .\[\{.\)$/m.test(m))out.push("macos if");
if(!/^        include: \$\{\{ fromJSON\(needs\.checks\.outputs\.macos\) \}\}$/m.test(m))out.push("macos matrix");
if(!/^    runs-on: \$\{\{ matrix\.runner \}\}$/m.test(m))out.push("macos runner");
if(!/^    timeout-minutes: 30$/m.test(m))out.push("macos timeout");
if(!/ref: \$\{\{ needs\.checks\.outputs\.sha \}\}/.test(m))out.push("macos not pinned to the checked tree");
if(!/GATE_MACOS_SUITE: \$\{\{ matrix\.name \}\}/.test(m)||!/run: node scripts\/agent\/gate\.mjs macos "\$GATE_MACOS_SUITE"/.test(m))out.push("macos step");
if(/actions\/cache(?!\/restore)|package-manager-cache: true/.test(m)||!/package-manager-cache: false/.test(m))out.push("macos caches");
if(!/^    needs: \[checks, test, macos\]$/m.test(body("gate")))out.push("gate needs");
console.log(out.join("; ")||"ok")' "$WF")
[ "$shape" = ok ] || why="$why; workflow: $shape"

# ---- the verdict: the macos job must succeed when the plan listed a suite, and is ignored when it did not
# needs <plan's macos output|none> <macos result|missing> [test result]
needs() { node -e 'const [m,r,t]=process.argv.slice(1),o={mode:"full",rollback_draft:"false"};if(m!=="none")o.macos=m;const n={checks:{result:"success",outputs:o},test:{result:t||"success"}};if(r!=="missing")n.macos={result:r};console.log(JSON.stringify(n))' "$@"; }
v() { (cd "$R" && NEEDS="$(needs "$@")" node scripts/agent/gate.mjs verdict 2>&1); echo "exit=$?"; }
o=$(v "$TVPLAN" success); has "exit=0" "$o" && has "macOS" "$o" || why="$why; planned and passed: $o"
for r in failure cancelled skipped missing; do o=$(v "$TVPLAN" $r); has "exit=1" "$o" && has "macos" "$o" || why="$why; planned and $r: $o"; done
o=$(v "$TVPLAN" success failure); has "exit=1" "$o" || why="$why; planned, test failed: $o"
o=$(v "[]" skipped); has "exit=0" "$o" && has "gate: checks and the test job passed" "$o" || why="$why; not planned: $o"
o=$(v none missing); has "exit=0" "$o" && has "gate: checks and the test job passed" "$o" || why="$why; no macos output: $o"
o=$(v "not json" skipped); has "exit=1" "$o" || why="$why; unreadable plan: $o"

# ---- gate.mjs macos <name>: the declared command from the repository root, on macOS only
rm -f "$R/tv-ran.txt"
o=$(cd "$R/apps" && GATE_PLATFORM=darwin node ../scripts/agent/gate.mjs macos tv 2>&1); st=$?
[ $st -eq 0 ] && [ -f "$R/tv-ran.txt" ] && has "bash apps/tv/test.sh" "$o" || why="$why; macos tv on a Mac: exit=$st $o"
rm -f "$R/tv-ran.txt"
o=$(cd "$R" && GATE_PLATFORM=linux node scripts/agent/gate.mjs macos tv 2>&1); st=$?
[ $st -eq 1 ] && [ ! -f "$R/tv-ran.txt" ] && has "needs macOS" "$o" || why="$why; macos tv off a Mac: exit=$st $o"
o=$(cd "$R" && GATE_PLATFORM=darwin node scripts/agent/gate.mjs macos other 2>&1); st=$?
[ $st -eq 1 ] && has "no macOS suite named other" "$o" || why="$why; undeclared suite: exit=$st $o"
printf '#!/usr/bin/env bash\nexit 3\n' > "$R/apps/tv/test.sh"
o=$(cd "$R" && GATE_PLATFORM=darwin node scripts/agent/gate.mjs macos tv 2>&1); st=$?
[ $st -ne 0 ] || why="$why; a failing suite passed: $o"
git -C "$R" checkout -q -- apps/tv/test.sh

if [ -z "$why" ]; then ok macos-suite-path-scoped; else fail macos-suite-path-scoped "$why"; fi
done_cases
