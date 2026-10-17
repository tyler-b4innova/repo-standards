// One heavy local gate per machine. `gate.mjs local` takes this lock before its first step and holds it to the end,
// so concurrent sessions (any repository, worktree or user) queue instead of overloading the machine together.
// The lock is a file created atomically (`wx`) in a shared directory; it names its holder. A holder whose PID is gone
// (checked on this host and PID namespace), or whose heartbeat stopped, is stale and is taken over with a message.
// Off under GITHUB_ACTIONS (runners are isolated) and with GATE_LOCK=off.
//   GATE_LOCK_DIR     shared directory (default /tmp/std-gate-lock; the system temp directory on Windows)
//   GATE_LOCK_WAIT_S  give up after this many seconds with "lock busy" (default: wait until the lock is free)
import { closeSync, mkdirSync, chmodSync, openSync, readFileSync, readlinkSync, renameSync, statSync, unlinkSync, utimesSync, writeSync } from "node:fs";
import { hostname, tmpdir, userInfo } from "node:os";
import { join } from "node:path";

const BEAT_MS = 10_000; // the holder touches the lock this often
const STALE_MS = 120_000; // a lock not touched for this long is stale, whatever its PID
const POLL_MS = 2_000;
const REPORT_MS = 60_000;

const pidNamespace = () => { try { return readlinkSync("/proc/self/ns/pid"); } catch { return ""; } };
const user = () => { try { return userInfo().username; } catch { return String(process.getuid?.() ?? "unknown"); } };
const read = (file) => { try { return { text: readFileSync(file, "utf8"), mtime: statSync(file).mtimeMs }; } catch (e) { if (e.code === "ENOENT") return null; throw e; } };
const parse = (text) => { try { const h = JSON.parse(text); return h && Number.isInteger(h.pid) ? h : null; } catch { return null; } };
const describe = (h) => (h ? `pid ${h.pid} (${h.user} on ${h.host}, ${h.repo}, since ${h.started})` : "an unreadable holder");

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
  const dir = env.GATE_LOCK_DIR || (process.platform === "win32" ? join(tmpdir(), "std-gate-lock") : "/tmp/std-gate-lock");
  const file = join(dir, "gate.lock");
  const wait = env.GATE_LOCK_WAIT_S === undefined ? Infinity : Number(env.GATE_LOCK_WAIT_S);
  if (!(wait >= 0)) throw new Error("GATE_LOCK_WAIT_S must be a number of seconds, 0 or more");
  try {
    mkdirSync(dir, { recursive: true });
    // Not sticky and writable by everyone, so another user can take over a stale lock. Only the creator can chmod.
    try { chmodSync(dir, 0o777); } catch {}
  } catch (e) {
    log(`::warning::local: machine gate lock unavailable (${dir}: ${e.code ?? e.message}); this gate runs without it. Set GATE_LOCK_DIR to a shared, writable directory.`);
    return () => {};
  }
  const me = { pid: process.pid, user: user(), host: hostname(), ns: pidNamespace(), repo, started: new Date().toISOString() };
  const mine = (h) => h && h.pid === me.pid && h.started === me.started && h.host === me.host;
  const start = Date.now();
  let reported = 0, said = "";
  for (;;) {
    let fd;
    try { fd = openSync(file, "wx", 0o666); } catch (e) {
      if (e.code !== "EEXIST") {
        log(`::warning::local: machine gate lock unavailable (${file}: ${e.code ?? e.message}); this gate runs without it. Set GATE_LOCK_DIR to a shared, writable directory.`);
        return () => {};
      }
    }
    if (fd !== undefined) {
      try { writeSync(fd, `${JSON.stringify(me)}\n`); } finally { closeSync(fd); }
      log(`local: machine gate lock taken (${file})`);
      const beat = setInterval(() => { const now = new Date(); try { if (mine(parse(read(file)?.text ?? ""))) utimesSync(file, now, now); } catch {} }, BEAT_MS);
      beat.unref();
      let released = false;
      return () => {
        if (released) return;
        released = true;
        clearInterval(beat);
        // Only this gate's own lock is removed: a lock taken over meanwhile belongs to someone else.
        try { if (mine(parse(read(file)?.text ?? ""))) unlinkSync(file); } catch {}
      };
    }
    const seen = read(file);
    if (!seen) continue; // released between the two calls: try again at once
    const holder = parse(seen.text), now = Date.now(), why = staleness(holder, seen.mtime, now);
    if (why) {
      // Move the stale file aside under a name of our own, then check it is the one judged: a holder that took over
      // in between is put back.
      const aside = `${file}.stale-${me.pid}-${now}`;
      try { renameSync(file, aside); } catch (e) { if (e.code === "ENOENT") continue; throw e; }
      const moved = read(aside);
      if (moved && moved.text !== seen.text) { try { renameSync(aside, file); } catch {} continue; }
      try { unlinkSync(aside); } catch {}
      log(`local: took over a stale machine gate lock from ${describe(holder)}: ${why}`);
      continue;
    }
    const waited = Math.round((now - start) / 1000);
    if (now - start >= wait * 1000) throw new Error(`lock busy: another local gate holds the machine gate lock (${describe(holder)}) after ${waited}s; retry later`);
    const line = describe(holder);
    if (line !== said || now - reported >= REPORT_MS) {
      log(`local: queued behind another local gate: ${line}; waited ${waited}s. This gate is waiting its turn, not stuck: do not stop it or the holder.`);
      reported = now; said = line;
    }
    if (interrupted()) throw new Error("interrupted while waiting for the machine gate lock");
    await new Promise((r) => setTimeout(r, POLL_MS));
    if (interrupted()) throw new Error("interrupted while waiting for the machine gate lock");
  }
}
