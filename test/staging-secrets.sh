#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME
R=$T/site
git init -q -b main "$R"
cp -R test/fixtures/staging-secrets/. "$R/"
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
why=""
node --input-type=module - "$R/wrangler.jsonc" <<'JS'
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { parse } from "./template/scripts/agent/staging.mjs";
const cfg = parse(readFileSync(process.argv[2], "utf8"));
assert.deepEqual(cfg.env.staging.secrets, cfg.secrets);
JS
[ $? = 0 ] || why="migration dropped required secrets"
git -C "$R" add -A && git -C "$R" commit -qm fixture
(cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1 || why="$why; valid migration: $(cat "$T/out")"
for mutation in 'delete cfg.env.staging.secrets' 'cfg.env.staging.secrets={required:["MAIL_KEY"]}'; do
  node --input-type=module - "$R/wrangler.jsonc" "$mutation" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { parse } from "./template/scripts/agent/staging.mjs";
const cfg = parse(readFileSync(process.argv[2], "utf8"));
new Function("cfg", process.argv[3])(cfg);
writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2));
JS
  git -C "$R" add -A && git -C "$R" commit -qm fixture
  if (cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1; then why="$why; missing required secret passed";
  elif ! grep -q 'env.staging lacks secrets.required' "$T/out"; then why="$why; wrong failure: $(cat "$T/out")"; fi
done
if [ -z "$why" ]; then ok staging-required-secrets-inherited; else fail staging-required-secrets-inherited "$why"; fi
# Captured by running the v0.7.1 migration on the fresh fixture, not a hand-built approximation.
R=$T/upgrade
git init -q -b main "$R"
cp test/fixtures/staging-secrets-071/wrangler.jsonc "$R/wrangler.jsonc"
cp "$R/wrangler.jsonc" "$T/before.jsonc"
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
why=""
node --input-type=module - "$T/before.jsonc" "$R/wrangler.jsonc" <<'JS'
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { parse } from "./template/scripts/agent/staging.mjs";
const old = parse(readFileSync(process.argv[2], "utf8")), text = readFileSync(process.argv[3], "utf8"), cfg = parse(text);
assert.equal(old.env.staging.secrets, undefined);
assert.deepEqual(cfg.env.staging.secrets.required, old.secrets.required);
delete cfg.env.staging.secrets;
assert.deepEqual(cfg, old);
assert.ok(text.includes("// Secrets required by both production and staging"));
JS
[ $? = 0 ] || why="0.7.1 declarations not repaired or existing config changed"
git -C "$R" add -A && git -C "$R" commit -qm fixture
(cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1 || why="$why; upgraded check: $(cat "$T/out")"
cp "$R/wrangler.jsonc" "$T/once.jsonc"
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
cmp -s "$T/once.jsonc" "$R/wrangler.jsonc" || why="$why; upgrade not idempotent"
for declaration in '{}' '{"required":["EXTRA_KEY","MAIL_KEY"]}'; do
  node --input-type=module - "$R/wrangler.jsonc" "$declaration" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { parse } from "./template/scripts/agent/staging.mjs";
const cfg = parse(readFileSync(process.argv[2], "utf8"));
cfg.env.staging.secrets = JSON.parse(process.argv[3]);
cfg.env.staging.vars = { NOTE: "preserve, }", EXTRA: "value" };
cfg.env.other = { vars: { NOTE: "untouched" } };
writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2));
JS
  cp "$R/wrangler.jsonc" "$T/partial.jsonc"
  node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
  node --input-type=module - "$T/partial.jsonc" "$R/wrangler.jsonc" <<'JS'
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { parse } from "./template/scripts/agent/staging.mjs";
const old = parse(readFileSync(process.argv[2], "utf8")), cfg = parse(readFileSync(process.argv[3], "utf8"));
const expected = [...new Set([...(old.env.staging.secrets.required ?? []), ...old.secrets.required])];
assert.deepEqual(cfg.env.staging.secrets.required, expected);
cfg.env.staging.secrets = old.env.staging.secrets;
assert.deepEqual(cfg, old);
JS
  [ $? = 0 ] || why="$why; partial declaration not preserved"
  cp "$R/wrangler.jsonc" "$T/once.jsonc"
  node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
  cmp -s "$T/once.jsonc" "$R/wrangler.jsonc" || why="$why; partial upgrade not idempotent"
done
if [ -z "$why" ]; then ok staging-required-secrets-upgrade; else fail staging-required-secrets-upgrade "$why"; fi
done_cases
