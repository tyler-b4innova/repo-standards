#!/usr/bin/env bash
# Affected-test selection through the real entry points (select.mjs and gate.mjs e2e). No network except the real-Playwright case.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GITHUB_ACTIONS GATE_SELECT GATE_BASE GITHUB_STEP_SUMMARY
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
  put "$d" package.json '{"name":"app","private":true,"dependencies":{"@app/util":"workspace:*"},"devDependencies":{"@playwright/test":"1.63.0"}}'
  put "$d" playwright.config.js 'export default { projects: [{ name: "chromium" }, { name: "firefox" }] };'
  put "$d" src/lib/a.ts 'export const a = 1;'; put "$d" src/lib/b.ts 'export const b = 2;'; put "$d" src/lib/c.ts 'export const c = 3;'
  put "$d" tests/e2e/helpers/nav.ts 'export const open = 1;'
  put "$d" tests/e2e/a.spec.ts 'import { test } from "@playwright/test";
import { open } from "./helpers/nav";
test("a", async () => { void open; });'
  put "$d" tests/e2e/b.spec.ts 'import { test } from "@playwright/test";
test("b", async () => {});'
  put "$d" tests/unit/a.test.mjs 'import test from "node:test";
import "../../src/lib/a.ts";
test("a", () => {});'
  put "$d" tests/unit/c.test.mjs 'import test from "node:test";
import "../../src/lib/c.ts";
test("c", () => {});'
  put "$d" tests/unit/tpl.test.mjs 'import test from "node:test";
import "../../src/lib/c.ts";
test("tpl", async () => { const n = "x"; await import(`./${n}.mjs`); });'
  put "$d" tests/unit/ws.test.mjs 'import test from "node:test";
import "@app/util";
test("ws", () => {});'
  put "$d" tests/unit/spaced.test.mjs 'import test from "node:test";
test("spaced", async () => { const n = "./x.mjs"; await import ( n ); });'
  put "$d" tests/unit/fsread.test.mjs 'import test from "node:test";
import { readFileSync } from "node:fs";
test("fs", () => { readFileSync("data.csv"); });'
  put "$d" tests/unit/alias.test.mjs 'import test from "node:test";
import "@/lib/b";
test("alias", () => {});'
  printf 'node_modules/\n' > "$d/.gitignore"
  git -C "$d" add -A && gc -C "$d" commit -qm base && git -C "$d" checkout -q -b feature
}
S() { local d=$1; shift; (cd "$d" && env "$@" node scripts/agent/select.mjs 2>&1); }
L() { local k=$1 d=$2; shift 2; (cd "$d" && env "$@" node scripts/agent/select.mjs --list "$k" 2>&1 | tr '\n' ' '); }
chg() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
reset() { git -C "$1" reset -q --hard main; }

