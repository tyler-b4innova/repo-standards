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

# pr-status-done: DONE only when open or merged, the body closes an issue, gate is green on the head SHA, and no review
# thread is open.
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
case "$("$PR" status 1 2>&1)" in *"also failing (not required for DONE; fix or explain): lint"*) ;; *) why="$why; failing lint not called out" ;; esac
mut "S.checks={'$HEAD_SHA':[{name:'gate',status:'completed',conclusion:'failure'}]}"; expect "gate red" 1 "NOT DONE: gate failure"
mut "S.checks={'$MAIN_SHA':$green}"; expect "gate on a stale SHA" 1 "no gate check on the head SHA"
mut "S.checks={'$HEAD_SHA':$green};S.pulls[0].state='closed'"; expect "closed unmerged" 1 "PR closed without merge"
mut "S.pulls[0].merged=true"; expect "merged" 0 DONE
mut "S.pulls[0].state='open';S.pulls[0].merged=false;S.pulls[0].body='no link'"; expect "no closes" 1 "body lacks Closes #N"
mut "S.pulls[0].body='Fixes #3'"
# the org rulesets require resolved review threads, so DONE does too
mut "S.checks={'$HEAD_SHA':$green};S.threads=[{isResolved:false,comments:{nodes:[{url:'https://github.com/acme/demo/pull/1#r9'}]}},{isResolved:true,comments:{nodes:[{url:'u'}]}}]"
expect "open thread" 1 "1 unresolved review thread(s)"
case "$("$PR" status 1 2>&1)" in *"unresolved: https://github.com/acme/demo/pull/1#r9"*) ;; *) why="$why; open thread not named" ;; esac
mut "S.threads[0].isResolved=true"; expect "threads resolved" 0 DONE
mut "S.threadsFail=true"; expect "threads unreadable" 1 "could not read review threads"
mut "S.threadsFail=false"
# pr-resolve-thread: resolve finds the thread holding a comment id and resolves only that one; an unknown id fails
mut "S.threads=[{id:'T1',isResolved:false,comments:{nodes:[{databaseId:11,url:'u1'},{databaseId:12,url:'u2'}]}},{id:'T2',isResolved:false,comments:{nodes:[{databaseId:21,url:'u3'}]}}]"
r1=$("$PR" resolve 1 12 2>&1); rs1=$?; r2=$("$PR" resolve 1 99 2>&1); rs2=$?
got=$(state "S.threads.map(t=>t.id+'='+t.isResolved).join(' ')")
if [ $rs1 -eq 0 ] && [ $rs2 -ne 0 ] && [ "$got" = "T1=true T2=false" ] && case "$r2" in *"no review thread on #1 holds comment 99"*) true ;; *) false ;; esac
then ok pr-resolve-thread; else fail pr-resolve-thread "$rs1 $r1 | $rs2 $r2 | $got"; fi
mut "S.threads=[]"
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

