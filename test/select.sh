#!/usr/bin/env bash
# Affected-test selection through the real entry points (select.mjs and gate.mjs e2e). No network except the real-Playwright case.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_ACTIONS GATE_SELECT GATE_BASE GITHUB_STEP_SUMMARY
export GITHUB_EVENT_NAME=pull_request # every case is a pull request unless it says otherwise
ENGINE=$PWD T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
# fixture <dir>: the base commit on main, then a feature branch. commit_base re-points main at the current commit.
fixture() {
  local d=$1; mkdir -p "$d"; git -C "$d" init -q -b main
  node "$ENGINE/bin/repo-standards.mjs" apply --target "$d" --overlay "$ENGINE/examples/overlay.json" --version 0.1.0 >/dev/null
  put "$d" package.json '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}'
  put "$d" playwright.config.js 'export default { projects: [{ name: "chromium" }, { name: "firefox" }] };'
  put "$d" src/lib/a.ts 'export const a = 1;'
  put "$d" tests/e2e/helpers/nav.ts 'export const open = 1;'
  put "$d" tests/e2e/a.spec.ts 'import { test } from "@playwright/test";
import { open } from "./helpers/nav";
test("a", async () => { void open; });'
  put "$d" tests/e2e/b.spec.ts 'import { test } from "@playwright/test";
test("b", async () => {});'
  printf 'node_modules/\n' > "$d/.gitignore"
  git -C "$d" add -A && gc -C "$d" commit -qm base && git -C "$d" checkout -q -b feature
}
S() { local d=$1; shift; (cd "$d" && env "$@" node scripts/agent/select.mjs 2>&1); }
L() { local d=$1; shift; (cd "$d" && env "$@" node scripts/agent/select.mjs --list 2>&1 | tr '\n' ' '); }
chg() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
reset() { git -C "$1" reset -q --hard main; }

