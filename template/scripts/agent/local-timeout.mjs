// The local gate's supervisor owns its deadline and machine lock in a separate process from step orchestration.
// A synchronous checkout read (for example a FIFO .env) can block orchestration's event loop: its own timer would
// never fire. The supervisor keeps running, stops the reported step/Worker groups and orchestration itself, then
// releases through finally. SIGKILL supervision for orphaned groups is a separate concern.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { machineLock } from "./gate-lock.mjs";

// apply renders gate.timeout_minutes into jobs.gate.timeout-minutes. Like check.mjs's jobs-have-timeouts, read its
// generated block YAML by indentation: no overlay or YAML package is needed in a consumer checkout. The 1.5x margin
// allows a developer machine to run slower than CI; this bounds a hung lock holder, not test quality.
export function localLimit(env) {
  let ciMinutes = 30;
  try {
    const lines = readFileSync(".github/workflows/std-gate.yml", "utf8").split("\n");
    const jobs = lines.findIndex((l) => /^jobs:\s*(?:#.*)?$/.test(l));
    let gate = false;
    for (let i = jobs + 1; jobs >= 0 && i < lines.length; i++) {
      const line = lines[i];
      if (/^\S/.test(line)) break;
      if (/^ {2}\S/.test(line) && !/^ {2}#/.test(line)) gate = /^ {2}gate:\s*(?:#.*)?$/.test(line);
      const m = gate && line.match(/^ {4}timeout-minutes:\s*([0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?)\s*(?:#.*)?$/i);
      if (m && Number(m[1]) > 0 && Number.isFinite(Number(m[1]))) { ciMinutes = Number(m[1]); break; }
    }
  } catch (e) { if (e.code !== "ENOENT") throw e; }
  const minimumMinutes = ciMinutes * 1.5;
  const limitMinutes = env.GATE_LOCAL_TIMEOUT_MIN === undefined ? minimumMinutes : Number(env.GATE_LOCAL_TIMEOUT_MIN);
  if (!(Number.isFinite(limitMinutes) && limitMinutes > 0 && limitMinutes >= minimumMinutes))
    throw new Error(`GATE_LOCAL_TIMEOUT_MIN must be finite minutes at least ${minimumMinutes} (1.5x the applied gate timeout); it cannot shorten or disable the limit`);
  return { ciMinutes, limitMinutes };
}

// The existing local cleanup paths, shared by orchestration and its supervisor. Each group is one they spawned.
export const signalGroup = (child, signal) => { if (child?.pid) try { process.kill(-child.pid, signal); } catch {} };
export const stop = async (child) => {
  if (!child) return;
  signalGroup(child, "SIGTERM");
  if (child.exitCode === null && child.signalCode === null) await new Promise((r) => setTimeout(r, 300));
  signalGroup(child, "SIGKILL");
};

export async function superviseLocal({ env, args, head, passFile, dirty, dirtyBefore, git, steps, results, ciMinutes, limitMinutes }) {
  const dir = mkdtempSync(`${tmpdir()}/gate-local-`), top = git("rev-parse", "--show-toplevel").trim();
  const repo = `${top.split("/").pop()}@${git("branch", "--show-current").trim() || head.slice(0, 7)}`;
  let core, active, worker, timer, currentStep = steps[0], interrupted = 0, timedOut = false, lockBusy = false, pass = false;
  let releaseLock = () => {}, abort;
  const cancelled = new Promise((_, reject) => { abort = reject; });
  const halt = (error, code) => {
    interrupted ||= code;
    signalGroup(active, "SIGTERM"); signalGroup(worker, "SIGTERM"); signalGroup(core, "SIGTERM");
    abort(error);
  };
  const handlers = Object.fromEntries(Object.entries({ SIGINT: 130, SIGTERM: 143, SIGHUP: 129 }).map(([s, code]) => [s, () => halt(new Error(`interrupted by ${s}`), code)]));
  handlers.uncaughtException = (error) => halt(error, 1);
  for (const [signal, handler] of Object.entries(handlers)) process.on(signal, handler);
  const execute = async () => {
    try { releaseLock = await machineLock({ env, repo, worktree: top, interrupted: () => Boolean(interrupted) }); }
    catch (e) { lockBusy = e.message.startsWith("lock busy:"); throw e; }
    if (interrupted) throw new Error("interrupted");
    // Queue time belongs to GATE_LOCK_WAIT_S; bound execution only after acquisition (also when the lock is off).
    console.log(`local: wall-clock limit ${limitMinutes} min (1.5x applied gate timeout ${ciMinutes} min; GATE_LOCAL_TIMEOUT_MIN may extend it)`);
    const started = performance.now();
    const arm = () => {
      const left = limitMinutes * 60_000 - (performance.now() - started);
      // Node clamps overflowing timers to 1 ms. Split long extensions; no timer keeps a finished gate alive.
      if (left > 0) { timer = setTimeout(arm, Math.min(left, 2 ** 31 - 1)); timer.unref(); return; }
      timedOut = true;
      halt(new Error(`wall-clock limit exceeded during ${currentStep}`), 124);
    };
    arm();
    core = spawn(process.execPath, [fileURLToPath(new URL("./gate.mjs", import.meta.url)), "local", "--supervised", ...args], {
      stdio: ["inherit", "inherit", "inherit", "ipc"], detached: true, env: { ...env, GATE_LOCAL_DIR: dir },
    });
    core.on("message", (m) => {
      if (steps.includes(m?.step)) currentStep = m.step;
      const group = (pid) => Number.isInteger(pid) && pid > 1 ? { pid, exitCode: null, signalCode: null } : null;
      if (Object.hasOwn(m ?? {}, "active")) active = group(m.active);
      if (Object.hasOwn(m ?? {}, "worker")) worker = group(m.worker);
      if (Array.isArray(m?.results)) for (const [name, result] of m.results) if (steps.includes(name)) results.set(name, result);
      if (m?.pass === true) pass = true;
      // A report already in flight when cancellation starts still belongs to this run and must be stopped too.
      if (interrupted) { signalGroup(active, "SIGTERM"); signalGroup(worker, "SIGTERM"); }
    });
    const code = await new Promise((resolve) => {
      core.once("error", () => resolve(1));
      core.once("close", (code) => resolve(code ?? 1));
    });
    if (!interrupted) process.exitCode = code;
  };
  try { await Promise.race([execute(), cancelled]); }
  catch (e) { console.error(`local: ${e.message}`); process.exitCode = interrupted || 1; }
  finally {
    clearTimeout(timer);
    await stop(active); await stop(worker); await stop(core);
    releaseLock();
    rmSync(dir, { recursive: true, force: true });
    for (const [signal, handler] of Object.entries(handlers)) process.off(signal, handler);
    if (timedOut) process.exitCode = 124;
    else if (interrupted) process.exitCode = interrupted;
    else if (lockBusy) process.exitCode = 75;
    if (!process.exitCode && pass && !dirtyBefore && !dirty() && git("rev-parse", "HEAD").trim() === head) writeFileSync(passFile, `${head}\n`);
    else rmSync(passFile, { force: true });
    // Only the supervisor publishes the summary, after release (including a release waiting for a takeover guard).
    if (timedOut) console.log(`local gate ${head}: TIMEOUT (exceeded ${limitMinutes} min during ${currentStep})`);
    else if (lockBusy && !interrupted) console.log(`local gate ${head}: not run (machine gate lock busy). This is not a gate result: wait, then run the local gate again.`);
    else console.log(`local gate ${head}: ${steps.map((s) => `${s}=${results.get(s)}`).join("; ")}`);
  }
}
