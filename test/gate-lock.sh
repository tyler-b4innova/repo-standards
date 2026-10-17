#!/usr/bin/env bash
# One heavy local gate per machine: `gate.mjs local` waits for, names, and takes over (when stale) the machine gate lock.
# Each case uses its own lock directory and starts and stops only the processes it records.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_ACTIONS GATE_LOCK GATE_LOCK_WAIT_S GATE_LOCK_SLOTS GITHUB_EVENT_PATH GITHUB_EVENT_NAME
T=$(mktemp -d)
# Only this script's own unreaped background jobs: a PID already waited for (and possibly reused) is never signalled.
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
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
start() { local name=$1; shift; (cd "$R" && exec env "$@" node scripts/agent/gate.mjs local --base main) > "$T/$name.log" 2>&1 & GATE=$!; }
seen() { grep -qF -e "$1" "$T/$2.log"; }
waitfor() { local i; for i in $(seq 1 "${3:-100}"); do seen "$1" "$2" && return 0; sleep 0.1; done; return 1; }
stopgate() { kill -TERM "$GATE" 2>/dev/null; wait "$GATE" 2>/dev/null; }
plant() { mkdir -p "$T/lock"; printf '{"pid":%s,"user":"someone","host":"%s","ns":"%s","repo":"other@main","started":"2026-01-01T00:00:00.000Z"}\n' "$1" "${2:-$host}" "${3:-$ns}" > "$LOCK"; }

# Two permits let a gate run beside a live holder, and release only its own permit.
sleep 300 & HOLDER=$!
plant "$HOLDER"
start slots GATE_LOCK_SLOTS=2 GATE_LOCK_WAIT_S=1
if waitfor 'setup --check starting' slots 50 && seen "machine gate lock taken (permit 2 of 2: $LOCK.2)" slots \
  && grep -q "\"pid\":$GATE," "$LOCK.2" && grep -q "\"pid\":$HOLDER," "$LOCK"; then ok gate-lock-slots-run-together
else fail gate-lock-slots-run-together "$(cat "$T/slots.log")"; fi
stopgate
if [ ! -e "$LOCK.2" ] && grep -q "\"pid\":$HOLDER," "$LOCK"; then ok gate-lock-slots-run-together
else fail gate-lock-slots-run-together 'release changed the other permit or left its own'; fi

# When both permits are held, both holder descriptions appear while queued and at the deadline.
sleep 300 & SECOND=$!
LOCK="$LOCK.2" plant "$SECOND"
start full GATE_LOCK_SLOTS=2 GATE_LOCK_WAIT_S=1
wait "$GATE"; code=$?
if [ "$code" -eq 75 ] && grep -q "queued behind 2 local gates: pid $HOLDER .*; pid $SECOND (" "$T/full.log" && grep -q "lock busy:.*pid $HOLDER .*; pid $SECOND (" "$T/full.log" \
  && seen 'not run (machine gate lock busy)' full && ! seen 'setup --check starting' full \
  && grep -q "\"pid\":$HOLDER," "$LOCK" && grep -q "\"pid\":$SECOND," "$LOCK.2"; then ok gate-lock-slots-full-waits
else fail gate-lock-slots-full-waits "exit=$code; $(cat "$T/full.log")"; fi
kill "$SECOND" 2>/dev/null; wait "$SECOND" 2>/dev/null

# Permit 2 uses the same stale takeover and its own guard, leaving the live first permit alone.
# A PID beyond the kernel PID range cannot be recycled by another session on a busy shared host.
DEAD=2147483647
LOCK="$LOCK.2" plant "$DEAD"
start slotstale GATE_LOCK_SLOTS=2 GATE_LOCK_WAIT_S=1
if waitfor 'setup --check starting' slotstale 50 && seen "took over a stale machine gate lock from pid $DEAD" slotstale \
  && seen "machine gate lock taken (permit 2 of 2: $LOCK.2)" slotstale && grep -q "\"pid\":$GATE," "$LOCK.2" \
  && grep -q "\"pid\":$HOLDER," "$LOCK"; then ok gate-lock-slots-stale-permit
