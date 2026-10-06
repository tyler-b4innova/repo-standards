#!/usr/bin/env bash
# Session-start fresh-base warnings (scripts/agent/fresh.mjs through `setup.sh --check`), with a local bare repository
# as origin.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
export HOME="$T/home" STD_FRESH_TIMEOUT_MS=1500; unset CI GH_TOKEN GITHUB_TOKEN; mkdir -p "$HOME"
run() { (cd "$1" && bash scripts/agent/setup.sh --check 2>&1); }
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
node bin/repo-standards.mjs apply --target "$T/seed" --overlay examples/overlay.json --version 0.1.0 >/dev/null && git -C "$T/seed" add -A && git -C "$T/seed" commit -qm init && git -C "$T/seed" push -q origin main
git clone -q "$T/origin.git" "$T/work"   # the shared checkout, on main
for i in 1 2 3; do echo $i > "$T/seed/n$i.txt"; git -C "$T/seed" add -A; git -C "$T/seed" commit -qm "n$i"; done; git -C "$T/seed" push -q origin main

# fresh-base-warns-behind: on main, 3 commits behind origin (unknown locally until the fetch) -> the count, status kept,
# nothing moved
before=$(git -C "$T/work" rev-parse HEAD)
out=$(run "$T/work"); st=$?
if [ $st -eq 0 ] && has "WARN: fresh-base: main is 3 commit(s) behind origin/main" "$out" && [ "$(git -C "$T/work" rev-parse HEAD)" = "$before" ] && [ -z "$(git -C "$T/work" status --porcelain)" ]
then ok fresh-base-warns-behind; else fail fresh-base-warns-behind "st=$st :: $out"; fi

# fresh-base-warns-primary-checkout: on main in the primary checkout -> warning (even when up to date); a linked
# worktree on a feature branch -> no fresh-base line
git -C "$T/work" merge -q --ff-only origin/main
out=$(run "$T/work"); st=$?
git -C "$T/work" worktree add -q -b feat "$T/wt" origin/main 2>/dev/null
out2=$(run "$T/wt"); st2=$?
if [ $st -eq 0 ] && has "WARN: fresh-base: working on main in the primary checkout" "$out" && ! has "behind" "$out" && [ $st2 -eq 0 ] && ! has "fresh-base" "$out2"
then ok fresh-base-warns-primary-checkout; else fail fresh-base-warns-primary-checkout "st=$st/$st2 :: $out | $out2"; fi

# fresh-base-never-blocks: an origin that never answers -> one notice within the timeout, status kept; in CI nothing
# runs (origin is never asked)
printf '#!/bin/sh\ntouch "%s/asked"\nsleep 30\n' "$T" > "$T/hang-ssh"; chmod +x "$T/hang-ssh"
git -C "$T/work" remote set-url origin "ssh://nowhere.invalid/x.git"
export GIT_SSH_COMMAND="$T/hang-ssh"
t0=$(date +%s); out=$(run "$T/work"); st=$?; dt=$(( $(date +%s) - t0 ))
notes=$(grep -c "^NOTE: fresh-base: could not fetch origin/main" <<<"$out")
asked=$([ -f "$T/asked" ] && echo yes || echo no); rm -f "$T/asked"
out2=$(CI=true run "$T/work"); st2=$?
asked2=$([ -f "$T/asked" ] && echo yes || echo no)
if [ $st -eq 0 ] && [ "$notes" = 1 ] && [ "$asked" = yes ] && [ $dt -le 5 ] && [ $st2 -eq 0 ] && [ "$asked2" = no ] && ! has "fresh-base" "$out2"
then ok fresh-base-never-blocks; else fail fresh-base-never-blocks "st=$st notes=$notes asked=$asked ${dt}s ci=$st2/$asked2 :: $out | $out2"; fi
done_cases