# pr-open-verified (refs): an open PR into another base is not reused; refs with # and + are URL-encoded;
# `--` ends options so a title may start with -, and an unknown option sends nothing.
why=""
echo z >z.txt && g add z.txt && g commit -qm "unpushed z" && n=$(lines)
out=$("$PR" open "Add x" "$T/body.md" 2>&1) && why="unpushed commit accepted"
case "$out" in *"push first"*) ;; *) why="$why; refusal lacks the push hint: $out" ;; esac
[ "$(grep -c -E '"method":"(POST|PATCH)"' "$LOG")" = "$(sed -n "1,${n}p" "$LOG" | grep -c -E '"method":"(POST|PATCH)"')" ] || why="$why; unpushed open wrote to GitHub"
git reset -q --hard HEAD~1
posts() { count '"method":"POST","path":"/repos/acme/demo/pulls"'; }
g branch -q rel main && git push -q origin rel 2>/dev/null
p0=$(posts)
out=$("$PR" open "To rel" "$T/body.md" --base rel 2>&1) || why="open --base rel exit $?: $out"
[ "$out" = https://github.com/acme/demo/pull/2 ] || why="$why; --base rel reused or misprinted: $out"
out=$("$PR" open "To rel again" "$T/body.md" --base rel 2>&1)
[ "$out" = https://github.com/acme/demo/pull/2 ] && [ "$(posts)" = $((p0 + 1)) ] || why="$why; second --base rel did not reuse #2: $out"
[ "$(state 'S.pulls.map(p=>p.head+">"+p.base).join(",")')" = "feat/x>main,feat/x>rel" ] || why="$why; pulls $(state 'JSON.stringify(S.pulls)')"
git checkout -q -b 'fix/#3-a+b' && git push -q -u origin HEAD 2>/dev/null
out=$("$PR" open "Special ref" "$T/body.md" 2>&1)
[ "$out" = https://github.com/acme/demo/pull/3 ] || why="$why; special-ref open printed '$out'"
out=$("$PR" open -- "-dash title" "$T/body.md" 2>&1)
[ "$out" = https://github.com/acme/demo/pull/3 ] || why="$why; open -- printed '$out'"
[ "$(state 'S.pulls[2]&&S.pulls[2].head+"|"+S.pulls[2].title')" = "fix/#3-a+b|-dash title" ] || why="$why; special-ref PR $(state 'JSON.stringify(S.pulls[2])')"
n=$(lines); out=$("$PR" open --bse rel "t" "$T/body.md" 2>&1) && why="$why; unknown option accepted"
[ "$(lines)" = "$n" ] || why="$why; unknown option sent a request"
git checkout -q feat/x
if [ -z "$why" ]; then ok pr-open-verified; else fail pr-open-verified "$why"; fi

# evidence-images-pinned-resolving (ignored .evidence/): captures post even when .evidence/ is gitignored,
# and only the named files are committed: a parked .evidence/pr.md and an unrelated staged file stay out.
why=""
echo .evidence/ >>.gitignore && g commit -qam "ignore .evidence" && git push -q 2>/dev/null
mkdir -p .evidence && echo "parked" >.evidence/pr.md && echo y >y.txt && git add y.txt
mut "S.issueComments[1].unshift({id:5,body:'<!-- std:evidence --> by someone else',user:{login:'other'}})"
"$PR" evidence 1 "$T/home page.png" >"$T/ev.out" 2>&1 || why="evidence failed: $(cat "$T/ev.out")"
files=$(git show --name-only --format= HEAD~1)
[ "$files" = ".evidence/home page.png" ] || why="$why; evidence commit held: $files"
[ -f .evidence/pr.md ] || why="$why; parked .evidence/pr.md was deleted"
[ "$(git diff --cached --name-only)" = y.txt ] || why="$why; staged y.txt not left staged"
body=$(state "S.issueComments[1].find(c=>c.user.login==='agent'&&c.body.includes('<!-- std:evidence -->')).body")
case "$body" in *"/blob/$(git rev-parse HEAD~1)/.evidence/home%20page.png"*) ;; *) why="$why; not pinned: $body" ;; esac
[ "$(state "S.issueComments[1].find(c=>c.id===5).body")" = "<!-- std:evidence --> by someone else" ] || why="$why; edited another author's evidence comment"
git reset -q y.txt && rm -rf y.txt .evidence
if [ -z "$why" ]; then ok evidence-images-pinned-resolving; else fail evidence-images-pinned-resolving "$why"; fi

# no-evidence-on-main (failed post): when the comment cannot be posted, the pushed tip still has no .evidence/.
why=""
mut "S.failComments=true"
"$PR" evidence 1 "$T/notes.txt" >"$T/ev.out" 2>&1 && why="post failure not reported"
tip=$(git --git-dir="$T/origin.git" ls-tree -r --name-only refs/heads/feat/x)
case "$tip" in *.evidence/*) why="$why; tip tracks .evidence/ after a failed post" ;; esac
mut "S.failComments=false"
if [ -z "$why" ]; then ok no-evidence-on-main; else fail no-evidence-on-main "$why"; fi

done_cases