else fail gate-lock-slots-stale-permit "$(cat "$T/slotstale.log")"; fi
stopgate
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$LOCK" "$LOCK.2"

# Invalid counts fail before any step, through the same entry point as invalid wait values.
for slots in 0 abc; do
  start invalid GATE_LOCK_SLOTS="$slots" GATE_LOCK_WAIT_S=0
  waitfor 'GATE_LOCK_SLOTS must be an integer, 1 or more' invalid 20
  stopgate; code=$?
  if [ "$code" -ne 0 ] && seen 'GATE_LOCK_SLOTS must be an integer, 1 or more' invalid && ! seen 'setup --check starting' invalid; then ok gate-lock-slots-invalid
  else fail gate-lock-slots-invalid "slots=$slots exit=$code; $(cat "$T/invalid.log")"; fi
done

# A live holder: the gate waits, names it, and starts only once the holder's lock is gone.
sleep 300 & HOLDER=$!
plant "$HOLDER"
start wait
if waitfor "queued behind another local gate: pid $HOLDER (someone on $host, other@main" wait && sleep 2 && ! seen 'setup --check starting' wait && seen 'do not stop it or the holder' wait; then ok gate-lock-waits-names-holder
else fail gate-lock-waits-names-holder "$(cat "$T/wait.log")"; fi
# Age comes from the start timestamp, not the fresh heartbeat; keep the existing holder fields in both messages.
node - "$LOCK" <<'JS'
const fs=require('fs'),f=process.argv[2],h=JSON.parse(fs.readFileSync(f));
h.started=new Date(Date.now()-120000).toISOString();h.worktree='/fixture/worktree';fs.writeFileSync(f,JSON.stringify(h));
JS
if waitfor 'worktree /fixture/worktree, age 2.' wait 40; then ok gate-lock-holder-age
else fail gate-lock-holder-age "$(cat "$T/wait.log")"; fi
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
# A PID beyond the kernel PID range cannot be recycled by another session on a busy shared host.
DEAD=2147483647
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
sleep 300 & REUSED=$!
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
if [ "$code" -eq 75 ] && seen 'lock busy: another local gate holds the machine gate lock (pid 1 (someone on elsewhere' fresh && seen 'not a gate result: wait, then run the local gate again' fresh \
  && grep -q '^local gate [0-9a-f]*: not run (machine gate lock busy)' "$T/fresh.log" && ! grep -q '=undefined' "$T/fresh.log" && ! seen 'setup --check starting' fresh && grep -q '"host":"elsewhere"' "$LOCK"; then ok gate-lock-wait-limit
else fail gate-lock-wait-limit "exit=$code; $(cat "$T/fresh.log")"; fi
rm -f "$LOCK"

# GATE_LOCK_WAIT_S bounds the wait itself: a lock freed after the limit but before the next poll is not taken.
sleep 300 & HOLDER=$!
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
# A PID beyond the kernel PID range cannot be recycled by another session on a busy shared host.
DEAD=2147483647
plant "$DEAD"; : > "$LOCK.takeover"
start verify
waitfor "queued behind another local gate: pid $DEAD" verify 60
sleep 300 & LIVE=$!
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

# The shared directory is not sticky, so anyone can plant a symlink or a FIFO at the lock's name: such a name is an
# unreadable holder judged by its own mtime, taken over by renaming over the name, and never followed or blocked on.
fmode() { node -p 'const s=require("fs").statSync(process.argv[1]); (s.mode & 0o7777).toString(8)+" "+new Date(s.mtimeMs).toISOString().slice(0,4)' "$1"; }
printf 'not a lock\n' > "$T/victim"; chmod 600 "$T/victim"; before=$(fmode "$T/victim")
rm -f "$LOCK"; ln -s "$T/victim" "$LOCK"; touch -h -t 202001010000 "$LOCK"
start symlink
if waitfor 'took over a stale machine gate lock from an unreadable holder' symlink && waitfor 'setup --check starting' symlink 50 \
  && [ -f "$LOCK" ] && [ ! -L "$LOCK" ] && grep -q "\"pid\":$GATE," "$LOCK" && [ "$(cat "$T/victim")" = "not a lock" ] && [ "$(fmode "$T/victim")" = "$before" ]; then ok gate-lock-symlink-at-lock-name
