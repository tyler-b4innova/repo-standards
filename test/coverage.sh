#!/usr/bin/env bash
# The suite's coverage line through the real test/run.sh, run in a scratch tree whose SCENARIOS.md and case files are
# fixtures (one prints ok, one prints skip, one id has no case).
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
mkdir "$T/test" "$T/tools" && cp test/run.sh "$T/test/run.sh" && cp tools/parallel.sh "$T/tools/parallel.sh"
scen() { printf -- '- **`%s`**: fixture.\n' "$@" > "$T/SCENARIOS.md"; }
cov() { (export CI=true; bash "$T/test/run.sh" 2>&1); }
printf 'echo "ok ran"\n' > "$T/test/ran.sh"
# engine-coverage-skip-fails: under CI a skip line fails the coverage line and is named; an id no case prints fails it too
scen ran; o1=$(cov); x1=$?
printf 'echo "skip offline (no network)"\n' > "$T/test/offline.sh"; scen ran offline; o2=$(cov); x2=$?
rm "$T/test/offline.sh"; o3=$(cov); x3=$?
if [ $x1 -eq 0 ] && has "ok engine-scenarios-covered (1 scenarios)" "$o1" \
  && [ $x2 -ne 0 ] && has "FAIL engine-scenarios-covered" "$o2" && has "skipped under CI: offline" "$o2" \
  && [ $x3 -ne 0 ] && has "FAIL engine-scenarios-covered" "$o3" && has "missing: offline" "$o3"; then ok engine-coverage-skip-fails
else fail engine-coverage-skip-fails "printed=$x1 skipped=$x2 unprinted=$x3: $(echo $o1) | $(echo $o2) | $(echo $o3)"; fi
done_cases
