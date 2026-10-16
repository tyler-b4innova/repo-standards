#!/usr/bin/env bash
# Gate cases through the real gate steps, and evidence cases through the review export, against a GitHub REST stand-in. No network.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GITHUB_SERVER_URL RANGE GH_TOKEN GATE_GITLEAKS_ARCHIVE
ENGINE=$PWD
T=$(mktemp -d)
PIDS=""
trap 'for p in $PIDS; do { kill "$p"; wait "$p"; } 2>/dev/null; done; rm -rf "$T"' EXIT
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
# Restricted PATH: only the tools setup.sh and check.mjs need, plus shims (so gh, ffmpeg, pdftoppm, soffice are absent).
mkpath() { mkdir -p "$1"; local t; for t in bash env git node sed grep id dirname cat; do ln -sf "$(command -v "$t")" "$1/$t"; done; }
shim() { printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
WF=.github/workflows/std-gate.yml

# ---- e2e and repo scripts
R=$(mkrepo)
out=$(GATE_SELECT=full G "$R" e2e); st=$?
mkdir -p "$R/tests/e2e" && echo "notes" > "$R/tests/e2e/README.txt"
out2=$(GATE_SELECT=full G "$R" e2e); st2=$?
echo 'import test from "node:test"; test("home renders", () => {});' > "$R/tests/e2e/home.test.mjs"
out3=$(GATE_SELECT=full G "$R" e2e); st3=$?
echo 'import test from "node:test"; import assert from "node:assert"; test("broken", () => assert.fail("x"));' > "$R/tests/e2e/broken.test.mjs"
GATE_SELECT=full G "$R" e2e >/dev/null; st4=$?
rm "$R/tests/e2e/broken.test.mjs"
echo '{"name":"app","private":true,"scripts":{"test:e2e":"echo e2e-script-ran"}}' > "$R/package.json"
out5=$(GATE_SELECT=full G "$R" e2e); st5=$?
if [ $st -eq 1 ] && has "add an end-to-end suite" "$out" && [ $st2 -eq 1 ] && [ $st3 -eq 0 ] && has 'e2e: node --test "tests/e2e/**/*.test.*js"' "$out3" &&
  has "pass 1" "$out3" && [ $st4 -ne 0 ] && [ $st5 -eq 0 ] && has "e2e: npm run test:e2e" "$out5" && has "e2e-script-ran" "$out5"; then ok gate-fails-without-e2e
else fail gate-fails-without-e2e "none=$st dir-without-runner=$st2 node-test=$st3 failing-test=$st4 script=$st5: $out $out3 $out5"; fi

R=$(mkrepo)
jset "$R/standards.json" 'o.e2e=false' && commit "$R"
out=$(G "$R" e2e); st=$?
# the step is skipped outright, even where a suite exists (it would fail here)
echo '{"name":"app","private":true,"scripts":{"test:e2e":"exit 1"}}' > "$R/package.json"; out2=$(G "$R" e2e); st2=$?
chk=$(cd "$R" && scripts/agent/setup.sh --check 2>&1); cst=$?
node "$ENGINE/bin/repo-standards.mjs" apply --target "$R" --overlay "$ENGINE/examples/overlay.json" --version 0.2.0 >/dev/null
kept=$(node -e 'const s=require(process.argv[1]);console.log(s.e2e===false&&s.version==="0.2.0")' "$R/standards.json")
if [ $st -eq 0 ] && has '::warning::e2e skipped' "$out" && [ $st2 -eq 0 ] && has '::warning::e2e skipped' "$out2" && ! has "e2e:" "$out2" && [ $cst -eq 0 ] && [ "$kept" = true ]; then ok e2e-opt-out-honoured
else fail e2e-opt-out-honoured "exit=$st suite-present=$st2 check=$cst kept=$kept: $out | $out2 | $chk"; fi

# ---- setup installs the repo's own Playwright browser (npm 6's npx once ran /usr/bin/install instead; nothing was installed)
R=$(mkrepo); P=$T/setup-bin; mkpath "$P"; shim "$P" curl 'exit 0'; shim "$P" npm 'echo "npm $*" >> "$SETUP_LOG"'
shim "$P" npx 'echo "npx $*" >> "$SETUP_LOG"; exit 0' # an npx that installs nothing, as npm 6's did
echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$R/package.json" && echo '{}' > "$R/package-lock.json"
su() { : > "$T/setup.log"; (cd "$R" && SETUP_LOG="$T/setup.log" PATH="$P" bash scripts/agent/setup.sh) 2>&1; }
o1=$(su); l1=$(cat "$T/setup.log")
mkdir -p "$R/node_modules/.bin" && printf '#!/bin/sh\necho "playwright $*" >> "$SETUP_LOG"\n' > "$R/node_modules/.bin/playwright" && chmod +x "$R/node_modules/.bin/playwright"
o2=$(su); l2=$(cat "$T/setup.log")
if has "playwright is in package.json but not installed" "$o1" && ! has playwright "$l1" && has "npm ci" "$l2" && has "playwright install chromium" "$l2" && ! has with-deps "$l2" && ! has npx "$l2"
then ok setup-installs-repo-playwright; else fail setup-installs-repo-playwright "missing: $o1 | $l1 || present: $o2 | $l2"; fi

# ---- e2e runs Chromium only (unless this run's browsers say more), against the preview when given
R=$(mkrepo); mkdir -p "$R/node_modules/.bin"
printf '#!/bin/sh\necho "playwright $* base=${PLAYWRIGHT_BASE_URL:-none} ge=${GATE_AFFECTED:-none}" >> "%s/pw.log"\n' "$T" > "$R/node_modules/.bin/playwright"; chmod +x "$R/node_modules/.bin/playwright"
echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$R/package.json"
echo 'export default { projects: [{ name: "chromium" }, { name: "firefox" }, { name: "webkit" }] };' > "$R/playwright.config.js"
pwrun() { : > "$T/pw.log"; (cd "$R" && env "$@" node scripts/agent/gate.mjs e2e) >/dev/null 2>&1; cat "$T/pw.log"; }
e1=$(pwrun GATE_X=1) e2=$(pwrun GATE_BROWSERS=chromium,firefox) e3=$(pwrun GATE_PREVIEW_URL=https://feat.preview.example.test)
echo 'export default { projects: [{ name: "desktop-chrome" }, { name: "mobile-chrome" }] };' > "$R/playwright.config.js"
e5=$(cd "$R" && node scripts/agent/gate.mjs e2e 2>&1); x5=$?
echo 'export default { projects: [{ name: "chromium" }, { name: "firefox" }] };' > "$R/playwright.config.js"
jset "$R/package.json" 'o.scripts={"test:e2e":"playwright test"}'; e6=$(pwrun GATE_X=1); jset "$R/package.json" 'delete o.scripts'
echo 'export default { use: {} };' > "$R/playwright.config.js"; e4=$(pwrun GATE_X=1)
IB=$T/install-bin; mkpath "$IB"; shim "$IB" npm 'exit 0'; shim "$IB" sudo 'exit 0' # root or sudo can run: install-deps is allowed
: > "$T/pw.log"; (cd "$R" && PATH="$IB" GATE_PLATFORM=linux PLAYWRIGHT_BROWSERS_PATH="$T/no-browsers" GATE_BROWSERS=chromium node scripts/agent/gate.mjs install) >/dev/null 2>&1; i1=$(cat "$T/pw.log")
if has "playwright test --project=chromium base=none" "$e1" && has "test --project=chromium --project=firefox" "$e2" && has "base=https://feat.preview.example.test" "$e3" \
  && has "playwright test base=none" "$e4" && ! has "project" "$e4" && [ $x5 -eq 1 ] && has "defines projects but none named chromium" "$e5" && has "playwright test --project=chromium" "$e6" && ! has firefox "$e6" && has "install chromium" "$i1" && has "install-deps chromium" "$i1" && ! has "firefox" "$i1"
then ok e2e-chromium-default; else fail e2e-chromium-default "default=$e1 | two=$e2 | preview=$e3 | no-projects=$e4 | script=$e6 | install=$i1"; fi

# ---- browser cache: the workflow caches the browsers by the exact Playwright version and this run's browsers; system
# packages are installed only when the cached browsers' shared libraries are missing. The fixtures are the folders
# Playwright really unpacks (its registry's EXECUTABLE_PATHS), whose names change between versions and architectures:
# chrome-linux for both builds up to 1.56 and on arm64 from 1.57 to 1.60; chrome-linux64 and chrome-headless-shell-linux64
# on x64 from 1.57; chrome-linux-arm64 and chrome-headless-shell-linux-arm64 on arm64 from 1.63. Each bundles a shared
# library: Playwright's own validation scans these too, not just the executable.
pwlayout() { # pwlayout <browsers dir> <chromium folder> <headless shell folder> <headless shell executable>
  mkdir -p "$1/chromium-1/$2" "$1/chromium_headless_shell-1/$3"
  : > "$1/chromium-1/$2/chrome"; : > "$1/chromium_headless_shell-1/$3/$4"; chmod +x "$1/chromium-1/$2/chrome" "$1/chromium_headless_shell-1/$3/$4"
  : > "$1/chromium-1/$2/libfoo.so.1"; : > "$1/chromium-1/INSTALLATION_COMPLETE"; : > "$1/chromium_headless_shell-1/INSTALLATION_COMPLETE"
}
pwlayout "$T/pw-linux" chrome-linux chrome-linux headless_shell
pwlayout "$T/pw-linux64" chrome-linux64 chrome-headless-shell-linux64 chrome-headless-shell
pwlayout "$T/pw-linux-arm64" chrome-linux-arm64 chrome-headless-shell-linux-arm64 chrome-headless-shell
BR=$T/pw-linux64
mkdir -p "$T/pw-unknown/chromium-1/chrome-win64" # no Linux build folder: nothing to scan is never a pass
# Playwright's install-deps, run as a user other than root, goes through sudo (dependencies.ts); there is no sudo on this
# PATH, as on a host without passwordless sudo, so calling it fails the run
printf '#!/bin/sh\necho "playwright $*" >> "%s/pw.log"\n[ "$1" = install-deps ] && exec sudo sh -c "apt-get update"\nexit 0\n' "$T" > "$R/node_modules/.bin/playwright"
LB=$T/ldd-bin; mkpath "$LB"; shim "$LB" npm 'exit 0'
shim "$LB" sudo "echo \"sudo \$*\" >> \"$T/sudo.log\"; exit 0" # sudo runs here (-n true); every call is logged
shim "$LB" ldd 'case "$1" in *"${LDD_BAD:-NONE}"*) echo "libgbm.so.1 => not found" ;; *) echo "libc.so.6 => /lib/libc.so.6" ;; esac'
binst() { : > "$T/pw.log"; (cd "$R" && PATH="$LB" GATE_PLATFORM=linux PLAYWRIGHT_BROWSERS_PATH="$1" LDD_BAD="$2" GATE_BROWSERS="${3:-chromium}" node scripts/agent/gate.mjs install --browsers-only) > "$T/binst.out" 2>&1
  echo "exit=$? $(cat "$T/pw.log") $(grep '^install:' "$T/binst.out")"; }
bwhy=""
for L in linux linux64 linux-arm64; do b=$(binst "$T/pw-$L" NONE)
  { has "exit=0" "$b" && has "playwright install chromium" "$b" && ! has "install-deps" "$b" && has "browser system packages present" "$b"; } || bwhy="$bwhy; chrome-$L, every library present: $b"; done
for bad in chrome-linux64/chrome chrome-headless-shell-linux64/chrome-headless-shell libfoo.so; do b=$(binst "$BR" "$bad")
  has "install-deps chromium" "$b" || bwhy="$bwhy; chrome-linux64, $bad missing a library: $b"; done
b=$(binst "$T/pw-linux-arm64" chrome-headless-shell-linux-arm64/chrome-headless-shell); has "install-deps chromium" "$b" || bwhy="$bwhy; chrome-linux-arm64 missing a library: $b"
bunk=$(binst "$T/pw-unknown" NONE); bnone=$(binst "$T/empty-browsers" NONE); bff=$(binst "$BR" NONE chromium,firefox)
# the cache key: the repo's exact Playwright version and the sorted browsers; none without Playwright
cp "$R/node_modules/.bin/playwright" "$T/pw.orig"; printf '#!/bin/sh\necho "Version 1.63.0"\n' > "$R/node_modules/.bin/playwright"
bkey=$(cd "$R" && GATE_BROWSERS=firefox,chromium node scripts/agent/gate.mjs playwright); bkey1=$(cd "$R" && GATE_BROWSERS=chromium node scripts/agent/gate.mjs playwright)
cp "$T/pw.orig" "$R/node_modules/.bin/playwright"; echo '{"name":"app","private":true}' > "$R/package.json"; bnokey=$(cd "$R" && node scripts/agent/gate.mjs playwright)
echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$R/package.json"
bwf=$(node -e '
const y=require("fs").readFileSync(process.argv[1],"utf8"),out=[],body=(j)=>{const i=y.indexOf("\n  "+j+":\n");const r=y.slice(i+1).split("\n").slice(1);const e=r.findIndex(l=>/^  \S/.test(l));return (e<0?r:r.slice(0,e)).join("\n")};
for(const j of ["gate"]){const b=body(j);
 if(!/actions\/cache\/restore@[0-9a-f]{40} # v/.test(b)||!b.includes("path: ~/.cache/ms-playwright")||!/steps\.pw\.outputs\.key/.test(b))out.push(j+" caches no browsers");
 if(!/gate\.mjs install --no-browsers/.test(b)||!/gate\.mjs install --browsers-only/.test(b)||/gate\.mjs install$/m.test(b))out.push(j+" installs browsers uncached")}
console.log(out.join("; ")||"ok")' "$R/$WF")
if [ -z "$bwhy" ] && has "install-deps chromium" "$bunk" && has "install-deps chromium" "$bnone" && has "install-deps chromium firefox" "$bff" \
  && has "key=playwright-" "$bkey" && has "-1.63.0-chromium+firefox" "$bkey" && has "-1.63.0-chromium" "$bkey1" && ! has "firefox" "$bkey1" && [ "$bnokey" = "key=" ] && [ "$bwf" = ok ]
then ok gate-browser-cache; else fail gate-browser-cache "layouts=${bwhy#; } | unknown=$bunk | firefox=$bff | none=$bnone | key=$bkey | $bkey1 | nokey=$bnokey | workflow=$bwf"; fi

# ---- browser-deps: the check install makes, for repository scripts and people. It only reports; --install runs install-deps.
# browser-deps-hermetic-root: PLAYWRIGHT_BROWSERS_PATH=0 is Playwright's hermetic install, under the project's own
# node_modules/playwright-core/.local-browsers, so the scan finds the browsers there (with HOME empty, the user's cache has none)
H=$(mkrepo); mkdir -p "$H/node_modules/.bin"; EH=$(mktemp -d "$T/home.XXXXXX")
printf '#!/bin/sh\necho "playwright $*" >> "%s/bd.log"\nexit 0\n' "$T" > "$H/node_modules/.bin/playwright"; chmod +x "$H/node_modules/.bin/playwright"
echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$H/package.json"
HB="$H/node_modules/playwright-core/.local-browsers"; pwlayout "$HB" chrome-linux64 chrome-headless-shell-linux64 chrome-headless-shell
bdrun() { : > "$T/bd.log"; (cd "$H" && env HOME="$EH" PATH="$LB" GATE_PLATFORM="${PLATFORM:-linux}" PLAYWRIGHT_BROWSERS_PATH="${BPATH-0}" LDD_BAD="${BAD:-NONE}" node scripts/agent/gate.mjs browser-deps "$@") 2>&1; echo "exit=$?"; }
: > "$T/sudo.log"; hp=$(bdrun); hpl=$(cat "$T/bd.log")
if has "exit=0" "$hp" && has "browser-deps: system packages present" "$hp" && ! has "install-deps" "$hpl"; then ok browser-deps-hermetic-root
else fail browser-deps-hermetic-root "present=$hp log=$hpl"; fi
# browser-deps-command: exit 0 when present (above); exit 1 naming the file and library when missing, with no install
# unless --install; --install then runs install-deps for the run's browsers; non-Linux and a repo without Playwright have nothing to check
mb=$(BAD=libfoo bdrun); mbl=$(cat "$T/bd.log")
mi=$(BAD=libfoo bdrun --install); mil=$(cat "$T/bd.log"); msudo=$(cat "$T/sudo.log")
dw=$(PLATFORM=darwin BPATH= bdrun); dwl=$(cat "$T/bd.log")
echo '{"name":"app","private":true}' > "$H/package.json"; np=$(bdrun); npl=$(cat "$T/bd.log")
echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$H/package.json"
if has "exit=1" "$mb" && has "libfoo.so.1: libgbm.so.1" "$mb" && ! has "install-deps" "$mbl" \
  && has "exit=0" "$mi" && has "install-deps chromium" "$mil" && has "sudo -n true" "$msudo" \
  && has "exit=0" "$dw" && ! has "install-deps" "$dwl" && has "exit=0" "$np" && ! has "install-deps" "$npl"; then ok browser-deps-command
else fail browser-deps-command "missing=$mb | $mbl || install=$mi | $mil sudo=$msudo || darwin=$dw || nopw=$np"; fi
# browser-deps-no-new-privs: under no_new_privs (agent sandboxes) a missing library is reported with the host requirement, and
# no sudo is called at all, `--install` included; the install step fails the same way. Linux only (setpriv sets the flag).
if command -v setpriv >/dev/null 2>&1; then
  NP=$(command -v node)
  npr() { : > "$T/sudo.log"; : > "$T/bd.log"; (cd "$H" && setpriv --no-new-privs env PATH="$LB" GATE_PLATFORM=linux PLAYWRIGHT_BROWSERS_PATH=0 LDD_BAD=libfoo "$NP" scripts/agent/gate.mjs "$@") 2>&1; echo "exit=$?"; }
  npb=$(npr browser-deps --install); npbs=$(cat "$T/sudo.log"); npbl=$(cat "$T/bd.log")
  npi=$(cd "$H" && : > "$T/sudo.log" && setpriv --no-new-privs env PATH="$LB" GATE_PLATFORM=linux PLAYWRIGHT_BROWSERS_PATH=0 LDD_BAD=libfoo "$NP" scripts/agent/gate.mjs install --browsers-only 2>&1; echo "exit=$?"); npis=$(cat "$T/sudo.log")
  if has "exit=1" "$npb" && has "libfoo.so.1: libgbm.so.1" "$npb" && has "cannot install system packages" "$npb" && [ -z "$npbs" ] && ! has "install-deps" "$npbl" \
    && has "exit=1" "$npi" && has "cannot install them" "$npi" && [ -z "$npis" ]; then ok browser-deps-no-new-privs
  else fail browser-deps-no-new-privs "browser-deps=$npb sudo=[$npbs] | install=$npi sudo=[$npis]"; fi
else echo "skip browser-deps-no-new-privs (needs setpriv, Linux)"; fi

# ---- setup and system packages: sudo is tried only when something is missing and sudo can run here
S=$T/setup-sys; mkdir -p "$S"; SL=$S/setup.log; SUL=$S/sudo.log
pwlayout "$S/browsers" chrome-linux64 chrome-headless-shell-linux64 chrome-headless-shell
mksetup() { # mksetup <repo> <bin dir> <with apt-get and sudo: yes|no> <gh present: yes|no>
  mkpath "$2"
  shim "$2" curl 'exit 0'; shim "$2" npm 'echo "npm $*" >> "$SETUP_LOG"'; shim "$2" npx 'exit 0'
  shim "$2" ffmpeg 'exit 0'; shim "$2" pdftoppm 'exit 0'
  [ "$4" = yes ] && shim "$2" gh 'exit 0'
  if [ "$3" = yes ]; then shim "$2" apt-get 'echo "apt-get $*" >> "$SUDO_LOG"; exit 0'; shim "$2" sudo 'echo "sudo $*" >> "$SUDO_LOG"; exit 0'; fi
  printf '#!/bin/sh\necho "playwright $*" >> "$SETUP_LOG"\nexit 0\n' > "$1/node_modules/.bin/playwright"; chmod +x "$1/node_modules/.bin/playwright"
  printf '#!/bin/sh\nif [ -n "$LDD_MISSING" ]; then echo "libgbm.so.1 => not found"; else echo "libc.so.6 => /lib/libc.so.6"; fi\n' > "$2/ldd"; chmod +x "$2/ldd"
}
SR=$(mkrepo); mkdir -p "$SR/node_modules/.bin"; echo '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}' > "$SR/package.json"; echo '{}' > "$SR/package-lock.json"
sy() { : > "$SL"; : > "$SUL"; (cd "$SR" && env SETUP_LOG="$SL" SUDO_LOG="$SUL" GATE_PLATFORM=linux PLAYWRIGHT_BROWSERS_PATH="$S/browsers" "$@" bash scripts/agent/setup.sh) 2>&1; }
# setup-no-sudo-without-need: gh, the tools and every browser library are present, so setup runs no sudo and no install-deps
P1=$S/bin-present; mksetup "$SR" "$P1" yes yes
o1=$(sy PATH="$P1" LDD_MISSING=); l1=$(cat "$SL"); s1=$(cat "$SUL")
if [ -z "$s1" ] && has "playwright install chromium" "$l1" && ! has "install-deps" "$l1" && ! has "with-deps" "$l1" && ! has "sudo cannot run here" "$o1"; then ok setup-no-sudo-without-need
else fail setup-no-sudo-without-need "sudo=[$s1] playwright=[$l1] out=$o1"; fi
# setup-installs-when-sudo-works: a library is missing and sudo can run: setup installs the apt packages and the browser's libraries
P2=$S/bin-sudo; mksetup "$SR" "$P2" yes no
o2=$(sy PATH="$P2" LDD_MISSING=1); l2=$(cat "$SL"); s2=$(cat "$SUL")
if has "sudo -n true" "$s2" && has "sudo -n apt-get install" "$s2" && has "install-deps chromium" "$l2" && ! has "sudo cannot run here" "$o2"; then ok setup-installs-when-sudo-works
else fail setup-installs-when-sudo-works "sudo=[$s2] playwright=[$l2] out=$o2"; fi
# setup-no-sudo-under-no-new-privs: agent sandboxes. A library and gh are missing: no sudo call (not even sudo -n true), no install,
# and one line names the packages and the host requirement. Linux with setpriv, not root.
if command -v setpriv >/dev/null 2>&1 && [ "$(id -u)" != 0 ]; then
  P3=$S/bin-nnp; mksetup "$SR" "$P3" yes no
  SP=$(command -v setpriv); : > "$SL"; : > "$SUL"
  o3=$(cd "$SR" && env SETUP_LOG="$SL" SUDO_LOG="$SUL" GATE_PLATFORM=linux PLAYWRIGHT_BROWSERS_PATH="$S/browsers" LDD_MISSING=1 PATH="$P3" "$SP" --no-new-privs bash scripts/agent/setup.sh 2>&1)
  l3=$(cat "$SL"); s3=$(cat "$SUL")
  if [ -z "$s3" ] && ! has "install-deps" "$l3" && ! has "apt-get" "$s3" && [ "$(grep -c 'sudo cannot run here' <<<"$o3")" = 1 ] && has "system packages" "$o3" && has "libgbm.so.1" "$o3" \
    && has "playwright install chromium" "$l3"; then ok setup-no-sudo-under-no-new-privs
  else fail setup-no-sudo-under-no-new-privs "sudo=[$s3] playwright=[$l3] out=$o3"; fi
else echo "skip setup-no-sudo-under-no-new-privs (needs setpriv, Linux, not root)"; fi

# e2e-budget-removed: a slow suite passes, a leftover e2e.budget warns in --check and changes nothing, and an overlay still setting gate.budget loads with one notice
R=$(mkrepo)
jset "$R/standards.json" 'o.e2e={command:"sleep 2",budget:0.01}'
t0=$(date +%s); bo=$(cd "$R" && node scripts/agent/gate.mjs e2e 2>&1); bx=$?; t1=$(date +%s)
bc=$(cd "$R" && node scripts/agent/check.mjs 2>&1)
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.gate={...o.gate,budget:{e2e:5}};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$ENGINE/examples/overlay.json" "$T/gb.json"
GD=$(mktemp -d "$T/r.XXXXXX"); git -C "$GD" init -q -b main
gerr=$(node "$ENGINE/bin/repo-standards.mjs" apply --target "$GD" --overlay "$T/gb.json" --version 0.1.0 2>&1 >/dev/null); gx=$?
if [ $bx -eq 0 ] && ! has "budget" "$bo" && has "e2e.budget is ignored" "$bc" && ! has "FAIL: standards.json e2e" "$bc" && [ $gx -eq 0 ] && [ "$(grep -c 'gate.budget was removed' <<<"$gerr")" = 1 ] \
  && ! grep -q "gate_budget\|PW_GLOBAL_TIMEOUT\|-minute budget" "$ENGINE/template/scripts/agent/gate.mjs" "$ENGINE/defaults.json" "$ENGINE/lib/engine.mjs"
then ok e2e-budget-removed; else fail e2e-budget-removed "run=$bx in $((t1 - t0))s: $bo | check: $bc | overlay=$gx: $gerr"; fi

# draft-cheap-ready-full (syntax): the syntax step runs on every gated run; it fails a broken script and, with a YAML parser, a broken
# workflow file; without PyYAML it says so and skips workflows. The workflow case needs PyYAML on the machine: no skip is allowed under CI.
R=$(mkrepo); sy1=$(cd "$R" && node scripts/agent/gate.mjs syntax 2>&1); sx1=$?
YB=$T/noyaml-bin; mkpath "$YB"; shim "$YB" python3 'exit 1'
sy2=$(cd "$R" && PATH="$YB" node scripts/agent/gate.mjs syntax 2>&1); sx2=$?
printf 'if then\n' > "$R/scripts/agent/broken.sh" && git -C "$R" add scripts/agent/broken.sh; sy3=$(cd "$R" && node scripts/agent/gate.mjs syntax 2>&1); sx3=$?
haveyaml=0; python3 -c "import yaml" 2>/dev/null && haveyaml=1
sx4=none sy4=""
if [ $haveyaml -eq 1 ]; then
  WR=$(mkrepo); printf 'on: [unclosed\n' > "$WR/.github/workflows/broken.yml" && git -C "$WR" add .github/workflows/broken.yml; sy4=$(cd "$WR" && node scripts/agent/gate.mjs syntax 2>&1); sx4=$?
fi
scripts_ok=0; [ $sx1 -eq 0 ] && has "syntax: scripts and workflows parse" "$sy1" && [ $sx2 -eq 0 ] && has "PyYAML is not on this runner" "$sy2" && [ $sx3 -eq 1 ] && has "scripts/agent/broken.sh" "$sy3" && scripts_ok=1
if [ $scripts_ok -eq 1 ] && [ $haveyaml -eq 0 ]; then echo "skip draft-cheap-ready-full (python3 has no PyYAML here, so the broken-workflow case did not run)"
elif [ $scripts_ok -eq 1 ] && [ "$sx4" = 1 ] && has ".github/workflows/broken.yml" "$sy4"; then ok draft-cheap-ready-full
else fail draft-cheap-ready-full "clean=$sx1 noyaml=$sx2 broken=$sx3 workflow=$sx4: $sy1 | $sy2 | $sy3 | $sy4"; fi

# ---- the rendered workflow
R=$(mkrepo)
shape=$(cd "$R" && node -e '
const fs=require("fs"),dir=".github/workflows",out=[];
let gates=0;
for (const f of fs.readdirSync(dir)) {
  const L=fs.readFileSync(dir+"/"+f,"utf8").split("\n"),j=L.indexOf("jobs:");
  const jobs=L.slice(j+1).filter(l=>/^  [A-Za-z0-9_-]+:\s*$/.test(l)).map(l=>l.trim().slice(0,-1));
  gates+=L.slice(j+1).filter(l=>/^    name: .*\|\| .gate. \}\}\s*$/.test(l)).length;
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

# one-test-job / one-gate-run-per-push: the full gate is ONE job named `gate`: one checkout and one install (with the cache
# restores), then the checks steps, then the test steps (typecheck, build, the repo checks, preview, e2e, in that order)
# for a full plan on a ready head, then the verdict, which reads the outcomes of the checks part and the test part. A push
# to a draft starts no job, a draft's job is named `draft (not gated)`, and a cancelled run runs no verdict
why=""; WFT=$ENGINE/template/.github/workflows/std-gate.yml
node --input-type=module - "$WFT" <<'JS' || why="$why; $?"
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const y = readFileSync(process.argv[2], "utf8"), parts = y.slice(y.indexOf("\njobs:")).split(/^  ([\w-]+):\s*$/m), jobs = {};
for (let i = 1; i < parts.length; i += 2) jobs[parts[i]] = parts[i + 1];
assert.deepEqual(Object.keys(jobs), ["gate"]);
const gate = jobs.gate;
assert.equal((gate.match(/gate\.mjs install --no-browsers/g) ?? []).length, 1, "one install");
assert.equal((gate.match(/actions\/checkout@/g) ?? []).length, 1, "one checkout");
assert.equal((gate.match(/actions\/setup-node@/g) ?? []).length, 1, "one setup-node");
const order = ["setup.sh --check", "gate.mjs syntax", "gate.mjs install", "run typecheck", "run build", "gate.local.sh", "gate.mjs preview", "gate.mjs e2e", "gate.mjs verdict"].map((k) => gate.indexOf(k));
assert.ok(order.every((n, i) => n > 0 && (i === 0 || n > order[i - 1])), "checks, install, typecheck, build, repo checks, preview, e2e, verdict in order: " + order);
assert.match(gate, /^    name: \$\{\{ github\.event\.pull_request\.draft == true && 'draft \(not gated\)' \|\| 'gate' \}\}$/m, "a draft's job is named draft (not gated)");
assert.match(gate, /^    if: github\.event\.pull_request\.draft != true$/m, "the job is skipped for a draft, never for a ready head");
assert.ok(!/needs\b/.test(gate), "no needs: one job, no job results to read");
assert.ok(!y.includes("STD_GATE_DRAFT_PUSHES"), "no draft opt-in knob");
// every test step runs only for a full plan on a ready head (a ready run queued before the PR was converted to draft
// carries the plan's live draft output, and the verdict fails it)
const stepsOf = (text) => text.split(/^      - /m).slice(1);
const testSteps = ["dependency cache", "install", "playwright", "browser cache", "browsers", "typecheck", "build", "repo checks", "preview", "e2e"];
for (const s of stepsOf(gate)) {
  const name = (s.match(/^name: (.*)$/m) ?? [])[1] ?? "";
  if (testSteps.includes(name)) assert.match(s, /if: steps\.plan\.outputs\.mode == 'full' && steps\.plan\.outputs\.rollback_draft != 'true'/, name + " is not gated on a full plan on a ready head");
}
const verdict = stepsOf(gate).find((s) => /^name: verdict$/m.test(s));
assert.match(verdict, /if: \$\{\{ !cancelled\(\) \}\}/, "a cancelled run runs no verdict");
assert.match(verdict, /CHECKS: \$\{\{ steps\.syntax\.outcome \}\}/, "the checks part is the syntax step's outcome");
assert.match(verdict, /TEST: \$\{\{ steps\.e2e\.outcome \}\}/, "the test part is the e2e step's outcome");
JS
v() { (cd "$ENGINE/template" >/dev/null && env MODE="$1" LIVE_DRAFT="$2" CHECKS="$3" TEST="$4" GITHUB_EVENT_PATH= node scripts/agent/gate.mjs verdict 2>&1); }
v1=$(v full false success success); x1=$?
v2=$(v full false success failure); x2=$?
v3=$(v cheap false success skipped); x3=$?
v4=$(v full false success skipped); x4=$?
v5=$(v full true success success); x5=$?
v6=$(v full false failure skipped); x6=$?
v7=$(v full false cancelled skipped); x7=$?
{ [ $x1 -eq 0 ] && [ $x2 -ne 0 ] && [ $x3 -ne 0 ] && [ $x4 -ne 0 ] && [ $x5 -ne 0 ] && [ $x6 -ne 0 ] && [ $x7 -ne 0 ]; } || why="$why; verdict $x1..$x7: $v1 | $v2 | $v3 | $v4 | $v5 | $v6 | $v7"
if [ -z "$why" ]; then ok one-test-job; ok one-gate-run-per-push; else fail one-test-job "$why"; fail one-gate-run-per-push "$why"; fi

# gate-run-name: the run-name carries the pull request's identity in the contract format, for pull_request events only
why=""
rn=$(sed -n 's/^run-name: //p' "$ENGINE/template/.github/workflows/std-gate.yml")
case "$rn" in '${{ github.event_name == '"'pull_request'"' && format('"'gate pr={0} base={1} head={2}'"', github.event.pull_request.number, github.base_ref, github.event.pull_request.head.sha) || '"''"' }}') ;; *) why="run-name: $rn" ;; esac
if [ -z "$why" ]; then ok gate-run-name; else fail gate-run-name "$why"; fi

# gate-concurrency-groups: a draft-payload run (every job skipped) can never cancel a ready run's full gate
why=""
node --input-type=module - "$ENGINE/template/.github/workflows/std-gate.yml" <<'JS' || why="$why; $?"
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const line = readFileSync(process.argv[2], "utf8").split("\n").find((l) => /^  group: /.test(l)).replace(/^  group: /, "");
const group = (github, inputs = {}) => line.replace(/\$\{\{(.*?)\}\}/g, (_, e) => new Function("github", "inputs", `return (${e});`)(github, inputs));
const pr = (number, action, draft) => ({ ref: "refs/pull/" + number + "/merge", event: { action, pull_request: { number, draft } } });
assert.notEqual(group(pr(7, "synchronize", true)), group(pr(7, "ready_for_review", false)), "draft synchronize vs ready_for_review");
assert.equal(group(pr(7, "synchronize", false)), group(pr(7, "synchronize", false)), "two ready synchronizes share a group");
assert.equal(group(pr(7, "synchronize", false)), group(pr(7, "ready_for_review", false)), "a ready push cancels the older ready run");
assert.notEqual(group(pr(7, "edited", false)), group(pr(7, "synchronize", false)), "edit has its own group");
assert.notEqual(group(pr(7, "synchronize", false)), group(pr(8, "synchronize", false)), "pull requests do not share a group");
assert.equal(group({ ref: "refs/heads/gh-readonly-queue/x", event: { pull_request: {} } }), "std-gate-refs/heads/gh-readonly-queue/x", "merge_group key unchanged");
assert.equal(group({ ref: "refs/heads/main", event: { pull_request: {} } }, { pr: "7" }), "std-gate-7", "workflow_dispatch key unchanged");
JS
if [ -z "$why" ]; then ok gate-concurrency-groups; else fail gate-concurrency-groups "$why"; fi

# dependency-cache-by-lockfile: gate and the warm-up cache the lockfile's package manager (npm, pnpm, yarn); pnpm and
# yarn come through corepack, and when that fails there is no cache rather than a failed setup step; both workflows
# run the same step, and the warm-up fires on any of the three lockfiles
why=""; CW=$ENGINE/template/.github/workflows
for wf in std-gate.yml std-cache-warm.yml; do [ "$(step_run "$CW/$wf" "package manager")" = "$(step_run "$CW/std-gate.yml" "package manager")" ] || why="$why; $wf step differs"; done
grep -q 'uses: actions/cache@' "$CW/std-cache-warm.yml" && grep -q 'path: ${{ steps.pm.outputs.path }}' "$CW/std-cache-warm.yml" && grep -q 'paths: \[package-lock.json, pnpm-lock.yaml, yarn.lock\]' "$CW/std-cache-warm.yml" || why="$why; warm-up trigger or cache"
pmrun() { # pmrun <lockfile> <corepack exit>: the step in a scratch dir with stub corepack/pnpm/yarn; prints its output
  local d; d=$(mktemp -d "$T/pm.XXXXXX"); mkdir "$d/bin"; : > "$d/$1"
  shim "$d/bin" corepack "exit $2"; shim "$d/bin" pnpm "echo 10.0.0"; shim "$d/bin" yarn "echo 1.22.0"
  (cd "$d" && GITHUB_OUTPUT="$d/out" PATH="$d/bin:$PATH" bash -e -c "$(step_run "$CW/std-gate.yml" "package manager")") >/dev/null 2>&1 || echo "step-failed"
  grep "^cache=" "$d/out" 2>/dev/null; }
got="$(pmrun package-lock.json 0)|$(pmrun pnpm-lock.yaml 0)|$(pmrun yarn.lock 0)|$(pmrun pnpm-lock.yaml 1)|$(pmrun none.txt 0)"
[ "$got" = "cache=npm|cache=pnpm|cache=yarn||" ] || why="$why; outputs: $got"
if [ -z "$why" ]; then ok dependency-cache-by-lockfile; else fail dependency-cache-by-lockfile "$why"; fi

# ---- evidence: .evidence/ never tracked (the standards check); the comment rule through the review export
R=$(mkrepo)
out1=$(cd "$R" && scripts/agent/setup.sh --check 2>&1); s1=$?
mkdir -p "$R/.evidence" && printf 'png' > "$R/.evidence/after-home-400.png" && commit "$R"
out2=$(cd "$R" && scripts/agent/setup.sh --check 2>&1); s2=$?
if [ $s1 -eq 0 ] && [ $s2 -eq 1 ] && has ".evidence/ is tracked (.evidence/after-home-400.png)" "$out2" && has "git rm -r --cached .evidence" "$out2" && has "pr.sh evidence" "$out2"; then ok no-evidence-on-main
else fail no-evidence-on-main "untracked=$s1 tracked=$s2: $out2"; fi

# Evidence repos are clones of one repo, so the marked head is in every PR head's history.
EV=$(mkrepo); mkev() { local d; d=$(mktemp -d "$T/ev.XXXXXX"); git clone -q "$EV" "$d" && echo "$d"; }
FX=$T/fixture.json LOG=$T/stub.log SHA=$(git -C "$EV" rev-parse HEAD)
export FX SHA
echo '{"repo":"acme/demo"}' > "$FX"
node test/stubs/gate-github.mjs "$T/port" "$LOG" "$FX" & PIDS="$PIDS $!"
PORT=$(wait_port "$T/port") || { fail stub-start "gate-github stub did not start"; exit 1; }
# fx '<js object>': write the fixture. The spec can use: c(id, login, body, app) for a comment; img(name) for an
# attachment named by its alt text; MK (the marker for the marked head); GOOD (before and after at 400 and 1280px);
# PAGES (before-1, after-1, after-2 as attachments); PINGOOD (before and after at 400 and 1280px as pinned .evidence/
# blob links) with PINFILES (those files, as the fixture's contents).
fx() { node -e 'const S=process.env.SHA, MK="<!-- std:evidence head="+S+" -->\n### Evidence\n", img=(n)=>"!["+n+"](https://github.com/user-attachments/assets/"+n.replace(/[^a-z0-9]/gi,"-")+"-id)",
c=(id,login,body,app,at="2026-10-13T09:00:00Z",edited)=>({id,created_at:at,updated_at:edited??at,html_url:"https://github.com/acme/demo/pull/9#issuecomment-"+id,user:{login},performed_via_github_app:app?{slug:"evidence-app"}:null,body}),
GOOD=MK+["before","after"].flatMap((b)=>[img(b+"-home-400.png"),img(b+"-home-1280.png")]).join("\n"),
PAGES=[img("before-1.png"),img("after-1.png"),img("after-2.png")].join("\n"),
PIN=(n)=>"!["+n+"](https://github.com/acme/demo/blob/"+S+"/.evidence/"+n+"?raw=true)",
PINGOOD=["before","after"].flatMap((b)=>[PIN(b+"-home-400.png"),PIN(b+"-home-1280.png")]).join("\n"),
PINFILES=["before","after"].flatMap((b)=>[S+":.evidence/"+b+"-home-400.png",S+":.evidence/"+b+"-home-1280.png"]);
require("fs").writeFileSync(process.env.FX,JSON.stringify({repo:"acme/demo",files:{},comments:{},...eval("("+process.argv[1]+")")}))' "$1"; }
# ev <repo> <pr>: the review rule (repo-standards/review, as a launcher calls it); the stand-in answers commits,
# compares and the policy files from <repo>
ev() {
  node -e 'const f=process.env.FX,x=JSON.parse(require("fs").readFileSync(f,"utf8"));x.head=process.argv[1];x.gitDir=process.argv[2];require("fs").writeFileSync(f,JSON.stringify(x))' "$(git -C "$1" rev-parse HEAD)" "$1"
  GITHUB_API_URL="http://127.0.0.1:$PORT" GITHUB_REPOSITORY=acme/demo node "$ENGINE/test/review-run.mjs" "$2" 2>&1; }

R=$(mkev)
fx '{files:{1:[...Array.from({length:150},(_,i)=>"lib/m"+i+".mjs"),"src/components/Button.tsx"]}}'
: > "$LOG"; out1=$(ev "$R" 1); s1=$?; log=$(cat "$LOG")
fx '{files:{1:[...Array.from({length:150},(_,i)=>"lib/m"+i+".mjs"),"src/components/Button.tsx"]},comments:{1:[c(11,"alice",GOOD)]}}'
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

# evidence-comment-author-or-app: only the PR author, an app or a trusted login may post the evidence
R=$(mkev)
fx '{files:{5:["src/app.css"]},comments:{5:[c(21,"mallory",GOOD)]}}'; out1=$(ev "$R" 5); s1=$?
fx '{files:{5:["src/app.css"]},comments:{5:[c(22,"evidence-app[bot]",GOOD,true)]}}'; out2=$(ev "$R" 5); s2=$?
fx '{files:{5:["src/app.css"]},comments:{5:[c(23,"alice",GOOD)]}}'; out3=$(ev "$R" 5); s3=$?
if [ $s1 -eq 1 ] && has "#issuecomment-21 by @mallory" "$out1" && [ $s2 -eq 0 ] && has "#issuecomment-22" "$out2" && [ $s3 -eq 0 ]; then ok evidence-comment-author-or-app
else fail evidence-comment-author-or-app "other-user=$s1 app=$s2 author=$s3: $out1"; fi

# evidence-pinned-transition: the pinned .evidence/ form is accepted before the cut-over while its links resolve at their
# commit and no UI commit follows; unresolved or stale pinned evidence is refused. evidence-marker-required: a marker-less comment is
# refused with the reason; a missing width and a repeated upload are refused as missing captures.
R=$(mkev)
fx '{files:{6:["src/app.css"]},contents:PINFILES,comments:{6:[c(31,"alice","<!-- std:evidence -->\n"+PINGOOD)]}}'; out1=$(ev "$R" 6); s1=$?
fx '{files:{6:["src/app.css"]},contents:PINFILES.slice(1),comments:{6:[c(36,"alice",PINGOOD)]}}'; out6=$(ev "$R" 6); s6=$?
R2=$(mkev); echo "a{}" > "$R2/app.css" && commit "$R2" "UI after the pinned evidence"
fx '{files:{7:["app.css"]},contents:PINFILES,comments:{7:[c(37,"alice",PINGOOD)]}}'; out7=$(ev "$R2" 7); s7=$?
fx '{files:{6:["src/app.css"]},comments:{6:[c(32,"alice",GOOD.replace(/<!-- std:evidence head=[0-9a-f]+ -->/,"<!-- std:evidence -->"))]}}'; out2=$(ev "$R" 6); s2=$?
fx '{files:{6:["src/app.css"]},comments:{6:[c(33,"alice",MK+[img("before-home-400.png"),img("before-home-1280.png"),img("after-home-400.png")].join("\n"))]}}'; out3=$(ev "$R" 6); s3=$?
fx '{files:{6:["src/app.css"]},comments:{6:[c(34,"alice",GOOD)]}}'; out4=$(ev "$R" 6); s4=$?
fx '{files:{6:["src/app.css"]},comments:{6:[c(35,"alice",MK+["before-home-400.png","before-home-1280.png","after-home-400.png","after-home-1280.png"].map((n)=>"![" + n + "](https://github.com/user-attachments/assets/one-upload)").join("\n"))]}}'; out5=$(ev "$R" 6); s5=$?
if [ $s1 -eq 0 ] && has "evidence: accepted" "$out1" && [ $s6 -eq 1 ] && has "unresolved" "$out6" && [ $s7 -eq 1 ] && has "UI changed after the evidence" "$out7"; then ok evidence-pinned-transition
else fail evidence-pinned-transition "valid=$s1 unresolved=$s6 stale=$s7: $out1 | $out6 | $out7"; fi
# pinned-cut-over: a pinned comment created or edited at or after the cut-over (2026-10-13T10:00:00Z) is refused with the re-post
# message, the same links created just before it are accepted, and an attachment comment created after it is still accepted.
R=$(mkev)
fx '{files:{8:["src/app.css"]},contents:PINFILES,comments:{8:[c(41,"alice","<!-- std:evidence -->\n"+PINGOOD,false,"2026-10-13T09:59:59Z")]}}'; out8=$(ev "$R" 8); s8=$?
fx '{files:{8:["src/app.css"]},contents:PINFILES,comments:{8:[c(42,"alice","<!-- std:evidence -->\n"+PINGOOD,false,"2026-10-13T10:00:00Z")]}}'; out9=$(ev "$R" 8); s9=$?
fx '{files:{8:["src/app.css"]},comments:{8:[c(43,"alice",GOOD,false,"2026-10-13T10:00:00Z")]}}'; out10=$(ev "$R" 8); s10=$?
fx '{files:{8:["src/app.css"]},contents:PINFILES,comments:{8:[c(44,"alice","<!-- std:evidence -->\n"+PINGOOD,false,"2026-10-13T09:00:00Z","2026-10-13T10:00:00Z")]}}'; out11=$(ev "$R" 8); s11=$?
if [ $s8 -eq 0 ] && has "evidence: accepted" "$out8" && [ $s9 -eq 1 ] && has "pinned .evidence/ links are no longer accepted; re-post with pr.sh evidence" "$out9" && [ $s10 -eq 0 ] && has "evidence: accepted" "$out10" && [ $s11 -eq 1 ] && has "pinned .evidence/ links are no longer accepted" "$out11"; then ok evidence-pinned-transition
else fail evidence-pinned-transition "before=$s8 after=$s9 attachment=$s10 edited-after=$s11: $out8 | $out9 | $out10 | $out11"; fi
if [ $s2 -eq 1 ] && has "no <!-- std:evidence head=<40-hex sha> --> marker; re-post with pr.sh evidence" "$out2"; then ok evidence-marker-required; else fail evidence-marker-required "marker-less=$s2: $out2"; fi
if [ $s3 -eq 1 ] && has "missing after 1280px" "$out3" && [ $s4 -eq 0 ] && has "evidence: accepted" "$out4" && [ $s5 -eq 1 ] && has "missing before 400px" "$out5"; then ok evidence-attachments-pinned
else fail evidence-attachments-pinned "missing-width=$s3 accepted=$s4 one-asset=$s5: $out3 | $out4 | $out5"; fi

# Stale or incomplete evidence: a later UI commit, a marked head outside the PR, or a merged side branch with UI.
R=$(mkev); echo "a{}" > "$R/app.css" && commit "$R" "UI after the evidence"
fx '{files:{7:["app.css"]},comments:{7:[c(41,"alice",GOOD)]}}'; st1=$(ev "$R" 7); x1=$?
# A side branch with a UI change merged after the evidence makes it stale too.
R=$(mkev); gc -C "$R" checkout -qb side; echo "b{}" > "$R/side.css" && commit "$R" "side UI"; gc -C "$R" checkout -q main
echo x > "$R/notes.txt" && commit "$R" "unrelated"; gc -C "$R" merge -q --no-ff --no-edit side
fx '{files:{7:["side.css"]},comments:{7:[c(44,"alice",GOOD)]}}'; st4=$(ev "$R" 7); x4=$?
R=$(mkev); RND=$(node -e 'console.log(require("crypto").randomBytes(20).toString("hex"))')
fx "{files:{7:[\"app.css\"]},comments:{7:[c(42,\"alice\",GOOD.replace(S,\"$RND\"))]}}"; st2=$(ev "$R" 7); x2=$?
fx '{files:{7:["app.css"]},comments:{7:[c(43,"alice",MK+[img("before-home-400.png"),img("after-home-400.png"),img("after-home-1280.png")].join("\n"))]}}'; st3=$(ev "$R" 7); x3=$?
if [ $x1 -eq 1 ] && has "UI changed after the evidence" "$st1" && [ $x2 -eq 1 ] && has "not in this PR's history" "$st2" && [ $x3 -eq 1 ] && has "missing before 1280px" "$st3" && [ $x4 -eq 1 ] && has "UI changed after the evidence" "$st4"; then ok evidence-attachments-pinned
else fail evidence-attachments-pinned "stale=$x1 outside=$x2 no1280=$x3 merged=$x4: $st1 | $st2 | $st3 | $st4"; fi

# A PR changing only documents accepts before-N/after-N page images; a web change does not.
R=$(mkev)
fx '{files:{8:["docs/report.docx","deck/q3.pptx"]},comments:{8:[c(51,"alice",MK+PAGES)]}}'; d1=$(ev "$R" 8); y1=$?
fx '{files:{8:["docs/report.docx","app.css"]},comments:{8:[c(52,"alice",MK+PAGES)]}}'; d2=$(ev "$R" 8); y2=$?
# mixed: the web set alone lacks pages; web set plus pages passes
fx '{files:{8:["docs/report.docx","app.css"]},comments:{8:[c(56,"alice",GOOD)]}}'; d6=$(ev "$R" 8); y6=$?
fx '{files:{8:["docs/report.docx","app.css"]},comments:{8:[c(57,"alice",GOOD+"\n"+PAGES)]}}'; d7=$(ev "$R" 8); y7=$?
fx '{files:{8:["docs/report.docx"]},comments:{8:[c(53,"alice",MK+img("after-1.png")+"\n"+img("after-2.png"))]}}'; d3=$(ev "$R" 8); y3=$?
fx '{files:{8:["docs/report.docx"]},comments:{8:[c(54,"alice",MK+img("before-01.png")+"\n"+img("after-02.png"))]}}'; d4=$(ev "$R" 8); y4=$?
# web captures are not document pages, even when both names end in the same number
fx '{files:{8:["docs/report.docx"]},comments:{8:[c(55,"alice",GOOD)]}}'; d5=$(ev "$R" 8); y5=$?
# viewport-named files cannot double as document pages
fx '{files:{8:["docs/report.docx","app.css"]},comments:{8:[c(58,"alice",MK+["before-400.png","before-1280.png","after-400.png","after-1280.png"].map((n)=>img(n)).join("\n"))]}}'; d8=$(ev "$R" 8); y8=$?
if [ $y1 -eq 0 ] && has "evidence: accepted" "$d1" && [ $y5 -eq 1 ] && has "missing before pages" "$d5" && [ $y6 -eq 1 ] && has "missing before pages" "$d6" && [ $y7 -eq 0 ] && has "evidence: accepted" "$d7" && [ $y8 -eq 1 ] && has "missing before pages" "$d8" && [ $y2 -eq 1 ] && has "missing before 400px" "$d2" && [ $y3 -eq 1 ] && has "missing before pages" "$d3" && [ $y4 -eq 1 ] && has "missing a page with both before and after" "$d4"; then ok evidence-document-pages
else fail evidence-document-pages "docs=$y1 mixed=$y2 no-before=$y3 unpaired=$y4 web-on-docs=$y5 mixed-web-only=$y6 mixed-both=$y7 viewport-as-pages=$y8 ($d8): $d1 | $d2 | $d3 | $d4 | $d5 | $d6 | $d7"; fi

# secrets-scan-changes-only: a dispatch re-gate (the fresh merge ref) scans only the pull request's own commits, so an
# old leak already on the base does not fail it (the scanner is checksum-pinned on macOS and Linux)
if node -e 'process.exit(["linux", "darwin"].includes(process.platform) && ["x64", "arm64"].includes(process.arch) ? 0 : 1)'; then
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
else echo "skip secrets-scan-changes-only (no pinned gitleaks build for this platform)"; fi
done_cases
