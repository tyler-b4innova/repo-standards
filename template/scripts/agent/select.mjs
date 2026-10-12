#!/usr/bin/env node
// Which e2e specs a pull request runs, and which declared macOS suites (standards.json macos) it needs, by one path rule (glob).
//   select.mjs [plan] [--base <ref>] [--files a,b] [--json]   what runs and why
//   select.mjs --list                                          ALL (the whole e2e suite), or the selected spec files, one per line
// One narrowing case, nothing else: every changed file of a pull_request is an added or modified spec file (*.spec.* / *.test.*) under an e2e/
// directory. Then only those specs run. Any other change (source, helpers, fixtures, setup, configuration, data, docs, a deletion or a rename) runs
// the app's whole e2e suite, as does any event but pull_request, an unknown base, "affected": false in standards.json and GATE_SELECT=full.
// Unit tests and repo checks (gate.local.sh) always run in full.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const git = (...a) => execFileSync("git", a, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28 });
const isE2eSpec = (f) => /(^|\/)e2e\/(.+\/)?[^/]+\.(spec|test)\.[cm]?[jt]sx?$/.test(f);

/** The changed files against the pull request's base as [status, path] rows (A, M, D ...); null when the base cannot be named. */
export function changes({ env = process.env, base = "", files = "" } = {}) {
  if (files) return files.split(",").map((f) => ["M", f.trim()]).filter((r) => r[1]);
  let event = {};
  if (env.GITHUB_EVENT_PATH && existsSync(env.GITHUB_EVENT_PATH)) { try { event = JSON.parse(readFileSync(env.GITHUB_EVENT_PATH, "utf8")); } catch {} }
  let sha = base || env.GATE_BASE || "";
  try {
    const head = git("rev-parse", "HEAD").trim(), parents = git("rev-list", "--parents", "-n", "1", "HEAD").trim().split(" ").slice(1);
    if (!sha && head !== event.pull_request?.head?.sha && parents.length === 2) sha = parents[0];
    else if (sha || event.pull_request?.base?.sha) sha = git("merge-base", sha || event.pull_request.base.sha, "HEAD").trim();
    else for (const r of ["origin/HEAD", "origin/main", "origin/master", "main", "master"]) { try { sha = git("merge-base", r, "HEAD").trim(); break; } catch {} }
    if (!sha) return null;
    const rows = git("diff", "--name-status", "--no-renames", "-z", sha).split("\0").filter(Boolean), out = [];
    for (let i = 0; i + 1 < rows.length; i += 2) out.push([rows[i], rows[i + 1]]);
    // Untracked files count where a person is working; a CI checkout holds none that are not build output.
    if (env.GITHUB_ACTIONS !== "true") for (const f of git("ls-files", "-o", "--exclude-standard", "-z").split("\0").filter(Boolean)) out.push(["A", f]);
    return out;
  } catch { return null; }
}

/** @returns {{ mode: "full"|"scoped", why: string, specs: string[], rows: string[][] }} */
export function plan({ env = process.env, base = "", files = "", affected } = {}) {
  const std = (() => { try { return JSON.parse(readFileSync("standards.json", "utf8")); } catch { return {}; } })();
  const rows = changes({ env, base, files });
  const full = (why) => ({ mode: "full", why, specs: [], rows: rows ?? [] });
  if ((affected ?? std.affected) === false) return full('standards.json sets "affected": false');
  if (env.GATE_SELECT === "full") return full("GATE_SELECT=full");
  if (env.GITHUB_EVENT_NAME !== "pull_request") return full(`${env.GITHUB_EVENT_NAME ? `a ${env.GITHUB_EVENT_NAME} run` : "a run with no GITHUB_EVENT_NAME"} is not a pull request`);
  if (!rows) return full("the pull request's base cannot be found in this checkout");
  const other = rows.find(([s, f]) => !(["A", "M"].includes(s) && isE2eSpec(f)));
  if (other) return full(`${other[1]} ${other[0] === "D" ? "was deleted" : "is not an added or modified e2e spec"}`);
  if (!rows.length) return full("no changed file was found");
  return { mode: "scoped", why: "only e2e spec files changed", specs: rows.map((r) => r[1]).sort(), rows };
}