R=$T/r; fixture "$R"
# affected-e2e-app-scope: any change outside the tests runs the app's whole e2e suite (docs, data and the base branch included); only test-file changes narrow it
put "$R" src/lib/b.ts 'export const b = 22;'; chg "$R"; e1=$(L e2e "$R"); o1=$(S "$R")
reset "$R"; put "$R" README.md 'docs'; chg "$R"; e2=$(L e2e "$R")
reset "$R"; put "$R" data/rows.csv 'a,b'; chg "$R"; e3=$(L e2e "$R")
reset "$R"; put "$R" tests/e2e/b.spec.ts 'import { test } from "@playwright/test";
test("b", async () => { void 1; });'; chg "$R"; e4=$(L e2e "$R")
reset "$R"; put "$R" tests/e2e/helpers/nav.ts 'export const open = 2;'; chg "$R"; e5=$(L e2e "$R")
reset "$R"; put "$R" tests/e2e/helpers/orphan.ts 'export const x = 1;'; chg "$R"; e6=$(S "$R")
EV=$T/ev.json; printf '{"pull_request":{"base":{"ref":"main","sha":"%s"}}}' "$(git -C "$R" rev-parse main)" > "$EV"
reset "$R"; put "$R" src/lib/b.ts 'export const b = 5;'; chg "$R"; e7=$(L e2e "$R" GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$EV")
if [ "$e1" = "ALL " ] && has "the whole e2e suite" "$o1" && [ "$e2" = "ALL " ] && [ "$e3" = "ALL " ] && [ "$e4" = "tests/e2e/b.spec.ts " ] && [ "$e5" = "tests/e2e/a.spec.ts " ] \
  && has "FULL suite" "$e6" && has "no test imports the test helper" "$e6" && [ "$e7" = "ALL " ] && ! has "the base is main" "$o1"
then ok affected-e2e-app-scope; else fail affected-e2e-app-scope "app=$e1 docs=$e2 data=$e3 spec=$e4 helper=$e5 orphan=$e6 pr=$e7"; fi

# affected-unit-tracing: unit tests follow the import graph; a test depending on any load the tracer cannot resolve always runs
reset "$R"; put "$R" src/lib/a.ts 'export const a = 9;'; chg "$R"; u1=$(L unit "$R")
reset "$R"; put "$R" src/lib/c.ts 'export const c = 9;'; chg "$R"; u2=$(L unit "$R")
want_open="tests/unit/alias.test.mjs tests/unit/fsread.test.mjs tests/unit/spaced.test.mjs tests/unit/tpl.test.mjs tests/unit/ws.test.mjs"
if [ "$u1" = "tests/unit/a.test.mjs $want_open " ] && [ "$u2" = "tests/unit/alias.test.mjs tests/unit/c.test.mjs tests/unit/fsread.test.mjs tests/unit/spaced.test.mjs tests/unit/tpl.test.mjs tests/unit/ws.test.mjs " ]
then ok affected-unit-tracing; else fail affected-unit-tracing "a=$u1 | c=$u2"; fi

# affected-unplaced-runs-full
reset "$R"; git -C "$R" rm -q src/lib/a.ts; gc -C "$R" commit -qm del; f1=$(S "$R")
reset "$R"; jset "$R/package.json" 'o.devDependencies["@playwright/test"]="1.64.0"'; chg "$R"; f2=$(S "$R")
reset "$R"; put "$R" vitest.config.js 'export default {};'; chg "$R"; f3=$(S "$R")
reset "$R"; put "$R" src/lib/a.ts 'export const a = 5;'; chg "$R"; f4=$(S "$R" GATE_BASE=0000000000000000000000000000000000000000)
if has "was deleted" "$f1" && has "FULL suite" "$f1" && has "package.json is configuration or a dependency" "$f2" && has "vitest.config.js is configuration" "$f3" && has "FULL suite" "$f4" && has "base cannot be found" "$f4"
then ok affected-unplaced-runs-full; else fail affected-unplaced-runs-full "del=$f1 | dep=$f2 | cfg=$f3 | base=$f4"; fi

# affected-opt-out
reset "$R"; put "$R" tests/e2e/b.spec.ts 'import { test } from "@playwright/test";
test("b", async () => { void 2; });'; chg "$R"; p1=$(L e2e "$R")
jset "$R/standards.json" 'o.affected=false'; p2=$(S "$R"); pc=$(cd "$R" && node scripts/agent/check.mjs 2>&1)
jset "$R/standards.json" 'o.affected="sometimes"'; pc2=$(cd "$R" && node scripts/agent/check.mjs 2>&1)
jset "$R/standards.json" 'delete o.affected'; p3=$(S "$R" GATE_SELECT=full)
if [ "$p1" = "tests/e2e/b.spec.ts " ] && has "FULL suite" "$p2" && has '"affected": false' "$p2" && ! has "standards.json affected" "$pc" && has "standards.json affected is" "$pc2" && has "GATE_SELECT=full" "$p3"
then ok affected-opt-out; else fail affected-opt-out "default=$p1 | off=$p2 | check=$pc | bad=$pc2 | env=$p3"; fi

# affected-non-pr-runs-full: only a pull_request event is selected; a push to main (the release check, also after a squash), a manual run and the merge queue run everything
reset "$R"; put "$R" tests/e2e/b.spec.ts 'import { test } from "@playwright/test";
test("b", async () => { void 3; });'; chg "$R"
printf '{"pull_request":{"base":{"ref":"main","sha":"%s"}},"before":"%s","merge_group":{"base_sha":"%s"}}' "$(git -C "$R" rev-parse main)" "$(git -C "$R" rev-parse main)" "$(git -C "$R" rev-parse main)" > "$T/ev9.json"
n_pr=$(L e2e "$R" GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$T/ev9.json"); n_ok=1
for ev in push workflow_dispatch merge_group schedule; do o=$(S "$R" GITHUB_EVENT_NAME=$ev GITHUB_EVENT_PATH="$T/ev9.json"); has "FULL suite" "$o" && has "is not a pull request" "$o" || { n_ok=0; echo "$ev: $o" >&2; }; done
mkdir -p "$R/node_modules/.bin"; printf '#!/bin/sh\necho "playwright $* ge=$GATE_AFFECTED" >> "%s/rel.log"\n' "$T" > "$R/node_modules/.bin/playwright"; chmod +x "$R/node_modules/.bin/playwright"; : > "$T/rel.log"
(cd "$R" && GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$T/ev9.json" node scripts/agent/gate.mjs e2e >/dev/null 2>&1); rel=$(cat "$T/rel.log")
if [ "$n_pr" = "tests/e2e/b.spec.ts " ] && [ "$n_ok" = 1 ] && has "ge=full" "$rel" && ! has 'spec\.ts$' "$rel"; then ok affected-non-pr-runs-full
else fail affected-non-pr-runs-full "pr: $n_pr | non-pr ok=$n_ok | release e2e: $rel"; fi

# affected-runners: the e2e step hands a test-only change to Playwright and node --test as file filters, runs the whole suite for an app change, and
# runs a custom e2e.command as written with the selection in its environment (GATE_SELECT=full reaches it too)
reset "$R"; put "$R" tests/e2e/b.spec.ts 'import { test } from "@playwright/test";
test("b", async () => { void 4; });'; chg "$R"
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
git -C "$R4" checkout -q main; jset "$R4/standards.json" 'o.e2e="echo CUSTOM $GATE_AFFECTED [$GATE_AFFECTED_E2E]"'; chg "$R4" cmd; git -C "$R4" checkout -q -b feature2
put "$R4" tests/e2e/y.test.mjs 'import test from "node:test";
test("y", () => console.log("RAN-Y")); // edit'; chg "$R4"; c1=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
c2=$(cd "$R4" && GATE_SELECT=full node scripts/agent/gate.mjs e2e 2>&1)
if has 'test --project=chromium tests/e2e/b\.spec\.ts$' "$pw1" && has "ge=scoped" "$pw1" && has "playwright test tests/e2e --project=chromium ge=full" "$pw2" \
  && has "RAN-X" "$n1" && ! has "RAN-Y" "$n1" && has "RAN-X" "$n2" && has "RAN-Y" "$n2" \
  && has "CUSTOM scoped [tests/e2e/y.test.mjs]" "$c1" && has "runs as written" "$c1" && has "CUSTOM full []" "$c2"
then ok affected-runners; else fail affected-runners "pw1=$pw1 | pw2=$pw2 | n1=$n1 | n2=$n2 | c1=$c1 | c2=$c2"; fi

# affected-full-runs-every-project: with a real multi-project Playwright config, GATE_SELECT=full runs every project and the config's whole
# directory (no --project, no positional tests/e2e), so a failing spec outside tests/e2e fails the run; a pull request still runs the Chromium project
# only. The e2e step carries no time limit.
if curl -sSfI --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; then
  R10=$T/r10; fixture "$R10"; rm -rf "$R10/tests/unit"
  put "$R10" package.json '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.55.0"}}'
  put "$R10" playwright.config.js 'export default { projects: [{ name: "chromium", testDir: "tests/e2e" }, { name: "api", testDir: "api-tests" }] };'
  put "$R10" tests/e2e/a.spec.ts 'import { test } from "@playwright/test";
test("ok", async () => {});'
  put "$R10" tests/e2e/b.spec.ts 'import { test } from "@playwright/test";
test("ok b", async () => {});'
  put "$R10" api-tests/fail.spec.ts 'import { test, expect } from "@playwright/test";
test("api project", async () => { expect(1).toBe(2); });'
  (cd "$R10" && npm install --no-audit --no-fund --silent >/dev/null 2>&1) ; git -C "$R10" checkout -q main; chg "$R10" pw; git -C "$R10" checkout -q -b f2
  put "$R10" src/lib/a.ts 'export const a = 3;'; chg "$R10"
  po=$(cd "$R10" && node scripts/agent/gate.mjs e2e 2>&1); px=$?
  fo=$(cd "$R10" && GATE_SELECT=full node scripts/agent/gate.mjs e2e 2>&1); fx=$?
  if [ $px -eq 0 ] && [ $fx -ne 0 ] && has "api project" "$fo" && ! grep -Eq "AbortSignal|timeout:|killSignal|PW_GLOBAL_TIMEOUT" <(sed -n '/cmd === "e2e"/,/cmd === "secrets"/p' "$ENGINE/template/scripts/agent/gate.mjs")
  then ok affected-full-runs-every-project; else fail affected-full-runs-every-project "pr exit=$px: $po | full exit=$fx: $fo"; fi
else echo "skip affected-full-runs-every-project (no network to install Playwright)"; fi

done_cases
