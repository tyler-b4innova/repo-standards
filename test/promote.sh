#!/usr/bin/env bash
# One-branch releases: a pull request from the default branch into another branch is an ordinary pull request to the
# review rule (the package export a launcher calls), against a GitHub stand-in. There are no promotions.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD T=$(mktemp -d)
trap '{ kill $STUB; wait $STUB; } 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo; git init -q -b staging "$R" && node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.1.0 >/dev/null
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f));o.flow="staged";require("fs").writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$R/standards.json"
git -C "$R" add -A && git -C "$R" commit -qm init
HEAD2=$(printf 'b%.0s' $(seq 40))
state() { # state <files-json> <reviews-json>
  printf '{"pr":{"number":7,"head":{"ref":"staging","sha":"%s","repo":{"full_name":"acme/demo"}},"base":{"ref":"main"},"user":{"login":"launcher[bot]","type":"Bot"}},"files":%s,"reviews":%s,"perms":{"alice":"write"}}' "$HEAD2" "$1" "$2" > "$T/state.json"
}
state '[]' '[]'
node test/stubs/promote-github.mjs "$T/port" "$T/state.json" "$R" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
gate() { GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_REPOSITORY=acme/demo node test/review-run.mjs 7 2>&1; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# a default-branch-into-main PR with a UI change needs the evidence comment like any PR; a person's approval is no
# substitute (code-owner approval is the rulesets' business), and nothing mentions a promotion
why=""
UI='["src/components/Hero.svelte","worker/src/index.ts"]'
state "$UI" '[{"user":{"login":"alice","type":"User"},"state":"APPROVED","commit_id":"'"$HEAD2"'"}]'; a=$(gate); sa=$?
[ $sa -eq 1 ] && has "evidence" "$a" && ! has "promotion" "$a" && ! has "approved by" "$a" || why="ui: $sa $a"
state '["worker/src/index.ts","README.md"]' '[]'; b=$(gate); sb=$?
[ $sb -eq 0 ] && ! has "promotion" "$b" || why="$why; no ui: $sb $b"
if [ -z "$why" ]; then ok review-no-promotions; else fail review-no-promotions "$why"; fi
done_cases