// The path rule for every changed-file decision (ui_paths, non-deployable paths, macOS suites): ** any depth, * one segment, {a,b} either.
export const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");

// macOS suites (standards.json "macos"): tests that need macOS, declared and never discovered. Each names the suite, the path
// globs whose change runs it, the runner label it runs on and the command run from the repository root.
const MACOS_KEYS = ["name", "paths", "runner", "command"];
export const MACOS_FIX = 'standards.json macos: a non-empty list of {"name": "<suite>", "paths": ["<glob>"], "runner": "<macOS runner label>", "command": "<command run from the repository root>"}, each name once; omit macos for none';
/** The declared macOS suites ([] when there is no declaration); throws on a malformed one. */
export function macosSuites(std) {
  const list = std?.macos;
  if (list === undefined) return [];
  if (!Array.isArray(list) || !list.length) throw new Error(`standards.json macos must be a non-empty list of suites: ${JSON.stringify(list)}`);
  const names = new Set(), text = (v) => typeof v === "string" && v.trim() !== "";
  return list.map((s) => {
    if (!s || typeof s !== "object" || Array.isArray(s)) throw new Error(`standards.json macos entry must be an object {${MACOS_KEYS.join(", ")}}: ${JSON.stringify(s)}`);
    const unknown = Object.keys(s).filter((k) => !MACOS_KEYS.includes(k));
    if (unknown.length) throw new Error(`standards.json macos entry has an unknown key ${unknown.join(", ")} (${MACOS_KEYS.join(", ")}): ${JSON.stringify(s)}`);
    for (const k of ["name", "runner", "command"]) if (!text(s[k])) throw new Error(`standards.json macos entry ${k} must be a non-empty string: ${JSON.stringify(s)}`);
    if (!Array.isArray(s.paths) || !s.paths.length || !s.paths.every(text)) throw new Error(`standards.json macos entry paths must be a non-empty list of globs: ${JSON.stringify(s)}`);
    if (names.has(s.name)) throw new Error(`standards.json macos suite name ${s.name} is repeated`);
    names.add(s.name);
    return { name: s.name, paths: s.paths, runner: s.runner, command: s.command };
  });
}
/** Which declared macOS suites a change needs: those with a changed file under their paths; every one when the changed files are unknown (null). */
export function macosPlan(std, files) {
  return macosSuites(std).map((s) => {
    const paths = s.paths.map(glob), hit = files?.find((f) => paths.some((r) => r.test(f)));
    return { ...s, run: !files || !!hit, why: !files ? "the pull request's base cannot be found, so every suite runs" : hit ? `${hit} changed` : `nothing changed under ${s.paths.join(", ")}` };
  });
}

export const describe = (r) => `select: ${r.mode === "full" ? "the whole e2e suite" : `${r.specs.length} e2e spec(s)`} (${r.why}); ${r.rows.length} changed file(s)${r.mode === "scoped" ? "\n" + r.specs.map((s) => `  ${s}`).join("\n") : ""}`;
/** The selected spec files; null when the whole e2e suite runs. */
export const listFor = (r) => (r.mode === "full" ? null : r.specs);
export function summarize(text, env = process.env) {
  if (env.GITHUB_STEP_SUMMARY) { try { appendFileSync(env.GITHUB_STEP_SUMMARY, `\n\`\`\`\n${text}\n\`\`\`\n`); } catch {} }
  return text;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const a = process.argv.slice(2), opt = (n) => { const i = a.indexOf(`--${n}`); return i >= 0 ? a[i + 1] ?? "" : ""; };
  if (a[0] && a[0] !== "plan" && !a[0].startsWith("--")) { console.error("usage: select.mjs [plan] [--base <ref>] [--files a,b] [--json] | --list"); process.exit(2); }
  try { process.chdir(git("rev-parse", "--show-toplevel").trim()); } catch {}
  const r = plan({ base: opt("base"), files: opt("files") });
  if (a.includes("--list")) { const l = listFor(r); console.log(l === null ? "ALL" : l.join("\n")); }
  else if (a.includes("--json")) console.log(JSON.stringify({ mode: r.mode, why: r.why, specs: r.specs }, null, 2));
  else console.log(summarize(describe(r)));
}
