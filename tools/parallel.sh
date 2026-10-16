#!/usr/bin/env bash
# Runs each given script with bash, TEST_JOBS at a time (a positive integer; otherwise one per CPU), and prints each
# script's whole output in the order given, so the log reads as a serial run. Exits 1 if any script exited non-zero.
# Used by test/run.sh for the engine's case files, which are independent (each works in its own temporary directories).
set -uo pipefail
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
parallel=${TEST_JOBS:-}
case "$parallel" in '' | *[!0-9]* | 0*) parallel=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2) ;; esac
case "$parallel" in '' | *[!0-9]* | 0*) parallel=2 ;; esac
files=("$@") status=0
for i in "${!files[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$parallel" ]; do sleep 0.1; done
  ( bash "${files[$i]}" > "$out/$i.log" 2>&1; echo $? > "$out/$i.rc" ) &
done
wait
for i in "${!files[@]}"; do
  cat "$out/$i.log"
  [ "$(cat "$out/$i.rc" 2>/dev/null)" = 0 ] || status=1
done
exit $status
