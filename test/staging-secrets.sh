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
done_cases
