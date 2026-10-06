#!/usr/bin/env node
// Steps of the `gate` job (std-gate.yml), also runnable locally:
//   plan | classify [base] | install | run <script>... | preview | release | e2e | secrets | syntax | instructions | verdict
// UI paths: pack.json defaults; standards.json "ui_paths" as a list replaces the include globs,
// as {include, ignore} replaces include and adds ignore. e2e: none fails unless "e2e": false.
import { execFileSync as ex, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync as has, mkdtempSync, readdirSync as ls, readFileSync as rd, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { scan } from "./jsscan.mjs";
import { rollbackFindings } from "./rollback.mjs";
import { verifyGeneratedBuild } from "./release-config.mjs";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["verdict", "plan", "classify", "install", "run", "preview", "release", "e2e", "secrets", "syntax", "instructions"], ok = SUBS.includes(cmd);
if (!ok || args.includes("--help")) {
  console.log(rd(new URL(import.meta.url), "utf8").split("\n").slice(1, 6).map((l) => l.slice(3)).join("\n"));
  process.exit(ok || cmd === "--help" ? 0 : 2);
}
const git = (...a) => ex("git", a, { encoding: "utf8", stdio: "pipe" });
try { process.chdir(git("rev-parse", "--show-toplevel").trim()); } catch {}
const json = (f) => { try { return JSON.parse(rd(f, "utf8")); } catch { return null; } };
const pkg = json("package.json"), std = json("standards.json") ?? {};
const fail0 = (msg, fix) => { console.log(`::error::${msg}\nfix: ${fix}`); process.exit(1); };
if (has("package.json") && !pkg && ["install", "run", "e2e"].includes(cmd)) fail0("package.json is not valid JSON", "fix package.json");
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

if (cmd === "instructions") {
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
  if (!files) fail("instructions: the pull request's base commit is not in this checkout", "check out with fetch-depth: 0 (std-gate.yml does)");
  const bad = new Set(files.filter((f) => INSTRUCTION.some((r) => r.test(f))));
  if (files.some((f) => CODEOWNERS.includes(f))) {
    const [before, after] = [ownersBlock(prBase()), ownersBlock("HEAD")];
    if (before.block !== after.block) bad.add(`${after.path ?? before.path} (managed std block${after.path !== before.path ? `, now read from ${after.path ?? "no CODEOWNERS"}` : ""})`);
  }
  if (bad.size) fail(`instruction files changed by ${author || "this pull request"} (${ref}):\n  ${[...bad].join("\n  ")}`,
    "agents never change instruction files; only the org App's standards-sync (standards/v*) and approved retro (retro/*) pull requests may. Revert these files; a rule change goes through the weekly retro.");
  console.log("instructions: no instruction file or managed CODEOWNERS block changed");
} else if (cmd === "verdict") {
  // The required `gate` job: the checks job and the tail (NEEDS, the workflow's needs as JSON) each succeeded, or the
  // tail was skipped because the checks planned a draft's cheap gate. Anything else (a failure, a cancellation, a
  // skip the plan did not call for, a missing job) fails it.
  let needs;
  try { needs = JSON.parse(env.NEEDS ?? ""); } catch { fail("no job results (NEEDS)", "run the verdict from std-gate.yml's gate job"); }
  const tail = ["build", "e2e", "repo"], mode = needs.checks?.outputs?.mode, bad = [];
  for (const j of ["checks", ...tail]) {
    const r = needs[j]?.result ?? "missing";
    if (r !== "success" && !(r === "skipped" && tail.includes(j) && mode === "cheap" && needs.checks?.result === "success")) bad.push(`${j}: ${r}`);
  }
  if (bad.length) fail(`gate: ${bad.join(", ")}`, "open the failed job's log; a skipped or cancelled job never passes gate");
  console.log(`gate: ${mode === "cheap" ? "checks passed (draft: the tail runs from ready_for_review)" : "checks, build, e2e and repo checks passed"}`);
} else if (cmd === "plan") {
  // full: build and test this head. cheap: a consumer draft (checks, secrets and syntax);
  // consumer drafts run the full gate from ready_for_review.
  const get = ghApi();
  let mode = "full", why = "build and test this head";
  const pr = prNumber ? await get(`/pulls/${prNumber}`) : null;
  // The engine must exercise its own fixtures for code changes, including on draft PRs.
  const engineCode = pkg?.name === "repo-standards" && has("bin/repo-standards.mjs") && !docOnly();
  if (pr?.draft && !engineCode) { mode = "cheap"; why = "draft: the full gate runs from ready_for_review"; }
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
    const red = runs.find((c) => c.status === "completed" && !["success", "skipped"].includes(c.conclusion));
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
  // The release check (std-release-check.yml, on main): wait for this commit's Workers Builds (staging Preview and the
  // uploaded production version), then name the extra browsers and the staging URL for the install and e2e steps.
  const get = ghApi(), sha = env.GITHUB_SHA ?? git("rev-parse", "HEAD").trim(), short = sha.slice(0, 7);
  // A push that changes only non-deployable paths (pack.json non_deploy_paths) leaves staging as it was: nothing to test.
  // The whole push (the event's before..sha); a manual run, or a before no longer in history, skips nothing.
  let pushed = null;
  const before = event.before && !/^0+$/.test(event.before) ? event.before : null;
  if (before) try { pushed = git("diff", "--name-only", "--no-renames", "-z", before, sha).split("\0").filter(Boolean); } catch {}
  const nd = (pack.non_deploy_paths ?? []).map(glob);
  if (pushed?.length && pushed.every((f) => nd.some((r) => r.test(f)))) {
    console.log(`::notice::release check skipped: only non-deployable paths changed (${pushed.join(", ")})`);
    output("skip", "true"); output("browsers", ""); output("url", "");
    process.exit(0);
  }
  const name = pack.preview?.check_name ?? "Workers Builds";
  const builds = async (c) => ((await get(`/commits/${c}/check-runs?per_page=100`))?.check_runs ?? []).filter((x) => x.name?.startsWith(name));
  // The check can be created late: where the parent commit had a build, this commit's is waited for, not taken as absent.
  let parent = null;
  try { parent = git("rev-parse", `${sha}^`).trim(); } catch {}
  const hasBuilds = (await builds(sha)).length > 0 || (parent ? (await builds(parent)).length > 0 : false);
  const wait = Number(env.GATE_PREVIEW_WAIT_S ?? 480) * 1000, poll = Number(env.GATE_POLL_S ?? 15) * 1000, start = Date.now();
  if (!hasBuilds) console.log(`release: no "${name}" check on ${short} or its parent; testing staging as it stands`);
  else for (;;) {
    const runs = await builds(sha);
    const red = runs.find((c) => c.status === "completed" && !["success", "skipped"].includes(c.conclusion));
    if (red) fail(`Cloudflare build failed for ${short}: ${red.name} ${red.conclusion} (${red.details_url})`, "fix the Worker build on main; staging and the uploaded version come from it");
    if (runs.length && runs.every((c) => c.status === "completed")) break;
    if (Date.now() - start >= wait)
      fail(runs.length ? `the Cloudflare build for ${short} is still running after ${wait / 1000}s` : `no "${name}" check on ${short} after ${wait / 1000}s, though the repository has Workers Builds`, "re-run the release check once the build finishes");
    await new Promise((r) => setTimeout(r, poll));
  }
  const extra = [...new Set([...(e2eCfg.browsers ?? []), ...(pack.e2e_release_browsers ?? [])])];
  console.log(`release: ${extra.join(", ")} against ${std.staging_url} (${short})`);
  output("browsers", extra.join(","));
  output("url", std.staging_url ?? "");
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
} else if (cmd === "install") {
  if (!pkg) console.log("notice: no package.json; nothing to install");
  else {
    if (pm !== "npm") must("corepack", ["enable"]);
    must(pm, pm === "pnpm" ? ["install", "--frozen-lockfile"] : pm === "yarn" ? ["install", has(".yarnrc.yml") ? "--immutable" : "--frozen-lockfile"]
      : has("package-lock.json") || has("npm-shrinkwrap.json") ? ["ci"] : ["install", "--no-package-lock"]);
    const d = { ...pkg.dependencies, ...pkg.devDependencies };
    // The repo's own Playwright (so the browser matches the lockfile); only this run's browsers. Browsers are not cached.
    const bin = has("node_modules/.bin/playwright") ? ["node_modules/.bin/playwright", []] : ["npx", ["--no-install", "playwright"]];
    if ((d.playwright || d["@playwright/test"]) && !args.includes("--no-browsers")) must(bin[0], [...bin[1], "install", "--with-deps", ...browsers()]);
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
  const docs = docOnly();
  if (docs) { docSkip("e2e", docs); process.exit(0); }
  // standards.json "e2e": "<command>" names the suite; else a script, a tests/e2e or e2e dir, or a root Playwright config.
  const script = ["test:e2e", "e2e"].find((s) => pkg?.scripts?.[s]), dir = ["tests/e2e", "e2e"].find(has);
  const rootPw = ls(".").some((f) => /^playwright\.config\.[cm]?[jt]s$/.test(f)), pw = rootPw || (dir && ls(dir).some((f) => /^playwright\.config\.[cm]?[jt]s$/.test(f)));
  // Playwright runs this run's browsers only (Chromium unless the release check opts in more), when the config defines
  // those projects; a config without projects runs as it is.
  const cfgFile = [...(rootPw ? ls(".") : []), ...(dir && !rootPw ? ls(dir).map((f) => `${dir}/${f}`) : [])].find((f) => /(^|\/)playwright\.config\.[cm]?[jt]s$/.test(f));
  const cfg = cfgFile ? rd(cfgFile, "utf8") : "", named = (b) => new RegExp(`name:\\s*['"\`]${b}['"\`]`).test(cfg);
  const projects = /\bprojects\s*:/.test(cfg) ? browsers().filter(named).map((b) => `--project=${b}`) : [];
  const pwBin = has("node_modules/.bin/playwright") ? ["node_modules/.bin/playwright", []] : ["npx", ["--no-install", "playwright"]];
  // A package script that runs `playwright test` gets the same project selection (npm needs `--` before it).
  const pwScript = script && /\bplaywright\s+test\b/.test(pkg.scripts[script]);
  // Without --project Playwright runs every project, so a config whose projects are named otherwise is refused.
  if (!e2eCmd && (!script || pwScript) && cfg && /\bprojects\s*:/.test(cfg) && !projects.length)
    fail(`${cfgFile} defines projects but none named ${browsers().join(" or ")}, so gate cannot pick the Chromium run`, 'name the Chromium project "chromium" (gate runs only that), or set standards.json e2e.command');
  const run = e2eCmd ? ["bash", ["-c", e2eCmd]] : script ? [pm, ["run", script, ...(pwScript && projects.length ? [...(pm === "npm" ? ["--"] : []), ...projects] : [])]] : dir && pw ? [pwBin[0], [...pwBin[1], "test", dir, ...projects]]
    : rootPw ? [pwBin[0], [...pwBin[1], "test", ...projects]]
    : dir && ls(dir, { recursive: true }).some((f) => /\.test\.[cm]?js$/.test(f)) ? ["node", ["--test", `${dir}/**/*.test.*js`]] : null;
  // Budget: the whole suite within gate_budget.e2e minutes (standards.json e2e.budget may only tighten it).
  if (e2eCfg.budget !== undefined && !(typeof e2eCfg.budget === "number" && e2eCfg.budget > 0)) fail(`standards.json e2e.budget is ${JSON.stringify(e2eCfg.budget)}`, "minutes above 0 (it may only tighten the org budget)");
  const mins = Math.min(e2eCfg.budget ?? Infinity, pack.gate_budget?.e2e ?? 5), ms = Math.round(mins * 60000);
  const url = env.GATE_PREVIEW_URL ?? "";
  // A client site's preview must not be indexed: its home page and a page only the Worker can answer (a 404; static
  // _headers rules do not cover Worker-rendered responses) both say noindex, in a robots meta or X-Robots-Tag. The
  // fetches and their body reads stop at the e2e budget, and the suite gets only the time left.
  const started = Date.now();
  if (url && pack.profile === "client") {
    const directives = (v) => v.toLowerCase().split(",").map((d) => d.replace(/^[^:]*:/, "").trim());
    const attrs = (tag) => Object.fromEntries([...tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g)].map((a) => [a[1].toLowerCase(), a[2] ?? a[3] ?? a[4]]));
    const signal = AbortSignal.timeout(ms);
    for (const page of [url, new URL("/__std-noindex-probe", url).href]) {
      let res = null, html = "";
      try { res = await fetch(page, { redirect: "follow", signal }); html = await res.text(); }
      catch (e) { fail(e.name === "TimeoutError" || e.name === "AbortError" ? `the preview at ${page} did not answer within the e2e budget (${mins} min)` : `the preview at ${page} did not answer: ${e.cause?.code ?? e.message}`, "re-run gate once the preview is up"); }
      // Only active markup counts: not inside an HTML comment, <noscript> or <template>.
      const active = html.replace(/<!--[\s\S]*?-->/g, "").replace(/<(noscript|template)\b[\s\S]*?<\/\1\s*>/gi, "");
      const meta = [...active.matchAll(/<meta\b[^>]*>/gi)].map(([t]) => attrs(t)).some((a) => /^(robots|googlebot)$/i.test(a.name ?? "") && directives(a.content ?? "").some((d) => ["noindex", "none"].includes(d)));
      if (!meta && !directives(res.headers.get("x-robots-tag") ?? "").some((d) => ["noindex", "none"].includes(d)))
        fail(`the preview at ${page} carries no noindex (robots meta or X-Robots-Tag)`, "previews must not be indexed: send X-Robots-Tag: noindex on every non-production host, from public/_headers for static files and from the middleware for Worker-rendered responses");
    }
    console.log(`preview noindex: ok (${url})`);
  }
  const left = ms - (Date.now() - started);
  if (left <= 0) fail(`e2e exceeded its ${mins}-minute budget`, "the preview answered too slowly for the suite to run; re-run gate");
  if (run) {
    console.log(`e2e: ${run[0]} ${run[1].map((a) => (a.includes("*") ? `"${a}"` : a)).join(" ")}${url ? ` against ${url}` : ""} (budget ${mins} min)`);
    const r = spawnSync(run[0], run[1], { stdio: "inherit", timeout: left, killSignal: "SIGKILL",
      env: { ...env, PW_GLOBAL_TIMEOUT: String(left), ...(url && { PLAYWRIGHT_BASE_URL: url, BASE_URL: url }) } });
    if (r.error?.code === "ETIMEDOUT" || r.signal) fail(`e2e exceeded its ${mins}-minute budget`, "make the slow tests faster (fewer navigations, the preview URL), then move the slow tail to the release check on main; do not shard");
    if (r.status) process.exit(r.status);
  }
  else fail("no e2e suite (test:e2e or e2e script; tests/e2e/ or e2e/ with playwright.config.* or *.test.*js)",
    'add an end-to-end suite through the real entry point; docs/static repos (or Builds-only repos) only: "e2e": false in standards.json');
} else if (cmd === "secrets") {
  const V = "8.30.1", SUM = "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb", local = env.GATE_GITLEAKS_ARCHIVE;
  const linux = process.platform === "linux" && process.arch === "x64";
  const notLinux = () => fail(`secret scan needs linux x64, not ${process.platform}-${process.arch}`, "let the gate job run it");
  if (!linux && !local) notLinux();
  const dir = mkdtempSync(`${tmpdir()}/gitleaks-`), tgz = local || `${dir}/gl.tgz`;
  if (!local) {
    const res = await fetch(`https://github.com/gitleaks/gitleaks/releases/download/v${V}/gitleaks_${V}_linux_x64.tar.gz`);
    if (!res.ok) fail(`gitleaks download: ${res.status}`, "re-run the job");
    writeFileSync(tgz, Buffer.from(await res.arrayBuffer()));
  }
  const got = createHash("sha256").update(rd(tgz)).digest("hex");
  if (got !== SUM) fail(`gitleaks archive checksum mismatch: got ${got}, want ${SUM}`, "do not run it; re-run, or pin a new version and checksum in the engine");
  if (!linux) notLinux();
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
