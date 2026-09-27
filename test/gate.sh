#!/usr/bin/env bash
# Gate, evidence and sandbox-setup cases. Network: secret-scan-in-gate (gitleaks release, linux x64 only),
# setup-installs-repo-deps and evidence-capture-web (npm registry, Playwright chromium).
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

R=$(mkrepo)
echo '{"name":"app","private":true,"scripts":{"typecheck":"echo typecheck-ran","build":"node build.mjs"}}' > "$R/package.json"
echo 'console.log("build-ran"); process.exit(Number(process.env.BUILD_EXIT || 0));' > "$R/build.mjs"
out1=$(G "$R" run typecheck); s1=$?
out2=$(G "$R" run build); s2=$?
out3=$(G "$R" run lint); s3=$?
out4=$(cd "$R" && BUILD_EXIT=3 node scripts/agent/gate.mjs run build 2>&1); s4=$?
if [ $s1 -eq 0 ] && has typecheck-ran "$out1" && [ $s2 -eq 0 ] && has build-ran "$out2" && [ $s3 -eq 0 ] && has "notice: no lint script" "$out3" &&
  [ $s4 -ne 0 ] && has build-ran "$out4"; then ok gate-runs-repo-scripts
else fail gate-runs-repo-scripts "typecheck=$s1 build=$s2 missing=$s3 failing=$s4: $out1 $out2 $out3"; fi

# ---- the rendered workflow
R=$(mkrepo)
line=$(step_run "$R/$WF" "repo checks")
out1=$(cd "$R" && bash -c "$line" 2>&1); s1=$?
printf '#!/usr/bin/env bash\necho hook-ran\nexit 4\n' > "$R/scripts/agent/gate.local.sh" && chmod +x "$R/scripts/agent/gate.local.sh"
out2=$(cd "$R" && bash -c "$line" 2>&1); s2=$?
printf '#!/usr/bin/env bash\necho hook-ran\n' > "$R/scripts/agent/gate.local.sh"
out3=$(cd "$R" && bash -c "$line" 2>&1); s3=$?
order=$(node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n").map(l=>l.trim()),n=L.filter(l=>l.startsWith("- name: ")||l.startsWith("- uses: "));console.log(n.at(-1)==="- name: repo checks"&&n.indexOf("- name: standards")>=0)' "$R/$WF")
if [ -n "$line" ] && [ $s1 -eq 0 ] && has "notice: no scripts/agent/gate.local.sh" "$out1" && [ $s2 -ne 0 ] && has hook-ran "$out2" &&
  [ $s3 -eq 0 ] && has hook-ran "$out3" && [ "$order" = true ]; then ok repo-gate-hook-runs
else fail repo-gate-hook-runs "run='$line' none=$s1 failing=$s2 passing=$s3 last-step=$order: $out1"; fi

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
    for (const s of ["scripts/agent/setup.sh --check","gate.mjs evidence","gate.mjs secrets","gate.mjs install","gate.mjs run typecheck","gate.mjs run build","gate.mjs e2e","scripts/agent/gate.local.sh"])
      if (!runs.includes(s)) out.push("missing step: "+s);
    for (const m of runs.matchAll(/gate\.mjs (\w+)/g)) if (require("child_process").spawnSync("node",["scripts/agent/gate.mjs",m[1],"--help"]).status!==0) out.push("unknown subcommand "+m[1]);
  }
}
if (gates!==1) out.push(gates+" jobs named gate");
console.log(out.join("; ")||"ok")')
if [ "$shape" = ok ]; then ok gate-is-one-required-job; else fail gate-is-one-required-job "$shape"; fi

