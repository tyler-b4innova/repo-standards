#!/usr/bin/env node
// Offline standards self-check (`scripts/agent/setup.sh --check`: session start and `gate`).
// One line per failure with its fix; warnings never fail. Exit 1 on any failure.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { claudePins, codexPins } from "./pins.mjs";

if (process.argv.includes("--help")) {
  console.log("usage: node scripts/agent/check.mjs   (offline standards self-check; exit 1 on failure)");
  process.exit(0);
}
const git = (...a) => execFileSync("git", a, { encoding: "utf8", maxBuffer: 1 << 26 });
process.chdir(git("rev-parse", "--show-toplevel").trim());
const read = (f) => { try { return readFileSync(f, "utf8"); } catch { return null; } };
const json = (f) => { try { return JSON.parse(read(f)); } catch { return null; } };
const sha = (s) => createHash("sha256").update(s).digest("hex");
const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
const out = [];
let fails = 0;
const fail = (msg, fix) => { out.push(`FAIL: ${msg} | fix: ${fix}`); fails++; };
const warn = (msg) => out.unshift(`WARN: ${msg}`);

const pack = json("scripts/agent/pack.json");
if (!pack) fail("scripts/agent/pack.json missing or invalid", "re-apply the pack from the org standards repository");
else {
  const tracked = git("ls-files", "-z").split("\0").filter(Boolean);
  const pin = git("log", "-1", "--format=%h", "--", "standards.lock").trim() || "HEAD";
  const restore = (p) => `git checkout ${pin} -- ${p}`;
  const std = json("standards.json");
  if (!std) fail("standards.json missing or not JSON", restore("standards.json"));
  else {
    const one = (k, vals) => vals.includes(std[k]) || fail(`standards.json ${k} is ${JSON.stringify(std[k])}`, `use one of ${vals.join("|")}`);
    one("pack", [pack.pack]); one("profile", ["internal", "client"]); one("dispatch", ["auto", "manual", "off"]);
    one("sensitive", [true, false]); const e = std.e2e, eo = e && typeof e === "object" && !Array.isArray(e);
    const e2eOk = e === undefined || e === false || (typeof e === "string" && e.trim()) || (eo && Object.keys(e).every((k) => ["command", "browsers", "preview", "budget"].includes(k))
      && (e.command === undefined || (typeof e.command === "string" && e.command.trim())) && (e.browsers === undefined || (Array.isArray(e.browsers) && e.browsers.every((b) => ["chromium", "firefox", "webkit"].includes(b))))
      && [undefined, false].includes(e.preview) && (e.budget === undefined || (typeof e.budget === "number" && e.budget > 0)));
    if (!e2eOk) fail(`standards.json e2e is ${JSON.stringify(e)}`, 'use false (docs/static only), the e2e command, or {"command", "browsers" (promotion PRs), "preview": false, "budget" (minutes, tighter only)}');
    if (std.deploy_workflow !== undefined && !(typeof std.deploy_workflow === "string" && /^[\w.-]+\.ya?ml$/.test(std.deploy_workflow)))
      fail(`standards.json deploy_workflow is ${JSON.stringify(std.deploy_workflow)}`, "name the one deploy workflow file, e.g. deploy.yml"); one("flow", [undefined, "staged", "direct"]); one("design_signoff", [undefined, true, false]);
    if (std.allow_paths !== undefined && !(Array.isArray(std.allow_paths) && std.allow_paths.every((g) => typeof g === "string" && g.trim())))
      fail(`standards.json allow_paths is ${JSON.stringify(std.allow_paths)}`, 'a list of globs, e.g. ["plugins/*/.mcp.json"]');
    if (!/^\d+\.\d+\.\d+$/.test(std.version ?? "")) fail("standards.json version is not X.Y.Z", restore("standards.json"));
    const globs = (v) => v === undefined || (Array.isArray(v) && v.every((g) => typeof g === "string"));
    const ui = std.ui_paths;
    if (!(globs(ui) || (ui && typeof ui === "object" && globs(ui.include) && globs(ui.ignore))))
      fail("standards.json ui_paths must be a glob list or {include, ignore}", "fix it, or delete it for the engine defaults");
    if (!globs(std.risk_paths)) fail("standards.json risk_paths must be a glob list", "fix it, delete it for the engine defaults, or [] for none");
    // production_urls: what the org launcher smoke-tests after a production deploy
    if (std.production_urls !== undefined && !(Array.isArray(std.production_urls) && std.production_urls.every((u) => { try { return new URL(u).protocol === "https:"; } catch { return false; } })))
      fail(`standards.json production_urls is ${JSON.stringify(std.production_urls)}`, 'a list of absolute https URLs, e.g. ["https://example.com/"]');
  }

  // The lock: every managed file and the AGENTS.md block, by sha256.
  const lock = read("standards.lock"), agents = read("AGENTS.md");
  const begin = `<!-- std:begin ${pack.pack} -->`, end = "<!-- std:end -->";
  if (!lock) fail("standards.lock missing", restore("standards.lock"));
  else {
    const [, lp, lv, lpr] = lock.match(/^# (\S+) v(\S+) (\S+) engine \S+/) ?? [];
    for (const [k, l] of [["pack", lp], ["version", lv], ["profile", lpr]])
      if (std && std[k] !== l) fail(`standards.lock says ${k} ${l ?? "(no header)"}, standards.json ${std[k]}`, `${restore("standards.json standards.lock")}   (or re-apply the pack)`);
    for (const [want, path] of lock.split("\n").filter((l) => l && !l.startsWith("#")).map((l) => l.split(/\s+/))) {
      if (path === "AGENTS.md#std") {
        const lines = (agents ?? "").split("\n"), i = lines.indexOf(begin), j = lines.indexOf(end, i);
        if (i < 0 || j < 0 || sha(lines.slice(i, j + 1).join("\n") + "\n") !== want)
          fail("the managed AGENTS.md block was edited or removed", `restore it from: git show ${pin}:AGENTS.md`);
      } else if (path.endsWith("#std")) { // the managed CODEOWNERS block (UI paths' code owners)
        const file = path.slice(0, -4), lines = (read(file) ?? "").split("\n"), i = lines.findIndex((l) => l.startsWith(`# std:begin ${pack.pack} `)), j = lines.indexOf("# std:end", i);
        if (i < 0 || j < 0 || sha(lines.slice(i, j + 1).join("\n") + "\n") !== want)
          fail(`the managed ${file} block was edited or removed`, `restore it from: git show ${pin}:${file}   (UI paths come from standards.json ui_paths)`);
        else if (lines.slice(j + 1).some((l) => l.trim() && !l.trim().startsWith("#")))
          fail(`${file} has lines after the managed block, which override it (the last match wins)`, "move them above the `# std:begin` line");
      } else if (!existsSync(path)) fail(`managed file missing: ${path}`, restore(path));
      else if (sha(readFileSync(path)) !== want) fail(`managed file changed: ${path}`, `${restore(path)}   (change it upstream)`);
    }
  }
  if (agents === null) fail("AGENTS.md missing", restore("AGENTS.md"));
  else {
    const size = Buffer.byteLength(agents), n = (agents.match(/<!-- std:begin [a-z0-9-]+ -->/g) ?? []).length, m = agents.split(end).length - 1;
    if (size > 4096) fail(`AGENTS.md is ${size} bytes (limit 4096)`, "cut the repo-owned part to repeated failure modes only; nothing package.json, config or CI already says");
    if (n !== 1 || m !== 1) fail(`AGENTS.md has ${n} std:begin and ${m} std:end markers (need one each)`, "delete the duplicate block");
  }

  // Agent config
  const claude = read("CLAUDE.md");
  // import-only: the shim is @AGENTS.md first, then only Claude-specific lines (Claude reads the import, then the rest).
  if (claude !== null && (pack.claude_md === "forbid" || claude.split("\n").find((l) => l.trim())?.trim() !== "@AGENTS.md"))
    fail("CLAUDE.md holds its own content", pack.claude_md === "forbid" ? "git rm CLAUDE.md   (agents read AGENTS.md)" : "move it to AGENTS.md; CLAUDE.md starts with @AGENTS.md, then only Claude-specific lines");
  if (claude === null && existsSync("CLAUDE.local.md")) warn("CLAUDE.local.md without CLAUDE.md makes Claude skip AGENTS.md | fix: add a CLAUDE.md holding @AGENTS.md, or remove CLAUDE.local.md");
  // Claude Code reads AGENTS.md only when no CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md sits in the working
  // directory or above it; the user's own ~/.claude/CLAUDE.md does not count. Folders above the repository, up to $HOME.
  const real = (p) => { try { return realpathSync(p); } catch { return p; } };
  const home = real(homedir()), tilde = (p) => (p.startsWith(home + "/") ? "~" + p.slice(home.length) : p);
  // A root CLAUDE.md that imports AGENTS.md still loads it, so ancestors cannot hide it then.
  const imports = claude?.split("\n").find((l) => l.trim())?.trim() === "@AGENTS.md";
  for (let d = dirname(process.cwd()), up = !imports && home !== process.cwd() && process.cwd().startsWith(home + "/"); up; d = dirname(d)) {
    for (const f of ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"])
      if (!(d === home && f === ".claude/CLAUDE.md") && existsSync(join(d, f)))
        warn(`${tilde(join(d, f))} makes Claude skip AGENTS.md in this repository | fix: delete it (personal rules belong in ~/.claude/CLAUDE.md, which does not count)`);
    if (d === home || d === dirname(d)) break;
  }
  let link = null;
  try { link = readlinkSync(".claude/skills"); } catch {}
  if (link !== "../.agents/skills") fail(".claude/skills is not a link to ../.agents/skills", "rm -rf .claude/skills && ln -s ../.agents/skills .claude/skills");
  const s = json(".claude/settings.json");
  const on = (m) => ["", "*"].includes(m ?? "") || ["startup", "resume"].every((e) => m.split("|").includes(e));
  if (!s?.hooks?.SessionStart?.some((m) => on(m.matcher) && m.hooks?.some((h) => h.command === '"$CLAUDE_PROJECT_DIR"/scripts/agent/setup.sh --check')))
    fail(".claude/settings.json lacks the SessionStart setup.sh --check hook for startup and resume", restore(".claude/settings.json"));
  // The deny set and the Codex bypass keys are engine-owned; the pack pins no model.
  if (s && JSON.stringify(s.permissions?.deny) !== JSON.stringify(pack.permissions_deny))
    fail(".claude/settings.json deny set changed", restore(".claude/settings.json"));
  // Repositories never pin a model or effort: each person's app (or the org launcher) chooses.
  const pinned = [...claudePins(s).map((k) => `.claude/settings.json ${k}`), ...codexPins(read(".codex/config.toml")).map((p) => `.codex/config.toml ${p.key}`)];
  if (pinned.length) fail(`the repo pins a model or effort (${pinned.join(", ")})`, "delete those keys (or re-apply the pack): model and effort belong to each person's app or the launcher");
  const [top] = (read(".codex/config.toml") ?? "").split(/^(?=\s*\[)/m);
  if (!Object.entries(pack.codex_top).every(([k, v]) => new RegExp(`^\\s*${k}\\s*=\\s*"${v}"\\s*(#.*)?$`, "m").test(top)))
    fail(".codex/config.toml engine keys changed", restore(".codex/config.toml"));

  // Forbidden paths and content
  // standards.json allow_paths: repo-owned globs for shipped content that looks like agent config (a plugin's .mcp.json);
  // they exempt the .mcp.json and forbidden-path checks only.
  // standards.json nested_instructions: [{path, reason}], the only AGENTS.md / CLAUDE.md files allowed below the root.
  const nested = new Set(), declaredNested = std?.nested_instructions;
  if (declaredNested !== undefined) {
    if (!Array.isArray(declaredNested)) fail("standards.json nested_instructions must be a list", "use [{path, reason}] or remove it");
    else for (const e of declaredNested) {
      if (!(e && typeof e === "object" && Object.keys(e).sort().join(",") === "path,reason" && typeof e.path === "string" && typeof e.reason === "string" && e.reason.trim())) {
        fail("standards.json nested_instructions has an invalid entry", "each entry is {path, reason} with a nonempty reason"); continue;
      }
      const base = e.path.split("/").pop();
      if (!["AGENTS.md", "CLAUDE.md"].includes(base) || e.path === base) fail(`nested_instructions: ${e.path} is not an AGENTS.md or CLAUDE.md below the root`, "declare only nested AGENTS.md or CLAUDE.md files");
      else if (!tracked.includes(e.path)) fail(`nested_instructions names ${e.path}, which is not tracked`, "remove the stale entry");
      else nested.add(e.path);
    }
  }
  const allowed = (Array.isArray(std?.allow_paths) ? std.allow_paths.filter((g) => typeof g === "string" && g.trim()) : []).map(glob);
  for (const f of tracked) {
    const name = f.split("/").pop(), dirs = f.split("/").slice(0, -1).map((d) => d.toLowerCase()), ok = allowed.some((r) => r.test(f));
    if (name === "CONTEXT.md") fail(`CONTEXT.md is forbidden: ${f}`, `git rm ${f}   (rules go in AGENTS.md)`);
    if (["AGENTS.md", "CLAUDE.md"].includes(name) && f !== name && !nested.has(f))
      fail(`undeclared nested instruction file: ${f}`, `fold it into the root AGENTS.md and git rm ${f}, or declare it in standards.json nested_instructions as {"path": "${f}", "reason": "<the subdirectory's own rule>"}`);
    if (name === ".mcp.json" && !ok) fail(`${f} is committed`, `git rm --cached ${f} && echo .mcp.json >> .gitignore`);
    if (f.startsWith(".evidence/")) fail(`.evidence/ is tracked (${f})`, "git rm -r .evidence   (pr.sh evidence removes it after posting)");
    if ((/\.(md|markdown)$/i.test(name) && dirs.some((d) => pack.decision_dirs.includes(d))) || /^ADR-.*\.md$/i.test(name) || pack.decision_record_globs.some((g) => glob(g).test(f)))
      fail(`decision record tracked: ${f}`, `git rm ${f}   (decisions are not recorded; they must be evident in the work)`);
    if (!ok) for (const g of pack.forbid_paths) if (glob(g).test(f)) fail(`${f} matches the org's forbidden path ${g}`, `git rm -r --cached ${f}`);
  }
  // CI: one gate per head. Every job has a timeout; repo workflows neither test on pull requests nor re-test pushes to
  // the default or integration branch (checks go in scripts/agent/gate.local.sh); no schedule runs more than daily;
  // Playwright installs name their browsers. A line-level reading of the block YAML workflows use.
  const exceptions = new Set(), declared = std?.duplicate_check_exceptions;
  if (declared !== undefined) {
    if (!Array.isArray(declared)) fail("standards.json duplicate_check_exceptions must be a list", "use [{path, sha256, reason}] or remove it");
    else for (const e of declared) {
      const valid = e && typeof e === "object" && !Array.isArray(e) &&
        Object.keys(e).sort().join(",") === "path,reason,sha256" &&
        typeof e.path === "string" && /^\.github\/workflows\/[A-Za-z0-9._-]+\.ya?ml$/.test(e.path) &&
        typeof e.sha256 === "string" && /^[0-9a-f]{64}$/.test(e.sha256) &&
        typeof e.reason === "string" && e.reason.trim();
      if (!valid) { fail("standards.json duplicate_check_exceptions has an invalid entry", "name one workflow path, its lowercase SHA256, and a nonempty reason"); continue; }
      if (exceptions.has(e.path)) { fail(`duplicate_check_exceptions repeats ${e.path}`, "keep one pinned entry per workflow"); continue; }
      if (!tracked.includes(e.path)) { fail(`duplicate_check_exceptions names missing workflow ${e.path}`, "track the exact workflow, or remove the exception"); continue; }
      if (sha(readFileSync(e.path)) !== e.sha256) { fail(`duplicate_check_exceptions SHA256 mismatch for ${e.path}`, "update the reviewed hash and reason for this workflow revision, or remove the exception"); continue; }
      exceptions.add(e.path);
    }
  }
  const deploy = std?.deploy_workflow;
  for (const f of tracked.filter((f) => /^\.github\/workflows\/[^/]+\.ya?ml$/.test(f))) {
    const text = read(f) ?? "", L = text.split("\n"), name = f.split("/").pop(), managed = /^std-/.test(name);
    const onAt = L.findIndex((l) => /^["']?on["']?:/.test(l)), inline = onAt >= 0 ? L[onAt].replace(/^["']?on["']?:\s*/, "").trim() : "";
    const block = (at, indent) => { const b = []; for (let i = at + 1; i < L.length && (L[i].trim() === "" || L[i].search(/\S/) > indent || L[i].trim().startsWith("#")); i++) b.push(L[i]); return b; };
    const onBlock = onAt >= 0 ? block(onAt, 0) : [];
    const triggers = inline ? inline.replace(/[[\]{}]/g, "").split(",").map((t) => t.trim().split(":")[0]).filter(Boolean)
      : onBlock.filter((l) => /^ {2}[a-z_]+:/.test(l)).map((l) => l.trim().split(":")[0]);
    const pushAt = onBlock.findIndex((l) => /^ {2}push:/.test(l)), push = pushAt >= 0 ? block(onAt + 1 + pushAt, 2).map((l) => l.trim()).join(" ") : "";
    const pushBranches = /branches:/.test(push) ? push.replace(/.*branches:\s*/, "").split(/tags:|paths:|branches-ignore:|paths-ignore:/)[0].match(/[\w./*-]+/g) ?? [] : null;
    const integrationPush = triggers.includes("push") && (pushBranches === null ? !/tags:/.test(push) : pushBranches.some((b) => ["main", "master", "staging", "develop", "*", "**"].includes(b)));
    const crons = [...text.matchAll(/cron:\s*["']([^"']+)["']/g)].map((m) => m[1].trim());
    if (crons.length > 1 || crons.some((c) => !/^\d+\s+\d+\s/.test(c)))
      fail(`${f} is scheduled more often than daily (${crons.join("; ")})`, "one daily or rarer cron; polling and monitoring belong in Workers Cron Triggers");
    const jobsAt = L.findIndex((l) => /^jobs:/.test(l));
    const jobs = [];
    if (jobsAt >= 0) for (let i = jobsAt + 1; i < L.length; i++) {
      const m = L[i].match(/^ {2}([A-Za-z0-9_-]+):\s*$/);
      if (m) jobs.push({ name: m[1], body: block(i, 2) });
      else if (/^\S/.test(L[i])) break;
    }
    for (const j of jobs) if (!j.body.some((l) => /^ {4}(timeout-minutes|uses):/.test(l)))
      fail(`${f} job ${j.name} has no timeout-minutes (the default is 360 minutes)`, `add timeout-minutes to ${j.name} (gate 15, anything else at most 20)`);
    const runs = jobs.flatMap((j) => j.body).filter((l) => !/^\s*(-\s*)?(name|uses|id|if):/.test(l)).join("\n");
    if (/playwright install\b(?![^\n;&|]*\b(chromium|chrome|firefox|webkit|msedge)\b)/.test(runs))
      fail(`${f} runs playwright install without naming a browser (it downloads all of them)`, "name the browser: playwright install --with-deps chromium");
    const checks = /\b(tests?|e2e|lint|typecheck|tsc|vitest|jest|playwright|eslint|biome|gate|check)\b/i, builds = /\bbuild\b/i;
    if (!managed && !exceptions.has(f) && (triggers.some((t) => ["pull_request", "pull_request_target"].includes(t)) || (integrationPush && name !== deploy)) && (checks.test(runs) || (name !== deploy && integrationPush && builds.test(runs))))
      fail(`${f} runs checks on ${triggers.filter((t) => ["pull_request", "pull_request_target", "push"].includes(t)).join(" and ")}, beside the one gate`, "move them into scripts/agent/gate.local.sh and delete the workflow (a deploy workflow on push is declared as standards.json deploy_workflow and does not test)");
    if (!managed && name === deploy && checks.test(runs)) fail(`${f} is the declared deploy workflow but runs checks`, "gate tests; the deploy workflow only builds and deploys");
  }
  const scripts = Object.values(json("package.json")?.scripts ?? {}).join("\n") + "\n" + (read("scripts/agent/gate.local.sh") ?? "");
  if (/playwright install\b(?![^\n;&|]*\b(chromium|chrome|firefox|webkit|msedge)\b)/.test(scripts))
    fail("package.json scripts or gate.local.sh run playwright install without naming a browser", "name the browser: playwright install --with-deps chromium");
  // Quarantined tests: @quarantine(<issue link>, until YYYY-MM-DD), at most 14 days out, never past due.
  let q = "";
  try { q = git("grep", "-nI", "@quarantine", "--", ".", ":!scripts/agent", ":!*.md"); } catch {}
  const today = new Date().toISOString().slice(0, 10), limit = new Date(Date.now() + 14 * 864e5).toISOString().slice(0, 10);
  const testFile = (f) => /\.[cm]?[jt]sx?$/.test(f) && (/\.(test|spec)\.[cm]?[jt]sx?$/.test(f) || /(^|\/)(tests?|e2e|__tests__)\//.test(f));
  for (const line of q.split("\n").filter((l) => l && testFile(l.split(":")[0]))) {
    const at = line.split(":").slice(0, 2).join(":"), m = line.match(/@quarantine\b.*?(https?:\/\/\S+\/issues\/\d+|#\d+).*?\buntil\s+(\d{4}-\d{2}-\d{2})/);
    if (!m) fail(`${at}: @quarantine needs an issue link and an expiry`, "write @quarantine(#123, until YYYY-MM-DD), at most 14 days out");
    else if (m[2] < today) fail(`${at}: quarantine expired ${m[2]}`, "fix the test, or delete it; quarantine is not a place to keep it");
    else if (m[2] > limit) fail(`${at}: quarantine runs to ${m[2]}, more than 14 days out`, `set until ${limit} or sooner`);
  }
  for (const pat of pack.forbid_patterns) {
    let hit = "";
    try { hit = git("grep", "-nIiE", pat, "--", ".", ":!scripts/agent/pack.json").split(":").slice(0, 2).join(":"); } catch {}
    if (hit) fail(`forbidden internal reference /${pat}/ at ${hit}`, "remove the internal reference");
  }
  // Client sites: checks for the rules their copy-pasted AGENTS.md lines used to state (each guarded real damage).
  if (pack.profile === "client") {
    const src = tracked.filter((f) => /\.(astro|html|svelte|vue|[cm]?[jt]sx?)$/.test(f) && !/^(scripts\/agent|node_modules|dist)\//.test(f));
    // The Turnstile script is the versioned /turnstile/v0/api.js; the unversioned URL 404s, so the form never gets a token.
    for (const f of src)
      for (const [u] of (read(f) ?? "").matchAll(/challenges\.cloudflare\.com\/turnstile\/[^\s"'`)<>]*/g))
        if (!/\/siteverify$/.test(u) && !/\/turnstile\/v0\/api\.js(\?.*)?$/.test(u))
          fail(`${f} loads Turnstile from ${u}, not the versioned script`, "use https://challenges.cloudflare.com/turnstile/v0/api.js");
  }
  for (const host of pack.shared_preview_hosts)
    for (const f of tracked.filter((f) => /(^|\/)wrangler\.(jsonc?|toml)$/.test(f)))
      // The exact host only: {label}.preview.<zone> is the per-Worker form and must not match preview.<zone>.
      if (new RegExp(`(^|[^a-z0-9.-])${host.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![a-z0-9.-])`, "i").test(read(f) ?? ""))
        fail(`${f} uses the shared preview host ${host} (it binds to one Worker)`, `use a per-Worker host: ${pack.preview_host_pattern ?? "preview.<zone>"}`);
  if (Array.isArray(std?.ui_paths) && !std.ui_paths.length) {
    const ui = tracked.filter((f) => pack.ui_paths.some((g) => glob(g).test(f)) && !pack.ui_ignore.some((g) => glob(g).test(f)));
    if (ui.length) warn(`ui_paths is [] so gate needs no evidence, but these match the default UI globs: ${ui.slice(0, 10).join(", ")}`);
  }

  const userClaude = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "settings.json"), uc = json(userClaude);
  if (existsSync(dirname(userClaude)) && uc?.permissions?.defaultMode !== "bypassPermissions" && !uc?.skipDangerousModePermissionPrompt)
    warn(`Claude: bypass is not on for you, so agents will prompt | fix (once per person): set permissions.defaultMode "bypassPermissions" in ${userClaude}, or run claude --dangerously-skip-permissions once and accept`);
  const codexFile = join(process.env.CODEX_HOME || join(homedir(), ".codex"), "config.toml"), user = read(codexFile);
  if (user !== null) {
    const root = process.cwd(), esc = root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    if (!new RegExp(`^\\[projects\\."${esc}"\\]\\s*\\n(?:(?!\\[).*\\n)*?\\s*trust_level\\s*=\\s*"trusted"`, "m").test(user))
      warn(`Codex: project not trusted, so the repo's bypass and rules in .codex/ are inactive | fix: trust the folder when codex asks, or add [projects."${root}"] trust_level = "trusted" to ${codexFile}`);
    let ver = "";
    try { ver = execFileSync("codex", ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 1500 }).match(/(\d+)\.(\d+)/)?.slice(1).join(".") ?? ""; } catch {}
    const [maj, min] = ver.split(".").map(Number);
    if (ver && (maj === 0 && min < 155)) warn(`Codex CLI ${ver} is older than 0.155, which the repo's .codex/config.toml targets | fix: update codex`);
  }
  if (!fails) out.push(`standards ok: ${pack.pack} v${std.version} ${std.profile} (engine ${pack.engine}) dispatch=${std.dispatch}`);
}
console.log(out.join("\n"));
if (fails) {
  console.log(`standards check: ${fails} failure(s)`);
  process.exit(1);
}
