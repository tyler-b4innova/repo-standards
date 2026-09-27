#!/usr/bin/env bash
# PR helper cases (scripts/agent/pr.sh) against a local GitHub stub; a local bare repo is origin, so pushes stay offline.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
SP=""
trap '[ -z "$SP" ] || { kill "$SP"; wait "$SP"; } 2>/dev/null; rm -rf "$T"' EXIT
g() { git -c user.name=t -c user.email=t@t "$@"; }
git init -q --bare "$T/origin.git" && git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$T/work" && git -C "$T/work" checkout -q -b main
node bin/repo-standards.mjs apply --target "$T/work" --overlay examples/overlay.json --version 0.1.0 >/dev/null || { fail pr-setup "apply failed"; exit 1; }
LOG="$T/requests.jsonl"
: >"$LOG"
node test/stubs/pr-github.mjs "$T/port" "$LOG" "$T/origin.git" &
SP=$!
for _ in $(seq 100); do [ -s "$T/port" ] && break; sleep 0.05; done
export GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GH_REPO=acme/demo GH_TOKEN=test-token
PR="$T/work/scripts/agent/pr.sh"
cd "$T/work" || exit 1
g add -A && g commit -qm init && git remote add origin "$T/origin.git" && git push -q -u origin main 2>/dev/null
git checkout -q -b feat/x && echo x >x.txt && g add x.txt
GIT_COMMITTER_DATE=2026-01-02T00:00:00Z g commit -qm "add x"
printf 'Adds x.\n\nCloses #3\n' >"$T/body.md"
printf 'Adds x.\n\nRefs #3\n' >"$T/nolink.md"
lines() { wc -l <"$LOG" | tr -d ' '; }
count() { local n; n=$(grep -c -- "$1" "$LOG"); echo "${n:-0}"; }
mut() { node -e "(async()=>{const u=process.env.GITHUB_API_URL+'/__state';const S=await (await fetch(u)).json();$1;await fetch(u,{method:'POST',body:JSON.stringify(S)})})()"; }
state() { node -e "(async()=>{const S=await (await fetch(process.env.GITHUB_API_URL+'/__state')).json();console.log($1)})()"; }
URL=https://github.com/acme/demo/pull/1

# pr-open-verified: dry-run sends nothing; an unpushed branch is refused (and not pushed);
# two opens on the pushed branch create one draft, then reuse it; the URL prints only after a read-back.
why=""
out=$("$PR" open "Add x" "$T/body.md" --dry-run 2>&1) || why="dry-run exit $?: $out"
[ "$(lines)" = 0 ] || why="$why; dry-run sent $(lines) request(s)"
case "$out" in *'"draft":true'*) ;; *) why="$why; dry-run did not print the draft request" ;; esac
out=$("$PR" open "Add x" "$T/body.md" 2>&1) && why="$why; unpushed branch accepted"
case "$out" in *"git push -u origin HEAD"*) ;; *) why="$why; refusal lacks the push hint: $out" ;; esac
git --git-dir="$T/origin.git" rev-parse -q --verify refs/heads/feat/x >/dev/null && why="$why; the helper pushed the branch itself"
git push -q -u origin HEAD 2>/dev/null
for run in 1 2; do
  out=$("$PR" open "Add x ($run)" "$T/body.md" 2>&1) || why="$why; open $run exit $?: $out"
  [ "$out" = "$URL" ] || why="$why; open $run printed '$out'"
  last=$(tail -1 "$LOG")
  case "$last" in *'"method":"GET","path":"/repos/acme/demo/pulls/1"'*) ;; *) why="$why; open $run last request was not the read-back: $last" ;; esac
done
[ "$(count '"method":"POST","path":"/repos/acme/demo/pulls"')" = 1 ] || why="$why; expected exactly one create"
[ "$(count '"method":"PATCH","path":"/repos/acme/demo/pulls/1"')" = 1 ] || why="$why; second open did not update the PR"
[ "$(state 'S.pulls.length+":"+S.pulls[0].draft+":"+S.pulls[0].title')" = "1:true:Add x (2)" ] || why="$why; state $(state 'JSON.stringify(S.pulls)')"
if [ -z "$why" ]; then ok pr-open-verified; else fail pr-open-verified "$why"; fi

