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

# Release honours the takeover guard: a gate stopping while another gate is mid-takeover waits for it to finish, then
# leaves the lock that takeover put in place (it never checks ownership and then unlinks a replaced lock).
rm -f "$LOCK"
start rel
waitfor 'setup --check starting' rel 50
: > "$LOCK.takeover"
kill -TERM "$GATE"; sleep 1
waiting=no; grep -q '^local gate [0-9a-f]*:' "$T/rel.log" || waiting=yes
plant 1 elsewhere ""; rm -f "$LOCK.takeover"
wait "$GATE" 2>/dev/null
if [ "$waiting" = yes ] && grep -q '"host":"elsewhere"' "$LOCK" && grep -q '^local gate [0-9a-f]*:' "$T/rel.log"; then ok gate-lock-release-waits-for-takeover
else fail gate-lock-release-waits-for-takeover "waiting=$waiting; $(cat "$T/rel.log"; cat "$LOCK" 2>&1)"; fi
rm -f "$LOCK"

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

# GATE_LOCK_WAIT_S bounds the wait itself: a lock freed after the limit but before the next poll is not taken.
sleep 300 & HOLDER=$!; PIDS+=("$HOLDER")
plant "$HOLDER"
start exact GATE_LOCK_WAIT_S=0.5
waitfor 'queued behind another local gate' exact
sleep 1.2; rm -f "$LOCK"
for i in $(seq 1 40); do kill -0 "$GATE" 2>/dev/null || break; seen 'setup --check starting' exact && break; sleep 0.1; done
stopgate; code=$?
if [ "$code" -ne 0 ] && seen 'lock busy' exact && ! seen 'setup --check starting' exact; then ok gate-lock-wait-limit-exact
else fail gate-lock-wait-limit-exact "exit=$code; $(cat "$T/exact.log")"; fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$LOCK"

# A takeover replaces only the holder it judged stale: while another gate is mid-takeover (its guard), this gate waits,
# and once that gate's lock is in place it is waited on, never moved aside.
sleep 0.01 & DEAD=$!; wait "$DEAD"
plant "$DEAD"; : > "$LOCK.takeover"
start verify
waitfor "queued behind another local gate: pid $DEAD" verify 60
sleep 300 & LIVE=$!; PIDS+=("$LIVE")
plant "$LIVE"; rm -f "$LOCK.takeover"
if waitfor "queued behind another local gate: pid $LIVE" verify 60 && ! seen 'took over a stale machine gate lock' verify && grep -q "\"pid\":$LIVE," "$LOCK"; then ok gate-lock-takeover-verifies-holder
else fail gate-lock-takeover-verifies-holder "$(cat "$T/verify.log"; cat "$LOCK" 2>&1)"; fi
stopgate
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; rm -f "$LOCK" "$LOCK.takeover"

# A lock file this user cannot read is an unreadable holder, waited on like any other (root reads every file).
if [ "$(id -u)" != 0 ]; then
  plant 1 elsewhere ""; chmod 000 "$LOCK"
  start unread GATE_LOCK_WAIT_S=0.5
  wait "$GATE"; code=$?
  if [ "$code" -ne 0 ] && seen 'lock busy: another local gate holds the machine gate lock (an unreadable holder)' unread && ! seen 'setup --check starting' unread; then ok gate-lock-unreadable-holder
  else fail gate-lock-unreadable-holder "exit=$code; $(cat "$T/unread.log")"; fi
  rm -f "$LOCK"
else echo "skip gate-lock-unreadable-holder (platform: root reads every file)"; fi

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

# The lock directory is shared by every user: made 0777 (not sticky) whatever the creator's umask, never through a symlink.
MOD=$PWD/template/scripts/agent/gate-lock.mjs
cat > "$T/take.mjs" <<'JS'
const { machineLock } = await import(process.argv[2]);
const logs = [];
const release = await machineLock({ env: { GATE_LOCK_DIR: process.argv[3] }, repo: "take@main", log: (l) => logs.push(l) });
console.log(logs.join("\n"));
if (process.argv[4] === "die") process.kill(process.pid, "SIGKILL"); // dies holding the lock
release();
JS
mode() { node -p '(require("fs").statSync(process.argv[1]).mode & 0o7777).toString(8)' "$1"; }
mkdir "$T/shared"
out=$( umask 077; node "$T/take.mjs" "$MOD" "$T/shared/lock" 2>&1 )
if [ "$(mode "$T/shared/lock")" = 777 ] && printf '%s' "$out" | grep -q 'machine gate lock taken' && [ -z "$(ls "$T/shared" | grep -v '^lock$')" ]; then ok gate-lock-shared-dir
else fail gate-lock-shared-dir "mode=$(mode "$T/shared/lock") left=$(ls "$T/shared") :: $out"; fi
out=$( umask 077; node "$T/take.mjs" "$MOD" "$T/rd" die 2>&1 )
if [ "$(mode "$T/rd/gate.lock")" = 644 ]; then ok gate-lock-file-readable
else fail gate-lock-file-readable "mode=$(mode "$T/rd/gate.lock") :: $out"; fi
mkdir "$T/private" && chmod 700 "$T/private" && ln -s "$T/private" "$T/linked"
out=$(node "$T/take.mjs" "$MOD" "$T/linked" 2>&1)
if printf '%s' "$out" | grep -q 'machine gate lock unavailable.*not a real directory' && [ "$(mode "$T/private")" = 700 ] && [ ! -e "$T/private/gate.lock" ]; then ok gate-lock-dir-symlink
else fail gate-lock-dir-symlink "target mode=$(mode "$T/private") files=$(ls "$T/private") :: $out"; fi
# Another user, under umask 077, makes the directory and dies holding the lock; this user reads and takes it over. Needs a second user (CI has one).
if [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && id nobody >/dev/null 2>&1; then
  X=$(mktemp -d /tmp/gate-lock-xu.XXXXXX); chmod 1777 "$X"; cp "$MOD" "$T/take.mjs" "$X/"; chmod 644 "$X"/*.mjs
  sudo -n -u nobody env -i PATH="$PATH" sh -c 'umask 077; exec "$0" "$@"' "$(command -v node)" "$X/take.mjs" "$X/gate-lock.mjs" "$X/lock" die > "$T/xu-other.log" 2>&1
  owner=$(node -p 'require("os").userInfo().uid === require("fs").statSync(process.argv[1]).uid ? "me" : "other"' "$X/lock/gate.lock" 2>&1)
  out=$(node "$T/take.mjs" "$MOD" "$X/lock" 2>&1)
  if [ "$owner" = other ] && printf '%s' "$out" | grep -q 'took over a stale machine gate lock from pid [0-9]* (nobody on .*is no longer running' && printf '%s' "$out" | grep -q 'machine gate lock taken'; then ok gate-lock-cross-user-takeover
  else fail gate-lock-cross-user-takeover "owner=$owner other: $(cat "$T/xu-other.log") :: $out"; fi
  sudo -n rm -rf "$X"
else echo "skip gate-lock-cross-user-takeover (platform: needs a second user through passwordless sudo)"; fi
done_cases
