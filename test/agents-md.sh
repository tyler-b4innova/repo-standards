#!/usr/bin/env bash
# The shared instruction block (visuals, no per-repo exceptions, Cloudflare deploys) and the overlay setting that makes
# AGENTS.md exactly that block. Through apply and the offline check.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GH_TOKEN
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "${OVERLAY:-$OV}" --version 0.1.0 --target "$1"; }
check() { (cd "$1" && scripts/agent/setup.sh --check) 2>&1; }
why=""
R=$T/default; git init -q -b main "$R"; apply "$R" >/dev/null
a=$(cat "$R/AGENTS.md")
has "Visuals (screenshots, video) are for the people reviewing the PR, in GitHub or the portal, like Cursor's visual PRs; never a test, never compared." "$a" || why="visuals rule missing"
has "a video when it moves, before/after for a static change (\`std-evidence\`)" "$a" || why="$why; visuals rule incomplete"
! has "Visual change (UI, .docx, .pptx)" "$a" || why="$why; the old visual line remains"
has "No per-repo exceptions, and no new rules, gates or numbers to fix a symptom" "$a" && has "his decisions are his own words in the issue, commit or PR they concern." "$a" || why="$why; no-exceptions rule missing"
has "Cloudflare deploys: Workers Builds in the account that owns the Worker runs \`scripts/agent/release.mjs\`. Nothing is deployed by hand, and no Cloudflare tokens in GitHub." "$a" || why="$why; deploys rule missing"
if [ -z "$why" ]; then ok block-visuals-and-deploys; else fail block-visuals-and-deploys "$why"; fi

# default: repo content around the block survives a re-apply (unchanged behaviour)
why=""
printf '# Mine\n\nrepo rule\n\n%s\nafter\n' "$(sed -n '/<!-- std:begin/,/<!-- std:end -->/p' "$R/AGENTS.md")" >"$R/AGENTS.md"; commit "$R" repo >/dev/null; apply "$R" >/dev/null
has "repo rule" "$(cat "$R/AGENTS.md")" && has "after" "$(cat "$R/AGENTS.md")" || why="default apply dropped repo content"
# block-only: apply writes exactly the managed block, and --check refuses anything outside it
O=$T/ov.json; node -e 'const o=require(process.argv[1]);o.agents_md="block-only";require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$O"
OVERLAY=$O apply "$R" >/dev/null; commit "$R" block-only
first=$(head -1 "$R/AGENTS.md"); last=$(tail -1 "$R/AGENTS.md")
[ "$first" = "<!-- std:begin example -->" ] && [ "$last" = "<!-- std:end -->" ] && ! has "repo rule" "$(cat "$R/AGENTS.md")" || why="$why; block-only AGENTS.md is not exactly the block"
out=$(check "$R") || why="$why; block-only AGENTS.md failed --check: $out"
printf '\n## Repo rules\n\n- mine\n' >>"$R/AGENTS.md"; commit "$R" extra; out=$(check "$R") && why="$why; content after the block passed" || has "content outside the managed block" "$out" || why="$why; [$out]"
printf '# Title\n\n' | cat - <(git -C "$R" show HEAD~1:AGENTS.md) >"$R/AGENTS.md"; commit "$R" before; out=$(check "$R") && why="$why; content before the block passed" || has "content outside the managed block" "$out" || why="$why; before: [$out]"
# without the setting the same content is fine
R2=$T/plain; git init -q -b main "$R2"; apply "$R2" >/dev/null; printf '\n## Repo rules\n\n- mine\n' >>"$R2/AGENTS.md"; commit "$R2" extra; out=$(check "$R2") || why="$why; default --check refused repo content: $out"
# a bad value is refused
node -e 'const o=require(process.argv[1]);o.agents_md="whatever";require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$O"; out=$(OVERLAY=$O apply "$T/x" 2>&1) && why="$why; bad agents_md accepted"; has 'agents_md must be "block-only"' "$out" || why="$why; [$out]"
if [ -z "$why" ]; then ok agents-md-block-only; else fail agents-md-block-only "$why"; fi
done_cases
