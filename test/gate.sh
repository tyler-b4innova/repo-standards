#!/usr/bin/env bash
# Gate cases through the real gate steps, and evidence cases through the review export, against a GitHub REST stand-in. No network.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GITHUB_SERVER_URL RANGE GH_TOKEN GATE_GITLEAKS_ARCHIVE
ENGINE=$PWD PW_VERSION=1.63.0
T=$(mktemp -d)
PIDS=""
trap 'for p in $PIDS; do { kill "$p"; wait "$p"; } 2>/dev/null; done; rm -rf "$T"' EXIT
skip() { echo "skip $1 ($2)"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; } # has <needle> <text>
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
mkrepo() {
  local d; d=$(mktemp -d "$T/r.XXXXXX")
  git -C "$d" init -q -b main && node "$ENGINE/bin/repo-standards.mjs" apply --target "$d" --overlay "$ENGINE/examples/overlay.json" --version "${1:-0.1.0}" >/dev/null && commit "$d" init && echo "$d"
}
G() { local d=$1; shift; (cd "$d" && node scripts/agent/gate.mjs "$@") 2>&1; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
# step_run <workflow> <step name>: the step's run: line
step_run() { node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n"),i=L.findIndex(l=>l.trim()==="- name: "+process.argv[2]);if(i<0)process.exit(1);for(let j=i+1;j<L.length&&!/^\s*- /.test(L[j]);j++){const m=L[j].match(/^(\s*)run: (.*)$/);if(!m)continue;if(m[2]!=="|"){console.log(m[2]);process.exit(0)}const b=[];for(let k=j+1;k<L.length&&(L[k].trim()===""||L[k].search(/\S/)>m[1].length);k++)b.push(L[k].trim());console.log(b.join("\n").trim());process.exit(0)}process.exit(1)' "$1" "$2"; }
wait_port() { local i; for i in $(seq 100); do [ -s "$1" ] && { cat "$1"; return 0; }; sleep 0.1; done; return 1; }
online() { curl -sSfI --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; }
# Restricted PATH: only the tools setup.sh and check.mjs need, plus shims (so gh, ffmpeg, pdftoppm, soffice are absent).
mkpath() { mkdir -p "$1"; local t; for t in bash env git node sed grep id dirname cat; do ln -sf "$(command -v "$t")" "$1/$t"; done; }
shim() { printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
WF=.github/workflows/std-gate.yml

# ---- e2e and repo scripts
R=$(mkrepo)
out=$(G "$R" e2e); st=$?
mkdir -p "$R/tests/e2e" && echo "notes" > "$R/tests/e2e/README.txt"
out2=$(G "$R" e2e); st2=$?
echo 'import test from "node:test"; test("home renders", () => {});' > "$R/tests/e2e/home.test.mjs"
out3=$(G "$R" e2e); st3=$?
echo 'import test from "node:test"; import assert from "node:assert"; test("broken", () => assert.fail("x"));' > "$R/tests/e2e/broken.test.mjs"
G "$R" e2e >/dev/null; st4=$?
rm "$R/tests/e2e/broken.test.mjs"
echo '{"name":"app","private":true,"scripts":{"test:e2e":"echo e2e-script-ran"}}' > "$R/package.json"
out5=$(G "$R" e2e); st5=$?
if [ $st -eq 1 ] && has "add an end-to-end suite" "$out" && [ $st2 -eq 1 ] && [ $st3 -eq 0 ] && has 'e2e: node --test "tests/e2e/**/*.test.*js"' "$out3" &&
  has "pass 1" "$out3" && [ $st4 -ne 0 ] && [ $st5 -eq 0 ] && has "e2e: npm run test:e2e" "$out5" && has "e2e-script-ran" "$out5"; then ok gate-fails-without-e2e
else fail gate-fails-without-e2e "none=$st dir-without-runner=$st2 node-test=$st3 failing-test=$st4 script=$st5: $out $out3 $out5"; fi

R=$(mkrepo)
jset "$R/standards.json" 'o.e2e=false' && commit "$R"
out=$(G "$R" e2e); st=$?
node "$ENGINE/bin/repo-standards.mjs" apply --target "$R" --overlay "$ENGINE/examples/overlay.json" --version 0.2.0 >/dev/null
kept=$(node -e 'const s=require(process.argv[1]);console.log(s.e2e===false&&s.version==="0.2.0")' "$R/standards.json")
if [ $st -eq 0 ] && has '::warning::no e2e suite' "$out" && [ "$kept" = true ]; then ok e2e-opt-out-honoured
else fail e2e-opt-out-honoured "exit=$st kept=$kept: $out"; fi

# ---- setup installs the repo's own Playwright browser (npm 6's npx once ran /usr/bin/install instead; nothing was installed)
R=$(mkrepo); P=$T/setup-bin; mkpath "$P"; shim "$P" curl 'exit 0'; shim "$P" npm 'echo "npm $*" >> "$SETUP_LOG"'
shim "$P" npx 'echo "npx $*" >> "$SETUP_LOG"; exit 0' # an npx that installs nothing, as npm 6's did
echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$R/package.json" && echo '{}' > "$R/package-lock.json"
su() { : > "$T/setup.log"; (cd "$R" && SETUP_LOG="$T/setup.log" PATH="$P" bash scripts/agent/setup.sh) 2>&1; }
o1=$(su); l1=$(cat "$T/setup.log")
mkdir -p "$R/node_modules/.bin" && printf '#!/bin/sh\necho "playwright $*" >> "$SETUP_LOG"\n' > "$R/node_modules/.bin/playwright" && chmod +x "$R/node_modules/.bin/playwright"
o2=$(su); l2=$(cat "$T/setup.log")
if has "playwright is in package.json but not installed" "$o1" && ! has playwright "$l1" && has "npm ci" "$l2" && has "playwright install --with-deps chromium" "$l2" && ! has npx "$l2"
then ok setup-installs-repo-playwright; else fail setup-installs-repo-playwright "missing: $o1 | $l1 || present: $o2 | $l2"; fi

# ---- e2e runs Chromium only (unless this run's browsers say more), within its budget, against the preview when given
R=$(mkrepo); mkdir -p "$R/node_modules/.bin"
printf '#!/bin/sh\necho "playwright $* base=${PLAYWRIGHT_BASE_URL:-none} budget=$PW_GLOBAL_TIMEOUT" >> "%s/pw.log"\n' "$T" > "$R/node_modules/.bin/playwright"; chmod +x "$R/node_modules/.bin/playwright"
echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$R/package.json"
echo 'export default { projects: [{ name: "chromium" }, { name: "firefox" }, { name: "webkit" }] };' > "$R/playwright.config.js"
pwrun() { : > "$T/pw.log"; (cd "$R" && env "$@" node scripts/agent/gate.mjs e2e) >/dev/null 2>&1; cat "$T/pw.log"; }
e1=$(pwrun GATE_X=1) e2=$(pwrun GATE_BROWSERS=chromium,firefox) e3=$(pwrun GATE_PREVIEW_URL=https://feat.preview.example.test)
echo 'export default { projects: [{ name: "desktop-chrome" }, { name: "mobile-chrome" }] };' > "$R/playwright.config.js"
e5=$(cd "$R" && node scripts/agent/gate.mjs e2e 2>&1); x5=$?
echo 'export default { projects: [{ name: "chromium" }, { name: "firefox" }] };' > "$R/playwright.config.js"
jset "$R/package.json" 'o.scripts={"test:e2e":"playwright test"}'; e6=$(pwrun GATE_X=1); jset "$R/package.json" 'delete o.scripts'
echo 'export default { use: {} };' > "$R/playwright.config.js"; e4=$(pwrun GATE_X=1)
IB=$T/install-bin; mkpath "$IB"; shim "$IB" npm 'exit 0'
: > "$T/pw.log"; (cd "$R" && PATH="$IB" GATE_BROWSERS=chromium node scripts/agent/gate.mjs install) >/dev/null 2>&1; i1=$(cat "$T/pw.log")
if has "playwright test --project=chromium base=none budget=300000" "$e1" && has "test --project=chromium --project=firefox" "$e2" && has "base=https://feat.preview.example.test" "$e3" \
  && has "playwright test base=none" "$e4" && ! has "project" "$e4" && [ $x5 -eq 1 ] && has "defines projects but none named chromium" "$e5" && has "playwright test --project=chromium" "$e6" && ! has firefox "$e6" && has "install --with-deps chromium" "$i1" && ! has "firefox" "$i1"
then ok e2e-chromium-default; else fail e2e-chromium-default "default=$e1 | two=$e2 | preview=$e3 | no-projects=$e4 | script=$e6 | install=$i1"; fi
jset "$R/standards.json" 'o.e2e={command:"sleep 5",budget:0.02}'
t0=$(date +%s); bo=$(cd "$R" && node scripts/agent/gate.mjs e2e 2>&1); bx=$?; t1=$(date +%s)
jset "$R/standards.json" 'o.e2e={command:"true",budget:0.02}'; (cd "$R" && node scripts/agent/gate.mjs e2e) >/dev/null 2>&1; bq=$?
jset "$R/standards.json" 'o.e2e={command:"true",budget:0}'; bz=$(cd "$R" && node scripts/agent/gate.mjs e2e 2>&1); bzx=$?
if [ $bx -eq 1 ] && has "e2e exceeded its 0.02-minute budget" "$bo" && [ $((t1 - t0)) -lt 5 ] && [ $bq -eq 0 ] && [ $bzx -eq 1 ] && has "e2e.budget is 0" "$bz"; then ok e2e-budget-enforced
else fail e2e-budget-enforced "over=$bx in $((t1 - t0))s quick=$bq: $bo"; fi

# draft-cheap-ready-full (syntax): the cheap gate's syntax pass fails a broken script and, without PyYAML, skips workflows
R=$(mkrepo); sy1=$(cd "$R" && node scripts/agent/gate.mjs syntax 2>&1); sx1=$?
YB=$T/noyaml-bin; mkpath "$YB"; shim "$YB" python3 'exit 1'
sy2=$(cd "$R" && PATH="$YB" node scripts/agent/gate.mjs syntax 2>&1); sx2=$?
printf 'if then\n' > "$R/scripts/agent/broken.sh" && git -C "$R" add scripts/agent/broken.sh; sy3=$(cd "$R" && node scripts/agent/gate.mjs syntax 2>&1); sx3=$?
if [ $sx1 -eq 0 ] && [ $sx2 -eq 0 ] && has "PyYAML is not on this runner" "$sy2" && [ $sx3 -eq 1 ] && has "scripts/agent/broken.sh" "$sy3"; then ok draft-cheap-ready-full
else fail draft-cheap-ready-full "clean=$sx1 noyaml=$sx2 broken=$sx3: $sy1 | $sy2 | $sy3"; fi

# ---- the rendered workflow
R=$(mkrepo)
shape=$(cd "$R" && node -e '
const fs=require("fs"),dir=".github/workflows",out=[];
let gates=0;
for (const f of fs.readdirSync(dir)) {
  const L=fs.readFileSync(dir+"/"+f,"utf8").split("\n"),j=L.indexOf("jobs:");
  const jobs=L.slice(j+1).filter(l=>/^  [A-Za-z0-9_-]+:\s*$/.test(l)).map(l=>l.trim().slice(0,-1));
  gates+=L.slice(j+1).filter(l=>/^    name: gate\s*$/.test(l)).length;
  if (f==="std-gate.yml") {
    if (jobs.join()!=="gate") out.push("jobs: "+jobs.join());
    const runs=L.slice(j+1).join("\n");
    for (const s of ["scripts/agent/setup.sh --check","gate.mjs secrets","gate.mjs install","gate.mjs run typecheck","gate.mjs run build","gate.mjs e2e","scripts/agent/gate.local.sh"])
      if (!runs.includes(s)) out.push("missing step: "+s);
    for (const m of runs.matchAll(/gate\.mjs (\w+)/g)) if (require("child_process").spawnSync("node",["scripts/agent/gate.mjs",m[1],"--help"]).status!==0) out.push("unknown subcommand "+m[1]);
  }
}
if (gates!==1) out.push(gates+" jobs named gate");
console.log(out.join("; ")||"ok")')
if [ "$shape" = ok ]; then ok gate-fails-without-e2e; else fail gate-fails-without-e2e "$shape"; fi

# dependency-cache-by-lockfile: gate and the warm-up cache the lockfile's package manager (npm, pnpm, yarn); pnpm and
# yarn come through corepack, and when that fails there is no cache rather than a failed setup step; both workflows
# run the same step, and the warm-up fires on any of the three lockfiles
why=""; CW=$ENGINE/template/.github/workflows
for wf in std-gate.yml std-cache-warm.yml; do [ "$(step_run "$CW/$wf" "package manager")" = "$(step_run "$CW/std-gate.yml" "package manager")" ] || why="$why; $wf step differs"; done
grep -q 'cache: ${{ steps.pm.outputs.cache }}' "$CW/std-cache-warm.yml" && grep -q 'paths: \[package-lock.json, pnpm-lock.yaml, yarn.lock\]' "$CW/std-cache-warm.yml" || why="$why; warm-up trigger or cache"
pmrun() { # pmrun <lockfile> <corepack exit>: the step in a scratch dir with stub corepack/pnpm/yarn; prints its output
  local d; d=$(mktemp -d "$T/pm.XXXXXX"); mkdir "$d/bin"; : > "$d/$1"
  shim "$d/bin" corepack "exit $2"; shim "$d/bin" pnpm "echo 10.0.0"; shim "$d/bin" yarn "echo 1.22.0"
  (cd "$d" && GITHUB_OUTPUT="$d/out" PATH="$d/bin:$PATH" bash -e -c "$(step_run "$CW/std-gate.yml" "package manager")") >/dev/null 2>&1 || echo "step-failed"
  cat "$d/out" 2>/dev/null; }
got="$(pmrun package-lock.json 0)|$(pmrun pnpm-lock.yaml 0)|$(pmrun yarn.lock 0)|$(pmrun pnpm-lock.yaml 1)|$(pmrun none.txt 0)"
[ "$got" = "cache=npm|cache=pnpm|cache=yarn||" ] || why="$why; outputs: $got"
if [ -z "$why" ]; then ok dependency-cache-by-lockfile; else fail dependency-cache-by-lockfile "$why"; fi

# ---- evidence: .evidence/ never tracked (the standards check); the comment rule through the review export
R=$(mkrepo)
out1=$(cd "$R" && scripts/agent/setup.sh --check 2>&1); s1=$?
mkdir -p "$R/.evidence" && printf 'png' > "$R/.evidence/after-home-400.png" && commit "$R"
out2=$(cd "$R" && scripts/agent/setup.sh --check 2>&1); s2=$?
if [ $s1 -eq 0 ] && [ $s2 -eq 1 ] && has ".evidence/ is tracked (.evidence/after-home-400.png)" "$out2"; then ok no-evidence-on-main
else fail no-evidence-on-main "untracked=$s1 tracked=$s2: $out2"; fi

# Evidence repos are clones of one repo, so the pinned evidence commit is in every PR head's history.
EV=$(mkrepo); mkev() { local d; d=$(mktemp -d "$T/ev.XXXXXX"); git clone -q "$EV" "$d" && echo "$d"; }
FX=$T/fixture.json LOG=$T/stub.log SHA=$(git -C "$EV" rev-parse HEAD)
export FX SHA
echo '{"repo":"acme/demo"}' > "$FX"
node test/stubs/gate-github.mjs "$T/port" "$LOG" "$FX" & PIDS="$PIDS $!"
PORT=$(wait_port "$T/port") || { fail stub-start "gate-github stub did not start"; exit 1; }
# fx '<js object>': write the fixture; helpers c(id, login, body, app) and img(url-suffix); files: {pr: [...]}
fx() { node -e 'const S=process.env.SHA,U="https://github.com/acme/demo/blob/"+S+"/.evidence/",img=(u)=>"![shot]("+u+")",
c=(id,login,body,app)=>({id,html_url:"https://github.com/acme/demo/pull/9#issuecomment-"+id,user:{login},performed_via_github_app:app?{slug:"evidence-app"}:null,body});
require("fs").writeFileSync(process.env.FX,JSON.stringify({repo:"acme/demo",files:{},comments:{},contents:["before","after"].flatMap((b)=>[S+":.evidence/"+b+"-home-400.png",S+":.evidence/"+b+"-home-1280.png"]),...eval("("+process.argv[1]+")")}))' "$1"; }
# ev <repo> <pr>: the review rule (repo-standards/review, as a launcher calls it); the stand-in answers commits,
# compares and the policy files from <repo>
ev() {
  node -e 'const f=process.env.FX,x=JSON.parse(require("fs").readFileSync(f,"utf8"));x.head=process.argv[1];x.gitDir=process.argv[2];require("fs").writeFileSync(f,JSON.stringify(x))' "$(git -C "$1" rev-parse HEAD)" "$1"
  GITHUB_API_URL="http://127.0.0.1:$PORT" GITHUB_REPOSITORY=acme/demo node "$ENGINE/test/review-run.mjs" "$2" 2>&1; }
GOOD='["before","after"].flatMap((b)=>[img(U+b+"-home-400.png?raw=true"),img(U+b+"-home-1280.png?raw=true")]).join("\n")'

R=$(mkev)
fx '{files:{1:[...Array.from({length:150},(_,i)=>"lib/m"+i+".mjs"),"src/components/Button.tsx"]}}'
: > "$LOG"; out1=$(ev "$R" 1); s1=$?; log=$(cat "$LOG")
fx '{files:{1:[...Array.from({length:150},(_,i)=>"lib/m"+i+".mjs"),"src/components/Button.tsx"]},comments:{1:[c(11,"alice",'"$GOOD"')]}}'
out2=$(ev "$R" 1); s2=$?
if [ $s1 -eq 1 ] && has "src/components/Button.tsx" "$out1" && has "no accepted evidence comment" "$out1" && has '"path":"/repos/acme/demo/pulls/1/files","query":"?per_page=100&page=2"' "$log" &&
  [ $s2 -eq 0 ] && has "evidence: accepted" "$out2"; then ok ui-paths-evidence-required
else fail ui-paths-evidence-required "no-comment=$s1 accepted=$s2: $out1 $out2"; fi

bad=""
for f in docs/report.docx deck/q3.pptx src/styles/site.scss index.html src/components/Nav.astro public/logo.svg "public/hero.png=>archive/hero.png"; do
  fx "{files:{2:[\"$f\"]}}"; out=$(ev "$R" 2); st=$?
  { [ $st -eq 1 ] && has "${f%%=>*}" "$out"; } || bad="$bad $f=$st"
done
echo "<p>x</p>" > "$R/site.css" && commit "$R" && echo "<p>y</p>" > "$R/site.css" && mkdir -p "$R/docs" && printf 'x' > "$R/docs/brief.docx" && echo x > "$R/lib.mjs"
cls=$(G "$R" classify HEAD); cs=$?
if [ -z "$bad" ] && [ $cs -eq 0 ] && has site.css "$cls" && has docs/brief.docx "$cls" && ! has lib.mjs "$cls"; then ok ui-paths-evidence-required
else fail ui-paths-evidence-required "not required:$bad classify($cs)=$cls"; fi

R=$(mkev); r=""
t() { jset "$R/standards.json" "o.ui_paths=$1"; fx "{files:{3:[\"$2\"]}}"; out=$(ev "$R" 3); st=$?; [ $st -eq "$3" ] || r="$r [$1 $2 want $3 got $st]"; }
t '["content/**"]' content/pricing.txt 1
t '["content/**"]' src/components/Button.tsx 0
t '[]' src/app.css 0
t '{include:["content/**"]}' content/pricing.txt 1
t '{ignore:["release-notes/**"]}' release-notes/v2.html 0
t '{ignore:["release-notes/**"]}' src/app.css 1
jset "$R/standards.json" 'o.ui_paths=["content/**"]'; mkdir -p "$R/content" && echo x > "$R/content/a.txt" && echo y > "$R/app.css"
cls=$(G "$R" classify HEAD)
if [ -z "$r" ] && has content/a.txt "$cls" && ! has app.css "$cls"; then ok ui-paths-repo-override; else fail ui-paths-repo-override "$r classify=$cls"; fi

R=$(mkev)
fx '{files:{5:["src/app.css"]},comments:{5:[c(21,"mallory",'"$GOOD"')]}}'; out1=$(ev "$R" 5); s1=$?
fx '{files:{5:["src/app.css"]},comments:{5:[c(22,"evidence-app[bot]",'"$GOOD"',true)]}}'; out2=$(ev "$R" 5); s2=$?
fx '{files:{5:["src/app.css"]},comments:{5:[c(23,"alice",'"$GOOD"')]}}'; out3=$(ev "$R" 5); s3=$?
if [ $s1 -eq 1 ] && has "#issuecomment-21 by @mallory" "$out1" && [ $s2 -eq 0 ] && has "#issuecomment-22" "$out2" && [ $s3 -eq 0 ]; then ok evidence-comment-author-or-app
else fail evidence-comment-author-or-app "other-user=$s1 app=$s2 author=$s3: $out1"; fi

B1="https://github.com/acme/demo/blob/main/.evidence/after-home-400.png" B2="https://github.com/other/demo/blob/$SHA/.evidence/after-home-400.png" B3="https://github.com/acme/demo/blob/$SHA/.evidence/missing.png"
fx "{files:{6:[\"src/app.css\"]},comments:{6:[c(31,\"alice\",img(\"$B1\")),c(32,\"alice\",img(\"$B2\")),c(33,\"alice\",$GOOD+img(\"$B3\"))]}}"
: > "$LOG"; out1=$(ev "$R" 6); s1=$?; log=$(cat "$LOG")
fx '{files:{6:["src/app.css"]},comments:{6:[c(34,"alice",'"$GOOD"')]}}'; out2=$(ev "$R" 6); s2=$?
# an undecodable path is rejected evidence, never an error that leaves an old verdict standing
fx '{files:{6:["src/app.css"]},comments:{6:[c(35,"alice",'"$GOOD"'+img(U+"after-%ZZ-400.png"))]}}'; out3=$(ev "$R" 6); s3=$?
# a path under something that is a file, not a folder, is rejected too (the listing is a file object)
fx '{files:{6:["src/app.css"]},contents:["before","after"].flatMap((b)=>[process.env.SHA+":.evidence/"+b+"-home-400.png",process.env.SHA+":.evidence/"+b+"-home-1280.png"]).concat([process.env.SHA+":.evidence/foo"]),comments:{6:[c(36,"alice",'"$GOOD"'+img(U+"foo/bar.png"))]}}'; out4=$(ev "$R" 6); s4=$?
if [ $s1 -eq 1 ] && has "$B1" "$out1" && has "$B2" "$out1" && has "$B3" "$out1" && ! has "after-home-1280" "$out1" &&
  has "\"method\":\"GET\",\"path\":\"/repos/acme/demo/contents/.evidence\",\"query\":\"?ref=$SHA\"" "$log" && ! has "contents/.evidence/after-home-400.png" "$log" && [ $s2 -eq 0 ] \
  && [ $s3 -eq 1 ] && has "unresolved" "$out3" && ! has "URIError" "$out3" && [ $s4 -eq 1 ] && has "unresolved" "$out4" && ! has "TypeError" "$out4"; then ok evidence-images-pinned-resolving
else fail evidence-images-pinned-resolving "bad-images=$s1 good=$s2: $out1"; fi

# Stale or incomplete evidence: a later UI commit, a commit outside the PR, or no 1280px capture.
R=$(mkev); echo "a{}" > "$R/app.css" && commit "$R" "UI after the evidence"
fx '{files:{7:["app.css"]},comments:{7:[c(41,"alice",'"$GOOD"')]}}'; st1=$(ev "$R" 7); x1=$?
# A side branch with a UI change merged after the evidence makes it stale too.
R=$(mkev); gc -C "$R" checkout -qb side; echo "b{}" > "$R/side.css" && commit "$R" "side UI"; gc -C "$R" checkout -q main
echo x > "$R/notes.txt" && commit "$R" "unrelated"; gc -C "$R" merge -q --no-ff --no-edit side
fx '{files:{7:["side.css"]},comments:{7:[c(44,"alice",'"$GOOD"')]}}'; st4=$(ev "$R" 7); x4=$?
R=$(mkev); RND=$(node -e 'console.log(require("crypto").randomBytes(20).toString("hex"))')
fx "{files:{7:[\"app.css\"]},contents:[\"before\",\"after\"].flatMap((b)=>[\"$RND:.evidence/\"+b+\"-a-400.png\",\"$RND:.evidence/\"+b+\"-a-1280.png\"]),comments:{7:[c(42,\"alice\",[\"before\",\"after\"].flatMap((b)=>[img(\"https://github.com/acme/demo/blob/$RND/.evidence/\"+b+\"-a-400.png\"),img(\"https://github.com/acme/demo/blob/$RND/.evidence/\"+b+\"-a-1280.png\")]).join(\"\"))]}}"; st2=$(ev "$R" 7); x2=$?
fx '{files:{7:["app.css"]},comments:{7:[c(43,"alice",img(U+"before-home-400.png?raw=true")+img(U+"after-home-400.png?raw=true")+img(U+"after-home-1280.png?raw=true"))]}}'; st3=$(ev "$R" 7); x3=$?
# Two files cannot stand in for four captures, and only image files count.
fx '{files:{7:["app.css"]},contents:[process.env.SHA+":.evidence/before-after-400.txt",process.env.SHA+":.evidence/before-after-1280.txt"],comments:{7:[c(45,"alice",img(U+"before-after-400.txt")+img(U+"before-after-1280.txt"))]}}'; st5=$(ev "$R" 7); x5=$?
if [ $x1 -eq 1 ] && has "UI changed after the evidence" "$st1" && [ $x2 -eq 1 ] && has "not in this PR's history" "$st2" && [ $x3 -eq 1 ] && has "missing before 1280px" "$st3" && [ $x4 -eq 1 ] && has "UI changed after the evidence" "$st4" &&
  [ $x5 -eq 1 ] && has "missing before 400px, before 1280px, after 400px, after 1280px" "$st5"; then ok evidence-images-pinned-resolving
else fail evidence-images-pinned-resolving "stale=$x1 outside=$x2 no1280=$x3 merged=$x4 two-files=$x5: $st1 | $st2 | $st3 | $st4 | $st5"; fi

# A PR changing only documents accepts before-N/after-N page images; a web change does not.
R=$(mkev); PAGES='img(U+"before-1.png")+img(U+"after-1.png")+img(U+"after-2.png")'
PC='contents:["before-1","after-1","after-2"].map((n)=>process.env.SHA+":.evidence/"+n+".png")'
fx "{files:{8:[\"docs/report.docx\",\"deck/q3.pptx\"]},$PC,comments:{8:[c(51,\"alice\",$PAGES)]}}"; d1=$(ev "$R" 8); y1=$?
fx "{files:{8:[\"docs/report.docx\",\"app.css\"]},$PC,comments:{8:[c(52,\"alice\",$PAGES)]}}"; d2=$(ev "$R" 8); y2=$?
# mixed: the web set alone lacks pages; web set plus pages passes
fx "{files:{8:[\"docs/report.docx\",\"app.css\"]},comments:{8:[c(56,\"alice\",$GOOD)]}}"; d6=$(ev "$R" 8); y6=$?
fx "{files:{8:[\"docs/report.docx\",\"app.css\"]},contents:[\"before-home-400\",\"before-home-1280\",\"after-home-400\",\"after-home-1280\",\"before-1\",\"after-1\",\"after-2\"].map((n)=>process.env.SHA+\":.evidence/\"+n+\".png\"),comments:{8:[c(57,\"alice\",$GOOD+$PAGES)]}}"; d7=$(ev "$R" 8); y7=$?
fx "{files:{8:[\"docs/report.docx\"]},$PC,comments:{8:[c(53,\"alice\",img(U+\"after-1.png\")+img(U+\"after-2.png\"))]}}"; d3=$(ev "$R" 8); y3=$?
fx "{files:{8:[\"docs/report.docx\"]},contents:[\"before-01\",\"after-02\"].map((n)=>process.env.SHA+\":.evidence/\"+n+\".png\"),comments:{8:[c(54,\"alice\",img(U+\"before-01.png\")+img(U+\"after-02.png\"))]}}"; d4=$(ev "$R" 8); y4=$?
# web captures are not document pages, even when both names end in the same number
fx "{files:{8:[\"docs/report.docx\"]},comments:{8:[c(55,\"alice\",$GOOD)]}}"; d5=$(ev "$R" 8); y5=$?
# viewport-named files cannot double as document pages
VP='["before-400","before-1280","after-400","after-1280"]'
fx "{files:{8:[\"docs/report.docx\",\"app.css\"]},contents:$VP.map((n)=>process.env.SHA+\":.evidence/\"+n+\".png\"),comments:{8:[c(58,\"alice\",$VP.map((n)=>img(U+n+\".png\")).join(\"\"))]}}"; d8=$(ev "$R" 8); y8=$?
if [ $y1 -eq 0 ] && has "evidence: accepted" "$d1" && [ $y5 -eq 1 ] && has "missing before pages" "$d5" && [ $y6 -eq 1 ] && has "missing before pages" "$d6" && [ $y7 -eq 0 ] && has "evidence: accepted" "$d7" && [ $y8 -eq 1 ] && has "missing before pages" "$d8" && [ $y2 -eq 1 ] && has "missing before 400px" "$d2" && [ $y3 -eq 1 ] && has "missing before pages" "$d3" && [ $y4 -eq 1 ] && has "missing a page with both before and after" "$d4"; then ok evidence-document-pages
else fail evidence-document-pages "docs=$y1 mixed=$y2 no-before=$y3 unpaired=$y4 web-on-docs=$y5 mixed-web-only=$y6 mixed-both=$y7 viewport-as-pages=$y8 ($d8): $d1 | $d2 | $d3 | $d4 | $d5 | $d6 | $d7"; fi

# secrets-scan-changes-only: a dispatch re-gate (the fresh merge ref) scans only the pull request's own commits, so an
# old leak already on the base does not fail it (linux x64 only: the scanner is the pinned gitleaks build)
if [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ]; then
  W=$(mkrepo)
  echo "token = ghp_$(printf 'aB3dE6gH9jK2mN5pQ8sT1vW4yZ7cF0hJ3lN6')" > "$W/old.txt" && commit "$W" "old leak"
  gc -C "$W" checkout -qb feat; echo ok > "$W/clean.txt" && commit "$W" clean
  mr() { gc -C "$W" checkout -q main && gc -C "$W" checkout -q --detach && gc -C "$W" merge -q --no-ff --no-edit feat; }
  echo '{"inputs":{"pr":"1"}}' > "$T/dispatch.json"
  se() { (cd "$W" && GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="$T/dispatch.json" node scripts/agent/gate.mjs secrets) 2>&1; }
  mr; o1=$(se); x1=$?
  gc -C "$W" checkout -q feat; echo "token = ghp_$(printf 'Zy8xW7vU6tS5rQ4pO3nM2lK1jI0hG9fE8dC7')" > "$W/new.txt" && commit "$W" "new leak"; mr; o2=$(se); x2=$?
  if [ $x1 -eq 0 ] && has "HEAD^1..HEAD^2" "$o1" && [ $x2 -eq 1 ]; then ok secrets-scan-changes-only
  else fail secrets-scan-changes-only "clean=$x1 leak=$x2: $o1 | $o2"; fi
else echo "skip secrets-scan-changes-only (the pinned gitleaks build runs on linux x64; gate's CI runs it)"; fi
done_cases
