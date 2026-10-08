#!/usr/bin/env bash
# Affected-test selection through the real entry points (select.mjs and gate.mjs e2e). No network.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GITHUB_ACTIONS GATE_SELECT GATE_BASE GITHUB_STEP_SUMMARY
ENGINE=$PWD T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }
# fixture <dir>: a Playwright repo on main (the base), then a feature branch to change.
fixture() {
  local d=$1; mkdir -p "$d"; git -C "$d" init -q -b main
  node "$ENGINE/bin/repo-standards.mjs" apply --target "$d" --overlay "$ENGINE/examples/overlay.json" --version 0.1.0 >/dev/null
  put "$d" package.json '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.63.0"}}'
  put "$d" playwright.config.js 'export default { projects: [{ name: "chromium" }, { name: "firefox" }] };'
  put "$d" src/lib/a.ts 'export const a = 1;'
  put "$d" src/lib/b.ts 'export const b = 2;'
  put "$d" src/lib/c.ts 'export const c = 3;'
  put "$d" src/lib/shared.ts 'export const shared = 0;'
  put "$d" src/lib/orphan.ts 'export const orphan = 0;'
  put "$d" src/pages/about.astro '---
import { b } from "../lib/b";
---
<p>about</p>'
  put "$d" tests/e2e/a.spec.ts 'import { test } from "@playwright/test";
import { a } from "../../src/lib/a";
import { shared } from "../../src/lib/shared";
test("a", async () => { void a; void shared; });'
  put "$d" tests/e2e/about.spec.ts 'import { test } from "@playwright/test";
test("about", async ({ page }) => { await page.goto("/about"); });
import "../../src/lib/shared";'
  put "$d" tests/e2e/smoke.spec.ts '// @smoke
import { test } from "@playwright/test";
import "../../src/lib/shared";
test("smoke", async () => {});'
  put "$d" tests/e2e/c.test.mjs 'import test from "node:test";
import { c } from "../../src/lib/c.ts";
test("c", () => { void c; });'
  put "$d" docs/notes.md 'notes'
  printf 'node_modules/\n' > "$d/.gitignore"
  git -C "$d" add -A && gc -C "$d" commit -qm base && git -C "$d" checkout -q -b feature
}
S() { local d=$1; shift; (cd "$d" && env "$@" node scripts/agent/select.mjs 2>&1); }
L() { local d=$1; shift; (cd "$d" && env "$@" node scripts/agent/select.mjs --list all 2>&1 | tr '\n' ' '); }

R=$T/r; fixture "$R"
# affected-selects-reaching-tests: one module -> only its tests (+ smoke); the base branch is main and that changes nothing
put "$R" src/lib/b.ts 'export const b = 22;'; gc -C "$R" add -A && gc -C "$R" commit -qm b
EV=$T/event.json; printf '{"pull_request":{"base":{"ref":"main","sha":"%s"}}}' "$(git -C "$R" rev-parse main)" > "$EV"
o1=$(S "$R" GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$EV"); l1=$(L "$R" GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$EV")
put "$R" src/lib/c.ts 'export const c = 33;'; gc -C "$R" add -A && gc -C "$R" commit -qm c
l2=$(L "$R")
put "$R" docs/notes.md 'more notes'; put "$R" src/lib/orphan.ts 'export const orphan = 1;'; gc -C "$R" add -A && gc -C "$R" commit -qm docs
l3=$(L "$R")
if has "2 of 4 test files" "$o1" && has "tests/e2e/about.spec.ts [playwright]: src/lib/b.ts changed: tests/e2e/about.spec.ts -> src/pages/about.astro -> src/lib/b.ts" "$o1" && has "tests/e2e/smoke.spec.ts [playwright]: the smoke set" "$o1" \
  && ! has "FULL" "$o1" && ! has "the base is main" "$o1" && [ "$l1" = "tests/e2e/about.spec.ts tests/e2e/smoke.spec.ts " ] \
  && [ "$l2" = "tests/e2e/about.spec.ts tests/e2e/c.test.mjs tests/e2e/smoke.spec.ts " ]
then ok affected-selects-reaching-tests; else fail affected-selects-reaching-tests "o1=$o1 | l1=$l1 | l2=$l2"; fi

# affected-unplaced-runs-full
R2=$T/r2; fixture "$R2"
put "$R2" src/lib/orphan.ts 'export const orphan = 1;'; gc -C "$R2" add -A && gc -C "$R2" commit -qm orphan; u1=$(S "$R2")
git -C "$R2" reset -q --hard main; git -C "$R2" rm -q src/lib/a.ts && gc -C "$R2" commit -qm del; u2=$(S "$R2")
git -C "$R2" reset -q --hard main; put "$R2" package.json '{"name":"app","private":true,"devDependencies":{"@playwright/test":"1.64.0"}}'; gc -C "$R2" add -A && gc -C "$R2" commit -qm dep; u3=$(S "$R2")
git -C "$R2" reset -q --hard main; put "$R2" src/lib/a.ts 'import "@/nope"; export const a = 1;'; gc -C "$R2" add -A && gc -C "$R2" commit -qm alias; u4=$(S "$R2")
git -C "$R2" reset -q --hard main; put "$R2" src/lib/a.ts 'export const a = 5;'; gc -C "$R2" add -A && gc -C "$R2" commit -qm a; u5=$(S "$R2" GATE_BASE=0000000000000000000000000000000000000000)
if has "FULL suite" "$u1" && has "no test reaches src/lib/orphan.ts" "$u1" && has "src/lib/a.ts was deleted" "$u2" && has "package.json is a shared foundation" "$u3" \
  && has "import(s) the graph cannot resolve" "$u4" && has "FULL suite" "$u5" && has "base cannot be found" "$u5"
