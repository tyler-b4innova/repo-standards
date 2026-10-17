#!/usr/bin/env bash
# One heavy local gate per machine: `gate.mjs local` waits for, names, and takes over (when stale) the machine gate lock.
# Each case uses its own lock directory and starts and stops only the processes it records.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_ACTIONS GATE_LOCK GATE_LOCK_WAIT_S GITHUB_EVENT_PATH GITHUB_EVENT_NAME
T=$(mktemp -d) PIDS=()
trap 'for p in "${PIDS[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
R=$T/repo; mkdir "$R"
git -C "$R" init -q -b main
printf '{}\n' > "$R/standards.json"
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.11 >/dev/null
# The first step holds the lock long enough to observe it; the gate stops it (its process group) on a signal.
printf '#!/bin/sh\nsleep 30\n' > "$R/scripts/agent/setup.sh"; chmod +x "$R/scripts/agent/setup.sh"
git -C "$R" add -A && git -C "$R" commit -qm fixture
git -C "$R" checkout -q -b feature
printf 'x\n' > "$R/feature.txt" && git -C "$R" add feature.txt && git -C "$R" commit -qm feature
export GATE_LOCK_DIR=$T/lock LOCK=$T/lock/gate.lock
host=$(node -p 'require("os").hostname()') ns=$(node -e 'try{console.log(require("fs").readlinkSync("/proc/self/ns/pid"))}catch{console.log("")}')

# start <name> [env...]: the local gate in the background; its PID in $GATE.
start() { local name=$1; shift; (cd "$R" && exec env "$@" node scripts/agent/gate.mjs local --base main) > "$T/$name.log" 2>&1 & GATE=$!; PIDS+=("$GATE"); }
seen() { grep -qF -e "$1" "$T/$2.log"; }
waitfor() { local i; for i in $(seq 1 "${3:-100}"); do seen "$1" "$2" && return 0; sleep 0.1; done; return 1; }
stopgate() { kill -TERM "$GATE" 2>/dev/null; wait "$GATE" 2>/dev/null; }
plant() { mkdir -p "$T/lock"; printf '{"pid":%s,"user":"someone","host":"%s","ns":"%s","repo":"other@main","started":"2026-01-01T00:00:00.000Z"}\n' "$1" "${2:-$host}" "${3:-$ns}" > "$LOCK"; }

# A live holder: the gate waits, names it, and starts only once the holder's lock is gone.
sleep 300 & HOLDER=$!; PIDS+=("$HOLDER")
plant "$HOLDER"
start wait
if waitfor "queued behind another local gate: pid $HOLDER (someone on $host, other@main" wait && sleep 2 && ! seen 'setup --check starting' wait && seen 'do not stop it or the holder' wait; then ok gate-lock-waits-names-holder
else fail gate-lock-waits-names-holder "$(cat "$T/wait.log")"; fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$LOCK"
if waitfor 'setup --check starting' wait 50 && seen 'machine gate lock taken' wait && grep -q "\"pid\":$GATE," "$LOCK"; then ok gate-lock-starts-after-holder
else fail gate-lock-starts-after-holder "$(cat "$T/wait.log"; cat "$LOCK" 2>&1)"; fi
# SIGTERM while holding: the gate stops its step and removes its own lock.
held=no; grep -q "\"pid\":$GATE," "$LOCK" 2>/dev/null && held=yes
stopgate; code=$?
if [ "$held" = yes ] && [ ! -e "$LOCK" ] && seen 'interrupted by SIGTERM' wait; then ok gate-lock-released-on-signal
else fail gate-lock-released-on-signal "held=$held exit=$code; $(ls -la "$T/lock"; cat "$T/wait.log")"; fi

# A dead holder on this host and PID namespace: taken over at once, with a message.
sleep 0.01 & DEAD=$!; wait "$DEAD"
plant "$DEAD"
start stale
if waitfor "took over a stale machine gate lock from pid $DEAD" stale && seen 'is no longer running' stale && waitfor 'setup --check starting' stale 50; then ok gate-lock-stale-takeover
else fail gate-lock-stale-takeover "$(cat "$T/stale.log")"; fi
stopgate
# A holder whose PID cannot be checked from here (another host): judged by its heartbeat.
plant 1 elsewhere ""
touch -t 202601010000 "$LOCK"
start beat
if waitfor 'took over a stale machine gate lock from pid 1 (someone on elsewhere' beat && seen 'heartbeat stopped' beat; then ok gate-lock-stale-takeover
else fail gate-lock-stale-takeover "heartbeat: $(cat "$T/beat.log")"; fi
stopgate
# A running PID on this host whose lock stopped beating (a PID reused after its holder was killed outright): stale.
sleep 300 & REUSED=$!; PIDS+=("$REUSED")
plant "$REUSED"
touch -t 202601010000 "$LOCK"
start reused
if waitfor "took over a stale machine gate lock from pid $REUSED" reused && seen 'heartbeat stopped' reused && waitfor 'setup --check starting' reused 50; then ok gate-lock-stale-reused-pid
else fail gate-lock-stale-reused-pid "$(cat "$T/reused.log")"; fi
stopgate
kill "$REUSED" 2>/dev/null; wait "$REUSED" 2>/dev/null
plant 1 elsewhere ""
start fresh GATE_LOCK_WAIT_S=1
wait "$GATE"; code=$?
if [ "$code" -ne 0 ] && seen 'lock busy: another local gate holds the machine gate lock (pid 1 (someone on elsewhere' fresh && ! seen 'setup --check starting' fresh && grep -q '"host":"elsewhere"' "$LOCK"; then ok gate-lock-wait-limit
else fail gate-lock-wait-limit "exit=$code; $(cat "$T/fresh.log")"; fi
rm -f "$LOCK"

# Off under GitHub Actions and with GATE_LOCK=off: no lock file is made and a planted holder is ignored.
sleep 300 & HOLDER=$!; PIDS+=("$HOLDER")
plant "$HOLDER"
start actions GITHUB_ACTIONS=true
if waitfor 'setup --check starting' actions && ! seen 'machine gate lock' actions && grep -q "\"pid\":$HOLDER," "$LOCK"; then ok gate-lock-off-in-ci
else fail gate-lock-off-in-ci "$(cat "$T/actions.log")"; fi
stopgate
start optout GATE_LOCK=off
if waitfor 'setup --check starting' optout && seen 'machine gate lock off (GATE_LOCK=off)' optout && grep -q "\"pid\":$HOLDER," "$LOCK"; then ok gate-lock-opt-out
else fail gate-lock-opt-out "$(cat "$T/optout.log")"; fi
stopgate
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$LOCK"

# A gate never removes a lock that is no longer its own (taken over while it ran).
cat > "$T/own.mjs" <<'JS'
import { writeFileSync, existsSync } from "node:fs";
const { machineLock } = await import(process.argv[2]);
const release = await machineLock({ env: { GATE_LOCK_DIR: process.argv[3] }, repo: "own@main", log: () => {} });
writeFileSync(`${process.argv[3]}/gate.lock`, '{"pid":1,"user":"x","host":"elsewhere","ns":"","repo":"other","started":"s"}\n');
release();
console.log(existsSync(`${process.argv[3]}/gate.lock`) ? "kept" : "removed");
JS
out=$(node "$T/own.mjs" "$PWD/template/scripts/agent/gate-lock.mjs" "$T/own" 2>&1)
if [ "$out" = kept ]; then ok gate-lock-releases-only-its-own; else fail gate-lock-releases-only-its-own "$out"; fi
done_cases