on=$(node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n"),i=L.indexOf("on:"),k=[];for(let j=i+1;j<L.length&&/^\s/.test(L[j]);j++){const m=L[j].match(/^  ([a-z_]+):/);if(m)k.push(m[1])}console.log(k.join(" "))' "$R/$WF")
if has merge_group "$on" && has pull_request "$on"; then ok gate-runs-on-merge-group; else fail gate-runs-on-merge-group "triggers: $on"; fi

line=$(step_run "$R/$WF" standards)
out1=$(cd "$R" && bash -c "$line" 2>&1); s1=$?
echo "- extra rule" >> "$R/.agents/skills/std-evidence/SKILL.md" && commit "$R" drift
out2=$(cd "$R" && bash -c "$line" 2>&1); s2=$?
if [ -n "$line" ] && [ $s1 -eq 0 ] && [ $s2 -eq 1 ] && has "managed file changed: .agents/skills/std-evidence/SKILL.md" "$out2"; then ok gate-runs-check
else fail gate-runs-check "run='$line' clean=$s1 drift=$s2: $out2"; fi

pins=$(node -e '
const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n"),out=[];
const uses=L.filter(l=>/^\s*-?\s*uses:/.test(l));
if (!uses.length) out.push("no uses: lines");
for (const u of uses) if (!/uses:\s*[^@\s]+@[0-9a-f]{40}(\s|$)/.test(u)) out.push("unpinned: "+u.trim());
const c=L.findIndex(l=>/uses:\s*actions\/checkout@/.test(l)),ind=L[c].search(/\S/);
let creds=false;
for (let j=c+1;j<L.length&&(L[j].search(/\S/)>ind||!L[j].trim());j++) if (/^\s*persist-credentials:\s*false\s*$/.test(L[j])) creds=true;
if (!creds) out.push("checkout keeps credentials");
console.log(out.join("; ")||"ok")' "$R/$WF")
head -c 4096 /dev/urandom > "$T/tampered.tgz"
out=$(cd "$R" && GATE_GITLEAKS_ARCHIVE="$T/tampered.tgz" node scripts/agent/gate.mjs secrets 2>&1); st=$?
if [ "$pins" = ok ] && [ $st -eq 1 ] && has "checksum mismatch" "$out"; then ok gate-supply-chain-pinned
else fail gate-supply-chain-pinned "workflow: $pins; tampered archive exit=$st: $out"; fi

if [ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]; then skip secret-scan-in-gate "linux-x64 only"
else
  R=$(mkrepo); base=$(git -C "$R" rev-parse HEAD)
  echo "release notes" > "$R/notes.txt" && commit "$R"; clean=$(git -C "$R" rev-parse HEAD)
  out1=$(cd "$R" && RANGE="$base..$clean" node scripts/agent/gate.mjs secrets 2>&1); s1=$?
  key="AKIA$(node -e 'const a="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";let s="";for(let i=0;i<16;i++)s+=a[require("crypto").randomInt(32)];console.log(s)')"
  printf 'aws_access_key_id = "%s"\n' "$key" > "$R/config.ini" && commit "$R"
  out2=$(cd "$R" && RANGE="$clean..HEAD" node scripts/agent/gate.mjs secrets 2>&1); s2=$?
  out3=$(G "$R" secrets); s3=$?
  if [ $s1 -eq 0 ] && [ $s2 -eq 1 ] && has aws-access-token "$out2" && has config.ini "$out2" && ! has "$key" "$out2" && [ $s3 -eq 1 ] && ! has "$key" "$out3"; then ok secret-scan-in-gate
  else fail secret-scan-in-gate "clean-range=$s1 leak-range=$s2 tree=$s3 redacted=$(has "$key" "$out2$out3" && echo no || echo yes): $out1 $out2"; fi
fi

# ---- evidence (gate side), against the REST stub
R=$(mkrepo)
out1=$(G "$R" evidence); s1=$?
mkdir -p "$R/.evidence" && printf 'png' > "$R/.evidence/after-home-400.png" && commit "$R"
out2=$(G "$R" evidence); s2=$?
if [ $s1 -eq 0 ] && [ $s2 -eq 1 ] && has ".evidence/ is tracked (.evidence/after-home-400.png)" "$out2"; then ok no-evidence-on-main
else fail no-evidence-on-main "untracked=$s1 tracked=$s2: $out2"; fi

FX=$T/fixture.json LOG=$T/stub.log SHA=$(node -e 'console.log(require("crypto").randomBytes(20).toString("hex"))')
export FX SHA
echo '{"repo":"acme/demo"}' > "$FX"
node test/stubs/gate-github.mjs "$T/port" "$LOG" "$FX" & PIDS="$PIDS $!"
PORT=$(wait_port "$T/port") || { fail stub-start "gate-github stub did not start"; exit 1; }
# fx '<js object>': write the fixture; helpers c(id, login, body, app) and img(url-suffix); files: {pr: [...]}
fx() { node -e 'const S=process.env.SHA,U="https://github.com/acme/demo/blob/"+S+"/.evidence/",img=(u)=>"![shot]("+u+")",
c=(id,login,body,app)=>({id,html_url:"https://github.com/acme/demo/pull/9#issuecomment-"+id,user:{login},performed_via_github_app:app?{slug:"evidence-app"}:null,body});
require("fs").writeFileSync(process.env.FX,JSON.stringify({repo:"acme/demo",files:{},comments:{},contents:[S+":.evidence/after-home-400.png",S+":.evidence/after-home-1280.png"],...eval("("+process.argv[1]+")")}))' "$1"; }
# ev <repo> <pr>: the evidence step on a pull_request event
ev() { printf '{"pull_request":{"number":%s,"user":{"login":"alice"}}}\n' "$2" > "$T/event.json"
  (cd "$1" && GITHUB_EVENT_PATH="$T/event.json" GITHUB_API_URL="http://127.0.0.1:$PORT" GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=stub-token node scripts/agent/gate.mjs evidence) 2>&1; }
GOOD='img(U+"after-home-400.png?raw=true")+"\n"+img(U+"after-home-1280.png?raw=true")'

R=$(mkrepo)
fx '{files:{1:[...Array.from({length:150},(_,i)=>"lib/m"+i+".mjs"),"src/components/Button.tsx"]}}'
: > "$LOG"; out1=$(ev "$R" 1); s1=$?; log=$(cat "$LOG")
fx '{files:{1:[...Array.from({length:150},(_,i)=>"lib/m"+i+".mjs"),"src/components/Button.tsx"]},comments:{1:[c(11,"alice",'"$GOOD"')]}}'
out2=$(ev "$R" 1); s2=$?
if [ $s1 -eq 1 ] && has "src/components/Button.tsx" "$out1" && has "no accepted evidence comment" "$out1" && has '"path":"/repos/acme/demo/pulls/1/files","query":"?per_page=100&page=2"' "$log" &&
  [ $s2 -eq 0 ] && has "evidence: accepted" "$out2"; then ok ui-paths-evidence-required
else fail ui-paths-evidence-required "no-comment=$s1 accepted=$s2: $out1 $out2"; fi

bad=""
for f in docs/report.docx deck/q3.pptx src/styles/site.scss index.html src/components/Nav.astro public/logo.svg; do
  fx "{files:{2:[\"$f\"]}}"; out=$(ev "$R" 2); st=$?
  { [ $st -eq 1 ] && has "$f" "$out"; } || bad="$bad $f=$st"
done
echo "<p>x</p>" > "$R/site.css" && commit "$R" && echo "<p>y</p>" > "$R/site.css" && mkdir -p "$R/docs" && printf 'x' > "$R/docs/brief.docx" && echo x > "$R/lib.mjs"
cls=$(G "$R" classify HEAD); cs=$?
if [ -z "$bad" ] && [ $cs -eq 0 ] && has site.css "$cls" && has docs/brief.docx "$cls" && ! has lib.mjs "$cls"; then ok ui-paths-default-fallback
else fail ui-paths-default-fallback "not required:$bad classify($cs)=$cls"; fi

R=$(mkrepo); r=""
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

R=$(mkrepo)
fx '{files:{4:["lib/server.mjs","README.md","tests/e2e/home.spec.tsx","src/components/Button.test.tsx",".github/workflows/ci.yml","package.json"]}}'
out=$(ev "$R" 4); st=$?
if [ $st -eq 0 ] && has "no UI paths changed" "$out"; then ok non-ui-change-no-evidence; else fail non-ui-change-no-evidence "exit=$st: $out"; fi

fx '{files:{5:["src/app.css"]},comments:{5:[c(21,"mallory",'"$GOOD"')]}}'; out1=$(ev "$R" 5); s1=$?
fx '{files:{5:["src/app.css"]},comments:{5:[c(22,"evidence-app[bot]",'"$GOOD"',true)]}}'; out2=$(ev "$R" 5); s2=$?
fx '{files:{5:["src/app.css"]},comments:{5:[c(23,"alice",'"$GOOD"')]}}'; out3=$(ev "$R" 5); s3=$?
if [ $s1 -eq 1 ] && has "#issuecomment-21 by @mallory" "$out1" && [ $s2 -eq 0 ] && has "#issuecomment-22" "$out2" && [ $s3 -eq 0 ]; then ok evidence-comment-author-or-app
else fail evidence-comment-author-or-app "other-user=$s1 app=$s2 author=$s3: $out1"; fi

B1="https://github.com/acme/demo/blob/main/.evidence/after-home-400.png" B2="https://github.com/other/demo/blob/$SHA/.evidence/after-home-400.png" B3="https://github.com/acme/demo/blob/$SHA/.evidence/missing.png"
fx "{files:{6:[\"src/app.css\"]},comments:{6:[c(31,\"alice\",img(\"$B1\")),c(32,\"alice\",img(\"$B2\")),c(33,\"alice\",$GOOD+img(\"$B3\"))]}}"
: > "$LOG"; out1=$(ev "$R" 6); s1=$?; log=$(cat "$LOG")
fx '{files:{6:["src/app.css"]},comments:{6:[c(34,"alice",'"$GOOD"')]}}'; out2=$(ev "$R" 6); s2=$?
if [ $s1 -eq 1 ] && has "$B1" "$out1" && has "$B2" "$out1" && has "$B3" "$out1" && ! has "after-home-1280" "$out1" &&
  has "\"method\":\"HEAD\",\"path\":\"/repos/acme/demo/contents/.evidence/missing.png\",\"query\":\"?ref=$SHA\"" "$log" && [ $s2 -eq 0 ]; then ok evidence-images-pinned-resolving
else fail evidence-images-pinned-resolving "bad-images=$s1 good=$s2: $out1"; fi

# ---- sandbox setup (restricted PATH with shims; no network)
R=$(mkrepo); P=$T/p1; mkpath "$P"
shim "$P" curl 'exit 0'; shim "$P" sudo 'exec "$@"'; shim "$P" apt-get 'echo "E: Unable to locate package $*" >&2; exit 100'
out=$(cd "$R" && PATH=$P scripts/agent/setup.sh 2>&1); st=$?
if [ $st -eq 0 ] && has "failed (continuing)" "$out" && has "apt-get" "$out" && has "standards ok" "$out"; then ok setup-never-blocks-sandbox
else fail setup-never-blocks-sandbox "exit=$st: $out"; fi

R=$(mkrepo)
echo '{"name":"app","private":true,"devDependencies":{"playwright":"*"}}' > "$R/package.json" && echo '{"lockfileVersion":3}' > "$R/package-lock.json" && commit "$R"
setup_calls() { # setup_calls <curl-exit>: run setup with recording package-manager shims; print the call log
  local p; p=$(mktemp -d "$T/p.XXXXXX"); mkpath "$p"; shim "$p" curl "exit $1"
  for t in apt-get sudo npm npx pnpm yarn corepack; do shim "$p" "$t" "echo \"$t \$*\" >> $p/calls.log"; done
  (cd "$R" && PATH=$p scripts/agent/setup.sh 2>&1) > "$p/out.log"; echo "exit=$?" >> "$p/out.log"
  cat "$p/out.log"; echo "--calls--"; cat "$p/calls.log" 2>/dev/null; }
off=$(setup_calls 7); on=$(setup_calls 0)
if has "offline: skipping installs" "$off" && has "standards ok" "$off" && has "exit=0" "$off" && has $'--calls--' "$off" && [ "${off##*--calls--}" = "" ] &&
  has "npm ci" "${on##*--calls--}"; then ok setup-offline-skips-installs
else fail setup-offline-skips-installs "offline: $off | online calls: ${on##*--calls--}"; fi

R=$(mkrepo); P=$T/p3; mkpath "$P"
shim "$P" curl 'exit 0'; shim "$P" sudo 'exec "$@"'; shim "$P" apt-get "echo \"\$*\" >> $P/apt.log"
(cd "$R" && PATH=$P scripts/agent/setup.sh >/dev/null 2>&1); before=$(cat "$P/apt.log" 2>/dev/null); : > "$P/apt.log"
mkdir -p "$R/docs" && printf 'x' > "$R/docs/brief.docx" && commit "$R"
out=$(cd "$R" && PATH=$P scripts/agent/setup.sh 2>&1); st=$?; after=$(cat "$P/apt.log")
if [ $st -eq 0 ] && ! has libreoffice "$before" && has poppler-utils "$after" && has libreoffice-writer "$after" && has libreoffice-impress "$after"; then ok setup-installs-capture-tools
else fail setup-installs-capture-tools "exit=$st without-docx: $before | with-docx: $after"; fi

# ---- real installs (network): repo deps via setup, then web capture with that install
PWR=""
if ! online; then fail setup-installs-repo-deps "needs network (npm registry)"
else
  R=$(mkrepo); mkdir -p "$R/vendor/tiny"
  echo '{"name":"tiny","version":"1.0.0","main":"index.js"}' > "$R/vendor/tiny/package.json" && echo 'module.exports = 42;' > "$R/vendor/tiny/index.js"
  echo "{\"name\":\"app\",\"private\":true,\"dependencies\":{\"tiny\":\"file:vendor/tiny\"},\"devDependencies\":{\"playwright\":\"$PW_VERSION\"}}" > "$R/package.json"
  echo node_modules/ >> "$R/.gitignore"
  (cd "$R" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1) && commit "$R"
  lock=$(git -C "$R" hash-object package-lock.json)
  out=$(cd "$R" && scripts/agent/setup.sh 2>&1); st=$?
  launch=$(cd "$R" && node -e 'require("playwright").chromium.launch().then(async b=>{console.log(require("tiny")===42&&"launched");await b.close()})' 2>&1)
  if [ $st -eq 0 ] && [ -f "$R/node_modules/playwright/package.json" ] && [ "$(git -C "$R" hash-object package-lock.json)" = "$lock" ] &&
    [ -z "$(git -C "$R" status --porcelain)" ] && [ "$launch" = launched ] && has "standards ok" "$out"; then ok setup-installs-repo-deps; PWR=$R
  else fail setup-installs-repo-deps "exit=$st launch=$launch status=$(git -C "$R" status --porcelain): $(printf '%s' "$out" | tail -15)"; fi
fi

if [ -z "$PWR" ]; then fail evidence-capture-web "needs the Playwright install from setup-installs-repo-deps"
else
  cat > "$T/site.mjs" <<'JS'
import { createServer } from "node:http"; import { writeFileSync } from "node:fs";
const s = createServer((q, r) => { r.writeHead(200, { "Content-Type": "text/html" }); r.end('<!doctype html><body style="margin:0"><div style="height:2400px;background:linear-gradient(#fff,#39f)">Pricing</div></body>'); });
s.listen(0, "127.0.0.1", () => writeFileSync(process.argv[2], String(s.address().port)));
JS
  node "$T/site.mjs" "$T/site.port" & PIDS="$PIDS $!"
  SP=$(wait_port "$T/site.port")
  out=$(cd "$PWR" && node scripts/agent/evidence.mjs --url "http://127.0.0.1:$SP" --path /pricing --name after --out "$T/shots" --video --seconds 1 2>&1); st=$?
  dims=$(node -e 'const fs=require("fs");console.log(process.argv.slice(1).map(f=>{try{const b=fs.readFileSync(f);return b.readUInt32BE(16)+"x"+b.readUInt32BE(20)}catch{return "missing"}}).join(" "))' "$T/shots/after-pricing-400.png" "$T/shots/after-pricing-1280.png")
  if [ $st -eq 0 ] && [ "$dims" = "400x2400 1280x2400" ] && has "$T/shots/after-pricing-400.png" "$out" && has "$T/shots/after-pricing-1280.png" "$out" &&
    has "after-pricing.webm" "$out" && [ -s "$T/shots/after-pricing.webm" ]; then ok evidence-capture-web
  else fail evidence-capture-web "exit=$st dims=$dims: $out"; fi
fi

done_cases
