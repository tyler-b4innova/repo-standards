#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
why=""
for pm in npm pnpm; do
  R=$T/$pm
  git init -q -b main "$R"
  cp -R "test/fixtures/cache-$pm/." "$R/"
  node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
  node --input-type=module - "$R" <<'JS'
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
for (const workflow of ["std-gate", "std-cache-warm"]) {
  const yaml = readFileSync(`${process.argv[2]}/.github/workflows/${workflow}.yml`, "utf8");
  const jobs = yaml.slice(yaml.indexOf("\njobs:")).split(/^  ([\w-]+):\s*$/m);
  for (let i = 1; i < jobs.length; i += 2) {
    const name = jobs[i], body = jobs[i + 1];
    const install = /run: node scripts\/agent\/gate\.mjs install\b/.test(body);
    if (!body.includes("actions/setup-node@")) continue;
    if (install) {
      // the gate only restores (a re-gate on the default branch runs a pull request's tree); the warm-up on main saves
      assert.match(body, workflow === "std-gate" ? /uses: actions\/cache\/restore@[0-9a-f]{40} # v/ : /uses: actions\/cache@[0-9a-f]{40} # v/, `${workflow}/${name} must cache installs`);
      assert.match(body, /path: \$\{\{ steps.pm.outputs.path \}\}/);
      assert.match(body, /^          package-manager-cache: false\b/m, `${workflow}/${name} must not use setup-node's saving cache`);
      assert.doesNotMatch(body, /^\s+cache:/m, `${workflow}/${name} setup-node cache saves`);
      assert.match(body, /echo cache=pnpm/);
      assert.match(body, /echo cache=npm/);
    } else {
      assert.doesNotMatch(body, /^\s+cache:/m, `${workflow}/${name} caches without installing`);
      assert.match(body, /^          package-manager-cache: false\b/m, `${workflow}/${name} must disable implicit npm caching`);
    }
  }
  if (workflow === "std-gate") {
    assert.doesNotMatch(yaml, /uses: actions\/cache@/, "std-gate must never write a cache");
    assert.doesNotMatch(yaml, /^\s+cache:/m, "std-gate must never write a cache (setup-node cache saves)");
    const checks = jobs[jobs.indexOf("checks") + 1];
    assert.ok(!checks.includes("gate.mjs install"));
    assert.ok(!checks.includes("id: pm"));
    for (const name of ["build", "e2e", "repo"]) assert.ok(jobs[jobs.indexOf(name) + 1].includes("gate.mjs install"));
  } else assert.ok(jobs[jobs.indexOf("warm") + 1].includes("gate.mjs install"));
}
JS
  [ $? = 0 ] || why="$why $pm cache/install mismatch"
done
if [ -z "$why" ]; then ok cache-only-with-install; else fail cache-only-with-install "$why"; fi
done_cases
