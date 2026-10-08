#!/usr/bin/env bash
# The release check on every Worker: the full suite runs once on the merge commit, against staging, and posts the
# check-run `release-check`. Through apply, the offline check and the workflow file.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GH_TOKEN
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "$OV" --version 0.1.0 --target "$1"; }
check() { (cd "$1" && scripts/agent/setup.sh --check) 2>&1; }
WF=.github/workflows/std-release-check.yml
STAGING=https://staging.preview.example.com/
# worker <name> [staging_url]: a Worker repository with the pack applied
worker() { local d=$T/$1; git init -q -b main "$d"; printf '{\n  "name": "site",\n  "main": "src/index.ts",\n}\n' >"$d/wrangler.jsonc"; apply "$d" >/dev/null
  [ -z "${2:-}" ] || { jset "$d/standards.json" "o.staging_url=\"$2\""; apply "$d" >/dev/null; }; echo "$d"; }

why=""
W=$(worker w "$STAGING"); N=$(worker nourl)
git init -q -b main "$T/plain"; apply "$T/plain" >/dev/null
# a Worker with a staging_url ships it (no browsers named); one without a staging_url, or with no Worker, does not
[ -f "$W/$WF" ] && grep -q "  $WF$" "$W/standards.lock" || why="not shipped to a Worker with staging_url"
[ ! -e "$N/$WF" ] || why="$why; shipped without staging_url"
[ ! -e "$T/plain/$WF" ] || why="$why; shipped without a Worker"
# "e2e": false is still the opt-out
O=$(worker off "$STAGING"); jset "$O/standards.json" 'o.e2e=false'; apply "$O" >/dev/null; [ ! -e "$O/$WF" ] || why="$why; shipped despite e2e false"
# the workflow: the job is the check-run, pushes to main and manual runs only, one run per commit, never scheduled
yml=$(cat "$W/$WF")
has "name: release-check" "$yml" && grep -qE '^  release-check:' "$W/$WF" || why="$why; job is not named release-check"
has "branches: [main]" "$yml" && has "workflow_dispatch" "$yml" && ! has pull_request "$yml" && ! grep -qE '^\s*(schedule|- cron):' "$W/$WF" || why="$why; triggers"
has 'group: std-release-check-${{ github.sha }}' "$yml" || why="$why; concurrency is not per commit"
has "gate.mjs e2e" "$yml" && has "gate.local.sh" "$yml" || why="$why; not the full suite (e2e and repo checks)"
has "GATE_FULL" "$yml" || why="$why; selection is not switched off"
if [ -z "$why" ]; then ok release-check-every-worker; else fail release-check-every-worker "$why"; fi

# check.mjs: the managed workflow passes; a repo-owned workflow that tests on push to main does not, whatever its name
why=""
commit "$W" init; out=$(check "$W") || why="managed release check rejected: $out"
for name in ci.yml release-check.yml; do
  R=$T/own-$name; cp -R "$W" "$R"
  printf 'name: own\non:\n  push:\n    branches: [main]\njobs:\n  t:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 10\n    steps:\n      - uses: actions/checkout@v4\n      - run: npm test\n' >"$R/.github/workflows/$name"
  commit "$R" own; out=$(check "$R") && why="$why; $name tests on push to main passed" || has "beside the one gate" "$out" || why="$why; $name: [$out]"
done
# a managed workflow edited by hand fails the lock
R=$T/edited; cp -R "$W" "$R"; echo "# edit" >>"$R/$WF"; commit "$R" edit; check "$R" >/dev/null && why="$why; edited managed workflow passed"
if [ -z "$why" ]; then ok release-check-managed-only; else fail release-check-managed-only "$why"; fi

# --check says why a repository has no release check
why=""
commit "$N" init; out=$(check "$N") || why="no staging_url failed: $out"
has "no release check: standards.json has no staging_url" "$out" || why="$why; no staging_url notice: [$out]"
commit "$T/plain" init; out=$(check "$T/plain") || why="$why; no Worker failed: $out"
has "no release check: no Worker" "$out" || why="$why; no Worker notice: [$out]"
out=$(check "$W"); ! has "no release check" "$out" || why="$why; notice despite a release check: $out"
if [ -z "$why" ]; then ok release-check-notice; else fail release-check-notice "$why"; fi

# every production version carries the full commit sha as its tag; --check warns where a repo file uploads without one
why=""
R=$T/tagless; cp -R "$W" "$R"; jset "$R/package.json" 'o.scripts={deploy:"wrangler versions upload"}' 2>/dev/null || echo '{"scripts":{"deploy":"wrangler versions upload"}}' >"$R/package.json"; commit "$R" tagless
out=$(check "$R"); has "wrangler versions upload without --tag" "$out" || why="no tag warning: [$out]"
echo '{"scripts":{"deploy":"wrangler versions upload --tag \"$WORKERS_CI_COMMIT_SHA\""}}' >"$R/package.json"; commit "$R" tagged
out=$(check "$R"); ! has "without --tag" "$out" || why="$why; tagged upload warned"
grep -q 'WORKERS_CI_COMMIT_SHA || env.GITHUB_SHA' template/scripts/agent/release.mjs && grep -q '"--tag", sha' template/scripts/agent/release.mjs || why="$why; release.mjs does not tag with the commit"
if [ -z "$why" ]; then ok release-version-tagged; else fail release-version-tagged "$why"; fi
done_cases
