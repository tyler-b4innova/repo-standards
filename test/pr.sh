#!/usr/bin/env bash
# PR helper cases (scripts/agent/pr.sh) against a local GitHub stub; a local bare repo is origin, so pushes stay offline.
set -uo pipefail
cd "$(dirname "$0")/.."
ENGINE=$PWD
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
unset GITHUB_ACTIONS GITHUB_TOKEN # CI sets them; the refusal cases set GITHUB_ACTIONS themselves
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
# a REST id past GraphQL's Int, in the third thread's second comment page (pages of 2 threads, 1 comment)
mut "S.threadPage=2;S.commentPage=1;S.threads=[{id:'T1',isResolved:false,comments:{nodes:[{databaseId:11}]}},{id:'T2',isResolved:false,comments:{nodes:[{databaseId:21}]}},{id:'T3',isResolved:false,comments:{nodes:[{fullDatabaseId:'4114745646'},{fullDatabaseId:'4114745647'}]}}]"
r3=$("$PR" resolve 1 4114745647 2>&1); rs3=$?; got3=$(state "S.threads.map(t=>t.id+'='+t.isResolved).join(' ')")
mut "S.threadPage=100;S.commentPage=100"
if [ $rs1 -eq 0 ] && [ $rs2 -ne 0 ] && [ "$got" = "T1=true T2=false" ] && case "$r2" in *"no review thread on #1 holds comment 99"*) true ;; *) false ;; esac \
  && [ $rs3 -eq 0 ] && [ "$got3" = "T1=false T2=false T3=true" ]
then ok pr-resolve-thread; else fail pr-resolve-thread "$rs1 $r1 | $rs2 $r2 | $got | $rs3 $r3 | $got3"; fi
mut "S.threads=[]"
if [ -z "$why" ]; then ok pr-status-done; else fail pr-status-done "$why"; fi

# evidence-attachments-posted: pr.sh evidence uploads through `gh pr comment --attach` (the gh double is on PATH), leaves one
# marked comment (a re-post replaces it; another author's is untouched), and makes no commit, no push and no .evidence/.
printf 'mp4' >"$T/clip.mp4" && echo notes >"$T/notes.txt"
for n in before-400 before-1280 after-400 after-1280; do printf '\211PNG\r\n' >"$T/$n.png"; done
mkdir -p "$T/bin" && printf '#!/bin/sh\nexec node "%s/test/stubs/gh-attach.mjs" "$@"\n' "$ENGINE" >"$T/bin/gh" && chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_SHIM_LOG="$T/gh.jsonl"; : >"$GH_SHIM_LOG"
CAP=("$T/before-400.png" "$T/before-1280.png" "$T/after-400.png" "$T/after-1280.png" "$T/clip.mp4")
HEAD_SHA=$(git rev-parse HEAD)
why=""
mut "S.issueComments[1]=[{id:5,body:'<!-- std:evidence --> by someone else',user:{login:'other'}}]"
U1=$("$PR" evidence 1 "${CAP[@]}" 2>"$T/ev.out") || why="$why; evidence run 1 failed: $(cat "$T/ev.out")"
U2=$("$PR" evidence 1 "${CAP[@]}" 2>"$T/ev.out") || why="$why; evidence run 2 failed: $(cat "$T/ev.out")"
# the second run keeps the first comment: same URL, same id, and the body is the new upload
[ -n "$U1" ] && [ "$U1" = "$U2" ] || why="$why; the URL changed across runs: $U1 then $U2"
[ "$(state "S.issueComments[1].find(c=>c.user.login==='agent').id")" = "${U1##*issuecomment-}" ] || why="$why; the kept comment is not $U1"
body=$(state "S.issueComments[1].find(c=>c.user.login==='agent').body")
[ "$(state "S.issueComments[1].filter(c=>c.user.login==='agent').length")" = 1 ] || why="$why; not exactly one own comment"
[ "$(state "S.issueComments[1].find(c=>c.id===5).body")" = "<!-- std:evidence --> by someone else" ] || why="$why; edited another author's comment"
case "$body" in "<!-- std:evidence head=$HEAD_SHA -->"$'\n'"### Evidence"*) ;; *) why="$why; marker or heading wrong: $body" ;; esac
for n in before-400 before-1280 after-400 after-1280; do
  case "$body" in *"![$n.png](https://github.com/user-attachments/assets/"*) ;; *) why="$why; $n.png not embedded by name" ;; esac
