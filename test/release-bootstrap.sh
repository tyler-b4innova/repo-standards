#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset OP_CLI OP_VAULT OP_SERVICE_ACCOUNT_TOKEN
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"
chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
export RELEASE_LOG=$T/release.log RELEASE_SECRET_LIST=$T/list.json
printf '%s\n' '{"site-staging":["API_KEY"],"site":["API_KEY"]}' > "$RELEASE_SECRET_LIST"
R=$T/repo
git init -q -b main "$R"
cp -R test/fixtures/release-astro/. "$R/"
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.3 >/dev/null
mkdir -p "$R/node_modules/.bin"
touch "$R/node_modules/.bin/wrangler"
node - "$R/wrangler.jsonc" <<'JS'
const fs = require('fs'), file = process.argv[2], cfg = JSON.parse(fs.readFileSync(file));
cfg.secrets = {required: ['API_KEY']};
cfg.env.staging.secrets = cfg.secrets;
fs.writeFileSync(file, JSON.stringify(cfg));
JS
release() { (cd "$R" && node scripts/agent/release.mjs main) > "$T/out" 2>&1; }
proof() { node --input-type=module - "$RELEASE_LOG" "$1" <<'JS'
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const calls = readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse).filter(x => x.args);
if (process.argv[3] === 'blocked') {
  assert.ok(calls.every(x => x.args[0] !== 'versions'));
} else {
  const check = calls.find(x => x.args[0] === 'secret');
  assert.equal(check.name, 'site-staging');
  assert.ok(!check.args.includes('--env'));
  assert.ok(calls.some(x => x.args[0] === 'versions' && x.name === 'site'));
  assert.ok(calls.filter(x => x.args[0] === 'versions').every(x => !x.args.includes('--secrets-file')));
  if (process.argv[3] === 'bootstrap') assert.ok(calls.find(x => x.args[0] === 'deploy').args.includes('--secrets-file'));
}
JS
}
if release && proof target; then ok release-staging-secret-target; else fail release-staging-secret-target 'Astro staging secret check failed'; fi
: > "$RELEASE_LOG"
why=""
if MISSING_STAGING=1 release; then why='missing staging unexpectedly passed';
elif ! grep -q '^::error::staging Worker site-staging requires supplied secrets: API_KEY; if it does not exist yet, bootstrap it once' "$T/out" || ! grep -q 'wrangler deploy --env staging --secrets-file <file> --dry-run --name site-staging.*then npx wrangler deploy --env staging --secrets-file <file> --name site-staging --env-file <empty-env-file>;' "$T/out" || ! proof blocked; then why='missing actionable bootstrap error'; fi
printf '#!/bin/sh\nprintf fixture-value\n' > "$T/bin/op"
chmod +x "$T/bin/op"
: > "$RELEASE_LOG"
if MISSING_STAGING=1 OP_CLI="$T/bin/op" OP_VAULT=example OP_SERVICE_ACCOUNT_TOKEN=fixture-token release && proof bootstrap; then
  ! grep -q 'fixture-value' "$T/out" || why='secret printed'
else why="$why; configured bootstrap failed"; fi
if [ -z "$why" ]; then ok release-staging-bootstrap; else fail release-staging-bootstrap "$why"; fi
done_cases
