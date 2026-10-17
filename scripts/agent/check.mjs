#!/usr/bin/env node
// Offline standards self-check (`scripts/agent/setup.sh --check`: session start and `gate`).
// One line per failure with its fix; warnings never fail. Exit 1 on any failure.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { rollbackFindings } from "./rollback.mjs";
import { scan } from "./jsscan.mjs";
import { localConfig } from "./local.mjs";
import { claudePins, codexPins } from "./pins.mjs";
import { verifyGeneratedBuild, workerFiles, declaredWorkers, readConfig, effectiveConfig, assertStaging, assertReleaseAccounts } from "./release-config.mjs";
import { findings as stagingFindings, parse as parseWrangler } from "./staging.mjs";

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
// A real production-host guard in (comment-free) source: the request hostname tested for membership in a list or set of
// quoted hosts (.includes / .has), or compared with a quoted host (=== / !==). Reading or logging the hostname is not one.
const HOST = /["'`](?:[a-z0-9-]+\.)+[a-z]{2,}["'`]/i;
function hostGuard(t) {
  // The hostname itself, or a variable holding it: const h = url.hostname, or const { hostname } = url (and aliases of those).
  const aliases = new Set();
  for (const m of t.matchAll(/\{([^{}]*)\}\s*=\s*[^;\n]+/g)) for (const p of m[1].split(",")) { const [k, v] = p.split(":").map((x) => x.trim()); if (k === "hostname") aliases.add(v || k); }
  for (let grew = true; grew; ) {
    grew = false;
    const ref = `(?:\\.hostname\\b${[...aliases].map((a) => `|\\b${a.replace(/\$/g, "\\$")}\\b`).join("")})`;
    for (const m of t.matchAll(new RegExp(`([A-Za-z_$][\\w$]*)\\s*=\\s*(?:new\\s+URL\\([^)]*\\)|[\\w$.?()\\[\\]]*?)${ref}\\s*[,;\\n)]`, "g")))
      if (!aliases.has(m[1])) { aliases.add(m[1]); grew = true; }
  }
  const ref = `(?:[\\w$.?()\\[\\]"'\`]*\\.hostname\\b${[...aliases].map((a) => `|\\b${a.replace(/\$/g, "\\$")}\\b`).join("")})`;
  if (new RegExp(`${ref}\\s*[!=]==?\\s*${HOST.source}|${HOST.source}\\s*[!=]==?\\s*${ref}`, "i").test(t)) return true;
  for (const m of t.matchAll(/(\]|[A-Za-z_$][\w$]*)\s*\)?\s*\.\s*(includes|has)\s*\(/g)) {
    let depth = 1, j = m.index + m[0].length;
    for (; j < t.length && depth; j++) depth += t[j] === "(" ? 1 : t[j] === ")" ? -1 : 0;
    const arg = t.slice(m.index + m[0].length, j - 1).trim();
    if (!/\.hostname$/.test(arg) && !aliases.has(arg)) continue;
    if (m[1] === "]") { const open = t.lastIndexOf("[", m.index); if (open >= 0 && HOST.test(t.slice(open, m.index))) return true; continue; }
    const decl = t.match(new RegExp(`\\b(?:const|let|var)\\s+${m[1].replace(/\$/g, "\\$")}\\b[^=]*=\\s*(?:new\\s+Set\\s*\\(\\s*)?\\[([^\\]]*)\\]`));
    if (decl && HOST.test(decl[1])) return true;
  }
  return false;
}
const out = [];
let fails = 0;
const fail = (msg, fix) => { out.push(`FAIL: ${msg} | fix: ${fix}`); fails++; };
const warn = (msg) => out.unshift(`WARN: ${msg}`);

const rollback = rollbackFindings();
for (const message of rollback.errors) { if (rollback.draft) warn(`${message} | fix: split into expand now, contract in a later release`); else fail(message, "split into expand now, contract in a later release"); }
for (const note of rollback.notes) out.push(`NOTE: ${note}`);
if (!rollback.errors.length) out.push("rollback-safe ok");