R=$T/r; fixture "$R"
SPEC='import { test } from "@playwright/test";
test("b", async () => { void 1; });'
# affected-e2e-narrows-only-on-specs: only added or modified e2e specs narrow the run (a pull request into main included); anything else runs the whole e2e suite
put "$R" tests/e2e/b.spec.ts "$SPEC"; put "$R" tests/e2e/new.spec.ts "$SPEC"; chg "$R"; s1=$(L "$R"); o1=$(S "$R")
reset "$R"; put "$R" tests/e2e/b.spec.ts "$SPEC"; put "$R" tests/e2e/helpers/nav.ts 'export const open = 2;'; chg "$R"; s2=$(L "$R")
reset "$R"; put "$R" tests/e2e/b.spec.ts "$SPEC"; put "$R" README.md docs; chg "$R"; s3=$(L "$R")
reset "$R"; git -C "$R" rm -q tests/e2e/b.spec.ts; gc -C "$R" commit -qm del; s4=$(L "$R")
reset "$R"; git -C "$R" mv tests/e2e/b.spec.ts tests/e2e/c.spec.ts; gc -C "$R" commit -qm mv; s5=$(L "$R")
reset "$R"; put "$R" tests/e2e/global-setup.ts 'export default () => {};'; chg "$R"; s6=$(L "$R")
reset "$R"; put "$R" tests/e2e/fixtures/data.json '{}'; chg "$R"; s7=$(L "$R")
reset "$R"; put "$R" playwright.config.js 'export default { projects: [{ name: "chromium" }] };'; chg "$R"; s8=$(L "$R")
reset "$R"; put "$R" src/lib/a.ts 'export const a = 2;'; chg "$R"; s9=$(L "$R")
reset "$R"; put "$R" unit/a.test.mjs 'import test from "node:test";'; chg "$R"; s10=$(L "$R")
EV=$T/ev.json; printf '{"pull_request":{"base":{"ref":"main","sha":"%s"}}}' "$(git -C "$R" rev-parse main)" > "$EV"
reset "$R"; put "$R" tests/e2e/b.spec.ts "$SPEC"; chg "$R"; s11=$(L "$R" GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$EV")
put "$R" tests/e2e/b.spec.ts "$SPEC"; chg "$R"
m1=$(L "$R" GITHUB_EVENT_NAME=); m2=$(cd "$R" && env -u GITHUB_EVENT_NAME node scripts/agent/select.mjs --list 2>&1 | tr '\n' ' '); m3=$(L "$R" GITHUB_EVENT_NAME=pull_request_target)
if [ "$m1" = "ALL " ] && [ "$m2" = "ALL " ] && [ "$m3" = "ALL " ]; then mm=1; else mm=0; fi
reset "$R"; put "$R" tests/e2e/b.spec.ts "$SPEC"; put "$R" tests/e2e/new.spec.ts "$SPEC"; chg "$R"
if [ $mm = 1 ] && [ "$s1" = "tests/e2e/b.spec.ts tests/e2e/new.spec.ts " ] && has "2 e2e spec(s)" "$o1" && ! has "the base is main" "$o1" && [ "$s11" = "tests/e2e/b.spec.ts " ]; then n=1; else n=0; fi
all=1; for v in "$s2" "$s3" "$s4" "$s5" "$s6" "$s7" "$s8" "$s9" "$s10"; do [ "$v" = "ALL " ] || all=0; done
if [ $n = 1 ] && [ $all = 1 ]; then ok affected-e2e-narrows-only-on-specs
else fail affected-e2e-narrows-only-on-specs "specs=$s1 pr=$s11 | helper=$s2 docs=$s3 del=$s4 rename=$s5 setup=$s6 fixture=$s7 config=$s8 src=$s9 unit=$s10"; fi

# affected-opt-out
reset "$R"; put "$R" tests/e2e/b.spec.ts "$SPEC"; chg "$R"
jset "$R/standards.json" 'o.affected=false'; p2=$(S "$R"); pc=$(cd "$R" && node scripts/agent/check.mjs 2>&1)
jset "$R/standards.json" 'o.affected="sometimes"'; pc2=$(cd "$R" && node scripts/agent/check.mjs 2>&1)
jset "$R/standards.json" 'delete o.affected'; p3=$(S "$R" GATE_SELECT=full); p4=$(S "$R" GATE_BASE=0000000000000000000000000000000000000000)
if has "the whole e2e suite" "$p2" && has '"affected": false' "$p2" && ! has "standards.json affected" "$pc" && has "standards.json affected is" "$pc2" && has "GATE_SELECT=full" "$p3" && has "base cannot be found" "$p4"
then ok affected-opt-out; else fail affected-opt-out "off=$p2 | check=$pc | bad=$pc2 | env=$p3 | base=$p4"; fi

# affected-runners: a spec-only change reaches Playwright and node --test as file filters; every other change runs the whole suite; a custom e2e.command runs as written
# with the selection in its environment, and with GATE_SELECT=full when the whole suite runs
mkdir -p "$R/node_modules/.bin"; printf '#!/bin/sh\necho "playwright $* ge=$GATE_AFFECTED" >> "%s/rel.log"\n' "$T" > "$R/node_modules/.bin/playwright"; chmod +x "$R/node_modules/.bin/playwright"
reset "$R"; put "$R" tests/e2e/b.spec.ts "$SPEC"; chg "$R"
: > "$T/rel.log"; (cd "$R" && node scripts/agent/gate.mjs e2e >/dev/null 2>&1); pw1=$(cat "$T/rel.log")
reset "$R"; put "$R" src/lib/b.ts 'export const b = 8;'; chg "$R"
: > "$T/rel.log"; (cd "$R" && node scripts/agent/gate.mjs e2e >/dev/null 2>&1); pw2=$(cat "$T/rel.log")
R4=$T/r4; mkdir -p "$R4"; git -C "$R4" init -q -b main
node "$ENGINE/bin/repo-standards.mjs" apply --target "$R4" --overlay "$ENGINE/examples/overlay.json" --version 0.1.0 >/dev/null
put "$R4" package.json '{"name":"app","private":true}'; put "$R4" src/x.mjs 'export const x = 1;'
put "$R4" tests/e2e/x.test.mjs 'import test from "node:test";
test("x", () => console.log("RAN-X"));'
put "$R4" tests/e2e/y.test.mjs 'import test from "node:test";
test("y", () => console.log("RAN-Y"));'
chg "$R4" base; git -C "$R4" checkout -q -b feature
put "$R4" tests/e2e/x.test.mjs 'import test from "node:test";
test("x", () => console.log("RAN-X"));  // edit'; chg "$R4"
n1=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
reset "$R4"; put "$R4" src/x.mjs 'export const x = 2;'; chg "$R4"; n2=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
git -C "$R4" checkout -q main; jset "$R4/standards.json" 'o.e2e="echo CUSTOM $GATE_AFFECTED $GATE_SELECT [$GATE_AFFECTED_E2E]"'; chg "$R4" cmd; git -C "$R4" checkout -q -b feature2
put "$R4" tests/e2e/y.test.mjs 'import test from "node:test";
test("y", () => console.log("RAN-Y")); // edit'; chg "$R4"; c1=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
put "$R4" src/x.mjs 'export const x = 3;'; chg "$R4"; c2=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
git -C "$R" checkout -q main; jset "$R/package.json" 'o.scripts={"test:e2e":"playwright test --grep @smoke"}'; chg "$R" grep; git -C "$R" checkout -q -b g1
put "$R" tests/e2e/b.spec.ts "$SPEC"; chg "$R"; : > "$T/rel.log"; (cd "$R" && node scripts/agent/gate.mjs e2e >/dev/null 2>&1); g1=$(cat "$T/rel.log")
git -C "$R" checkout -q main; jset "$R/package.json" 'o.scripts={"test:e2e":"playwright test"}'; chg "$R" bare; git -C "$R" checkout -q -b g2
put "$R" tests/e2e/b.spec.ts "$SPEC"; chg "$R"; : > "$T/rel.log"; (cd "$R" && node scripts/agent/gate.mjs e2e >/dev/null 2>&1); g2=$(cat "$T/rel.log")
git -C "$R" checkout -q main; jset "$R/package.json" 'o.scripts={"test:e2e":"playwright test && echo done"}'; chg "$R" chain; git -C "$R" checkout -q -b g3
put "$R" tests/e2e/b.spec.ts "$SPEC"; chg "$R"; : > "$T/rel.log"; (cd "$R" && node scripts/agent/gate.mjs e2e >/dev/null 2>&1); g3=$(cat "$T/rel.log")
if [ "$(echo $g1)" = "playwright test --grep @smoke ge=scoped" ] && has "--project=chromium" "$g2" && has 'b\.spec\.ts$' "$g2" && [ "$(echo $g3)" = "playwright test ge=scoped" ]; then gr=1; else gr=0; fi
if [ $gr = 1 ] && has 'test --project=chromium tests/e2e/b\.spec\.ts$ ge=scoped' "$pw1" && has "playwright test tests/e2e --project=chromium ge=full" "$pw2" \
  && has "RAN-X" "$n1" && ! has "RAN-Y" "$n1" && has "RAN-X" "$n2" && has "RAN-Y" "$n2" \
  && has "CUSTOM scoped [tests/e2e/y.test.mjs]" "$c1" && has "runs as written" "$c1" && has "CUSTOM full full []" "$c2"
then ok affected-runners; else fail affected-runners "grep=$g1 bare=$g2 chain=$g3 pw1=$pw1 | pw2=$pw2 | n1=$n1 | n2=$n2 | c1=$c1 | c2=$c2"; fi

# affected-full-runs-every-project: with a real multi-project Playwright config, GATE_SELECT=full (the release check) runs every project with no --project and no
# positional tests/e2e, so a failing spec outside tests/e2e fails the run; a pull request, the merge queue and a manual re-gate run the Chromium project only.
# The e2e step carries no time limit.
if curl -sSfI --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; then
  R10=$T/r10; fixture "$R10"; rm -rf "$R10/tests"
  put "$R10" package.json '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.55.0"}}'
  put "$R10" playwright.config.js 'export default { projects: [{ name: "chromium", testDir: "tests/e2e" }, { name: "api", testDir: "api-tests" }] };'
  put "$R10" tests/e2e/a.spec.ts 'import { test } from "@playwright/test";
test("ok", async () => {});'
  put "$R10" api-tests/fail.spec.ts 'import { test, expect } from "@playwright/test";
test("api project", async () => { expect(1).toBe(2); });'
  (cd "$R10" && npm install --no-audit --no-fund --silent >/dev/null 2>&1); git -C "$R10" checkout -q main; chg "$R10" pw; git -C "$R10" checkout -q -b f2
  put "$R10" src/lib/a.ts 'export const a = 3;'; chg "$R10"
  po=$(cd "$R10" && node scripts/agent/gate.mjs e2e 2>&1); px=$?
  bad=""
  fo=$(cd "$R10" && GATE_SELECT=full node scripts/agent/gate.mjs e2e 2>&1); fx=$?
  { [ $fx -ne 0 ] && has "api project" "$fo"; } || bad="$bad GATE_SELECT=full(exit=$fx)"
  # every other gate run (the merge queue, a manual re-gate, a push) is Chromium only and never narrows
  for ev in merge_group workflow_dispatch; do
    fo=$(cd "$R10" && env GITHUB_EVENT_NAME=$ev node scripts/agent/gate.mjs e2e 2>&1); fx=$?
    { [ $fx -eq 0 ] && ! has "api project" "$fo"; } || bad="$bad $ev(exit=$fx)"
  done
  if [ $px -eq 0 ] && [ -z "$bad" ] && ! grep -Eq "AbortSignal|timeout:|killSignal|PW_GLOBAL_TIMEOUT" <(sed -n '/cmd === "e2e"/,/cmd === "secrets"/p' "$ENGINE/template/scripts/agent/gate.mjs")
  then ok affected-full-runs-every-project; else fail affected-full-runs-every-project "pr exit=$px: $po | wrong project selection:$bad"; fi
else echo "skip affected-full-runs-every-project (no network to install Playwright)"; fi

done_cases