then ok affected-unplaced-runs-full; else fail affected-unplaced-runs-full "orphan=$u1 | del=$u2 | dep=$u3 | alias=$u4 | base=$u5"; fi

# affected-opt-out
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
git -C "$R2" reset -q --hard main; put "$R2" src/lib/b.ts 'export const b = 9;'; gc -C "$R2" add -A && gc -C "$R2" commit -qm b
p1=$(S "$R2")
jset "$R2/standards.json" 'o.affected=false'; p2=$(S "$R2"); pc=$(cd "$R2" && node scripts/agent/check.mjs 2>&1)
jset "$R2/standards.json" 'o.affected="sometimes"'; pc2=$(cd "$R2" && node scripts/agent/check.mjs 2>&1)
jset "$R2/standards.json" 'delete o.affected'; p3=$(S "$R2" GATE_SELECT=full)
if has "2 of 4 test files" "$p1" && has "FULL suite" "$p2" && has '"affected": false' "$p2" && ! has "standards.json affected" "$pc" && has "standards.json affected is" "$pc2" && has "GATE_SELECT=full" "$p3"
then ok affected-opt-out; else fail affected-opt-out "default=$p1 | off=$p2 | check=$pc | bad=$pc2 | env=$p3"; fi

# affected-runners: the e2e step hands the selection to Playwright and to node --test
R3=$T/r3; fixture "$R3"; mkdir -p "$R3/node_modules/.bin"
printf '#!/bin/sh\necho "playwright $* ge=$GATE_AFFECTED" >> "%s/pw.log"\n' "$T" > "$R3/node_modules/.bin/playwright"; chmod +x "$R3/node_modules/.bin/playwright"
echo node_modules/ > "$R3/.gitignore"
put "$R3" src/lib/b.ts 'export const b = 2.5;'; gc -C "$R3" add -A && gc -C "$R3" commit -qm b
: > "$T/pw.log"; e1=$(cd "$R3" && node scripts/agent/gate.mjs e2e 2>&1); pw1=$(cat "$T/pw.log")
git -C "$R3" reset -q --hard main; put "$R3" docs/notes.md 'x'; put "$R3" src/lib/shared.ts 'export const shared = 1;'; gc -C "$R3" add -A && gc -C "$R3" commit -qm shared
: > "$T/pw.log"; (cd "$R3" && node scripts/agent/gate.mjs e2e >/dev/null 2>&1); pw2=$(cat "$T/pw.log")
git -C "$R3" reset -q --hard main; put "$R3" src/lib/orphan.ts 'export const orphan = 2;'; gc -C "$R3" add -A && gc -C "$R3" commit -qm orphan
: > "$T/pw.log"; (cd "$R3" && node scripts/agent/gate.mjs e2e >/dev/null 2>&1); pw3=$(cat "$T/pw.log")
# node tests only: a repo with no Playwright suite
R4=$T/r4; mkdir -p "$R4"; git -C "$R4" init -q -b main
node "$ENGINE/bin/repo-standards.mjs" apply --target "$R4" --overlay "$ENGINE/examples/overlay.json" --version 0.1.0 >/dev/null
put "$R4" package.json '{"name":"app","private":true}'
put "$R4" src/x.mjs 'export const x = 1;'; put "$R4" src/y.mjs 'export const y = 1;'
put "$R4" tests/e2e/x.test.mjs 'import test from "node:test";
import "../../src/x.mjs";
test("x", () => console.log("RAN-X"));'
put "$R4" tests/e2e/y.test.mjs 'import test from "node:test";
import "../../src/y.mjs";
test("y", () => console.log("RAN-Y"));'
gc -C "$R4" add -A && gc -C "$R4" commit -qm base && git -C "$R4" checkout -q -b feature
put "$R4" src/x.mjs 'export const x = 2;'; gc -C "$R4" add -A && gc -C "$R4" commit -qm x
n1=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
put "$R4" docs.md 'only docs'; git -C "$R4" reset -q --hard main; put "$R4" docs.md 'only docs'; gc -C "$R4" add -A && gc -C "$R4" commit -qm docs
n2=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
git -C "$R4" reset -q --hard main; put "$R4" src/y.mjs 'export const y = 2;'; gc -C "$R4" add -A && gc -C "$R4" commit -qm y
git -C "$R4" checkout -q main; jset "$R4/standards.json" 'o.e2e="echo CUSTOM $GATE_AFFECTED [$GATE_AFFECTED_NODE]"'; gc -C "$R4" commit -qam cmd; git -C "$R4" checkout -q feature; git -C "$R4" rebase -q main
n3=$(cd "$R4" && node scripts/agent/gate.mjs e2e 2>&1)
if has "test --project=chromium tests/e2e/about\\.spec\\.ts\$ tests/e2e/smoke\\.spec\\.ts\$ ge=scoped" "$pw1" && ! has "firefox" "$pw1" && has "tests/e2e/a\\.spec\\.ts\$ tests/e2e/about" "$pw2" && has "ge=scoped" "$pw2" && has "playwright test tests/e2e --project=chromium ge=full" "$pw3" \
  && has "RAN-X" "$n1" && ! has "RAN-Y" "$n1" && has "no affected node test" "$n2" && has "CUSTOM scoped [tests/e2e/y.test.mjs]" "$n3" \
  && [ "$(cd "$R4" && node scripts/agent/select.mjs --list node)" = "tests/e2e/y.test.mjs" ] && [ "$(cd "$R" && GATE_SELECT=full node scripts/agent/select.mjs --list node)" = "ALL" ]
then ok affected-runners; else fail affected-runners "pw1=$pw1 | pw2=$pw2 | pw3=$pw3 | n1=$n1 | n2=$n2 | n3=$n3 | e1=$e1"; fi

done_cases