else fail gate-lock-symlink-at-lock-name "victim=$(fmode "$T/victim") was $before; $(ls -la "$T/lock"; cat "$T/symlink.log")"; fi
stopgate; rm -f "$LOCK"
mkfifo "$LOCK"; touch -t 202001010000 "$LOCK"
start fifo
if waitfor 'took over a stale machine gate lock from an unreadable holder' fifo && waitfor 'setup --check starting' fifo 50 && [ -f "$LOCK" ] && [ ! -p "$LOCK" ]; then ok gate-lock-fifo-at-lock-name
else fail gate-lock-fifo-at-lock-name "$(ls -la "$T/lock"; cat "$T/fifo.log")"; fi
[ -p "$LOCK" ] && { exec 3>"$LOCK"; exec 3>&-; } # an old gate blocked reading the FIFO gets EOF, so it can be stopped
stopgate; rm -f "$LOCK"
# The heartbeat touches only through the descriptor it verified: a holder's lock swapped for a symlink to a copy of its
# own record (as another user could plant) is never touched through the symlink.
start beatlink
waitfor 'machine gate lock taken' beatlink 50
cp "$LOCK" "$T/record-copy"; touch -t 202001010000 "$T/record-copy"; rm -f "$LOCK"; ln -s "$T/record-copy" "$LOCK"
sleep 11
if [ "$(fmode "$T/record-copy" | cut -d' ' -f2)" = 2020 ]; then ok gate-lock-heartbeat-no-follow
else fail gate-lock-heartbeat-no-follow "copy touched: $(fmode "$T/record-copy"); $(cat "$T/beatlink.log")"; fi
stopgate; rm -f "$LOCK"

MOD=$PWD/template/scripts/agent/gate-lock.mjs
# A takeover guard left by a gate that died holding it (untouched for 5 s) is evicted, and the stale lock taken over.
# A PID beyond the kernel PID range cannot be recycled by another session on a busy shared host.
DEAD=2147483647
plant "$DEAD"; : > "$LOCK.takeover"; touch -t 202001010000 "$LOCK.takeover"
start oldguard
if waitfor "took over a stale machine gate lock from pid $DEAD" oldguard && waitfor 'setup --check starting' oldguard 50 && [ -z "$(ls "$T/lock" | grep -v '^gate.lock$')" ]; then ok gate-lock-stale-guard
else fail gate-lock-stale-guard "$(ls -la "$T/lock"; cat "$T/oldguard.log")"; fi
stopgate; rm -f "$LOCK"
# The takeover guard is waited for only until GATE_LOCK_WAIT_S: a guard freed after the deadline is not used to take over.
cat > "$T/deadline.mjs" <<'JS'
import { spawn } from "node:child_process";
const { machineLock } = await import(process.argv[2]);
const dir = process.argv[3];
spawn("sh", ["-c", `sleep 0.3; rm -f "${dir}/gate.lock.takeover"`], { stdio: "ignore" });
try { await machineLock({ env: { GATE_LOCK_DIR: dir, GATE_LOCK_WAIT_S: "0.1" }, repo: "deadline@main", log: () => {} }); console.log("took"); }
catch (e) { console.log(e.message.startsWith("lock busy") ? "busy" : e.message); }
JS
mkdir -p "$T/dl"; printf '{"pid":%s,"user":"someone","host":"%s","ns":"%s","repo":"other@main","started":"s"}\n' "$DEAD" "$host" "$ns" > "$T/dl/gate.lock"; : > "$T/dl/gate.lock.takeover"
out=$(node "$T/deadline.mjs" "$MOD" "$T/dl" 2>&1)
if [ "$out" = busy ]; then ok gate-lock-guard-wait-deadline; else fail gate-lock-guard-wait-deadline "$out"; fi

