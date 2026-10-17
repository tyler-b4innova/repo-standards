// A bounded number of heavy local gates per machine. `gate.mjs local` takes a permit before its first step and holds
// it to the end, so concurrent sessions (any repository, worktree or user) queue once the machine is full. Each permit
// is a file created atomically in a shared directory; it names its holder. A holder whose PID is gone
// (checked on this host and PID namespace), or whose heartbeat stopped, is stale and is taken over with a message.
// Off under GITHUB_ACTIONS (runners are isolated) and with GATE_LOCK=off. Any user can delete a live lock in the shared
// directory: it coordinates the machine's trusted users and is not a security boundary.
//   GATE_LOCK_DIR     shared directory (default /tmp/std-gate-lock; the system temp directory on Windows): a real
//                     directory (not a symlink) every user of the gate can write; created mode 0777 when missing
//   GATE_LOCK_SLOTS   integer >= 1 (default 1); set the same count for every user on a machine, to fit its memory.
//                     Permit 1 is gate.lock; further permits are gate.lock.<i>, each with its own .takeover guard.
//                     Mixed counts share the lower permits; a smaller count competes only for those permits.
//   GATE_LOCK_WAIT_S  give up after this many seconds with "lock busy" and exit 75, not a gate result (default: wait
//                     until the lock is free)
import { randomBytes } from "node:crypto";
import { accessSync, closeSync, constants, fchmodSync, fstatSync, futimesSync, linkSync, lstatSync, mkdtempSync, openSync, readFileSync, readlinkSync, renameSync, rmdirSync, unlinkSync, writeSync } from "node:fs";
import { hostname, tmpdir, userInfo } from "node:os";
import { dirname, join } from "node:path";

const BEAT_MS = 10_000; // the holder touches the lock this often
const STALE_MS = 120_000; // a lock not touched for this long is stale, whatever its PID
const POLL_MS = 2_000;
const REPORT_MS = 60_000;
const GUARD_STALE_MS = 5_000; // the takeover guard is held for a few file operations; older than this, its holder died
const GUARD_WAIT_MS = 1_000;

// Every name in the shared directory is handled as a name: anyone can plant a symlink or a FIFO there (it is not sticky,
// so the kernel's protected_symlinks/protected_regular do not apply). Opens never follow a symlink or block, files are
// created exclusively, the heartbeat touches through the descriptor it verified, and a takeover renames over the name.
const { O_RDONLY, O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW = 0, O_NONBLOCK = 0 } = constants;
const pidNamespace = () => { try { return readlinkSync("/proc/self/ns/pid"); } catch { return ""; } };
const user = () => { try { return userInfo().username; } catch { return String(process.getuid?.() ?? "unknown"); } };
// The lock's text and the mtime of the name itself. Anything there that is not a regular file this user can read (a
// lock from an older gate under a strict umask, a planted symlink or FIFO) is an unreadable holder, judged by its mtime.
const read = (file) => {
  let fd;
  try { fd = openSync(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); } catch (e) {
    if (e.code === "ENOENT") return null;
    if (!["EACCES", "EPERM", "ELOOP", "EMLINK", "ENXIO", "EOPNOTSUPP"].includes(e.code)) throw e;
    try { return { text: "", mtime: lstatSync(file).mtimeMs }; } catch (e2) { if (e2.code === "ENOENT") return null; throw e2; }
  }
  try { const st = fstatSync(fd); return { text: st.isFile() ? readFileSync(fd, "utf8") : "", mtime: st.mtimeMs }; } finally { closeSync(fd); }
};
// The holder record, readable by every user whatever the creator's umask (set through the descriptor, not the path).
function writeRecord(path, text) {
  const fd = openSync(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644);
  try { if (process.platform !== "win32") fchmodSync(fd, 0o644); writeSync(fd, text); } finally { closeSync(fd); }
}
const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
// Removes the entry at `name` only if it is still `doomed` once moved aside under a private name: an entry that replaced
// it meanwhile (another gate's) is linked back, never deleted. There is no atomic compare-and-unlink, so this is the
// check: judge what was actually moved, not what was seen before.
function removeIf(name, doomed) {
  const aside = `${name}.aside-${randomBytes(8).toString("hex")}`;
  try { renameSync(name, aside); } catch { return; }
  try { if (!doomed(lstatSync(aside))) linkSync(aside, name); } catch {} finally { try { unlinkSync(aside); } catch {} }
}
// Runs fn under the takeover guard and returns true, or false if the guard stayed busy for waitMs. Takeovers and
// releases both run under it, so a release never checks its ownership and then unlinks a lock a takeover replaced in
// between, and a holder a takeover has verified cannot be released (and the lock taken by a new gate) before it is
// replaced. A guard untouched for GUARD_STALE_MS was left by a gate that died holding it and is removed.
function guarded(guard, fn, waitMs = GUARD_WAIT_MS) {
  const until = Date.now() + waitMs;
  for (;;) {
    let fd;
    try { fd = openSync(guard, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644); } catch (e) {
      if (e.code !== "EEXIST") throw e;
      try { if (Date.now() - lstatSync(guard).mtimeMs > GUARD_STALE_MS) removeIf(guard, (st) => Date.now() - st.mtimeMs > GUARD_STALE_MS); } catch {}
      if (Date.now() >= until) return false;
      pause(Math.min(20, Math.max(1, until - Date.now())));
      continue;
    }
    let own;
    try { own = fstatSync(fd); } finally { closeSync(fd); }
    try { fn(); return true; } finally { removeIf(guard, (st) => st.ino === own.ino && st.dev === own.dev && st.mtimeMs === own.mtimeMs); }
  }
}
const parse = (text) => { try { const h = JSON.parse(text); return h && Number.isInteger(h.pid) ? h : null; } catch { return null; } };
const describe = (h) => (h ? `pid ${h.pid} (${h.user} on ${h.host}, ${h.repo}, since ${h.started})` : "an unreadable holder");

