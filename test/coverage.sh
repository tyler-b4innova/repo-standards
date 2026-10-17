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
# every run starts from a known environment: GITHUB_ACTIONS and STD_GATE are scrubbed (this suite runs under test/ci-env, which sets the first)
covenv() { (export CI=true; env -u GITHUB_ACTIONS -u STD_GATE "$@" bash "$T/test/run.sh" 2>&1); }
cov() { covenv; }
printf 'echo "ok ran"\n' > "$T/test/ran.sh"
# engine-coverage-skip-fails: under CI a skip line fails the coverage line and is named; an id no case prints fails it too
scen ran; o1=$(cov); x1=$?
printf 'echo "skip offline (no network)"\n' > "$T/test/offline.sh"; scen ran offline; o2=$(cov); x2=$?
rm "$T/test/offline.sh"; o3=$(cov); x3=$?
if [ $x1 -eq 0 ] && has "ok engine-scenarios-covered (1 scenarios)" "$o1" \
  && [ $x2 -ne 0 ] && has "FAIL engine-scenarios-covered" "$o2" && has "skipped under CI: offline" "$o2" \
  && [ $x3 -ne 0 ] && has "FAIL engine-scenarios-covered" "$o3" && has "missing: offline" "$o3"; then ok engine-coverage-skip-fails
else fail engine-coverage-skip-fails "printed=$x1 skipped=$x2 unprinted=$x3: $(echo $o1) | $(echo $o2) | $(echo $o3)"; fi
# engine-coverage-platform-skip: a skip that declares a platform limit passes on a local pre-flight (no GITHUB_ACTIONS, or a gate
# run's STD_GATE under test/ci-env's GITHUB_ACTIONS=true) and is named; under GITHUB_ACTIONS=true it fails; any other skip fails locally
printf 'echo "skip plat (linux only: setpriv)"\n' > "$T/test/plat.sh"; scen ran plat; p1=$(covenv); xp1=$?
p2=$(covenv GITHUB_ACTIONS=true); xp2=$?
p3=$(covenv GITHUB_ACTIONS=true STD_GATE=1); xp3=$?
printf 'echo "skip offline (no network)"\n' > "$T/test/offline.sh"; scen ran plat offline; m1=$(covenv); xm1=$?
if [ $xp1 -eq 0 ] && has "ok engine-scenarios-covered" "$p1" && has "skipped locally (platform): plat" "$p1" \
  && [ $xp2 -ne 0 ] && has "FAIL engine-scenarios-covered" "$p2" && has "skipped under CI: plat" "$p2" \
  && [ $xp3 -eq 0 ] && has "skipped locally (platform): plat" "$p3" \
  && [ $xm1 -ne 0 ] && has "skipped under CI: offline" "$m1" && ! has "skipped under CI: plat" "$m1"; then ok engine-coverage-platform-skip
else fail engine-coverage-platform-skip "platform=$xp1 github=$xp2 gate=$xp3 mixed=$xm1 :: $(echo $p1) | $(echo $p2) | $(echo $p3) | $(echo $m1)"; fi
done_cases
