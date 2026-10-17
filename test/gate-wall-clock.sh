#!/usr/bin/env bash
# A hung local gate bounds its own hold time. All processes and locks belong to this fixture.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_ACTIONS GATE_LOCK GATE_LOCK_WAIT_S GATE_LOCAL_TIMEOUT_MIN GITHUB_EVENT_PATH GITHUB_EVENT_NAME
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo; mkdir "$R"; git -C "$R" init -q -b main
printf '{}\n' > "$R/standards.json"
node -e 'const fs=require("fs"),o=JSON.parse(fs.readFileSync("examples/overlay.json"));o.gate={timeout_minutes:7};fs.writeFileSync(process.argv[1],JSON.stringify(o))' "$T/overlay.json"
node bin/repo-standards.mjs apply --target "$R" --overlay "$T/overlay.json" --version 0.8.21 >/dev/null
# Stop in the first step: the real local entry point must enforce its limit even before setup completes.
cat > "$R/scripts/agent/setup.sh" <<'STEP'
#!/bin/sh
[ "${FAST:-}" != 1 ] || exit 1
exec node hang.mjs
STEP
chmod +x "$R/scripts/agent/setup.sh"
cat > "$R/hang.mjs" <<'JS'
import { writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
// A descendant that ignores TERM must still die with the active step's process group.
const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'], {stdio:'inherit'});
writeFileSync(process.env.GROUP_FILE, String(process.pid));
setInterval(()=>{},1000);
JS
git -C "$R" add -A && git -C "$R" commit -qm fixture
git -C "$R" checkout -q -b feature; echo feature > "$R/note.txt"; git -C "$R" add note.txt; git -C "$R" commit -qm feature
export GATE_LOCK_DIR=$T/lock GROUP_FILE=$T/group
top=$(git -C "$R" rev-parse --show-toplevel)
workflow=$R/.github/workflows/std-gate.yml
has() { grep -qF -e "$1" "$T/$2.log"; }
waitfor() { local i; for i in $(seq 1 "${3:-60}"); do has "$1" "$2" && return 0; sleep 0.1; done; return 1; }
start() { local name=$1; shift; (cd "$R" && exec env "$@" node scripts/agent/gate.mjs local --base main) > "$T/$name.log" 2>&1 & GATE=$!; }
# An outer watchdog is essential on the old implementation: report the missing timeout, never leave a hung test.
finish() { local i; for i in $(seq 1 60); do kill -0 "$GATE" 2>/dev/null || break; sleep 0.1; done; kill -TERM "$GATE" 2>/dev/null; wait "$GATE" 2>/dev/null; }
# Applied timeout, absent workflow/setting, extension-only override validation, and a very large extension (no Node timer overflow).
start applied FAST=1; wait "$GATE"
cp "$workflow" "$T/workflow"
rm "$workflow"; start absent FAST=1; wait "$GATE"
cp "$T/workflow" "$workflow"; sed '/^    timeout-minutes:/d' "$workflow" > "$T/no-setting"; cp "$T/no-setting" "$workflow"
start no-setting FAST=1; wait "$GATE"
cp "$T/workflow" "$workflow"
limits=1
for value in 0 -1 10 nope Infinity NaN ''; do
  start invalid FAST=1 GATE_LOCAL_TIMEOUT_MIN="$value"; wait "$GATE"; x=$?
  if [ "$x" -eq 0 ] || ! has 'GATE_LOCAL_TIMEOUT_MIN must be finite minutes at least 10.5' invalid || has 'setup --check starting' invalid; then limits=0; fi
done
start extended FAST=1 GATE_LOCAL_TIMEOUT_MIN=11; wait "$GATE"
start huge FAST=1 GATE_LOCAL_TIMEOUT_MIN=100000; wait "$GATE"
if [ "$limits" -eq 1 ] && has 'wall-clock limit 10.5 min' applied && has 'wall-clock limit 45 min' absent && has 'wall-clock limit 45 min' no-setting && has 'wall-clock limit 11 min' extended && ! has 'TimeoutOverflowWarning' huge; then ok gate-local-limit-from-apply
else fail gate-local-limit-from-apply "validation=$limits; $(cat "$T/applied.log" "$T/absent.log" "$T/no-setting.log" "$T/extended.log" "$T/huge.log")"; fi
# A small rendered timeout keeps the real timer test fast; the override may extend it fractionally, never shorten it.
sed 's/^    timeout-minutes: .*/    timeout-minutes: 0.02/' "$T/workflow" > "$workflow"
# A clean timed-out checkout must not qualify for the pass record that pr.sh ready reads.
git -C "$R" add .github/workflows/std-gate.yml; git -C "$R" commit -qm 'small fixture timeout'
rec=$R/$(git -C "$R" rev-parse --git-path std-local-gate)
echo stale > "$rec"
start holder GATE_LOCAL_TIMEOUT_MIN=0.08; FIRST=$GATE
waitfor 'setup --check starting' holder
waitfor 'machine gate lock taken' holder
# Verify that the lock records the git worktree path, and that BOTH waiting and busy messages carry every holder field.
start queued FAST=1 GATE_LOCK_WAIT_S=8; SECOND=$GATE
waitfor 'queued behind another local gate' queued 20
start busy FAST=1 GATE_LOCK_WAIT_S=0.1; wait "$GATE"; bx=$?
record_ok=$(node -e 'const fs=require("fs"),cp=require("child_process"),h=JSON.parse(fs.readFileSync(process.argv[1]));console.log(h.worktree===cp.execFileSync("git",["-C",process.argv[2],"rev-parse","--show-toplevel"],{encoding:"utf8"}).trim()?"yes":"no")' "$T/lock/gate.lock" "$R" 2>/dev/null)
if [ "$record_ok" = yes ] && [ "$bx" -eq 75 ] && grep -qE 'since .*age [0-9]+\.[0-9]+ min' "$T/queued.log" && grep -qE 'lock busy:.*since .*age [0-9]+\.[0-9]+ min' "$T/busy.log" && has "worktree $top" queued && has "worktree $top" busy; then ok gate-lock-holder-age
else fail gate-lock-holder-age "record=$record_ok busy=$bx; $(cat "$T/queued.log" "$T/busy.log")"; fi
GATE=$FIRST; finish; hx=$?
GATE=$SECOND; finish; qx=$?
group=$(cat "$GROUP_FILE" 2>/dev/null || echo 0)
# kill(0) checks the whole process group, including a descendant left after its leader exited.
gone=0
for i in $(seq 1 30); do
  if ! node -e 'try{process.kill(-Number(process.argv[1]),0)}catch{process.exit(1)}' "$group"; then gone=1; break; fi
  sleep 0.1
done
if [ "$hx" -eq 124 ] && [ "$gone" -eq 1 ] && grep -qE '^local gate [0-9a-f]+: TIMEOUT \(exceeded 0.08 min during setup --check\)$' "$T/holder.log" && [ ! -e "$rec" ]; then ok gate-local-wall-clock
else fail gate-local-wall-clock "exit=$hx group-gone=$gone pass-record=$([ -e "$rec" ] && echo yes || echo no); $(cat "$T/holder.log")"; fi
if [ "$hx" -eq 124 ] && has 'queued behind another local gate' queued && has 'machine gate lock taken' queued && has 'setup --check starting' queued && [ ! -e "$T/lock/gate.lock" ]; then ok gate-lock-released-on-timeout
else fail gate-lock-released-on-timeout "holder=$hx queued=$qx; $(cat "$T/queued.log")"; fi
done_cases
