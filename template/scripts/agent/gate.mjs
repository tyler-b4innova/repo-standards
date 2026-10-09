#!/usr/bin/env node
// Steps of the `gate` job (std-gate.yml), also runnable locally:
//   local [--base <ref>] | plan | release-start | release-verify | release-report | classify [base] | install [--no-browsers|--browsers-only] | playwright | run <script>... | preview | release | e2e | secrets | syntax | instructions | verdict
// UI paths: pack.json defaults; standards.json "ui_paths" as a list replaces the include globs,
// as {include, ignore} replaces include and adds ignore. e2e: none fails unless "e2e": false.
import { execFileSync as ex, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync as has, mkdtempSync, readdirSync as ls, readFileSync as rd, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { createConnection } from "node:net";
import { localConfig, localWorkerConfig } from "./local.mjs";
import { scan } from "./jsscan.mjs";
import { rollbackFindings } from "./rollback.mjs";
import { rootFile, verifyGeneratedBuild } from "./release-config.mjs";
import { describe as describeSelection, listFor, plan as planSelection, summarize } from "./select.mjs";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["local", "verdict", "plan", "classify", "install", "playwright", "run", "preview", "release", "release-start", "release-verify", "release-report", "e2e", "secrets", "syntax", "instructions"], ok = SUBS.includes(cmd);
if (!ok || args.includes("--help")) {
  console.log(rd(new URL(import.meta.url), "utf8").split("\n").slice(1, 6).map((l) => l.slice(3)).join("\n"));
  process.exit(ok || cmd === "--help" ? 0 : 2);
}
const json_ = (t) => { try { return JSON.parse(t); } catch { return null; } };
const git = (...a) => ex("git", a, { encoding: "utf8", stdio: "pipe" });
try { process.chdir(git("rev-parse", "--show-toplevel").trim()); } catch {}
const json = (f) => { try { return JSON.parse(rd(f, "utf8")); } catch { return null; } };
const pkg = json("package.json"), std = json("standards.json") ?? {};
const fail0 = (msg, fix) => { console.log(`::error::${msg}\nfix: ${fix}`); process.exit(1); };
if (has("package.json") && !pkg && ["local", "install", "run", "e2e"].includes(cmd)) fail0("package.json is not valid JSON", "fix package.json");
const pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : "npm";
const fail = (msg, fix) => { console.log(`::error::${msg}\nfix: ${fix}`); process.exit(1); };
const sh = (c, a) => spawnSync(c, a, { stdio: "inherit" }).status ?? 1;
const must = (c, a) => { const s = sh(c, a); if (s) process.exit(s); };
const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
// The pull request this run is for: the event's, or a workflow_dispatch re-gate's `pr` input (base retargets).
const event = env.GITHUB_EVENT_PATH ? json(env.GITHUB_EVENT_PATH) ?? {} : {};
const prNumber = event.pull_request?.number ?? (env.GITHUB_EVENT_NAME === "workflow_dispatch" && /^\d+$/.test(event.inputs?.pr ?? "") ? Number(event.inputs.pr) : null);
const pack = json("scripts/agent/pack.json") ?? {};
const e2eCfg = typeof std.e2e === "object" && std.e2e ? std.e2e : {}, e2eCmd = typeof std.e2e === "string" ? std.e2e : e2eCfg.command;
// Browsers for this run: Chromium on pull requests; the release check sets the repo's (and overlay's) extra browsers.
const browsers = () => (env.GATE_BROWSERS || "chromium").split(",").filter(Boolean);
const output = (k, v) => { console.log(`${k}=${v}`); if (env.GITHUB_OUTPUT) writeFileSync(env.GITHUB_OUTPUT, `${k}=${v}\n`, { flag: "a" }); };
const ghApi = () => {
  let token = env.GH_TOKEN || env.GITHUB_TOKEN;
  try { token ||= ex("gh", ["auth", "token"], { encoding: "utf8", stdio: "pipe" }).trim(); } catch {}
  const base = `${env.GITHUB_API_URL || "https://api.github.com"}/repos/${env.GITHUB_REPOSITORY}`, headers = { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json" };
  return async (path, { need = true } = {}) => {
    const r = await fetch(`${base}${path}`, { headers });
    if (r.ok) return r.json();
    if (need) fail(`GET ${path}: ${r.status}`, "grant the job actions, pull-requests and issues read");
    return null;
  };
};
// The Workers Builds check-runs of one commit: its staging deployment (and uploaded production version) is that build.
// Only the Cloudflare App's checks count: a same-named check from another App is no deployment evidence.
const buildApp = () => pack.preview?.check_app ?? "cloudflare-workers-and-pages";
// Every page is read (a commit can carry more than 100 check-runs) before filtering by name and App.
const buildRuns = async (get, commit, name) => {
  const all = [];
  for (let page = 1; ; page++) {
    const batch = (await get(`/commits/${commit}/check-runs?per_page=100&page=${page}`))?.check_runs ?? [];
    all.push(...batch);
    if (batch.length < 100) break;
  }
  return all.filter((x) => x.name?.startsWith(name) && x.app?.slug === buildApp());
};
// Staging serves the newest build that deployed. Any commit after this one on the default branch (each one, never the net
// diff: a change and its revert net to nothing but each deploys) whose build is running or succeeded replaces what this
// commit's release check would test; builds that Cloudflare skipped (watch paths) deploy nothing and do not count.
async function supersededBy(get, sha, name) {
  const branch = event.repository?.default_branch || "main";
  for (let page = 1; ; page++) {
    const commits = ((await get(`/compare/${sha}...${encodeURIComponent(branch)}?per_page=100&page=${page}`))?.commits ?? []).map((c) => c.sha).filter((c) => c !== sha);
    for (const c of commits) {
      const live = (await buildRuns(get, c, name)).some((r) => r.status !== "completed" || !["skipped", "neutral"].includes(r.conclusion));
      if (live) return c;
    }
    if (commits.length < 100) return null;
  }
}
// The verdict is the check-run `release-check` on the dispatched commit (the job's own check lands on the ref's tip).
// Created in_progress when the job starts (RELEASE_CHECK_ID), completed exactly once: by the report step
// (success, failure, cancelled), or earlier as neutral with the reason when the run is superseded or has nothing to certify.
const checksWrite = (method, path, body) => fetch(`${env.GITHUB_API_URL || "https://api.github.com"}/repos/${env.GITHUB_REPOSITORY}${path}`, { method,
  headers: { Authorization: `Bearer ${env.GH_TOKEN || env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json", "Content-Type": "application/json" }, body: body && JSON.stringify(body) });
const runUrl = () => `${env.GITHUB_SERVER_URL || "https://github.com"}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}`;
async function completeCheck(conclusion, title, summary) {
  if (!env.RELEASE_CHECK_ID) return;
  const r = await checksWrite("PATCH", `/check-runs/${env.RELEASE_CHECK_ID}`, { status: "completed", conclusion, completed_at: new Date().toISOString(), details_url: runUrl(), output: { title, summary } });
  if (!r.ok) fail(`could not complete release-check (${r.status})`, "grant the job checks: write");
}
// Cancel this run and never return: neither a pass for a commit it cannot certify nor a red failure. The cancel is
// asynchronous (GitHub documents up to five minutes): wait for the runner to be interrupted, then force-cancel, then fail closed.
async function cancelRun(why) {
  console.log(`::notice::release check cancelled: ${why}`);
  output("skip", "true"); output("browsers", ""); output("url", "");
  await completeCheck("neutral", "release-check: nothing certified", `No verdict for this commit: ${why}. This is not a pass.`);
  const base = `${env.GITHUB_API_URL || "https://api.github.com"}/repos/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID || "0"}`;
  const post = (tail) => fetch(`${base}/${tail}`, { method: "POST", headers: { Authorization: `Bearer ${env.GH_TOKEN || env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json" } });
  const sleep = (sec) => new Promise((res) => setTimeout(res, sec * 1000));
  let r = await post("cancel");
  if (!r.ok) fail(`could not cancel the release check (${r.status}): ${why}`, "grant the job actions: write");
  await sleep(Number(env.GATE_CANCEL_WAIT_S ?? 300));
  r = await post("force-cancel");
  if (!r.ok) fail(`the release check was not interrupted after cancel, and force-cancel failed (${r.status}): ${why}`, "cancel the run; it must not pass");
  await sleep(Number(env.GATE_FORCE_WAIT_S ?? 60));
  fail(`the release check was not interrupted after cancel and force-cancel: ${why}`, "cancel the run; it must not pass");
}
const playwrightBin = () => has("node_modules/.bin/playwright") ? ["node_modules/.bin/playwright", []] : ["npx", ["--no-install", "playwright"]];
// True when the system packages for this run's browsers must be installed (Linux only; elsewhere Playwright has none).
// Playwright's own host validation is bundled and not callable, so Chromium gets an equivalent check: `ldd` over every
// executable and shared library in the browser's `chrome-linux` directory, with that directory on LD_LIBRARY_PATH, as
// Playwright does. Firefox and WebKit load libraries it also checks through a library path and dlopen (libxul.so,
// libGLESv2.so.2, libx264.so) that this scan cannot reproduce, so they always install their packages.
function browserDepsMissing() {
  if ((env.GATE_PLATFORM || process.platform) !== "linux") return false;
  const other = browsers().filter((b) => b !== "chromium");
  if (other.length) { console.log(`install: ${other.join(", ")} always installs system packages`); return true; }
  const root = env.PLAYWRIGHT_BROWSERS_PATH && env.PLAYWRIGHT_BROWSERS_PATH !== "0" ? env.PLAYWRIGHT_BROWSERS_PATH : `${homedir()}/.cache/ms-playwright`;
  const dirs = (has(root) ? ls(root) : []).filter((x) => /^chromium(_headless_shell)?-/.test(x));
  if (!dirs.some((x) => /^chromium-/.test(x))) { console.log(`install: chromium not found under ${root}; installing system packages`); return true; }
  for (const x of dirs) {
    const dir = `${root}/${x}/chrome-linux`;
    if (!has(dir)) { console.log(`install: ${dir} missing; installing system packages`); return true; }
    for (const e of ls(dir, { withFileTypes: true })) {
      const f = `${dir}/${e.name}`;
      if (!e.isFile() || !(/\.so(\.|$)/i.test(e.name) || (statSync(f).mode & 0o111))) continue;
      const r = spawnSync("ldd", [f], { encoding: "utf8", cwd: dir, env: { ...env, LD_LIBRARY_PATH: [env.LD_LIBRARY_PATH, dir].filter(Boolean).join(":") } });
      if (r.error || /=>.*not found/.test(`${r.stdout}`)) { console.log(`install: ${f} misses shared libraries; installing system packages`); return true; }
    }
  }
  console.log("install: browser system packages present");
  return false;
}
function ui(files) {
  const p = json("scripts/agent/pack.json") ?? {}, o = std.ui_paths;
  const inc = (Array.isArray(o) ? o : o?.include ?? p.ui_paths ?? []).map(glob), ign = [...(p.ui_ignore ?? []), ...(o?.ignore ?? [])].map(glob);
  return files.filter((f) => inc.some((r) => r.test(f)) && !ign.some((r) => r.test(f)));
}

// A pull request whose changed paths are all non-deployable (pack.json non_deploy_paths: docs, agent instructions and
// config) has nothing to preview or test end to end: its changed files, or null. The diff is the checked-out
// merge commit (pull_request and re-gate runs) against its base parent, or the PR head against the event's base.
// The pull request's base point: the checked-out merge commit's base parent (pull_request and re-gate runs), or the
// merge base of the PR head and the event's base. null when there is neither.
function prBase() {
  const head = git("rev-parse", "HEAD").trim(), parents = git("rev-list", "--parents", "-n", "1", "HEAD").trim().split(" ").slice(1);
  if (head !== event.pull_request?.head?.sha && parents.length === 2) return parents[0];
  return event.pull_request?.base?.sha ? git("merge-base", event.pull_request.base.sha, "HEAD").trim() : null;
}
// The paths the pull request changes, both sides of a rename. null when its base cannot be found.
function prFiles() {
  try {
    const base = prBase();
    return base ? git("diff", "--name-only", "--no-renames", "-z", base, "HEAD").split("\0").filter(Boolean) : null;
  } catch { return null; }
}
function docOnly() {
  if (!prNumber) return null;
  const files = prFiles();
  if (!files) return null;
  const paths = (pack.non_deploy_paths ?? []).map(glob);
  return files.length && files.every((f) => paths.some((r) => r.test(f))) ? files : null;
}
const docSkip = (step, files) => console.log(`::notice::${step} skipped: only non-deployable paths changed (${files.join(", ")})`);

// Client sites: the built HTML (dist/) carries no HTML comments, no comments in inline scripts and no source-platform
// names (pack.json source_platforms), all of which leak how and where the site was made.
function scanBuilt() {
  const bad = [], names = pack.source_platforms ?? [];
  const word = names.length ? new RegExp(`\\b(${names.map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})\\b`, "i") : null;
  for (const f of ls("dist", { recursive: true }).map(String).filter((f) => /\.html?$/.test(f)).sort()) {
    const html = rd(`dist/${f}`, "utf8"), at = `dist/${f}`;
    if (/<!--(?!\s*\[if)/.test(html)) bad.push(`${at}: HTML comment`);
    // Inline JavaScript only (data blocks such as JSON-LD are not scripts); read by a lexer, not a regex.
    for (const [, attrs, body] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      const type = attrs.match(/\btype\s*=\s*["']?([^"'\s>]+)/i)?.[1]?.toLowerCase() ?? "";
      if (/\bsrc\s*=/i.test(attrs) || (type && !["module", "text/javascript", "application/javascript"].includes(type))) continue;
      if (scan(body).comments.length) { bad.push(`${at}: comment in an inline script`); break; }
    }
    const m = word && html.replace(/<[^>]*\b(integrity|nonce)="[^"]*"/g, "").match(word);
    if (m) bad.push(`${at}: source-platform name ${m[1]}`);
  }
  if (bad.length) fail(`built output:\n  ${bad.join("\n  ")}`, "remove the comments from the source (Astro keeps <!-- --> and is:inline script comments), and the platform names");
  console.log("built output: dist/ is clean");
}

// The Cloudflare bot's comment body -> the preview URL for `head` ("" when there is none). A table is read by its header
// row: the "Preview URL" (or "Deployment URL") cell of the row whose "Latest Commit" (or "Commit") is the head, in a
// markdown table or an HTML one. Failing that, the "Preview URL: <url> (commit <sha>)" line when it names the head.
// Never a link to the Cloudflare dashboard (the build's "View logs" and dashboard links); "No Preview URL" and a missing
// column mean there is none.
const cfUrl = (text) => [...text.matchAll(/https:\/\/[^\s<>()"'|\][,]+/g)].map((m) => m[0])
  .find((u) => { try { return !/(^|\.)dash\.cloudflare\.com$/i.test(new URL(u).hostname); } catch { return false; } }) ?? "";
const previewUrl = (body, head) => {
  const plain = (c) => c.replace(/<[^>]*>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
  const sameCommit = (c) => { const x = plain(c).toLowerCase(); return /^[0-9a-f]{7,40}$/.test(x) && head.startsWith(x); };
  const cols = (cells) => ({ url: cells.findIndex((c) => /^(preview|deployment) url$/i.test(plain(c))), commit: cells.findIndex((c) => /^(latest )?commit$/i.test(plain(c))) });
  const fromRow = (cells, map) => (map && map.url >= 0 && map.commit >= 0 && sameCommit(cells[map.commit] ?? "") && !/no preview url/i.test(cells[map.url] ?? "") ? cfUrl(cells[map.url] ?? "") : "");
  let map = null, found = "";
  for (const line of body.split("\n")) {
    if (!/^\s*\|/.test(line)) { map = null; continue; }
    const cells = line.trim().replace(/^\||\|$/g, "").split("|");
    if (cells.every((c) => /^\s*:?-+:?\s*$/.test(c))) continue;
    const m = cols(cells);
    if (m.url >= 0 || m.commit >= 0) map = m; else found ||= fromRow(cells, map);
  }
  for (const tr of body.split(/<\/tr>/i)) {
    const cells = [...tr.matchAll(/<t([hd])\b[^>]*>([\s\S]*?)<\/t\1>/gi)];
    if (!cells.length) continue;
    const text = cells.map((c) => c[2]);
    if (cells.every((c) => c[1].toLowerCase() === "h")) map = cols(text); else found ||= fromRow(text, map);
  }
  if (found) return found;
  for (const line of body.split("\n")) {
    const c = line.match(/preview url:.*\bcommit\s+([0-9a-f]{7,40})\b/i);
    if (c && head.startsWith(c[1].toLowerCase()) && !/no preview url/i.test(line)) found ||= cfUrl(line);
  }
  return found;
};

// Instruction files at any depth (the launcher's instructions-guard rule): AGENTS.md (and Codex's override), CLAUDE.md,
// CLAUDE.local.md and Claude's instruction folders under .claude/ (.claude/settings.json is the engine's, not one).
const INSTRUCTION = [/(^|\/)(AGENTS|AGENTS\.override|CLAUDE|CLAUDE\.local)\.md$/i, /(^|\/)\.claude\/(agents|commands|rules)\//];
// The managed block of the CODEOWNERS GitHub applies at `rev` (the first of these that exists): its path and block. A
// symlink there holds no block (GitHub does not follow it).
const CODEOWNERS = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"];
function ownersBlock(rev) {
  for (const path of CODEOWNERS) {
    const entry = git("ls-tree", rev, "--", path).trim();
    if (!entry) continue;
    const [mode, type] = entry.split(/\s+/);
    if (type === "tree") continue;
    if (mode === "120000" || type !== "blob") return { path, block: null };
    const lines = git("show", `${rev}:${path}`).split("\n"), i = lines.findIndex((l) => l.startsWith("# std:begin "));
    if (i < 0) return { path, block: null };
    const j = lines.indexOf("# std:end", i);
    return { path, block: lines.slice(i, j < 0 ? undefined : j + 1).join("\n") };
  }
  return { path: null, block: null };
}

if (cmd === "local") {
  const steps = ["setup --check", "instructions", "secrets", "syntax", "install", "typecheck", "build", "gate.local.sh", "worker", "e2e"], results = new Map(steps.map((s) => [s, "not run"]));
  const head = git("rev-parse", "HEAD").trim();
  // pr.sh ready reads this: written only when every step passed on a clean tree at this HEAD, cleared at the start of each run.
  const passFile = git("rev-parse", "--git-path", "std-local-gate").trim();
  rmSync(passFile, { force: true });
  const dirty = () => git("status", "--porcelain", "--untracked-files=all").trim(); // tracked changes and non-ignored untracked files
  const dirtyBefore = dirty();
  let base, baseRef, worker, active, address, interrupted = 0;
  if (args.length && (args.length !== 2 || args[0] !== "--base" || !args[1] || args[1].startsWith("-")))
    fail("local: expected local [--base <ref>]", "supply a comparison branch or commit with --base");
  for (const ref of args.length ? [args[1]] : ["origin/HEAD", "origin/main", "origin/master", "main", "master"]) {
    try { base = git("merge-base", ref, "HEAD").trim(); baseRef = ref; break; } catch {}
  }
  if (!base) {
    fail(`local: cannot resolve a comparison base${args.length ? ` from ${args[1]}` : " (origin/HEAD, origin/main, origin/master, main, master)"}`,
      "fetch the default branch or run local --base <ref>; HEAD is never used as a fallback");
  }
  if (base === head) fail(`nothing to compare: HEAD has no commits beyond ${baseRef}; run from a feature branch or pass --base`, "choose a base with commits beyond it on HEAD");
  // Wrangler 4.148's dotenv-expand overwrites empty env values; --env-file bypasses .dev.vars.
  // Refuse credential sources before every child, including files produced by earlier build steps.
  const noDotenvCredentials = (dir = ".") => {
    for (const entry of ls(dir, { withFileTypes: true })) {
      const path = `${dir}/${entry.name}`;
      if (entry.isDirectory() && ![".git", "node_modules", ".wrangler"].includes(entry.name)) noDotenvCredentials(path);
      else if (/^\.env(?:\.|$)/.test(entry.name) && /^\s*(?:export\s+)?(?:CLOUDFLARE_|CF_)(?:API_TOKEN|API_KEY|EMAIL|ACCOUNT_ID)\s*(?:=|:\s)/im.test(rd(path, "utf8")))
        throw new Error(`local: credential-bearing ${path} refused; remove Cloudflare credentials before running the local gate`);
    }
  };
  const dir = mkdtempSync(`${tmpdir()}/gate-local-`), eventFile = `${dir}/event.json`;
  writeFileSync(eventFile, JSON.stringify({ pull_request: { number: 1, base: { sha: base }, head: { sha: head, ref: git("branch", "--show-current").trim() }, user: { login: "local" } } }));
  const localEnv = { ...env, CI: "true", GITHUB_EVENT_NAME: "pull_request", GITHUB_EVENT_PATH: eventFile, GITHUB_SHA: head,
    PATH: `${process.cwd()}/node_modules/.bin:${env.PATH}`, GATE_BROWSERS: "chromium", WRANGLER_SEND_METRICS: "false", WRANGLER_CHECK_FOR_UPDATES: "false", WRANGLER_HOME: `${dir}/wrangler`, HOME: dir, USERPROFILE: dir, XDG_CONFIG_HOME: `${dir}/xdg` };
  for (const k of ["RELEASE_CHECK", "GH_TOKEN", "GITHUB_TOKEN", "GITHUB_OUTPUT", "GATE_PREVIEW_URL", "BASE_URL", "PLAYWRIGHT_BASE_URL", "CLOUDFLARE_ENV", "RANGE", "ROLLBACK_BASE", "ROLLBACK_DRAFT"])
    delete localEnv[k];
  for (const k of Object.keys(localEnv)) if (/^(CLOUDFLARE_|CF_)/.test(k)) delete localEnv[k];
  for (const k of ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_API_KEY", "CLOUDFLARE_EMAIL", "CLOUDFLARE_ACCOUNT_ID"]) localEnv[k] = "";
  const signalGroup = (child, signal) => { if (child?.pid) try { process.kill(-child.pid, signal); } catch {} };
  const stop = async (child) => {
    if (!child) return;
    signalGroup(child, "SIGTERM");
    if (child.exitCode === null && child.signalCode === null) await new Promise((r) => setTimeout(r, 300));
    signalGroup(child, "SIGKILL");
  };
  const occupied = async () => address && new Promise((resolve) => {
    const socket = createConnection({ host: address.hostname.replace(/^\[|\]$/g, ""), port: Number(address.port || (address.protocol === "https:" ? 443 : 80)) });
    const done = (used) => { socket.destroy(); resolve(used); };
    socket.once("connect", () => done(true)); socket.once("error", () => done(false)); socket.setTimeout(500, () => done(true));
  });
  let abort;
  const cancelled = new Promise((_, reject) => { abort = reject; });
  const onSignal = (signal) => {
    interrupted ||= { SIGINT: 130, SIGTERM: 143, SIGHUP: 129 }[signal];
    signalGroup(active, "SIGTERM"); signalGroup(worker, "SIGTERM");
    abort(new Error(`interrupted by ${signal}`));
  };
  const onException = (error) => { interrupted ||= 1; abort(error); };
  const handlers = { SIGINT: () => onSignal("SIGINT"), SIGTERM: () => onSignal("SIGTERM"), SIGHUP: () => onSignal("SIGHUP"), uncaughtException: onException };
  for (const [signal, handler] of Object.entries(handlers)) process.on(signal, handler);
  const run = async (name, command, argv) => {
    if (interrupted) throw new Error("interrupted");
    noDotenvCredentials();
    console.log(`local: ${name} starting`);
    results.set(name, "FAIL");
    const child = active = spawn(command, argv, { stdio: "inherit", env: localEnv, detached: true });
    const code = await new Promise((resolve) => { child.once("error", () => resolve(1)); child.once("exit", (c) => resolve(c ?? 1)); });
    await stop(child); active = null;
    if (code || interrupted) throw new Error(`${name} failed (exit ${code})`);
    results.set(name, "PASS"); console.log(`local: ${name} PASS`);
  };
  const execute = async () => {
    await run("setup --check", "scripts/agent/setup.sh", ["--check"]);
    const config = localConfig(std.local);
    for (const step of ["instructions", "secrets", "syntax", "install"]) await run(step, process.execPath, ["scripts/agent/gate.mjs", step, ...(step === "instructions" ? ["--local"] : [])]);
    for (const step of ["typecheck", "build"]) await run(step, process.execPath, ["scripts/agent/gate.mjs", "run", step]);
    if (has("scripts/agent/gate.local.sh")) await run("gate.local.sh", "bash", ["scripts/agent/gate.local.sh"]);
    else { results.set("gate.local.sh", "SKIP (absent)"); console.log("local: gate.local.sh SKIP (absent)"); }
    // No root Wrangler config and no release_workers: there is no Worker to start, whatever local defaults to. An explicit
    // local setting is still honoured (and refused when there is no config to run it against).
    const noWorker = std.local === undefined && !rootFile() && !(Array.isArray(std.release_workers) && std.release_workers.length);
    if (config === false) { results.set("worker", "SKIP (local: false)"); console.log("local: worker SKIP (local: false)"); }
    else if (noWorker) { results.set("worker", "SKIP (no Worker)"); console.log("local: worker SKIP (no Worker)"); }
    else {
      results.set("worker", "FAIL");
      const wait = Number(env.GATE_LOCAL_WAIT_S ?? 60);
      if (!(wait > 0 && Number.isFinite(wait))) throw new Error("GATE_LOCAL_WAIT_S must be finite seconds above 0");
      const ready = new URL(config.ready, config.url).href;
      const probe = async () => { try { const r = await fetch(ready, { redirect: "manual", signal: AbortSignal.timeout(500) }); await r.body?.cancel(); return r.status; } catch { return 0; } };
      const argv = localWorkerConfig(config);
      address = new URL(config.url);
      if (await occupied()) throw new Error(`local Worker address already in use: ${config.url}; stop that server first`);
      if (interrupted) throw new Error("interrupted");
      noDotenvCredentials();
      console.log(`local: worker starting: node_modules/.bin/wrangler ${argv.join(" ")}`);
      worker = spawn("node_modules/.bin/wrangler", argv, { stdio: "inherit", env: localEnv, detached: true });
      let error; worker.once("error", (e) => { error = e; });
      const deadline = Date.now() + wait * 1000;
      let status = 0;
      while (Date.now() < deadline && !interrupted && !error && worker.exitCode === null && worker.signalCode === null) {
        status = await probe();
        if (status >= 200 && status < 300) break;
        await new Promise((r) => setTimeout(r, 100));
      }
      if (interrupted || error || worker.exitCode !== null || worker.signalCode !== null || status < 200 || status >= 300)
        throw new Error(`local Worker did not become ready at ${ready} within ${wait}s${error ? `: ${error.message}` : ""}`);
      localEnv.PLAYWRIGHT_BASE_URL = localEnv.BASE_URL = config.url;
      results.set("worker", "PASS"); console.log(`local: worker PASS (${config.url})`);
    }
    await run("e2e", process.execPath, ["scripts/agent/gate.mjs", "e2e", "--local"]);
    if (worker && (worker.exitCode !== null || worker.signalCode !== null)) { results.set("worker", "FAIL"); throw new Error("local Worker exited during e2e"); }
  };
  try { await Promise.race([execute(), cancelled]); } catch (e) { console.error(`local: ${e.message}`); process.exitCode = interrupted || 1; }
  finally {
    await stop(active); await stop(worker);
    if (worker) {
      const deadline = Date.now() + 2000;
      while (await occupied() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
      if (await occupied()) { console.error(`local: Worker port was not freed: ${address.href}`); process.exitCode = 1; }
      else console.log("local: worker stopped; port freed");
    }
    rmSync(dir, { recursive: true, force: true });
    for (const [signal, handler] of Object.entries(handlers)) process.off(signal, handler);
    if (interrupted) process.exitCode = interrupted;
    console.log(`local gate ${head}: ${steps.map((s) => `${s}=${results.get(s)}`).join("; ")}`);
    if (!process.exitCode && !dirtyBefore && !dirty() && git("rev-parse", "HEAD").trim() === head) writeFileSync(passFile, `${head}\n`);
  }
} else if (cmd === "instructions") {
  // Agents never change instruction files. Only the org App's standards-sync (standards/v*) and approved retro
  // (retro/*) pull requests may; every other author is held to it, the repository owner's own login included.
  if (!prNumber) { console.log("::notice::instructions: not a pull request (the merge queue holds only pull requests that passed it)"); process.exit(0); }
  const pr = event.pull_request ?? (await ghApi()(`/pulls/${prNumber}`));
  const author = pr.user?.login ?? "", ref = pr.head?.ref ?? "";
  if (pack.sync_app_login && author === pack.sync_app_login && /^(retro\/.+|standards\/v\d.*)$/.test(ref)) {
    console.log(`instructions: exempt, ${author}'s ${ref} pull request (standards sync or approved retro)`);
    process.exit(0);
  }
  const files = prFiles();
  if (files && args.includes("--local")) files.push(...git("diff", "--name-only", "--no-renames", "HEAD").trim().split("\n").filter(Boolean), ...git("ls-files", "--others", "--exclude-standard").trim().split("\n").filter(Boolean));
  if (!files) fail("instructions: the pull request's base commit is not in this checkout", "check out with fetch-depth: 0 (std-gate.yml does)");
  const bad = new Set(files.filter((f) => INSTRUCTION.some((r) => r.test(f))));
  // The one change an author may make to AGENTS.md: exactly what the pack's apply generates for this repository at this
  // head. The BASE commit supplies the renderer (bin/ and everything it imports), the overlay, standards.json and the
  // template; the pull request supplies exactly one file, template/AGENTS.block.md, read as plain text, so none of its
  // JavaScript runs. A pull request that adds or changes the renderer or the overlay can never authorise an edit, and a
  // repository whose base has no renderer (standards.json "overlay" names the overlay apply uses) stays refused. AGENTS.md
  // and the block file must be regular git blobs (mode 100644): a symlink is refused. The gate runs
  // PR-supplied scripts, so this guard catches honest mistakes; it is not a security boundary against a crafted pull request.
  if (bad.has("AGENTS.md")) {
    const base = prBase(), at = (rev, path) => { try { return git("show", `${rev}:${path}`); } catch { return null; } };
    const regular = (rev, path) => { try { return /^100644 blob /.test(git("ls-tree", rev, "--", path)); } catch { return false; } };
    const baseStd = base ? json_(at(base, "standards.json")) : null, baseAgents = base ? at(base, "AGENTS.md") : null;
    const blockFile = "template/AGENTS.block.md", headBlock = regular("HEAD", blockFile) ? at("HEAD", blockFile) : null;
    if (base && regular("HEAD", "AGENTS.md") && headBlock !== null && baseAgents !== null && baseStd && typeof baseStd.overlay === "string"
      && at(base, "bin/repo-standards.mjs") !== null && at(base, baseStd.overlay) !== null) {
      const dir = mkdtempSync(`${tmpdir()}/agents-render-`);
      try {
        spawnSync("mkdir", ["-p", `${dir}/engine`, `${dir}/target`]);
        // the whole base tree is the engine, template included; only the block file is the pull request's
        if (spawnSync("sh", ["-c", `git archive ${base} | tar -x -C "${dir}/engine"`]).status === 0) {
          spawnSync("rm", ["-rf", `${dir}/engine/test`]);
          writeFileSync(`${dir}/engine/${blockFile}`, headBlock);
          spawnSync("git", ["init", "-q", `${dir}/target`]);
          writeFileSync(`${dir}/target/AGENTS.md`, baseAgents); writeFileSync(`${dir}/target/standards.json`, at(base, "standards.json"));
          const r = spawnSync(process.execPath, [`${dir}/engine/bin/repo-standards.mjs`, "apply", "--target", `${dir}/target`, "--overlay", `${dir}/engine/${baseStd.overlay}`, "--version", baseStd.version], { encoding: "utf8" });
          if (r.status === 0 && rd(`${dir}/target/AGENTS.md`, "utf8") === at("HEAD", "AGENTS.md")) bad.delete("AGENTS.md");
        }
      } finally { rmSync(dir, { recursive: true, force: true }); }
    }
  }
  if (files.some((f) => CODEOWNERS.includes(f))) {
    const [before, after] = [ownersBlock(prBase()), ownersBlock("HEAD")];
    if (before.block !== after.block) bad.add(`${after.path ?? before.path} (managed std block${after.path !== before.path ? `, now read from ${after.path ?? "no CODEOWNERS"}` : ""})`);
  }
  if (bad.size) fail(`instruction files changed by ${author || "this pull request"} (${ref}):\n  ${[...bad].join("\n  ")}`,
    "agents never change instruction files; only the org App's standards-sync (standards/v*) and approved retro (retro/*) pull requests may. Revert these files; a rule change goes through the weekly retro.");
  console.log("instructions: no instruction file or managed CODEOWNERS block changed");
} else if (cmd === "verdict") {
  // The required `gate` job: the checks job and the test job (NEEDS, the workflow's needs as JSON) each succeeded on a
  // READY pull request. A draft head never passes: the plan was cheap, the live draft flag was set, or the checks were
  // skipped for a push to a draft. A pull request flipped to ready by an Actions token fires no ready_for_review run,
  // so it must not inherit a green gate from its draft heads. Anything else (a failure, a cancellation, a skip, a
  // missing job) fails it.
  let needs;
  try { needs = JSON.parse(env.NEEDS ?? ""); } catch { fail("no job results (NEEDS)", "run the verdict from std-gate.yml's gate job"); }
  const mode = needs.checks?.outputs?.mode, draft = mode === "cheap" || needs.checks?.outputs?.rollback_draft === "true" || needs.checks?.result === "skipped", bad = [];
  if (draft) fail("gate: a draft head never passes the gate", "mark the pull request ready (pr.sh ready): the one full gate runs on ready_for_review; iterate with gate.mjs local");
  for (const j of ["checks", "test"]) {
    const r = needs[j]?.result ?? "missing";
    if (r !== "success") bad.push(`${j}: ${r}`);
  }
  if (bad.length) fail(`gate: ${bad.join(", ")}`, "open the failed job's log; a skipped or cancelled job never passes gate");
  console.log("gate: checks and the test job passed");
} else if (cmd === "plan") {
  // full: build and test this head. cheap: a consumer draft (checks, secrets and syntax);
  // consumer drafts run the full gate from ready_for_review.
  const get = ghApi();
  let mode = "full", why = "build and test this head";
  const pr = prNumber ? await get(`/pulls/${prNumber}`) : null;
  // The engine must exercise its own fixtures for code changes, including on draft PRs.
  const engineCode = pkg?.name === "repo-standards" && has("bin/repo-standards.mjs") && !docOnly();
  if (pr?.draft && !engineCode) { mode = "cheap"; why = "draft: the full gate runs from ready_for_review"; }
  // A description or title edit re-checks the description and nothing else: no build, no e2e. The cheap path must not
  // turn a head's red or unfinished full gate green, so an edit passes only on a head whose last gate run succeeded.
  if (event.action === "edited" && env.GITHUB_EVENT_NAME === "pull_request") {
    mode = "cheap"; why = "edit: only the checks run";
    const stamp = (c) => String(c.started_at ?? c.created_at ?? "");
    const last = ((await get(`/commits/${pr.head.sha}/check-runs?per_page=100`))?.check_runs ?? []).filter((c) => c.name === "gate").sort((a, b) => stamp(b).localeCompare(stamp(a)))[0];
    if (last && !(last.status === "completed" && last.conclusion === "success"))
      fail(`edit: this head's gate is ${last.status === "completed" ? last.conclusion : last.status}; a description edit cannot pass it`, "wait for that gate, fix it if red, and re-run this run afterwards");
  }
  // Pull requests run Chromium only; a repository's extra browsers run on main, against staging, before a release.
  console.log(`plan: ${mode} (${why})`);
  output("mode", mode);
  output("rollback_draft", String(pr?.draft === true));
  let rollbackBase;
  try { rollbackBase = prBase(); } catch {} // --check reports an unavailable comparison base.
  output("rollback_base", rollbackBase || event.pull_request?.base?.sha || event.merge_group?.base_sha || pr?.base?.sha || "");
  output("browsers", "chromium");
} else if (cmd === "syntax") {
  // The cheap gate's stand-in for building: managed scripts and workflows must at least parse.
  const bad = [], yaml = spawnSync("python3", ["-c", "import yaml"]).status === 0;
  if (!yaml) console.log("notice: python3 with PyYAML is not on this runner; workflows are not parsed here");
  for (const f of git("ls-files", "scripts/agent", ".github/workflows").split("\n").filter(Boolean)) {
    const text = rd(f, "utf8"), first = text.split("\n")[0];
    const r = /\.(sh)$/.test(f) || /^#!.*\bbash\b/.test(first) ? spawnSync("bash", ["-n", f], { encoding: "utf8" })
      : /\.(mjs|js)$/.test(f) || /^#!.*\bnode\b/.test(first) ? spawnSync("node", ["--check", ...(/\.(mjs|js)$/.test(f) ? [f] : ["--input-type=module"])], { encoding: "utf8", input: /\.(mjs|js)$/.test(f) ? undefined : text.replace(/^#!.*\n/, "") })
      : /\.ya?ml$/.test(f) && yaml ? spawnSync("python3", ["-c", "import sys,yaml; yaml.safe_load(open(sys.argv[1]))", f], { encoding: "utf8" }) : null;
    if (r && r.status) bad.push(`${f}: ${(r.stderr || r.stdout || "").trim().split("\n").slice(-1)[0]}`);
  }
  if (bad.length) fail(`syntax errors:\n  ${bad.join("\n  ")}`, "fix them; managed files come from the pack (setup.sh --check names the restore)");
  console.log("syntax: scripts and workflows parse");
} else if (cmd === "preview") {
  // Where the repo has Workers Builds (its base branch tip carries the check), gate waits for the head's build within
  // GATE_PREVIEW_WAIT_S (default 8 minutes), fails on a failed, missing or unfinished one, and e2e runs against that
  // build's preview URL (from the Cloudflare bot's PR comment for this commit), never locally; no URL fails too.
  // Cloudflare skipping the commit (build watch paths) is the one exception: there is no build, so e2e runs locally.
  // A repo without Workers Builds, or with "e2e": {"preview": false}, runs e2e locally.
  if (!prNumber || std.e2e === false || e2eCfg.preview === false) { console.log('preview: none (not a pull request, or standards.json has "e2e": false or e2e.preview false)'); output("url", ""); process.exit(0); }
  const docs = docOnly();
  if (docs) { docSkip("preview", docs); output("url", ""); process.exit(0); }
  const get = ghApi(), pr = await get(`/pulls/${prNumber}`), head = pr.head.sha, short = head.slice(0, 7);
  const name = pack.preview?.check_name ?? "Workers Builds", author = pack.preview?.comment_author ?? "cloudflare-workers-and-pages[bot]";
  const builds = async (sha) => ((await get(`/commits/${sha}/check-runs?per_page=100`))?.check_runs ?? []).filter((c) => c.name?.startsWith(name));
  const baseTip = pr.base?.ref ? (await get(`/branches/${encodeURIComponent(pr.base.ref)}`))?.commit?.sha : null;
  const hasBuilds = (await builds(head)).length > 0 || (baseTip ? (await builds(baseTip)).length > 0 : false);
  if (!hasBuilds) { console.log(`preview: the repository has no "${name}" check (none on ${short} or the ${pr.base?.ref ?? "base"} tip); e2e runs locally`); output("url", ""); process.exit(0); }
  const wait = Number(env.GATE_PREVIEW_WAIT_S ?? 480) * 1000, start = Date.now();
  let skipped = false;
  for (;;) {
    const runs = await builds(head);
    const red = runs.find((c) => c.status === "completed" && !["success", "skipped", "neutral"].includes(c.conclusion));
    if (red) fail(`Cloudflare build failed for ${short}: ${red.name} ${red.conclusion} (${red.details_url})`, "fix the Worker build; gate needs the preview to pass");
    if (runs.length && runs.every((c) => c.status === "completed")) { skipped = runs.every((c) => c.conclusion === "skipped"); break; }
    if (Date.now() - start >= wait)
      fail(runs.length ? `the Cloudflare build for ${short} is still running after ${wait / 1000}s` : `no "${name}" check on ${short} after ${wait / 1000}s, though the repository has Workers Builds`,
        "re-run gate once the build finishes; if the Worker's builds are off for pull requests, turn them on, or set standards.json e2e.preview to false");
    await new Promise((r) => setTimeout(r, 15000));
  }
  if (skipped) { console.log(`preview: Cloudflare skipped the build for ${short} (build watch paths); e2e runs locally`); output("url", ""); process.exit(0); }
  // A passed build must give e2e its preview: the URL for this commit in the Cloudflare comment (which can trail the
  // check a little). Never a local run where the repo has Workers Builds.
  const findUrl = async () => {
    const comments = [];
    for (let page = 1; ; page++) { const b = (await get(`/issues/${prNumber}/comments?per_page=100&page=${page}`)) ?? []; comments.push(...b); if (b.length < 100) break; }
    return comments.filter((c) => c.user?.login === author).reverse().map((c) => previewUrl(c.body ?? "", head)).find(Boolean) ?? "";
  };
  let url = await findUrl();
  while (!url && Date.now() - start < wait) { await new Promise((r) => setTimeout(r, 15000)); url = await findUrl(); }
  if (!url) fail(`the Cloudflare build for ${short} passed, but no preview URL for ${short} is in the ${author} comment`,
    "turn on the Worker's preview URLs (Workers Builds) so each build comments its URL, then re-run gate; or set standards.json e2e.preview to false");
  console.log(`preview: ${url} (${short})`);
  output("url", url);
} else if (cmd === "release") {
  // The release check (std-release-check.yml): dispatched before a production promotion. The commit under test is
  // RELEASE_SHA (the dispatch's sha input), never GITHUB_SHA (the ref's tip). Wait for every Workers Builds check on that commit, then name every configured browser
  // (Chromium and the extras) and the staging URL for the install, e2e and repo-check steps.
  const get = ghApi(), sha = env.RELEASE_SHA || git("rev-parse", "HEAD").trim(), short = sha.slice(0, 7);
  const name = pack.preview?.check_name ?? "Workers Builds";
  // Every Workers Builds check on the commit (one per Worker) must have completed successfully before the suite runs (no
  // time cap; the job's timeout is the only backstop). None at all is an error: staging is not deployed by Workers Builds.
  const wait = Number(env.GATE_PREVIEW_WAIT_S ?? Infinity) * 1000, poll = Number(env.GATE_POLL_S ?? 15) * 1000, start = Date.now();
  let runs;
  for (;;) {
    runs = await buildRuns(get, sha, name);
    if (!runs.length) fail(`no "${name}" check on ${short}`, "release-check is dispatched for a version's commit that has a Workers Builds check; pass the sha of one that does");
    const red = runs.find((c) => c.status === "completed" && !["success", "skipped"].includes(c.conclusion));
    if (red) fail(`Cloudflare build failed for ${short}: ${red.name} ${red.conclusion} (${red.details_url})`, "fix the Worker build on main; staging and the uploaded version come from it");
    if (runs.every((c) => c.status === "completed")) break;
    if (Date.now() - start >= wait) fail(`the Cloudflare build for ${short} is still running after ${wait / 1000}s`, "re-run the release check once the build finishes");
    await new Promise((r) => setTimeout(r, poll));
  }
  // What there is to certify comes only from the authenticated Builds results on this commit: any success certifies it, none (all skipped or neutral) is nothing to certify.
  if (!runs.some((c) => c.conclusion === "success")) await cancelRun(`nothing to certify: Cloudflare deployed nothing for ${short} (every build skipped or neutral)`);
  const sup = await supersededBy(get, sha, name);
  if (sup) await cancelRun(`superseded: ${sup.slice(0, 7)} on the default branch deploys staging after ${short}; its release check covers it`);
  const extra = [...new Set(["chromium", ...(e2eCfg.browsers ?? []), ...(pack.e2e_release_browsers ?? [])])]; // the full suite runs every configured browser
  console.log(`release: ${extra.join(", ")} against ${std.staging_url} (${short})`);
  output("browsers", extra.join(","));
  output("url", std.staging_url ?? "");
} else if (cmd === "release-verify") {
  // After the suite: a commit that deployed to staging meanwhile means the suite tested its deployment, not this commit's.
  const get = ghApi(), sha = env.RELEASE_SHA || git("rev-parse", "HEAD").trim();
  const sup = await supersededBy(get, sha, pack.preview?.check_name ?? "Workers Builds");
  if (sup) await cancelRun(`superseded during the suite: ${sup.slice(0, 7)} on the default branch deploys staging after ${sha.slice(0, 7)}; its release check covers it`);
  console.log(`release: no later commit deployed staging during ${sha.slice(0, 7)}'s suite`);
} else if (cmd === "release-start") {
  // First step after checkout: the dispatched sha must be the exact 40-hex commit and reachable from the default branch (a
  // version only ever comes from there); then the verdict check-run exists, in_progress, until the report step completes it.
  const sha = env.RELEASE_SHA ?? "", repo = event.repository?.default_branch || "main";
  if (!/^[0-9a-f]{40}$/.test(sha)) fail(`release-check needs the version's full 40-character commit sha (got ${JSON.stringify(sha)})`, "dispatch with sha set to the commit's full lowercase hex sha");
  let reachable = false;
  try { git("merge-base", "--is-ancestor", sha, `origin/${repo}`); reachable = true; } catch {}
  if (!reachable) fail(`${sha.slice(0, 7)} is not on the default branch (${repo}); a release-check certifies only a commit that main contains`, "dispatch with the sha of a commit on the default branch");
  const r = await checksWrite("POST", "/check-runs", { name: "release-check", head_sha: sha, status: "in_progress", started_at: new Date().toISOString(), details_url: runUrl(),
    output: { title: "release-check running", summary: `The full suite is running against staging for ${sha}.` } });
  if (!r.ok) fail(`could not create release-check on ${sha.slice(0, 7)} (${r.status})`, "grant the job checks: write");
  const id = (await r.json()).id;
  output("check_id", String(id));
  if (env.GITHUB_ENV) appendFileSync(env.GITHUB_ENV, `RELEASE_CHECK_ID=${id}\n`);
  console.log(`release-check ${id} in progress on ${sha.slice(0, 7)}`);
} else if (cmd === "release-report") {
  // Completes the verdict exactly once: success or failure from the job, cancelled when the job was cancelled. A run that
  // already completed it as neutral (superseded, nothing to certify) is left as it is.
  const sha = env.RELEASE_SHA ?? "", s = env.RELEASE_JOB_STATUS;
  if (!env.RELEASE_CHECK_ID) fail("no release-check to complete", "release-start creates it");
  const cur = await (await checksWrite("GET", `/check-runs/${env.RELEASE_CHECK_ID}`)).json();
  if (cur.status === "completed") { console.log(`release-check already ${cur.conclusion} on ${sha.slice(0, 7)}`); process.exit(0); }
  const conclusion = s === "success" ? "success" : s === "cancelled" ? "cancelled" : "failure";
  const say = { success: "passed", failure: "failed", cancelled: "was cancelled" }[conclusion];
  await completeCheck(conclusion, `release-check ${say}`, `The full suite ${say} against staging for ${sha}.${conclusion === "cancelled" ? " This is not a pass." : ""}`);
  console.log(`release-check ${conclusion} on ${sha.slice(0, 7)}`);
} else if (cmd === "classify") {
  // Codex cloud has no origin: fall back to a local default branch, then to HEAD itself (uncommitted and untracked
  // files only). Never the branch's upstream: that is usually the pushed feature head, which would hide its changes.
  let base;
  for (const b of args[0] ? [args[0]] : ["origin/HEAD", "origin/main", "origin/master", "main", "master", "HEAD"]) {
    try { base = git("merge-base", b, "HEAD").trim(); break; } catch {}
  }
  if (!base) fail(`base ${args[0]} not found`, "git fetch origin, or pass a base ref");
  const files = git("diff", "--name-only", "-z", base).split("\0").concat(git("ls-files", "-oz", "--exclude-standard").split("\0"));
  console.log(ui([...new Set(files.filter(Boolean))]).join("\n") || "no UI paths changed");
} else if (cmd === "playwright") {
  // The browser cache name for this run: the repo's exact Playwright version and this run's browsers. Empty when the
  // repo does not use Playwright (the workflow then skips the cache and the browser install).
  const d = { ...pkg?.dependencies, ...pkg?.devDependencies }, bin = playwrightBin();
  const v = (d.playwright || d["@playwright/test"]) ? spawnSync(bin[0], [...bin[1], "--version"], { encoding: "utf8" }) : null;
  const version = v?.status === 0 ? (v.stdout.match(/\d+\.\d+\.\d+\S*/) ?? [""])[0] : "";
  output("key", version ? `playwright-${process.platform}-${process.arch}-${version}-${[...browsers()].sort().join("+")}` : "");
} else if (cmd === "install") {
  if (!pkg) console.log("notice: no package.json; nothing to install");
  else {
    if (!args.includes("--browsers-only")) {
      if (pm !== "npm") must("corepack", ["enable"]);
      must(pm, pm === "pnpm" ? ["install", "--frozen-lockfile"] : pm === "yarn" ? ["install", has(".yarnrc.yml") ? "--immutable" : "--frozen-lockfile"]
        : has("package-lock.json") || has("npm-shrinkwrap.json") ? ["ci"] : ["install", "--no-package-lock"]);
    }
    const d = { ...pkg.dependencies, ...pkg.devDependencies };
    // The repo's own Playwright (so the browser matches the lockfile); only this run's browsers. The workflow caches
    // the browsers directory (named by `playwright`), so `install` downloads only on a miss; system packages are
    // installed only when the browsers' shared libraries are missing (apt update and install were most of the cost).
    if ((d.playwright || d["@playwright/test"]) && !args.includes("--no-browsers")) {
      const bin = playwrightBin();
      must(bin[0], [...bin[1], "install", ...browsers()]);
      if (browserDepsMissing()) must(bin[0], [...bin[1], "install-deps", ...browsers()]);
    }
  }
} else if (cmd === "run") {
  const s = args.find((x) => pkg?.scripts?.[x]);
  if (!args.length) fail("no script named", "gate.mjs run <script>...");
  if (!s) console.log(`notice: no ${args.join(" or ")} script in package.json; skipped`);
  else {
    console.log(`run: ${pm} run ${s}`); must(pm, ["run", s]);
    if (s === "build") {
      const rollback = rollbackFindings({ built: true });
      for (const message of rollback.errors) {
        if (rollback.draft) console.log(`::warning::${message}`);
        else fail(message, "split into expand now, contract in a later release");
      }
      for (const note of rollback.notes) console.log(`NOTE: ${note}`);
      try { verifyGeneratedBuild(std, pkg); }
      catch (e) { fail(`generated Wrangler config: ${e.message}`, "make the build honor CLOUDFLARE_ENV=staging before releasing"); }
    }
    if (s === "build" && pack.profile === "client" && has("dist")) scanBuilt();
  }
} else if (cmd === "e2e") {
  // "e2e": false skips this step and the preview step (docs and static repos, and repos whose Workers Builds run on every PR without an e2e suite).
  if (std.e2e === false) { console.log('::warning::e2e skipped; standards.json sets "e2e": false'); process.exit(0); }
  const docs = args.includes("--local") ? null : docOnly();
  if (docs) { docSkip("e2e", docs); process.exit(0); }
  // standards.json "e2e": "<command>" names the suite; else a script, a tests/e2e or e2e dir, or a root Playwright config.
  const script = ["test:e2e", "e2e"].find((s) => pkg?.scripts?.[s]), dir = ["tests/e2e", "e2e"].find(has);
  const rootPw = ls(".").some((f) => /^playwright\.config\.[cm]?[jt]s$/.test(f)), pw = rootPw || (dir && ls(dir).some((f) => /^playwright\.config\.[cm]?[jt]s$/.test(f)));
  // Playwright runs this run's browsers only (Chromium unless the release check opts in more), when the config defines
  // those projects; a config without projects runs as it is.
  const cfgFile = [...(rootPw ? ls(".") : []), ...(dir && !rootPw ? ls(dir).map((f) => `${dir}/${f}`) : [])].find((f) => /(^|\/)playwright\.config\.[cm]?[jt]s$/.test(f));
  const cfg = cfgFile ? rd(cfgFile, "utf8") : "", named = (b) => new RegExp(`name:\\s*['"\`]${b}['"\`]`).test(cfg);
  // Only GATE_SELECT=full (the release check) runs every Playwright project with no file filter; every gate run (pull request, merge queue, re-gate) is Chromium only.
  const everything = env.GATE_SELECT === "full", projects = !everything && /\bprojects\s*:/.test(cfg) ? browsers().filter(named).map((b) => `--project=${b}`) : [];
  const pwBin = has("node_modules/.bin/playwright") ? ["node_modules/.bin/playwright", []] : ["npx", ["--no-install", "playwright"]];
  // Only a package script that is exactly a bare `playwright test` gets the project and file arguments (npm needs `--` before them); any other script (flags such as --grep, `&&` chains) runs unchanged.
  const pwScript = script && /^\s*(?:(?:npx\s+(?:--no-install\s+)?|pnpm\s+(?:exec\s+)?|yarn\s+(?:exec\s+)?)?playwright\s+test)\s*$/.test(pkg.scripts[script]);
  // Without --project Playwright runs every project, so a config whose projects are named otherwise is refused.
  if (!everything && !e2eCmd && (!script || pwScript) && cfg && /\bprojects\s*:/.test(cfg) && !projects.length)
    fail(`${cfgFile} defines projects but none named ${browsers().join(" or ")}, so gate cannot pick the Chromium run`, 'name the Chromium project "chromium" (gate runs only that), or set standards.json e2e.command');
  // kind: what the run is, so the selected files can be handed to it ("pw" Playwright, "node" node --test, null as written).
  const nodeTests = dir && ls(dir, { recursive: true }).some((f) => /\.test\.[cm]?js$/.test(f));
  const kind = e2eCmd ? null : script ? (pwScript ? "pw" : null) : dir && pw ? "pw" : rootPw ? "pw" : nodeTests ? "node" : null;
  const run = e2eCmd ? ["bash", ["-c", e2eCmd]] : script ? [pm, ["run", script, ...(pwScript && projects.length ? [...(pm === "npm" ? ["--"] : []), ...projects] : [])]] : dir && pw ? [pwBin[0], [...pwBin[1], "test", ...(everything ? (rootPw ? [] : ["-c", cfgFile]) : [dir]), ...projects]]
    : rootPw ? [pwBin[0], [...pwBin[1], "test", ...projects]]
    : nodeTests ? ["node", ["--test", `${dir}/**/*.test.*js`]] : null;
  // No time limit of any kind here: a slow suite is a test-quality problem, not a gate failure. Only the workflow's
  // timeout-minutes stops a runaway job.
  const url = env.GATE_PREVIEW_URL ?? "";
  // The @a11y contract: tests tagged @a11y skip unless RELEASE_CHECK=1. Only the release check (e2e --release) passes it on; a
  // pull request's gate clears it, even when inherited.
  const { RELEASE_CHECK: releaseFlag, ...cleanEnv } = env, baseEnv = args.includes("--release") && releaseFlag === "1" ? env : cleanEnv;
  // A client site's preview must not be indexed: its home page and a page only the Worker can answer (a 404; static
  // _headers rules do not cover Worker-rendered responses) both say noindex, in a robots meta or X-Robots-Tag.
  if (url && pack.profile === "client" && !args.includes("--local")) {
    const directives = (v) => v.toLowerCase().split(",").map((d) => d.replace(/^[^:]*:/, "").trim());
    const attrs = (tag) => Object.fromEntries([...tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g)].map((a) => [a[1].toLowerCase(), a[2] ?? a[3] ?? a[4]]));
    for (const page of [url, new URL("/__std-noindex-probe", url).href]) {
      let res = null, html = "";
      try { res = await fetch(page, { redirect: "follow" }); html = await res.text(); }
      catch (e) { fail(`the preview at ${page} did not answer: ${e.cause?.code ?? e.message}`, "re-run gate once the preview is up"); }
      // Only active markup counts: not inside an HTML comment, <noscript> or <template>.
      const active = html.replace(/<!--[\s\S]*?-->/g, "").replace(/<(noscript|template)\b[\s\S]*?<\/\1\s*>/gi, "");
      const meta = [...active.matchAll(/<meta\b[^>]*>/gi)].map(([t]) => attrs(t)).some((a) => /^(robots|googlebot)$/i.test(a.name ?? "") && directives(a.content ?? "").some((d) => ["noindex", "none"].includes(d)));
      if (!meta && !directives(res.headers.get("x-robots-tag") ?? "").some((d) => ["noindex", "none"].includes(d)))
        fail(`the preview at ${page} carries no noindex (robots meta or X-Robots-Tag)`, "previews must not be indexed: send X-Robots-Tag: noindex on every non-production host, from public/_headers for static files and from the middleware for Worker-rendered responses");
    }
    console.log(`preview noindex: ok (${url})`);
  }
  if (run) {
    // Affected tests: what the change can reach (select.mjs), unless standards.json sets "affected": false. Playwright and
    // `node --test` runs take the selected files; a custom command or package script runs as written and reads GATE_AFFECTED*.
    const sel = planSelection({ env });
    console.log(summarize(describeSelection(sel), env));
    // The whole suite unless the PR only adds or modifies e2e specs (select.mjs). null = unfiltered.
    const e2eFiles = listFor(sel), esc = (f) => f.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$";
    const childEnv = { ...baseEnv, ...(url && { PLAYWRIGHT_BASE_URL: url, BASE_URL: url }), GATE_AFFECTED: e2eFiles ? "scoped" : "full", GATE_AFFECTED_E2E: (e2eFiles ?? []).join(" "),
      ...(e2eFiles ? {} : { GATE_SELECT: "full" }) };
    let argv = run[1];
    // Only specs the runner can be pointed at are passed as filters; any other layout runs the whole suite.
    const mine = e2eFiles?.filter((f) => script || rootPw || !dir || f.startsWith(`${dir}/`));
    const narrow = e2eFiles && mine.length === e2eFiles.length;
    if (narrow && kind === "pw") argv = [...run[1].filter((a) => script || a !== dir), ...(script && pm === "npm" && !run[1].includes("--") ? ["--"] : []), ...mine.map(esc)];
    else if (narrow && kind === "node" && mine.every((f) => /\.test\.[cm]?js$/.test(f))) argv = ["--test", ...mine];
    else if (e2eFiles) console.log(`e2e: ${e2eCmd ? "this command" : "this layout"} runs as written; it reads GATE_AFFECTED, GATE_AFFECTED_E2E and GATE_SELECT for the selection`);
    console.log(`e2e: ${run[0]} ${argv.map((a) => (a.includes("*") ? `"${a}"` : a)).join(" ")}${url ? ` against ${url}` : ""}`);
    const r = spawnSync(run[0], argv, { stdio: "inherit", env: childEnv });
    if (r.status) process.exit(r.status);
    if (r.error || r.signal) fail(`e2e did not finish: ${r.error?.message ?? r.signal}`, "re-run gate");
  }
  else fail("no e2e suite (test:e2e or e2e script; tests/e2e/ or e2e/ with playwright.config.* or *.test.*js)",
    'add an end-to-end suite through the real entry point; docs/static repos (or Builds-only repos) only: "e2e": false in standards.json');
} else if (cmd === "secrets") {
  const V = "8.30.1", local = env.GATE_GITLEAKS_ARCHIVE;
  const platform = `${process.platform}_${process.arch}`;
  const sums = {
    linux_x64: "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb",
    linux_arm64: "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080",
    darwin_x64: "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709",
    darwin_arm64: "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
  }, SUM = sums[platform];
  if (!SUM) fail(`secret scan unsupported on ${platform}`, "run on macOS or Linux, x64 or arm64");
  const dir = mkdtempSync(`${tmpdir()}/gitleaks-`), tgz = local || `${dir}/gl.tgz`;
  if (!local) {
    const res = await fetch(`https://github.com/gitleaks/gitleaks/releases/download/v${V}/gitleaks_${V}_${platform}.tar.gz`);
    if (!res.ok) fail(`gitleaks download: ${res.status}`, "re-run the job");
    writeFileSync(tgz, Buffer.from(await res.arrayBuffer()));
  }
  const got = createHash("sha256").update(rd(tgz)).digest("hex");
  if (got !== SUM) fail(`gitleaks archive checksum mismatch: got ${got}, want ${SUM}`, "do not run it; re-run, or pin a new version and checksum in the engine");
  must("tar", ["-xzf", tgz, "-C", dir, "gitleaks"]);
  // Always scan commits: PR base..head, merge group base..head, a dispatch re-gate's merge ref (base tip..PR head),
  // push before..sha (a new branch scans what the default branch lacks); RANGE overrides.
  const ev = env.GITHUB_EVENT_PATH ? json(env.GITHUB_EVENT_PATH) ?? {} : {}, reach = (x) => { try { git("cat-file", "-e", `${x}^{commit}`); return true; } catch { return false; } };
  const def = ev.repository?.default_branch, fresh = (b) => !b || /^0+$/.test(b) || !reach(b);
  // A workflow_dispatch re-gate checked out refs/pull/N/merge: its parents are the base tip and the PR head.
  const merge = env.GITHUB_EVENT_NAME === "workflow_dispatch" && reach("HEAD^2");
  const pair = merge ? ["HEAD^1", "HEAD^2"] : ev.pull_request ? [ev.pull_request.base.sha, ev.pull_request.head.sha] : ev.merge_group ? [ev.merge_group.base_sha, ev.merge_group.head_sha]
    : ev.after ? [fresh(ev.before) && def && ev.ref !== `refs/heads/${def}` && reach(`origin/${def}`) ? `origin/${def}` : ev.before, ev.after] : [null, env.GITHUB_SHA || "HEAD"];
  const r = env.RANGE || (pair[0] && !/^0+$/.test(pair[0]) && reach(pair[0]) ? `${pair[0]}..${pair[1]}` : pair[1]);
  console.log(`secrets: gitleaks git --log-opts=${r}`);
  if (sh(`${dir}/gitleaks`, ["git", `--log-opts=${r}`, "--redact", "--no-banner", "-v", "."]))
    fail("gitleaks found a secret (redacted above)", "rotate it and remove it from the branch history; false positive: its fingerprint in .gitleaksignore");
}
