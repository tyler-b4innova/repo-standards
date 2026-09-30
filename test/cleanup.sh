#!/usr/bin/env bash
# Session-start clean-up of merged local work (scripts/agent/cleanup.mjs through `setup.sh --check`), against a
# GitHub GraphQL stand-in. origin is only a URL here: nothing is fetched or pushed.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
SP=""
trap '[ -z "$SP" ] || { kill "$SP"; wait "$SP"; } 2>/dev/null; rm -rf "$T"' EXIT
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
echo '{"merged":{}}' > "$T/state.json"; : > "$T/log"
node test/stubs/cleanup-github.mjs "$T/port" "$T/state.json" "$T/log" & SP=$!
for _ in $(seq 100); do [ -s "$T/port" ] && break; sleep 0.05; done
export HOME="$T/home" GH_TOKEN=test-token GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")"; unset CI GITHUB_GRAPHQL_URL; mkdir -p "$HOME"
R=$T/repo; git init -q -b main "$R"; git -C "$R" remote add origin https://github.com/acme/demo.git
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.1.0 >/dev/null && printf '*.log\n' >> "$R/.gitignore" && g add -A && g commit -qm init
tip() { git -C "$R" rev-parse "$1"; }
br() { g checkout -q -b "$1" main && echo "$1" > "$R/$1.txt" && g add -A && g commit -qm "$1" && g checkout -q main; } # a branch one commit past main
wt() { g worktree add -q "$2" "$1" >/dev/null 2>&1; }
merged() { node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.merged[process.argv[2]]=[{oid:process.argv[3],repo:process.argv[4]||"acme/demo"}];require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json" "$@"; }
run() { (cd "${1:-$R}" && bash "$R/scripts/agent/setup.sh" --check 2>&1); }
exists() { git -C "$R" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }

# squash-merged: GitHub says merged at this very tip, though main does not contain it -> removed
br sq; merged sq "$(tip sq)"
# ancestor: the PR merged a later commit this tip leads to -> removed
br anc; g checkout -q anc && echo x >> "$R/anc.txt" && g commit -qam more && later=$(tip anc) && g reset -q --hard HEAD~1 && g checkout -q main; merged anc "$later"
# local work past the merged head -> kept
br ahead; g checkout -q ahead && echo y >> "$R/ahead.txt" && g commit -qam local && g checkout -q main; merged ahead "$(tip ahead~1)"
# open (not merged) -> kept; a fork's merged branch of the same name -> kept
br open; br forked; merged forked "$(tip forked)" someone/demo
# worktrees on merged branches: clean -> removed; ignored file only -> removed; dirty, untracked, locked, app-managed -> kept
for b in wclean wignored wdirty wuntracked wlocked wapp; do br $b; merged $b "$(tip $b)"; done
wt wclean "$T/wt-clean"; wt wignored "$T/wt-ignored"; echo x > "$T/wt-ignored/debug.log"
wt wdirty "$T/wt-dirty"; echo change >> "$T/wt-dirty/wdirty.txt"
wt wuntracked "$T/wt-untracked"; echo new > "$T/wt-untracked/new.txt"
wt wlocked "$T/wt-locked"; g worktree lock "$T/wt-locked"
mkdir -p "$HOME/.codex/worktrees"; wt wapp "$HOME/.codex/worktrees/wapp"
t0=$(date +%s); out=$(run); st=$?; dt=$(( $(date +%s) - t0 ))
got=""; for b in sq anc ahead open forked wclean wignored wdirty wuntracked wlocked wapp; do got="$got $b=$(exists $b)"; done
want=" sq=no anc=no ahead=yes open=yes forked=yes wclean=no wignored=no wdirty=yes wuntracked=yes wlocked=yes wapp=yes"
calls=$(grep -c POST "$T/log")
line=$(grep -c '^cleanup: removed merged' <<<"$out")
if [ $st -eq 0 ] && [ "$got" = "$want" ] && [ ! -d "$T/wt-clean" ] && [ ! -d "$T/wt-ignored" ] && [ -f "$T/wt-dirty/wdirty.txt" ] && [ -d "$T/wt-untracked" ] \
  && [ "$calls" = 1 ] && [ "$line" = 1 ] && has "sq" "$out" && [ $dt -le 3 ]
then ok cleanup-merged-work; else fail cleanup-merged-work "st=$st calls=$calls t=${dt}s got:$got :: $out"; fi
# the explicit pair the brief names
[ "$(exists sq)" = no ] && ok cleanup-squash-merged-removed || fail cleanup-squash-merged-removed "sq=$(exists sq)"
[ "$(exists wdirty)" = yes ] && grep -q change "$T/wt-dirty/wdirty.txt" && ok cleanup-dirty-worktree-survives || fail cleanup-dirty-worktree-survives "wdirty=$(exists wdirty)"

# the session's own worktree survives, even merged and clean
br sess; merged sess "$(tip sess)"; wt sess "$T/wt-sess"; out=$(run "$T/wt-sess"); s1=$?
# a hanging GitHub never blocks the session: nothing removed, the check's status kept, within the budget
br hang; merged hang "$(tip hang)"
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.hang=true;require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
t0=$(date +%s); out2=$(run); s2=$?; dt=$(( $(date +%s) - t0 ))
# unreachable GitHub and a failing check: the check's failure is the result, nothing removed
echo edit >> "$R/scripts/agent/pr.sh"; out3=$(GITHUB_API_URL=http://127.0.0.1:9 run); s3=$?; g checkout -q -- scripts/agent/pr.sh
# CI: gate runs --check; nothing is cleaned there
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8"));s.hang=false;require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
out4=$(CI=true run); s4=$?
if [ $s1 -eq 0 ] && [ "$(exists sess)" = yes ] && [ -d "$T/wt-sess" ] && [ $s2 -eq 0 ] && [ "$(exists hang)" = yes ] && [ $dt -le 4 ] \
  && [ $s3 -eq 1 ] && ! has "cleanup:" "$out3" && [ $s4 -eq 0 ] && [ "$(exists hang)" = yes ] && ! has "cleanup:" "$out4"
then ok cleanup-never-blocks; else fail cleanup-never-blocks "session=$s1/$(exists sess) hang=$s2 ${dt}s failing-check=$s3 ci=$s4/$(exists hang) :: $out | $out2 | $out3 | $out4"; fi
done_cases
