#!/usr/bin/env node
// Fresh-base warnings, run by `setup.sh --check` at session start (never in CI). A session that starts on a stale
// default branch works from outdated standards and skills; this names it. Warnings only: it fetches the default branch
// (refs only, short timeout), never touches the working tree, never fast-forwards or resets, never fails the session.
//   - on the default branch and behind origin/<default>: how many commits;
//   - on the default branch in the primary checkout (not a linked worktree): start the task in a worktree instead.
// The default branch is origin/HEAD, else the one of origin/main and origin/master that exists; with neither it is
// silent (no network to learn a name). usage: node scripts/agent/fresh.mjs
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";

const env = process.env;
const git = (a, o = {}) => execFileSync("git", a, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], ...o });
const tryGit = (...a) => { try { return git(a).trim(); } catch { return null; } };
const real = (p) => { try { return realpathSync(p); } catch { return p; } };
// stdout: a SessionStart hook's stdout reaches the agent; its stderr (exit 0) goes only to a debug log.
const say = (line) => console.log(line);

function main() {
  const head = tryGit("symbolic-ref", "-q", "--short", "HEAD");
  if (!head) return; // detached: a rebase, bisect or deliberate checkout
  let def = tryGit("symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")?.replace(/^origin\//, "");
  if (!def) {
    const known = ["main", "master"].filter((b) => tryGit("rev-parse", "-q", "--verify", `refs/remotes/origin/${b}`));
    if (known.length !== 1) return;
    def = known[0];
  }
  if (head !== def) return;
  // A bounded deadline always: only a whole number of milliseconds from 100 to 30000 is taken, else 3000
  // ('' and '0' would otherwise mean no deadline at all).
  const raw = env.STD_FRESH_TIMEOUT_MS ?? "", asked = /^\d+$/.test(raw) ? Number(raw) : NaN;
  const timeout = asked >= 100 && asked <= 30000 ? asked : 3000;
  // Never prompt: no askpass program (an empty GIT_ASKPASS also stops git falling back to core.askPass or
  // SSH_ASKPASS), no credential helper, and ssh in batch mode even under an inherited GIT_SSH_COMMAND.
  const inherited = env.GIT_SSH_COMMAND?.trim();
  const batch = !inherited ? "ssh -o BatchMode=yes"
    : /^\S*ssh(\s|$)/.test(inherited) ? inherited.replace(/^(\S*ssh)(\s|$)/, "$1 -o BatchMode=yes$2") : `${inherited} -o BatchMode=yes`;
  try {
    git(["-c", "credential.helper=", "-c", "credential.interactive=never", "-c", "core.askPass=",
      "fetch", "--quiet", "--no-tags", "origin", `+refs/heads/${def}:refs/remotes/origin/${def}`], {
      timeout, killSignal: "SIGKILL",
      env: { ...env, GIT_TERMINAL_PROMPT: "0", GIT_ASKPASS: "", SSH_ASKPASS: "", SSH_ASKPASS_REQUIRE: "never", GIT_SSH_COMMAND: batch } });
  } catch {
    say(`NOTE: fresh-base: could not fetch origin/${def} within ${timeout}ms; freshness unchecked`);
  }
  const fix = `git worktree add -b <branch> <path> origin/${def}`;
  const behind = Number(tryGit("rev-list", "--count", `HEAD..refs/remotes/origin/${def}`) ?? 0);
  if (behind > 0)
    say(`WARN: fresh-base: ${def} is ${behind} commit(s) behind origin/${def}; standards and skills here are outdated | fix: ${fix}   (or git merge --ff-only origin/${def} if nothing else uses this checkout)`);
  const top = real(git(["rev-parse", "--show-toplevel"]).trim());
  const primary = real(git(["worktree", "list", "--porcelain"]).split("\n")[0].replace(/^worktree /, ""));
  if (top === primary)
    say(`WARN: fresh-base: working on ${def} in the primary checkout | fix: start the task in a new worktree: git fetch origin ${def} && ${fix}`);
}
try { main(); } catch {}