// The lock directory is shared by every user of this machine, so it is world-writable and not sticky (0777): any user
// can create the lock and take over a stale one. A missing directory is made under a private name, opened up through
// its own descriptor (never a path that could be swapped for a symlink), then renamed into place, so it never appears
// with the creator's umask. An existing path is used only if it is a real directory this user can write; nothing
// existing is ever chmodded.
const lstat = (p) => { try { return lstatSync(p); } catch (e) { if (e.code === "ENOENT") return null; throw e; } };
function sharedDir(dir) {
  if (!lstat(dir)) {
    // Its parent must already exist: one created here would carry this user's umask, which other users may not traverse.
    if (!lstat(dirname(dir))) throw new Error(`its parent ${dirname(dir)} does not exist; use a directory every user of the gate can reach`);
    const fresh = mkdtempSync(`${dir}.new-`);
    try {
      if (process.platform !== "win32") {
        const fd = openSync(fresh, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
        try { fchmodSync(fd, 0o777); } finally { closeSync(fd); }
      }
      renameSync(fresh, dir); // fails if another gate made it first (or it is not empty): use theirs
    } catch (e) { if (!["EEXIST", "ENOTEMPTY", "ENOTDIR", "EISDIR", "EPERM", "EACCES"].includes(e.code)) throw e; }
    finally { try { rmdirSync(fresh); } catch {} }
  }
  const st = lstat(dir);
  if (!st || st.isSymbolicLink() || !st.isDirectory()) throw new Error("not a real directory (a symlink, a file or missing)");
  // Sticky (as /tmp itself is), another user could not replace a dead holder's lock, so gates would queue behind it.
  if (process.platform !== "win32" && st.mode & 0o1000) throw new Error("sticky (mode 1777): another user could not take over a stale lock; use a non-sticky directory (mode 0777)");
  accessSync(dir, constants.W_OK | constants.X_OK);
}

// Why the holder is stale, or null while it may still be running. A running PID only proves nothing yet: after a
// holder is killed outright (SIGKILL), its PID may be reused, so a lock untouched for STALE_MS is stale regardless.
function staleness(h, mtime, now) {
  const quiet = now - mtime > STALE_MS ? `its heartbeat stopped ${Math.round((now - mtime) / 1000)}s ago` : null;
  if (!h) return quiet && "its lock file is unreadable and untouched";
  if (h.host === hostname() && h.ns === pidNamespace()) {
    try { process.kill(h.pid, 0); } catch (e) { if (e.code !== "EPERM") return `pid ${h.pid} is no longer running`; }
  }
  return quiet;
}

// Resolves to a release function (a no-op when the lock is off). `interrupted()` is polled while waiting, so a signal
// stops the wait; `log` receives each status line.
export async function machineLock({ env = process.env, repo, log = console.log, interrupted = () => false } = {}) {
  if (env.GITHUB_ACTIONS === "true") return () => {};
  if (env.GATE_LOCK === "off") { log("local: machine gate lock off (GATE_LOCK=off)"); return () => {}; }
  // Literally /tmp, never $TMPDIR: sessions with a per-user TMPDIR would each get a lock of their own.
  const dir = env.GATE_LOCK_DIR || (process.platform === "win32" ? join(tmpdir(), "std-gate-lock") : "/tmp/std-gate-lock");
  const wait = env.GATE_LOCK_WAIT_S === undefined ? Infinity : Number(env.GATE_LOCK_WAIT_S);
  if (!(wait >= 0)) throw new Error("GATE_LOCK_WAIT_S must be a number of seconds, 0 or more");
  const slots = env.GATE_LOCK_SLOTS === undefined ? 1 : Number(env.GATE_LOCK_SLOTS);
  if (!Number.isSafeInteger(slots) || slots < 1) throw new Error("GATE_LOCK_SLOTS must be an integer, 1 or more");
  const unavailable = (where, e) => {
    log(`::warning::local: machine gate lock unavailable (${where}: ${e.message}); this gate runs without it. Set GATE_LOCK_DIR to a real directory every user of the gate can write (mode 0777).`);
    return () => {};
  };
  try { sharedDir(dir); } catch (e) { return unavailable(dir, e); }
  const me = { pid: process.pid, user: user(), host: hostname(), ns: pidNamespace(), repo, started: new Date().toISOString() };
  const record = `${JSON.stringify(me)}\n`;
  const mine = (h) => h && h.pid === me.pid && h.started === me.started && h.host === me.host;
  const held = ({ file, guard, index }) => {
    log(`local: machine gate lock taken (permit ${index} of ${slots}: ${file})`);
    // Verifies and touches the same file through one descriptor: never a name re-opened, never through a symlink.
    const beat = setInterval(() => {
      let fd;
      try {
        fd = openSync(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (fstatSync(fd).isFile() && mine(parse(readFileSync(fd, "utf8")))) { const now = new Date(); futimesSync(fd, now, now); }
      } catch {} finally { if (fd !== undefined) try { closeSync(fd); } catch {} }
    }, BEAT_MS);
    beat.unref();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      clearInterval(beat);
      // Only this gate's own lock is removed: a lock taken over meanwhile belongs to someone else.
      const drop = () => { if (mine(parse(read(file)?.text ?? ""))) unlinkSync(file); };
      // Waits past the guard's staleness, so a guard left by a dead gate is cleared rather than bypassed.
      try { if (!guarded(guard, drop, GUARD_STALE_MS * 2)) drop(); } catch {}
    };
  };
  const start = Date.now(), deadline = start + wait * 1000;
  let reported = 0, said = "";
  retry: for (;;) {
    // Try every free permit before judging held ones: a stale lower permit need not delay a free higher one.
    const permits = [];
    for (let index = 1; index <= slots; index++) {
      const file = join(dir, index === 1 ? "gate.lock" : `gate.lock.${index}`);
      const permit = { file, guard: `${file}.takeover`, index };
      try { writeRecord(file, record); return held(permit); } catch (e) { if (e.code !== "EEXIST") return unavailable(file, e); }
      permits.push(permit);
    }
    const holders = [];
    for (const permit of permits) {
      const { file, guard } = permit;
      const seen = read(file);
      if (!seen) continue retry; // released between the two calls: try again at once
      const holder = parse(seen.text), why = staleness(holder, seen.mtime, Date.now());
      if (why) {
        // Under the guard, check the holder is still the one judged stale, then replace it in one rename: a holder that
        // changed or came back to life is judged again, never removed.
        // The guard is waited for only until the deadline: past it, the answer is lock busy.
        let outcome = "busy";
        const left = deadline - Date.now();
        if (left > 0) guarded(guard, () => {
          const again = read(file);
          if (!again || again.text !== seen.text || !staleness(parse(again.text), again.mtime, Date.now())) { outcome = "changed"; return; }
          if (lstat(file)?.isDirectory()) {
            // A rename cannot replace a directory with a file: move the verified directory aside, then create the lock
            // exclusively, so a gate that took the free name first keeps it.
            const aside = `${file}.aside-${randomBytes(8).toString("hex")}`;
            try { renameSync(file, aside); } catch { outcome = "failed"; return; }
            try { rmdirSync(aside); } catch {}
            try { writeRecord(file, record); outcome = "took"; } catch (e) { outcome = e.code === "EEXIST" ? "changed" : "failed"; }
            return;
          }
          const fresh = `${file}.new-${randomBytes(8).toString("hex")}`;
          let made = false;
          outcome = "failed";
          try { writeRecord(fresh, record); made = true; renameSync(fresh, file); outcome = "took"; } catch {}
          finally { if (made && outcome !== "took") try { unlinkSync(fresh); } catch {} }
        }, Math.min(GUARD_WAIT_MS, left));
        if (outcome === "took") { log(`local: took over a stale machine gate lock from ${describe(holder)}: ${why}`); return held(permit); }
        if (outcome === "changed") continue retry;
      }
      holders.push(holder);
    }
    const now = Date.now(), waited = Math.round((now - start) / 1000);
    const line = holders.map(describe).join("; ");
    const who = slots === 1 ? "another local gate" : `${holders.length} local gates`;
    if (now >= deadline) throw new Error(`lock busy: ${who} ${slots === 1 ? "holds" : "hold"} the machine gate lock (${line}) after ${waited}s (GATE_LOCK_WAIT_S); not a gate result: wait, then run the local gate again`);
    if (line !== said || now - reported >= REPORT_MS) {
      log(`local: queued behind ${who}: ${line}; waited ${waited}s. This gate is waiting its turn, not stuck: do not stop it or the holder.`);
      reported = now; said = line;
    }
    if (interrupted()) throw new Error("interrupted while waiting for the machine gate lock");
    // Never sleep past the deadline: GATE_LOCK_WAIT_S bounds the wait to within one acquisition attempt.
    await new Promise((r) => setTimeout(r, Math.min(POLL_MS, deadline - now)));
    if (interrupted()) throw new Error("interrupted while waiting for the machine gate lock");
  }
}