# A directory at the lock's name (anyone can make one) is an unreadable holder: once stale it is moved aside and the lock
# created, never a queue that lasts forever.
rm -f "$LOCK"; mkdir "$LOCK"; touch -t 202001010000 "$LOCK"
start dirlock
if waitfor 'took over a stale machine gate lock from an unreadable holder' dirlock && waitfor 'setup --check starting' dirlock 50 && [ -f "$LOCK" ] && grep -q "\"pid\":$GATE," "$LOCK"; then ok gate-lock-dir-at-lock-name
else fail gate-lock-dir-at-lock-name "$(ls -la "$T/lock"; cat "$T/dirlock.log")"; fi
stopgate; rm -rf "$LOCK"
# The same directory takeover applies to permit 2, using its guard while permit 1 remains live.
sleep 300 & HOLDER=$!
plant "$HOLDER"
mkdir "$LOCK.2"; touch -t 202001010000 "$LOCK.2"
start dirslot GATE_LOCK_SLOTS=2 GATE_LOCK_WAIT_S=1
if waitfor 'setup --check starting' dirslot 50 && seen 'took over a stale machine gate lock from an unreadable holder' dirslot \
  && seen "machine gate lock taken (permit 2 of 2: $LOCK.2)" dirslot && [ -f "$LOCK.2" ] \
  && grep -q "\"pid\":$GATE," "$LOCK.2" && grep -q "\"pid\":$HOLDER," "$LOCK"; then ok gate-lock-dir-at-lock-name
else fail gate-lock-dir-at-lock-name "$(ls -la "$T/lock"; cat "$T/dirslot.log")"; fi
stopgate
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$LOCK"
# A lock directory whose parent is missing is not created (its parent would carry this user's umask): the gate warns and
# runs without the lock.
start noparent GATE_LOCK_DIR="$T/missing/lock"
if waitfor 'setup --check starting' noparent 50 && seen 'machine gate lock unavailable' noparent && seen 'does not exist' noparent && [ ! -e "$T/missing" ]; then ok gate-lock-dir-parent-missing
else fail gate-lock-dir-parent-missing "$(ls -la "$T"; cat "$T/noparent.log")"; fi
stopgate

# An existing sticky lock directory (mode 1777, like /tmp itself) is refused: another user could not take over a stale
# lock in it. The gate warns and runs without the lock.
mkdir "$T/sticky" && chmod 1777 "$T/sticky"
start sticky GATE_LOCK_DIR="$T/sticky"
if waitfor 'setup --check starting' sticky 50 && seen 'machine gate lock unavailable' sticky && seen 'sticky (mode 1777)' sticky && [ ! -e "$T/sticky/gate.lock" ]; then ok gate-lock-sticky-dir-refused
else fail gate-lock-sticky-dir-refused "$(ls -la "$T/sticky"; cat "$T/sticky.log")"; fi
stopgate

# Off under GitHub Actions and with GATE_LOCK=off: no lock file is made and a planted holder is ignored.
sleep 300 & HOLDER=$!
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
  # Through the real gate, in an existing (pre-created, non-sticky) lock directory: another user dies holding the lock.
  mkdir "$X/pre" && chmod 0777 "$X/pre"
  sudo -n -u nobody env -i PATH="$PATH" sh -c 'umask 077; exec "$0" "$@"' "$(command -v node)" "$X/take.mjs" "$X/gate-lock.mjs" "$X/pre" die > "$T/xu-other2.log" 2>&1
  start xu GATE_LOCK_DIR="$X/pre"
  if waitfor 'took over a stale machine gate lock from pid' xu && seen '(nobody on' xu && waitfor 'setup --check starting' xu 50 && grep -q "\"pid\":$GATE," "$X/pre/gate.lock"; then ok gate-lock-cross-user-takeover
  else fail gate-lock-cross-user-takeover "entry point: $(cat "$T/xu-other2.log"; cat "$T/xu.log")"; fi
  stopgate
  sudo -n rm -rf "$X"
else echo "skip gate-lock-cross-user-takeover (platform: needs a second user through passwordless sudo)"; fi
done_cases