const pack = json("scripts/agent/pack.json");
if (!pack) fail("scripts/agent/pack.json missing or invalid", "re-apply the pack from the org standards repository");
else {
  const tracked = git("ls-files", "-z").split("\0").filter(Boolean);
  // Test-quality offenders (warnings; the std-implement step 4 rules): flaky-by-design waits, retries and throttling.
  // Matched on source with comments blanked (`code` also blanks string literals), so prose and strings stay silent.
  const blank = (t, keepStrings) => {
    let o = "", i = 0;
    const sp = (s) => s.replace(/[^\n]/g, " ");
    while (i < t.length) {
      const c = t[i], n = t[i + 1];
      if (c === "/" && n === "/") { const e = t.indexOf("\n", i); const j = e < 0 ? t.length : e; o += sp(t.slice(i, j)); i = j; }
      else if (c === "/" && n === "*") { const e = t.indexOf("*/", i + 2); const j = e < 0 ? t.length : e + 2; o += sp(t.slice(i, j)); i = j; }
      else if (c === '"' || c === "'" || c === "`") {
        let j = i + 1;
        while (j < t.length && t[j] !== c && (c === "`" || t[j] !== "\n")) j += t[j] === "\\" ? 2 : 1;
        j = Math.min(j + 1, t.length);
        o += keepStrings ? t.slice(i, j) : c + sp(t.slice(i + 1, j - 1)) + (t[j - 1] === c ? c : "");
        i = j;
      } else { o += c; i++; }
    }
    return o;
  };
  const thirdParty = /(^|\/)(node_modules|vendors?|third[_-]party|bower_components)\//;
  const qualityTest = /(^|\/)(tests?|e2e)\/.*\.[cm]?[jt]sx?$|\.(spec|test)\.[cm]?[jt]sx?$/;
  const pwConfig = /(^|\/)playwright[^/]*\.config\.[cm]?[jt]s$/;
  const offenders = [
    [qualityTest, "code", /\bsetCPUThrottlingRate\b/g, "CPU throttling makes timing the assertion", "assert on an event or state, not on a slowed CPU"],
    [qualityTest, "strings", /\.send\s*\(\s*["'`]Emulation\.setCPUThrottlingRate["'`]/g, "CPU throttling makes timing the assertion", "assert on an event or state, not on a slowed CPU"],
    [qualityTest, "code", /\bwaitForTimeout\b/g, "waitForTimeout sleeps on the wall clock", "wait for an event or locator, or control time with page.clock"],
    [qualityTest, "code", /\btest\.retries\b|\btest\.(?:describe\.)?configure\s*\([^)]*\bretries\b/g, "test.retries hides flaky tests", "remove retries and fix the cause"],
    [pwConfig, "code", /\bretries\s*:/g, "retries in a Playwright config hides flaky tests", "remove retries and fix the cause"],
  ];
  for (const f of tracked) {
    if (thirdParty.test(f) || !offenders.some(([where]) => where.test(f))) continue;
    const text = read(f) ?? "", views = { strings: blank(text, true), code: blank(text, false) };
    const seen = new Set();
    for (const [where, view, re, what, fix] of offenders) {
      if (!where.test(f)) continue;
      for (const m of views[view].matchAll(re)) {
        const line = views[view].slice(0, m.index + m[0].length).split("\n").length;
        const key = `${line} ${what}`;
        if (!seen.has(key)) { seen.add(key); warn(`${f}:${line} ${what} | fix: ${fix}`); }
      }
    }
  }
  const pin = git("log", "-1", "--format=%h", "--", "standards.lock").trim() || "HEAD";
  const restore = (p) => `git checkout ${pin} -- ${p}`;
  const std = json("standards.json");
  if (!std) fail("standards.json missing or not JSON", restore("standards.json"));
  else {
    try { localConfig(std.local); } catch (e) { fail(e.message, 'use local: false for no Worker, or {"command":"node_modules/.bin/wrangler dev --local", "url":"http://127.0.0.1:8787", "ready":"/"}'); }
    const one = (k, vals) => vals.includes(std[k]) || fail(`standards.json ${k} is ${JSON.stringify(std[k])}`, `use one of ${vals.join("|")}`);
    one("pack", [pack.pack]); one("profile", ["internal", "client"]); one("dispatch", ["auto", "manual", "off"]);
    one("sensitive", [true, false]); const e = std.e2e, eo = e && typeof e === "object" && !Array.isArray(e);
    const e2eOk = e === undefined || e === false || (typeof e === "string" && e.trim()) || (eo && Object.keys(e).every((k) => ["command", "browsers", "preview", "budget"].includes(k))
      && (e.command === undefined || (typeof e.command === "string" && e.command.trim())) && (e.browsers === undefined || (Array.isArray(e.browsers) && e.browsers.every((b) => ["chromium", "firefox", "webkit"].includes(b))))
      && [undefined, false].includes(e.preview));
    if (eo && e.budget !== undefined) warn("standards.json e2e.budget is ignored: the e2e suite has no time budget | fix: remove it");
    if (std.affected !== undefined && typeof std.affected !== "boolean") fail(`standards.json affected is ${JSON.stringify(std.affected)}`, 'use false (the whole e2e suite on every pull request), or omit it');
    if (!e2eOk) fail(`standards.json e2e is ${JSON.stringify(e)}`, 'use false (docs/static only), the e2e command, or {"command", "browsers" (extra, run on main against staging_url), "preview": false}');
    // Removed per-repo exceptions: every repository is held to the same rules, so a leftover key only says what replaced it.
    for (const [k, instead] of [
      ["nested_instructions", "no AGENTS.md or CLAUDE.md is allowed below the root; its rules go in the root AGENTS.md or the org overlay"],
      ["allow_paths", "a .mcp.json at the top of a plugin folder (beside its .claude-plugin or .codex-plugin) passes by kind; any other still fails"],
      ["duplicate_check_exceptions", "no repository workflow runs on a pull request or a branch push beside gate; its checks go in scripts/agent/gate.local.sh"],
      ["deploy_workflow", "no repository workflow runs on a branch push; a deploy runs in Workers Builds (scripts/agent/release.mjs), or on a tag push or a manual run"],
    ]) if (std[k] !== undefined) warn(`standards.json ${k} was removed: ${instead} | fix: remove it`);
    if (std.flow !== "staged") one("flow", [undefined, "direct"]);
    else fail('standards.json flow "staged" is retired (one branch: main; a merge deploys staging and uploads the production version)',
      "merge staging into main, make main the default branch, delete staging, give Workers Builds' main trigger the one-branch release command, then remove flow"); one("design_signoff", [undefined, true, false]);
    if (!/^\d+\.\d+\.\d+$/.test(std.version ?? "")) fail("standards.json version is not X.Y.Z", restore("standards.json"));
    const globs = (v) => v === undefined || (Array.isArray(v) && v.every((g) => typeof g === "string"));
    const ui = std.ui_paths;
    if (!(globs(ui) || (ui && typeof ui === "object" && globs(ui.include) && globs(ui.ignore))))
      fail("standards.json ui_paths must be a glob list or {include, ignore}", "fix it, or delete it for the engine defaults");
    if (!globs(std.risk_paths)) fail("standards.json risk_paths must be a glob list", "fix it, delete it for the engine defaults, or [] for none");
    // staging_url: where the release check runs the full suite (extra browsers named make it required) (the staging Preview), required when any are named
    // and the repository has not opted out with "e2e": false (then no release check ships)
    const extra = e !== false && ((Array.isArray(e?.browsers) && e.browsers.length > 0) || (pack.e2e_release_browsers ?? []).length > 0);
    const https = (u) => { try { return new URL(u).protocol === "https:"; } catch { return false; } };
    if ((std.staging_url !== undefined || extra) && !https(std.staging_url))
      fail(`standards.json staging_url is ${JSON.stringify(std.staging_url)}${extra ? " (extra browsers run against it on main)" : ""}`, 'the staging Preview\'s https URL, e.g. "https://staging.preview.example.com/"');
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
    const n = (agents.match(/<!-- std:begin [a-z0-9-]+ -->/g) ?? []).length, m = agents.split(end).length - 1;
    if (n !== 1 || m !== 1) fail(`AGENTS.md has ${n} std:begin and ${m} std:end markers (need one each)`, "delete the duplicate block");
    else if (pack.agents_md === "block-only" && !(agents.trim().startsWith(begin) && agents.trim().endsWith(end)))
      fail("AGENTS.md has content outside the managed block (this organization's AGENTS.md is the standards block only)", "delete everything before the std:begin line and after the std:end line; repo rules belong in the org standards");
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
  // A plugin folder is a folder below the root holding .claude-plugin/plugin.json or .codex-plugin/plugin.json. The .mcp.json
  // at its top level is the plugin's own content, not this repository's MCP configuration; every other rule applies inside it.
  const plugins = new Set(tracked.map((f) => f.match(/^(.+)\/\.(claude|codex)-plugin\/plugin\.json$/)?.[1]).filter(Boolean));
  for (const f of tracked) {
    const name = f.split("/").pop(), dirs = f.split("/").slice(0, -1).map((d) => d.toLowerCase());
    if (name === "CONTEXT.md") fail(`CONTEXT.md is forbidden: ${f}`, `git rm ${f}   (rules go in AGENTS.md)`);
    if (["AGENTS.md", "CLAUDE.md"].includes(name) && f !== name)
      fail(`nested instruction file: ${f}`, `move its rules into the root AGENTS.md or the org overlay, then git rm ${f}`);
    if (name === ".mcp.json" && !plugins.has(dirname(f))) fail(`${f} is committed`, `git rm --cached ${f} && echo .mcp.json >> .gitignore`);
    if (f.startsWith(".evidence/")) fail(`.evidence/ is tracked (${f})`, "git rm -r --cached .evidence   (pr.sh evidence uploads them instead)");
    if ((/\.(md|markdown)$/i.test(name) && dirs.some((d) => pack.decision_dirs.includes(d))) || /^ADR-.*\.md$/i.test(name) || pack.decision_record_globs.some((g) => glob(g).test(f)))
      fail(`decision record tracked: ${f}`, `git rm ${f}   (decisions are not recorded; they must be evident in the work)`);
    for (const g of pack.forbid_paths) if (glob(g).test(f)) fail(`${f} matches the org's forbidden path ${g}`, `git rm -r --cached ${f}`);
  }
  // CI: one gate per head. Every job has a timeout; a repo workflow never runs on a pull request or a branch push, whatever
  // its steps say (checks go in scripts/agent/gate.local.sh); no schedule runs more than daily; Playwright installs name
  // their browsers. A line-level reading of the block YAML workflows use.
  for (const f of tracked.filter((f) => /^\.github\/workflows\/[^/]+\.ya?ml$/.test(f))) {
    const text = read(f) ?? "", L = text.split("\n"), name = f.split("/").pop(), managed = /^std-/.test(name);
    const onAt = L.findIndex((l) => /^["']?on["']?:/.test(l)), inline = onAt >= 0 ? L[onAt].replace(/^["']?on["']?:\s*/, "").replace(/(^|\s)#.*$/, "").trim() : "";
    const block = (at, indent) => { const b = []; for (let i = at + 1; i < L.length && (L[i].trim() === "" || L[i].search(/\S/) > indent || L[i].trim().startsWith("#")); i++) b.push(L[i]); return b; };
    const onBlock = onAt >= 0 ? block(onAt, 0) : [];
    const triggers = inline ? inline.replace(/[[\]{}]/g, "").split(",").map((t) => t.trim().split(":")[0].trim().replace(/^["']|["']$/g, "")).filter(Boolean)
      : onBlock.map((l) => l.match(/^ {2}(?:- )?["']?([a-z_]+)["']?(?::|\s*(?:#.*)?$)/)?.[1]).filter(Boolean); // a key, or a sequence item, quoted or not
    // GitHub runs a push trigger on branch pushes unless its filters name tags only (tags or tags-ignore, no branches or branches-ignore).
    const pushAt = onBlock.findIndex((l) => /^ {2}["']?push["']?:/.test(l));
    const push = inline || (pushAt >= 0 ? [onBlock[pushAt].replace(/^ {2}["']?push["']?:/, ""), ...block(onAt + 1 + pushAt, 2)].map((l) => l.replace(/(^|\s)#.*$/, "").trim()).join(" ") : "");
    const branchPush = triggers.includes("push") && (/\bbranches(-ignore)?["']?\s*:/.test(push) || !/\btags(-ignore)?["']?\s*:/.test(push));
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
    // A job with no timeout-minutes runs up to GitHub's default of 360 minutes
    // (docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idtimeout-minutes).
    for (const j of jobs) if (!j.body.some((l) => /^ {4}(timeout-minutes|uses):/.test(l)))
      fail(`${f} job ${j.name} has no timeout-minutes (GitHub's default is 360 minutes)`, `add timeout-minutes to ${j.name}: the org's one job timeout, the overlay's gate.timeout_minutes (the value every job in std-gate.yml carries)`);
    const runs = jobs.flatMap((j) => j.body).filter((l) => !/^\s*(-\s*)?(name|uses|id|if):/.test(l)).join("\n");
    if (/playwright install\b(?![^\n;&|]*\b(chromium|chrome|firefox|webkit|msedge)\b)/.test(runs))
      fail(`${f} runs playwright install without naming a browser (it downloads all of them)`, "name the browser: playwright install --with-deps chromium");
    // The trigger alone decides, never the words in its steps or the name of its branch. `managed` (std-*, hash-locked) keeps
    // its exemption: std-gate.yml is the one gate.
    const prs = triggers.filter((t) => ["pull_request", "pull_request_target"].includes(t));
    if (!managed && (prs.length || branchPush))
      fail(`${f} runs on ${[...prs, ...(branchPush ? ["a branch push"] : [])].join(" and ")}, beside the one gate`,
        "move its checks into scripts/agent/gate.local.sh and delete it; a deploy runs in Workers Builds (scripts/agent/release.mjs), or on a tag push or a manual run");
  }
  const scripts = Object.values(json("package.json")?.scripts ?? {}).join("\n") + "\n" + (read("scripts/agent/gate.local.sh") ?? "");
  if (/playwright install\b(?![^\n;&|]*\b(chromium|chrome|firefox|webkit|msedge)\b)/.test(scripts))
    fail("package.json scripts or gate.local.sh run playwright install without naming a browser", "name the browser: playwright install chromium");
  // A Playwright invocation of --with-deps or install-deps asks for a root install. The check is advisory: a false match would block
  // every gate, while the runtime refuses sudo and names what the host lacks. Each text is read on its own: a shell line continuation
  // joins lines within it, and an unquoted # starts a comment. The executable may be quoted.
  const shellText = (t) => t.replace(/\\\r?\n/g, " ").split("\n").map((l) => l.replace(/(^|\s)#.*$/, "")).join("\n");
  const rootFlag = /\bplaywright["']?[ \t]+install-deps\b|\bplaywright["']?[ \t]+install\b[^\n;&|]*--with-deps(?![\w-])/;
  const lifecycle = new Set(["preinstall", "install", "postinstall", "prepare", "prepublish"]);
  for (const [key, value] of Object.entries(json("package.json")?.scripts ?? {}))
    if (rootFlag.test(shellText(String(value))))
      warn(`package.json script "${key}" asks for a root install (--with-deps or install-deps) | fix: ${lifecycle.has(key)
        ? `drop --with-deps or install-deps from the ${key} hook; the gate installs browsers, and system packages only when one is missing`
        : "remove --with-deps or install-deps; the gate's own install (node scripts/agent/gate.mjs install) installs system packages only when one is missing, and a gate never needs root"}`);
  if (rootFlag.test(shellText(read("scripts/agent/gate.local.sh") ?? "")))
    warn("scripts/agent/gate.local.sh asks for a root install (--with-deps or install-deps) | fix: remove --with-deps or install-deps; the gate's own install (node scripts/agent/gate.mjs install) installs system packages only when one is missing, and a gate never needs root");
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
    // overflow: hidden on a block animated on a view()/scroll() timeline freezes the timeline; overflow-x on html breaks
    // scrolling. Innermost CSS rules of stylesheets and components' <style> blocks (a reading of the stylelint rule).
    for (const f of tracked.filter((f) => /\.(css|scss|astro|svelte|vue|html)$/.test(f) && !/^(node_modules|dist)\//.test(f))) {
      const text = read(f) ?? "", css = /\.s?css$/.test(f) ? text : [...text.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1]).join("\n");
      for (const [, sel, body] of css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
        const name = sel.trim().replace(/\s+/g, " ");
        if (/animation-timeline\s*:[^;]*\b(view|scroll)\(/.test(body) && /(^|[;\s])overflow(-[xy])?\s*:\s*hidden\b/.test(body))
          fail(`${f}: ${name} is animated on a scroll timeline but sets overflow: hidden, which freezes the timeline`, "use overflow: clip");
        if (name.split(",").some((x) => ["html", ":root"].includes(x.trim())) && /(^|[;\s])overflow-x\s*:\s*(hidden|auto|scroll)\b/.test(body))
          fail(`${f}: html sets overflow-x to a scroll container`, "remove it; clip the overflowing element instead (overflow: clip)");
      }
    }
    const wranglerFile = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"].find((f) => read(f) !== null), wrangler = wranglerFile ? read(wranglerFile) : "";
    // Every send_email binding name the config declares: JSON(C) at any depth (top level, previews, env.*), whatever
    // other fields an entry has; TOML [[send_email]] / [[env.<name>.send_email]] tables and inline arrays.
    function sendEmailBindings() {
      const names = new Set();
      if (/\.toml$/.test(wranglerFile ?? "")) {
        for (const m of wrangler.matchAll(/^\s*\[\[(?:[\w.-]+\.)?send_email\]\]\s*\n((?:(?!\s*\[)[^\n]*\n?)*)/gm))
          for (const n of m[1].matchAll(/^\s*name\s*=\s*["']([A-Za-z_]\w*)["']/gm)) names.add(n[1]);
        for (const m of wrangler.matchAll(/^\s*send_email\s*=\s*\[/gm)) {
          let depth = 0, j = m.index + m[0].length - 1;
          for (; j < wrangler.length; j++) { depth += wrangler[j] === "[" ? 1 : wrangler[j] === "]" ? -1 : 0; if (!depth) break; }
          for (const n of wrangler.slice(m.index, j).matchAll(/\bname\s*=\s*["']([A-Za-z_]\w*)["']/g)) names.add(n[1]);
        }
      } else if (wranglerFile) {
        let cfg = null;
        try { cfg = JSON.parse(scan(wrangler).source.replace(/,(\s*[}\]])/g, "$1")); } catch {}
        const walk = (v) => { if (Array.isArray(v)) v.forEach(walk); else if (v && typeof v === "object")
          for (const [k, x] of Object.entries(v)) { if (k === "send_email" && Array.isArray(x)) x.forEach((b) => typeof b?.name === "string" && names.add(b.name)); walk(x); } };
        if (cfg) walk(cfg);
        else for (const n of wrangler.matchAll(/["']name["']\s*:\s*["']([A-Za-z_]\w*)["']/g)) if (/send_email/.test(wrangler)) names.add(n[1]); // unparseable: every name, so no sender is missed
      }
      return [...names];
    }
    // Mail: one seam sends it, and the seam compares the request hostname with the production hosts, so previews,
    // workers.dev and localhost never mail the client. A sender calls .send( on a send_email binding from the wrangler
    // config (JSON, or a TOML [[send_email]] table), or imports cloudflare:email and calls .send(; passing the binding
    // on is not a send.
    const bindings = sendEmailBindings();
    const lexed = new Map(src.map((f) => [f, scan(read(f) ?? "")]));
    const sends = (f) => { const { code } = lexed.get(f), imports = /from\s+["']cloudflare:email["']/.test(read(f) ?? "");
      return bindings.some((b) => new RegExp(`\\b${b}\\s*\\)?\\s*\\.\\s*send\\s*\\(`).test(code)) || (imports && /\.\s*send\s*\(/.test(code)); };
    const senders = src.filter((f) => !/\.d\.ts$/.test(f) && !/(^|\/)(tests?|e2e|__tests__)\/|\.(test|spec)\.[cm]?[jt]sx?$/.test(f) && sends(f));
    const seam = senders.find((f) => hostGuard(lexed.get(f).source)) ?? senders[0];
    for (const f of senders.filter((f) => f !== seam)) fail(`${f} sends mail outside the email seam (${seam})`, `send through ${seam}, the one place that reroutes non-production hosts`);
    if (seam && !hostGuard(lexed.get(seam).source))
      fail(`${seam} sends mail but never compares the request hostname with the production hosts`, "mail real recipients only from the production hosts; reroute every other host (previews, workers.dev, localhost) to a test inbox");
    // Sentry: a site whose Worker runs code, on the Cloudflare SDK, reports from all four layers.
    const main = wrangler.match(/["']?main["']?\s*[:=]\s*["']([^"']+)["']/)?.[1]?.replace(/^\.\//, "");
    const deps = json("package.json") ?? {};
    if (main && { ...deps.dependencies, ...deps.devDependencies }["@sentry/cloudflare"]) {
      const missing = (layer, fix) => fail(`Sentry layer missing: ${layer}`, fix);
      // A main the build generates (not tracked, e.g. dist/_worker.js) is wrapped in the tracked source it is built from.
      const wrapped = tracked.includes(main) ? /\bwithSentry\s*\(/.test(lexed.get(main)?.code ?? scan(read(main) ?? "").code)
        : src.some((f) => !/(^|\/)(tests?|e2e|__tests__)\//.test(f) && /\bwithSentry\s*\(/.test(lexed.get(f).code));
      if (!wrapped) missing("wrapper", `wrap the Worker entry (${main}) in Sentry.withSentry`);
      if (!tracked.some((f) => /^src\/middleware(\.[cm]?[jt]s$|\/)/.test(f) && /\bcaptureException\s*\(/.test(scan(read(f) ?? "").code)))
        missing("middleware", "add src/middleware.ts (or src/middleware/) calling Sentry.captureException on a route error (the framework turns route errors into 500s the wrapper never sees)");
      const browser = src.find((f) => /@sentry\/browser/.test(read(f) ?? "") && /\binit\s*\(/.test(read(f) ?? ""));
      const tunnel = browser && (read(browser).match(/\btunnel\s*:\s*["'`](\/[^"'`]*)["'`]/)?.[1] ?? "").replace(/\/+$/, "");
      if (!browser) missing("browser", "init @sentry/browser in a client script, with a same-origin tunnel");
      else if (!tunnel || !tracked.some((f) => [`src/pages${tunnel}`, `src/pages${tunnel}/index`, `src/routes${tunnel}/+server`].some((b) => new RegExp(`^${b.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\.[cm]?[jt]s$`).test(f))))
        missing("tunnel", `serve the browser init's tunnel${tunnel ? ` (${tunnel})` : ""} from a same-origin route that forwards only this site's project`);
    }
  }
  // Staging and PR Previews (scripts/agent/staging.mjs): staging is a Wrangler environment with its own resources,
  // previews point at them, and no non-production config names a production resource. The root Worker config only.
  const sec = std?.secrets;
  if (sec !== undefined && !(sec && typeof sec === "object" && !Array.isArray(sec) && Object.keys(sec).every((k) => ["required", "store"].includes(k))
    && (sec.required === undefined || (Array.isArray(sec.required) && sec.required.every((n) => typeof n === "string" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(n))))
    && [undefined, "1password", "secrets_store"].includes(sec.store)))
    fail(`standards.json secrets is ${JSON.stringify(sec)}`, '{"required": ["NAME", ...], "store": "1password" (our accounts) or "secrets_store" (a client-owned account)}');
  if (![undefined, false].includes(std?.staging)) fail(`standards.json staging is ${JSON.stringify(std.staging)}`, "remove it, or false for a Worker that is not released through staging (previews are still checked)");
  const rootWrangler = ["wrangler.json", "wrangler.jsonc", "wrangler.toml"].find((f) => tracked.includes(f));
  // Declared Workers (standards.json workers) are the repository's primaries: validated like the root config, never discovered.
  let primaries = null;
  try { primaries = declaredWorkers(std ?? {}); }
  catch (e) { fail(e.message, 'standards.json workers: each entry a Wrangler config file or a directory holding one (or {"config": ..., "release_workers": [...], "build": "<command>"}), with distinct Worker names; no top-level release_workers'); }
  const declaredKey = std?.workers !== undefined;
  if (primaries && Array.isArray(sec?.required) && sec.required.length)
    fail("standards.json secrets.required with workers declared", "list each declared Worker's required secrets in its own wrangler config secrets.required; keep secrets.store here");
  // The release check (std-release-check.yml) ships to every Worker with a staging_url; say why a repository has none.
  if (std?.e2e !== false && !tracked.includes(".github/workflows/std-release-check.yml"))
    warn(`no release check: ${!rootWrangler && !primaries ? "no Worker (no root wrangler config, no declared workers)" : "standards.json has no staging_url"} | fix: ${!rootWrangler && !primaries ? "none needed unless a Worker is added" : "set staging_url to the staging Worker's https URL and re-run sync"}; the production deploy waits for a release-check on the version's commit`);
  // Every production `versions upload` carries `--tag <full commit sha>`: the portal maps a version to its commit, and
  // so to its release-check, through the tag. release.mjs does; a deploy command the repo's own files document must too.
  for (const [where, text] of [["package.json scripts", Object.values(json("package.json")?.scripts ?? {}).join("\n")],
    ...tracked.filter((f) => /^\.github\/workflows\/(?!std-)[^/]+\.ya?ml$/.test(f) || f === "scripts/agent/gate.local.sh").map((f) => [f, read(f) ?? ""])])
    if (/\bversions upload\b(?![^\n]*--tag\b)/.test(text)) warn(`${where}: wrangler versions upload without --tag | fix: add --tag "$WORKERS_CI_COMMIT_SHA" (Workers Builds; the full commit SHA) so the portal can tie the version to its release-check`);
  let productionConfigs = [];
  // A supporting Worker is validated as a staging target of its own.
  const supporting = (file) => {
    const cfg = readConfig(file);
    assertStaging(cfg, effectiveConfig(file, true, { redirect: false }), productionConfigs);
    const required = [...new Set(Array.isArray(cfg.secrets?.required) ? cfg.secrets.required : [])];
    const result = stagingFindings(cfg, { file, std: std ?? {}, pack, required, productionConfigs });
    result.fails.forEach(([m, f]) => fail(m, f)); result.warns.forEach(warn);
  };
  if (primaries) try {
    productionConfigs = primaries.flatMap((w) => [w.cfg, ...w.extraConfigs]);
    assertReleaseAccounts(productionConfigs[0], productionConfigs);
    for (const w of primaries) {
      // each declared primary gets the full validation, preview isolation from every declared Worker's production resources included
      if (w.cfg.env?.staging) assertStaging(w.cfg, effectiveConfig(w.file, true, { redirect: false }), productionConfigs);
      const required = [...new Set(Array.isArray(w.cfg.secrets?.required) ? w.cfg.secrets.required : [])];
      const result = stagingFindings(w.cfg, { file: w.file, std: std ?? {}, pack, required, productionConfigs });
      result.fails.forEach(([m, f]) => fail(m, f)); result.warns.forEach(warn);
      w.extras.forEach(supporting);
    }
  } catch (e) { fail(e.message, "give each declared Worker (and its release_workers) an isolated env.staging and a previews block on staging resources"); }
  else if (!declaredKey) try {
    const extras = workerFiles(std ?? {}, rootWrangler ?? null);
    productionConfigs = rootWrangler ? [readConfig(rootWrangler), ...extras.map(readConfig)] : [];
    if (productionConfigs.length) assertReleaseAccounts(productionConfigs[0], productionConfigs);
    if (extras.length && productionConfigs[0].env?.staging)
      assertStaging(productionConfigs[0], effectiveConfig(rootWrangler, true, { redirect: false }), productionConfigs);
    extras.forEach(supporting);
  } catch (e) { fail(e.message, "list each secondary Worker's own config in standards.json release_workers and give it an isolated env.staging"); }
  try { if (!declaredKey) verifyGeneratedBuild(std ?? {}, json("package.json"), rootWrangler ?? null); }
  catch (e) { fail(`generated Wrangler config: ${e.message}`, "make standards.json build or package.json scripts.build honor CLOUDFLARE_ENV=staging (use an adapter with environment selection), then rebuild without it for production"); }
  // the Worker calls the managed pass check (scripts/agent/portal-pass.mjs) before anything else
  const portalCheck = () => {
    if (pack.portal && !tracked.some((f) => /\.([cm]?[jt]sx?|svelte|astro)$/.test(f) && !f.startsWith("scripts/agent/") && !/(^|\/)(tests?|e2e|__tests__)\//.test(f)
      && /from\s+["'][^"']*scripts\/agent\/portal-pass(\.mjs)?["']/.test(read(f) ?? "") && /\bportalPass\s*\(/.test(scan(read(f) ?? "").code)))
      fail("no Worker source calls the portal pass check", 'import { portalPass } from "<path to>/scripts/agent/portal-pass.mjs" and, first in the fetch handler or middleware: const denied = await portalPass(request, env); if (denied) return denied;');
  };
  if (declaredKey) { if (primaries) portalCheck(); }
  else if (rootWrangler?.endsWith(".toml")) warn(`${rootWrangler} is not checked for staging isolation (TOML) | fix: convert it to wrangler.jsonc`);
  else if (rootWrangler) {
    const cfg = parseWrangler(read(rootWrangler) ?? "");
    if (!cfg || typeof cfg !== "object") fail(`${rootWrangler} does not parse`, "fix the JSON (comments and trailing commas are fine)");
    else {
      const required = [...new Set([...(Array.isArray(sec?.required) ? sec.required : []), ...(Array.isArray(cfg.secrets?.required) ? cfg.secrets.required : [])])];
      const r = stagingFindings(cfg, { file: rootWrangler, std: std ?? {}, pack, required, productionConfigs: productionConfigs.length ? productionConfigs : [cfg] });
      r.fails.forEach(([m, f]) => fail(m, f)); r.warns.forEach(warn);
      portalCheck();
    }
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
  }
  if (!fails) out.push(`standards ok: ${pack.pack} v${std.version} ${std.profile} (engine ${pack.engine}) dispatch=${std.dispatch}`);
}
console.log(out.join("\n"));
if (fails) {
  console.log(`standards check: ${fails} failure(s)`);
  process.exit(1);
}
