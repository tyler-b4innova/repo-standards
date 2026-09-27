#!/usr/bin/env bash
# Promotion PRs (staged flow: default branch -> main) through the real gate step, against a GitHub stand-in.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD T=$(mktemp -d)
trap '{ kill $STUB; wait $STUB; } 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo; git init -q -b staging "$R" && node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.1.0 >/dev/null
git -C "$R" add -A && git -C "$R" commit -qm init
HEAD1=$(printf 'a%.0s' $(seq 40)) HEAD2=$(printf 'b%.0s' $(seq 40))
state() { # state <files-json> <reviews-json> [head]
  printf '{"pr":{"number":7,"head":{"ref":"staging","sha":"%s"},"base":{"ref":"main"},"user":{"login":"launcher[bot]","type":"Bot"}},"files":%s,"reviews":%s,"perms":{"alice":"write","reader":"read","review-bot":"write"}}' "${3:-$HEAD2}" "$1" "$2" > "$T/state.json"
}
state '[]' '[]'
node test/stubs/promote-github.mjs "$T/port" "$T/state.json" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
echo '{"pull_request":{"number":7,"head":{"ref":"staging","sha":"'$HEAD2'"},"base":{"ref":"main"},"user":{"login":"launcher[bot]"}}}' > "$T/event.json"
gate() { (cd "$R" && GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_PATH="$T/event.json" node scripts/agent/gate.mjs evidence) 2>&1; }
rev() { printf '{"user":{"login":"%s","type":"%s"},"state":"%s","commit_id":"%s"}' "$1" "$2" "$3" "$4"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

state '["worker/src/index.ts","README.md"]' '[]'; out=$(gate); st=$?
if [ $st -eq 0 ] && has "no design sign-off needed" "$out"; then ok promote-no-ui-auto; else fail promote-no-ui-auto "$st $out"; fi

UI='["src/components/Hero.svelte","worker/src/index.ts"]'
state "$UI" '[]'; a=$(gate); sa=$?
state "$UI" "[$(rev review-bot Bot APPROVED "$HEAD2")]"; b=$(gate); sb=$?
state "$UI" "[$(rev reader User APPROVED "$HEAD2")]"; c=$(gate); sc=$?
state "$UI" "[$(rev alice User APPROVED "$HEAD2")]"; d=$(gate); sd=$?
if [ $sa -eq 1 ] && has "approve this promotion" "$a" && [ $sb -eq 1 ] && [ $sc -eq 1 ] && [ $sd -eq 0 ] && has "approved by @alice" "$d"; then ok promote-ui-needs-human-approval
else fail promote-ui-needs-human-approval "none=$sa bot=$sb read=$sc write=$sd: $a"; fi

# The approval event re-runs gate on the same head, which turns green; the workflow listens for it.
state "$UI" '[]'; before=$(gate); s1=$?
state "$UI" "[$(rev alice User APPROVED "$HEAD2")]"; after=$(gate); s2=$?
trig=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(/pull_request_review:\s*\n\s*types: \[submitted, dismissed\]/.test(y)&&/\/runs\/[^"\s]*\/rerun/.test(y))' "$R/.github/workflows/std-gate-rerun.yml")
if [ $s1 -eq 1 ] && [ $s2 -eq 0 ] && [ "$trig" = true ]; then ok promote-approval-then-merges; else fail promote-approval-then-merges "before=$s1 after=$s2 trigger=$trig"; fi

state "$UI" "[$(rev alice User APPROVED "$HEAD1")]"; a=$(gate); sa=$?
state "$UI" "[$(rev alice User APPROVED "$HEAD2"),$(rev alice User DISMISSED "$HEAD2")]"; b=$(gate); sb=$?
if [ $sa -eq 1 ] && has "no human approval on bbbbbbb" "$a" && [ $sb -eq 1 ]; then ok promote-stale-approval-rejected; else fail promote-stale-approval-rejected "stale=$sa dismissed=$sb: $a"; fi
done_cases
