#!/usr/bin/env bash
# The Codex-verdict step of gate (Tyler's rule: every bot finding is answered before merge), against a stand-in.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap '{ kill $STUB; wait $STUB; } 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo; git init -q -b main "$R" && node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.1.0 >/dev/null
HEAD1=$(printf 'c%.0s' $(seq 40)) OLD=$(printf 'd%.0s' $(seq 40))
echo '{}' > "$T/state.json"
node test/stubs/codex-github.mjs "$T/port" "$T/state.json" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
echo '{"pull_request":{"number":7}}' > "$T/event.json"
# the job token's scopes, read from the workflow the repo runs (every case below uses them)
export WF_PERMS=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8").match(/^permissions:\n((?:  .*\n)+)/m)[1];console.log([...y.matchAll(/^  ([a-z-]+): (read|write)$/gm)].map((m)=>m[1]).join(" "))' "$R/.github/workflows/std-gate.yml")
iso() { node -e 'console.log(new Date(Date.now()-Number(process.argv[1])*60000).toISOString())' "$1"; }
# st <draft> <user> <ref> <summary-sha|none> <status> <pushed-min-ago> [threads-json] [recent-summary: yes|no]
st() {
  node -e '
    const [draft, user, ref, sha, status, ago, threads, recent] = process.argv.slice(1), bot = { login: "chatgpt-codex-connector[bot]", type: "Bot" };
    const sum = (s) => ({ user: bot, updated_at: process.env.SUMMARY_AT || new Date().toISOString(), body: "<!-- codex-pull-request-review-summary -->\n| Review | Status | Commit | Trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | " + status + " | `" + s.slice(0, 7) + "` | New commits |" });
    const when = new Date(Date.now() - Number(ago) * 60000).toISOString();
    console.log(JSON.stringify({ pr: { number: 7, draft: draft === "true", user: { login: user }, head: { sha: process.argv[9], ref }, created_at: when },
      comments: { 7: sha === "none" ? [] : [sum(sha)], 3: recent === "yes" ? [sum(process.argv[10])] : [] },
      recent: [{ number: 7 }, { number: 3 }], threads: JSON.parse(threads || "[]"), pushed: when, timeline: JSON.parse(process.env.TIMELINE || "[]"), perms: (process.env.PERMS ?? process.env.WF_PERMS).split(" "), reviews: JSON.parse(process.env.REVIEWS || "[]") }));
  ' "$@" > "$T/state.json"; }
gate() { (cd "$R" && GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_GRAPHQL_URL="http://127.0.0.1:$(cat "$T/port")/graphql" GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t GITHUB_EVENT_PATH="$T/event.json" node scripts/agent/gate.mjs codex) 2>&1; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
OPEN='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"url":"https://github.com/acme/demo/pull/7#r1"}]}}]'
DONE='[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"url":"u"}]}}]'
r=""
chk() { local want=$1 needle=$2 out st; out=$(gate); st=$?; { [ $st -eq "$want" ] && has "$needle" "$out"; } || r="$r [$needle: exit $st: $out]"; }
st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 0 "verdict on ccccccc, no open findings"
st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$OPEN" yes "$HEAD1" "$HEAD1"; chk 1 "1 unresolved Codex thread"
# a summary completed before this head was pushed (same short SHA) does not count
SUMMARY_AT=$(iso 60) st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 1 "awaiting a Codex verdict for ccccccc"
st false alice feat "$OLD" '✅ **Completed** now' 5 "[]" yes "$HEAD1" "$OLD"; chk 1 "awaiting a Codex verdict for ccccccc"
# a base edit after the verdict (summary or full-SHA review) changes the diff: the verdict no longer counts
BASE='[{"event":"base_ref_changed","created_at":"'$(iso 1)'"}]'
TIMELINE=$BASE SUMMARY_AT=$(iso 2) st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 1 "awaiting a Codex verdict for ccccccc"
TIMELINE=$BASE REVIEWS='[{"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"commit_id":"'$HEAD1'","submitted_at":"'$(iso 2)'"}]' st false alice feat "$OLD" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$OLD"; chk 1 "awaiting a Codex verdict for ccccccc"
TIMELINE=$BASE REVIEWS='[{"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"commit_id":"'$HEAD1'","submitted_at":"'$(iso 0)'"}]' st false alice feat "$OLD" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$OLD"; chk 0 "verdict on ccccccc, no open findings"
st false alice feat "$HEAD1" '🔄 **Running** since' 5 "[]" yes "$HEAD1" "$OLD"; chk 1 "awaiting a Codex verdict"
st false alice feat "$OLD" '✅ **Completed** now' 30 "[]" yes "$HEAD1" "$OLD"; chk 1 "no Codex verdict for $HEAD1"
st true alice feat none x 30 "[]" yes "$HEAD1" "$OLD"; chk 0 "draft, not evaluated"
st false alice feat none x 30 "[]" no "$HEAD1" "$OLD"; chk 0 "no Codex reviews on this repo"
st false 'example-sync[bot]' standards/v1.2.3 none x 30 "[]" yes "$HEAD1" "$OLD"; chk 0 "pack-sync fallback PR"
# without actions: read (a private repo) the run-list read fails: the stand-in grants only what std-gate.yml lists
PERMS="contents pull-requests issues" st false alice feat "$HEAD1" '✅ **Completed** now' 5 "$DONE" yes "$HEAD1" "$HEAD1"; chk 1 "/actions/runs?head_sha=$HEAD1&event=pull_request&per_page=100: 403"
if [ -z "$r" ]; then ok codex-verdict-required; else fail codex-verdict-required "$r"; fi
done_cases
