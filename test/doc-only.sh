#!/usr/bin/env bash
# A pull request that changes only non-deployable paths skips gate's preview and e2e steps. Through the real gate steps.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_NAME GH_TOKEN GITHUB_TOKEN
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent GITHUB_REPOSITORY=acme/demo GITHUB_API_URL=http://127.0.0.1:9
ENGINE=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
# pr <files...>: a repository whose pull request changes these files; prints its dir. The checkout is the PR's merge
# commit (as actions/checkout gives a pull_request run), and the event names the PR and its base.
pr() {
  local d f; d=$(mktemp -d "$T/r.XXXXXX")
  git -C "$d" init -q -b main && node "$ENGINE/bin/repo-standards.mjs" apply --target "$d" --overlay "$ENGINE/examples/overlay.json" --version 0.1.0 >/dev/null
  mkdir -p "$d/src" && echo "export {};" >"$d/src/index.ts" && gc -C "$d" add -A && gc -C "$d" commit -qm base
  local base; base=$(git -C "$d" rev-parse HEAD)
  gc -C "$d" switch -qc feature
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; if [ "$f" = package.json ]; then echo '{"name":"fixture","private":true}' >"$d/$f"; else echo "change" >>"$d/$f"; fi; done
  gc -C "$d" add -A && gc -C "$d" commit -qm feature
  gc -C "$d" switch -q main && echo "elsewhere" >"$d/OTHER.txt" && gc -C "$d" add -A && gc -C "$d" commit -qm "base moved"
  gc -C "$d" merge -q --no-ff -m merge feature
  printf '{"pull_request":{"number":7,"base":{"sha":"%s"},"head":{"sha":"%s"}}}' "$base" "$(git -C "$d" rev-parse feature)" >"$d/.git/event.json"
  echo "$d"
}
G() { local d=$1; shift; (cd "$d" && GITHUB_EVENT_PATH=$d/.git/event.json node scripts/agent/gate.mjs "$@") 2>&1; }
why=""

# docs only: both steps skip, say so and name the files, and call nothing (the API here is unreachable)
R=$(pr README.md docs/guide/setup.md AGENTS.md apps/web/CLAUDE.md .github/ISSUE_TEMPLATE/bug.md .github/PULL_REQUEST_TEMPLATE.md LICENSE .impeccable/review/home-desktop.png)
e=$(G "$R" e2e); es=$?; p=$(G "$R" preview); ps=$?
[ $es -eq 0 ] && has "only non-deployable paths changed" "$e" && has "docs/guide/setup.md" "$e" || why="$why; docs e2e=$es: $e"
[ $ps -eq 0 ] && has "only non-deployable paths changed" "$p" && has "url=" "$p" || why="$why; docs preview=$ps: $p"

# a deployable path alongside docs runs both steps (no suite here, so e2e fails as it should)
R=$(pr README.md src/index.ts); e=$(G "$R" e2e); es=$?
[ $es -eq 1 ] && has "no e2e suite" "$e" && ! has "non-deployable" "$e" || why="$why; mixed e2e=$es: $e"

# Markdown that ships (content collections, public files) is deployable
for f in src/content/blog/post.md public/notes.md template/scripts/agent/rollback.mjs template/scripts/agent/check.mjs template/scripts/agent/gate.mjs lib/engine.mjs package.json; do
  R=$(pr "$f"); e=$(G "$R" e2e); es=$?; [ $es -eq 1 ] && has "no e2e suite" "$e" || why="$why; $f skipped: $e"
done

# outside a pull request nothing is skipped
R=$(pr README.md); e=$( (cd "$R" && GITHUB_EVENT_PATH= node scripts/agent/gate.mjs e2e) 2>&1); es=$?
[ $es -eq 1 ] && has "no e2e suite" "$e" || why="$why; no PR skipped: $e"

# a PR head checkout (not the merge commit) diffs against the event's base
R=$(pr docs/a.md); gc -C "$R" checkout -q feature; e=$(G "$R" e2e); es=$?
[ $es -eq 0 ] && has "only non-deployable paths changed" "$e" && ! has "OTHER.txt" "$e" || why="$why; head checkout e2e=$es: $e"

if [ -z "$why" ]; then ok gate-skips-doc-only; else fail gate-skips-doc-only "$why"; fi
done_cases