done
[ "$(printf '%s' "$body" | grep -o 'user-attachments/assets/' | wc -l | tr -d ' ')" = 5 ] || why="$why; video not attached: $body"
grep -q -- '"--attach","./1.png#before-400.png"' "$GH_SHIM_LOG" || why="$why; capture not attached with its name as alt text: $(cat "$GH_SHIM_LOG")"
[ "$(git rev-parse HEAD)" = "$HEAD_SHA" ] || why="$why; a commit was made"
[ "$(git --git-dir="$T/origin.git" rev-parse refs/heads/feat/x)" = "$HEAD_SHA" ] || why="$why; something was pushed"
[ ! -e .evidence ] && [ -z "$(git status --porcelain)" ] || why="$why; the checkout changed"
# gh 2.98 is refused before anything is sent; so are files that are not images or video (SVG included), and more than 50
printf '<svg/>' >"$T/diagram.svg"; mkdir -p "$T/many"; MANY=(); for i in $(seq 51); do printf '\211PNG\r\n' >"$T/many/c$i.png"; MANY+=("$T/many/c$i.png"); done
g0=$(wc -l <"$GH_SHIM_LOG"); n=$(lines)
out=$(GH_SHIM_VERSION=2.98.0 "$PR" evidence 1 "${CAP[@]}" 2>&1) && why="$why; gh 2.98 accepted"
case "$out" in *"gh 2.99 or later"*) ;; *) why="$why; no version message: $out" ;; esac
out=$("$PR" evidence 1 "$T/notes.txt" 2>&1) && why="$why; a text file accepted"
case "$out" in *"unsupported evidence file"*) ;; *) why="$why; no unsupported-file message: $out" ;; esac
out=$("$PR" evidence 1 "$T/diagram.svg" 2>&1) && why="$why; an SVG accepted"
case "$out" in *"unsupported evidence file"*) ;; *) why="$why; no SVG message: $out" ;; esac
out=$("$PR" evidence 1 "${MANY[@]}" 2>&1) && why="$why; 51 files accepted"
case "$out" in *"at most 50 files"*) ;; *) why="$why; no 50-file message: $out" ;; esac
[ "$(wc -l <"$GH_SHIM_LOG")" = "$g0" ] && [ "$(lines)" = "$n" ] || why="$why; a refused run sent requests"
# a failed post changes nothing: the previous own comment stays as it was
mut "S.failComments=true"; out=$("$PR" evidence 1 "${CAP[@]}" 2>&1) && why="$why; failed post reported success"
mut "S.failComments=false"
[ "$(state "S.issueComments[1].find(c=>c.user.login==='agent').body")" = "$body" ] || why="$why; a failed post changed the comment"
# a partial post (gh fails after the comment is up) leaves nothing behind: the previous comment stays, the new one is removed
idb=$(state "S.issueComments[1].find(c=>c.user.login==='agent').id")
out=$(GH_SHIM_PARTIAL=1 "$PR" evidence 1 "${CAP[@]}" 2>&1) && why="$why; a partial post reported success"
case "$out" in *"the previous evidence comment is unchanged"*) ;; *) why="$why; partial post message: $out" ;; esac
[ "$(state "S.issueComments[1].filter(c=>c.user.login==='agent').length")" = 1 ] && [ "$(state "S.issueComments[1].find(c=>c.user.login==='agent').id")" = "$idb" ] || why="$why; a partial post left a comment: $(state "JSON.stringify(S.issueComments[1])")"
# the review rule reads what the helper posted: same marker, same names, through the review export
FXP=$T/review-fixture.json
node -e '(async()=>{const S=await (await fetch(process.env.GITHUB_API_URL+"/__state")).json();require("fs").writeFileSync(process.argv[1],JSON.stringify({repo:"acme/demo",files:{1:["src/app.css"]},comments:{1:S.issueComments[1]},pull:{user:"agent",ref:"feat/x"},head:process.argv[2],gitDir:process.argv[3]}))})()' "$FXP" "$HEAD_SHA" "$PWD"
node "$ENGINE/test/stubs/gate-github.mjs" "$T/rport" "$T/rlog" "$FXP" & RP=$!
for _ in $(seq 100); do [ -s "$T/rport" ] && break; sleep 0.05; done
rv=$(GITHUB_API_URL="http://127.0.0.1:$(cat "$T/rport")" GITHUB_REPOSITORY=acme/demo node "$ENGINE/test/review-run.mjs" 1 2>&1); rs=$?
kill "$RP"; wait "$RP" 2>/dev/null
{ [ $rs -eq 0 ] && case "$rv" in *"evidence: accepted"*) ;; *) false ;; esac; } || why="$why; the review rule did not accept the posted evidence (exit $rs): $rv"
# no commit, push or .evidence/ anywhere on the branch
case "$(git ls-tree -r --name-only HEAD)" in *.evidence/*) why="$why; tip tracks .evidence/" ;; esac
if [ -z "$why" ]; then ok evidence-attachments-posted; ok no-evidence-on-main; else fail evidence-attachments-posted "$why"; fi

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

# ready: turns a draft ready once, and only when `gate.mjs local` passed on the pushed, clean head. Failures change nothing.
why=""
git push -q origin HEAD 2>/dev/null
HEAD_SHA=$(git rev-parse HEAD); GATE=$(git rev-parse --git-path std-local-gate)
mut "S.pulls[0].draft=true;S.pulls[0].state='open';S.pulls[0].merged=false;S.gqlFail=false"
draft() { state 'S.pulls[0].draft'; }
# no passing gate: refused, still draft
rm -f "$GATE"
out=$("$PR" ready 1 2>&1) && why="$why; ready accepted with no local gate"
case "$out" in *"node scripts/agent/gate.mjs local"*) ;; *) why="$why; refusal lacks the gate hint: $out" ;; esac
echo stale >"$GATE"; out=$("$PR" ready 1 2>&1) && why="$why; ready accepted a gate pass for another head"
[ "$(draft)" = true ] || why="$why; refused ready still flipped the PR"
# a pass on this head, but the tree is dirty or the head is unpushed
echo "$HEAD_SHA" >"$GATE"
echo dirty >>x.txt; out=$("$PR" ready 1 2>&1) && why="$why; ready accepted a dirty tree"; git checkout -q x.txt
g commit -q --allow-empty -m unpushed; out=$("$PR" ready 1 2>&1) && why="$why; ready accepted an unpushed head"; git reset -q --hard "$HEAD_SHA"
[ "$(draft)" = true ] || why="$why; refused ready flipped the PR"
# a pass on the pushed clean head flips it, once
out=$("$PR" ready 1 2>&1) || why="$why; ready exit $?: $out"
[ "$(draft)" = false ] || why="$why; ready did not mark the PR ready"
m=$(count 'markPullRequestReadyForReview'); out=$("$PR" ready 1 2>&1) && [ "$(count 'markPullRequestReadyForReview')" = "$m" ] || why="$why; ready on a ready PR sent a mutation again"
# an untracked, non-ignored file also blocks it
mut "S.pulls[0].draft=true"; echo "$HEAD_SHA" >"$GATE"; echo junk >untracked.txt
out=$("$PR" ready 1 2>&1) && why="$why; ready accepted an untracked file"
git config status.showUntrackedFiles no
out=$("$PR" ready 1 2>&1) && why="$why; ready accepted an untracked file with showUntrackedFiles=no"
git config --unset status.showUntrackedFiles; rm -f untracked.txt
[ "$(draft)" = true ] || why="$why; untracked-file refusal flipped the PR"
# inside Actions the flip would not start the full gate, whichever token variable is set: refused, nothing sent
for envs in "GITHUB_TOKEN=test-token" "GH_TOKEN=test-token" "GITHUB_TOKEN=other GH_TOKEN=test-token"; do
  n=$(lines); out=$(env GITHUB_ACTIONS=true $envs "$PR" ready 1 2>&1) && why="$why; ready ran inside Actions ($envs)"
  case "$out" in *"inside GitHub Actions"*) ;; *) why="$why; refusal does not name Actions ($envs): $out" ;; esac
  [ "$(lines)" = "$n" ] && [ "$(draft)" = true ] || why="$why; the Actions refusal sent requests or flipped the PR ($envs)"
done
mut "S.pulls[0].draft=true"
# a push lands during the toggle: the PR goes back to draft and ready fails
mut "S.moveHead=true"; out=$("$PR" ready 1 2>&1) && why="$why; ready succeeded though the head moved"
case "$out" in *"head moved"*) ;; *) why="$why; no plain head-moved message: $out" ;; esac
[ "$(draft)" = true ] || why="$why; the moved-head PR was left ready"
mut "S.moveHead=false;S.pulls[0].sha=null"
# GitHub refusing the toggle is an error, not a silent success
mut "S.pulls[0].draft=true;S.gqlFail=true"; echo "$HEAD_SHA" >"$GATE"; out=$("$PR" ready 1 2>&1) && why="$why; refused toggle reported success"
mut "S.gqlFail=false"
rm -f "$GATE"
if [ -z "$why" ]; then ok pr-open-verified; else fail pr-open-verified "$why"; fi

# pr-open-claimed-issue: an issue labelled agent-claimed is refused unless the branch is the launcher's agent/N-* or retro/N-*
# (N exactly: agent/30-* is not agent/3-*); --dry-run and --claimed-ok do not check it; another label, a cross-repo
# reference and an unlabelled issue do not refuse.
since() { sed -n "$(($1 + 1)),\$p" "$LOG"; }
why=""
mut "S.issues={3:[{name:'agent-claimed'}]}"
git checkout -q feat/x
n=$(lines); out=$("$PR" open "Add x" "$T/body.md" 2>&1) && why="$why; claimed issue accepted on feat/x"
case "$out" in *"issue #3 is claimed by the launcher"*"agent/3-<slug> or retro/3-<slug>"*"remove agent-claimed first"*) ;; *) why="$why; refusal does not name the claim: $out" ;; esac
since "$n" | grep -q '"path":"/repos/acme/demo/issues/3"' || why="$why; the claim was not read from issues/3"
since "$n" | grep -q -E '"method":"(POST|PATCH)"' && why="$why; the refusal wrote to GitHub"
n=$(lines); out=$("$PR" open --dry-run "Add x" "$T/body.md" 2>&1) || why="$why; dry-run refused a claimed issue: $out"
[ "$(lines)" = "$n" ] || why="$why; dry-run sent requests"
n=$(lines); out=$("$PR" open --claimed-ok "Add x" "$T/body.md" 2>&1) || why="$why; --claimed-ok refused: $out"
[ "$out" = "$URL" ] || why="$why; --claimed-ok printed '$out'"
since "$n" | grep -q '"path":"/repos/acme/demo/issues/3"' && why="$why; --claimed-ok still read the issue"
git checkout -q -b agent/3-add-x && git push -q -u origin HEAD 2>/dev/null
out=$("$PR" open "Add x" "$T/body.md" 2>&1) || why="$why; the launcher's own branch was refused: $out"
case "$out" in https://github.com/acme/demo/pull/*) ;; *) why="$why; no PR URL for the launcher's branch: $out" ;; esac
[ "$(state 'S.pulls.some(p=>p.head==="agent/3-add-x"&&p.base==="main")')" = true ] || why="$why; no PR opened from agent/3-add-x"
git checkout -q -b retro/3-add-x && git push -q -u origin HEAD 2>/dev/null
out=$("$PR" open "Add x" "$T/body.md" 2>&1) || why="$why; the retro branch was refused: $out"
[ "$(state 'S.pulls.some(p=>p.head==="retro/3-add-x")')" = true ] || why="$why; no PR opened from retro/3-add-x"
git checkout -q -b agent/30-add-x && git push -q -u origin HEAD 2>/dev/null
out=$("$PR" open "Add x" "$T/body.md" 2>&1) && why="$why; agent/30-* accepted for issue 3"
case "$out" in *"issue #3 is claimed by the launcher"*) ;; *) why="$why; agent/30-* refusal not the claim message: $out" ;; esac
git checkout -q feat/x
mut "S.issues={3:[{name:'bug'}]}"
out=$("$PR" open "Add x" "$T/body.md" 2>&1) || why="$why; a non-claim label refused: $out"
mut "S.issues={3:[{name:'agent-claimed'}]}"
printf 'Adds x.\n\nCloses other/repo#3\nCloses #5\n' >"$T/xrepo.md"
out=$("$PR" open "Add x" "$T/xrepo.md" 2>&1) || why="$why; a cross-repo reference to a claimed number refused: $out"
mut "S.issues={}"
if [ -z "$why" ]; then ok pr-open-claimed-issue; else fail pr-open-claimed-issue "$why"; fi

# pr-resolve-bot-threads-only: resolve refuses a thread whose first comment is a person's or a deleted account's, says to
# reply instead, and sends no mutation for it; a thread that starts with a bot's resolves, whatever a person replies later.
why=""
mut "S.threads=[{id:'TP',isResolved:false,comments:{nodes:[{databaseId:31,url:'uP1',author:{login:'alice',__typename:'User'}},{databaseId:32,url:'uP2',author:{login:'chatgpt-codex-connector',__typename:'Bot'}}]}},{id:'TD',isResolved:false,comments:{nodes:[{databaseId:41,url:'uD1',author:null}]}},{id:'TB',isResolved:false,comments:{nodes:[{databaseId:51,url:'uB1',author:{login:'chatgpt-codex-connector',__typename:'Bot'}},{databaseId:52,url:'uB2',author:{login:'alice',__typename:'User'}}]}},{id:'TS',isResolved:false,comments:{nodes:[{databaseId:61,url:'uS1',author:{login:'example-sync',__typename:'Bot'}}]}}]"
n=$(lines)
p1=$("$PR" resolve 1 31 2>&1) && why="$why; a person's thread resolved"
case "$p1" in *"@alice"*"reply"*) ;; *) why="$why; refusal does not name @alice and say to reply: $p1" ;; esac
"$PR" resolve 1 32 >/dev/null 2>&1 && why="$why; a bot reply inside a person's thread resolved"
"$PR" resolve 1 41 >/dev/null 2>&1 && why="$why; a deleted account's thread resolved"
since "$n" | grep -q resolveReviewThread && why="$why; a refused resolve sent a mutation"
"$PR" resolve 1 51 >/dev/null 2>&1 || why="$why; a thread that starts with a codex comment was refused"
"$PR" resolve 1 61 >/dev/null 2>&1 || why="$why; a Bot-typed thread from another app was refused"
[ "$(since "$n" | grep -c resolveReviewThread)" = 2 ] || why="$why; expected two resolves, sent $(since "$n" | grep -c resolveReviewThread)"
[ "$(state "S.threads.map(t=>t.id+'='+t.isResolved).join(' ')")" = "TP=false TD=false TB=true TS=true" ] || why="$why; threads $(state "S.threads.map(t=>t.id+'='+t.isResolved).join(' ')")"
mut "S.threads=[]"
if [ -z "$why" ]; then ok pr-resolve-bot-threads-only; else fail pr-resolve-bot-threads-only "$why"; fi

# pr-arm-gate-and-review: arm turns on squash auto-merge only for a ready PR whose base branch rules require both gate and
# review (across rulesets); a draft, or a branch missing either, is refused by name and sends no mutation; nothing merges.
why=""
mut "S.pulls[0].draft=false;S.pulls[0].state='open';S.pulls[0].merged=false;S.autoMerge=[];S.rules=[{type:'required_status_checks',parameters:{required_status_checks:[{context:'gate'}]}}]"
n=$(lines)
out=$("$PR" arm 1 2>&1) && why="$why; arm armed with only gate required"
case "$out" in *"missing: review"*) ;; *) why="$why; refusal does not name review: $out" ;; esac
since "$n" | grep -q '"path":"/repos/acme/demo/rules/branches/main"' || why="$why; the base branch rules were not read"
since "$n" | grep -q enablePullRequestAutoMerge && why="$why; refusal sent the auto-merge mutation"
mut "S.rules=[{type:'required_status_checks',parameters:{required_status_checks:[{context:'gate'}]}},{type:'required_status_checks',parameters:{required_status_checks:[{context:'review'}]}}];S.pulls[0].draft=true"
n=$(lines)
out=$("$PR" arm 1 2>&1) && why="$why; arm armed a draft"
case "$out" in *"is a draft"*) ;; *) why="$why; no draft message: $out" ;; esac
since "$n" | grep -q enablePullRequestAutoMerge && why="$why; a draft got the mutation"
mut "S.pulls[0].draft=false"
out=$("$PR" arm 1 2>&1) || why="$why; arm refused a ready PR whose rulesets require both: $out"
case "$out" in *"auto-merge armed on #1"*) ;; *) why="$why; no armed message: $out" ;; esac
[ "$(state 'JSON.stringify(S.autoMerge)')" = "[1]" ] || why="$why; auto-merge not recorded: $(state 'JSON.stringify(S.autoMerge)')"
since "$n" | grep enablePullRequestAutoMerge | grep -q 'mergeMethod:SQUASH' || why="$why; not a squash auto-merge"
[ "$(state 'S.pulls[0].merged')" = false ] || why="$why; arm merged the PR"
since "$n" | grep -q '/pulls/1/merge"' && why="$why; a merge request was sent"
mut "S.autoMerge=[];S.rules=[]"
if [ -z "$why" ]; then ok pr-arm-gate-and-review; else fail pr-arm-gate-and-review "$why"; fi

# pr-arm-rules-paged: the base branch rules are read page by page (100 a page, until a short one), so a required check on a
# later page counts: gate on the first page and review on the second, and arm arms.
why=""
mut "S.pulls[0].draft=false;S.pulls[0].state='open';S.pulls[0].merged=false;S.autoMerge=[];S.allowAutoMerge=true;S.autoMergeError=null;S.rules=[...Array(99).fill({type:'pull_request'}),{type:'required_status_checks',parameters:{required_status_checks:[{context:'gate'}]}},{type:'required_status_checks',parameters:{required_status_checks:[{context:'review'}]}}]"
n=$(lines)
out=$("$PR" arm 1 2>&1) || why="$why; arm refused rules spread over two pages: $out"
since "$n" | grep -q '"query":"?per_page=100&page=2"' || why="$why; the second page was not read: $(since "$n" | grep -F rules)"
[ "$(state 'JSON.stringify(S.autoMerge)')" = "[1]" ] || why="$why; auto-merge not armed: $(state 'JSON.stringify(S.autoMerge)')"
mut "S.autoMerge=[];S.rules=[]"
if [ -z "$why" ]; then ok pr-arm-rules-paged; else fail pr-arm-rules-paged "$why"; fi

# pr-arm-clean-status-reported: GitHub refuses auto-merge on a PR that is already clean; arm says so, tells the agent to report
# it, and merges nothing.
why=""
mut "S.pulls[0].draft=false;S.pulls[0].state='open';S.pulls[0].merged=false;S.autoMerge=[];S.allowAutoMerge=true;S.autoMergeError='Pull request is in clean status';S.rules=[{type:'required_status_checks',parameters:{required_status_checks:[{context:'gate'},{context:'review'}]}}]"
n=$(lines)
out=$("$PR" arm 1 2>&1) && why="$why; arm reported success on a clean PR"
case "$out" in *"already clean"*"report it"*) ;; *) why="$why; no clean-status message: $out" ;; esac
[ "$(state 'JSON.stringify(S.autoMerge)')" = "[]" ] || why="$why; auto-merge recorded"
since "$n" | grep -q '/pulls/1/merge"' && why="$why; a merge request was sent"
mut "S.autoMergeError=null;S.autoMerge=[];S.rules=[]"
if [ -z "$why" ]; then ok pr-arm-clean-status-reported; else fail pr-arm-clean-status-reported "$why"; fi

# pr-arm-auto-merge-off-refused: a repository with auto-merge off is refused by arm, which names an org admin as the one who
# enables it; arm writes no repository setting and sends no auto-merge mutation.
why=""
mut "S.pulls[0].draft=false;S.pulls[0].state='open';S.pulls[0].merged=false;S.autoMerge=[];S.autoMergeError=null;S.allowAutoMerge=false;S.rules=[{type:'required_status_checks',parameters:{required_status_checks:[{context:'gate'},{context:'review'}]}}]"
n=$(lines)
out=$("$PR" arm 1 2>&1) && why="$why; arm armed with auto-merge off for the repository"
case "$out" in *"auto-merge is off for this repository; an org admin enables it"*) ;; *) why="$why; no auto-merge-off message: $out" ;; esac
since "$n" | grep -q enablePullRequestAutoMerge && why="$why; the auto-merge mutation was sent"
since "$n" | grep -q -E '"method":"(PATCH|PUT|POST|DELETE)","path":"/repos/acme/demo"' && why="$why; a repository setting was written"
[ "$(state 'JSON.stringify(S.autoMerge)')" = "[]" ] || why="$why; auto-merge recorded"
mut "S.allowAutoMerge=true;S.autoMerge=[];S.rules=[]"
if [ -z "$why" ]; then ok pr-arm-auto-merge-off-refused; else fail pr-arm-auto-merge-off-refused "$why"; fi

done_cases