# pr-status-done: DONE only when open or merged, the body closes an issue, and gate is green on the head SHA.
HEAD_SHA=$(git rev-parse HEAD) MAIN_SHA=$(git rev-parse main)
green='[{"name":"gate","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"failure"}]'
why=""
expect() { # expect <label> <want-exit> <want-text>
  local o r
  o=$("$PR" status 1 2>&1); r=$?
  [ "$r" = "$2" ] || why="$why; $1: exit $r"
  case "$o" in *"$3"*) ;; *) why="$why; $1: missing '$3' in: $(echo "$o" | tail -1)" ;; esac
}
mut "S.checks={'$HEAD_SHA':$green}"; expect "green open" 0 DONE
mut "S.checks={'$HEAD_SHA':[{name:'gate',status:'completed',conclusion:'failure'}]}"; expect "gate red" 1 "NOT DONE: gate failure"
mut "S.checks={'$MAIN_SHA':$green}"; expect "gate on a stale SHA" 1 "no gate check on the head SHA"
mut "S.checks={'$HEAD_SHA':$green};S.pulls[0].state='closed'"; expect "closed unmerged" 1 "PR closed without merge"
mut "S.pulls[0].merged=true"; expect "merged" 0 DONE
mut "S.pulls[0].state='open';S.pulls[0].merged=false;S.pulls[0].body='no link'"; expect "no closes" 1 "body lacks Closes #N"
mut "S.pulls[0].body='Fixes #3'"
if [ -z "$why" ]; then ok pr-status-done; else fail pr-status-done "$why"; fi

# evidence-images-pinned-resolving (posting side): two posts leave one marked comment whose image URLs carry the 40-hex SHA.
printf '\211PNG\r\n' >"$T/home page.png" && echo notes >"$T/notes.txt"
why=""
for run in 1 2; do "$PR" evidence 1 "$T/home page.png" "$T/notes.txt" >"$T/ev.out" 2>&1 || why="$why; evidence run $run failed: $(cat "$T/ev.out")"; done
PIN=$(git rev-parse HEAD~1)
body=$(state "S.issueComments[1].filter(c=>c.body.includes('<!-- std:evidence -->')).map(c=>c.body).join('\n----\n')")
case "$body" in *"----"*) why="$why; more than one evidence comment" ;; esac
case "$body" in *"![home page.png](https://github.com/acme/demo/blob/$PIN/.evidence/home%20page.png?raw=true)"*) ;; *) why="$why; image not pinned to $PIN: $body" ;; esac
case "$body" in *"[notes.txt](https://github.com/acme/demo/blob/$PIN/.evidence/notes.txt)"*) ;; *) why="$why; non-image link missing" ;; esac
case "$body" in *'![notes.txt]'*) why="$why; non-image rendered as an image" ;; esac
[ "$(count '"method":"PATCH","path":"/repos/acme/demo/issues/comments/')" = 1 ] || why="$why; second post did not update the comment"
if [ -z "$why" ]; then ok evidence-images-pinned-resolving; else fail evidence-images-pinned-resolving "$why"; fi

# no-evidence-on-main (posting side): the pushed tip has no .evidence/ and every posted URL still resolves at its SHA.
why=""
tip=$(git --git-dir="$T/origin.git" ls-tree -r --name-only refs/heads/feat/x)
case "$tip" in *.evidence/*) why="tip still tracks .evidence/" ;; esac
[ "$(git rev-parse HEAD)" = "$(git --git-dir="$T/origin.git" rev-parse refs/heads/feat/x)" ] || why="$why; cleanup commit not pushed"
[ ! -e .evidence ] || why="$why; .evidence/ left in the worktree"
urls=$(echo "$body" | grep -oE 'https://github\.com/[^)]+' | sed 's/?raw=true$//')
[ -n "$urls" ] || why="$why; no URLs posted"
for u in $urls; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$GITHUB_API_URL${u#https://github.com}")
  [ "$code" = 200 ] || why="$why; $u -> $code"
done
if [ -z "$why" ]; then ok no-evidence-on-main; else fail no-evidence-on-main "$why"; fi

done_cases
