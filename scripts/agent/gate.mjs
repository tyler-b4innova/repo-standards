#!/usr/bin/env node
// Steps of the `gate` job (std-gate.yml), also runnable locally:
//   plan | classify [base] | install | run <script>... | preview | e2e | secrets | syntax
// UI paths: pack.json defaults; standards.json "ui_paths" as a list replaces the include globs,
// as {include, ignore} replaces include and adds ignore. e2e: none fails unless "e2e": false.
import { execFileSync as ex, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync as has, mkdtempSync, readdirSync as ls, readFileSync as rd, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["plan", "classify", "install", "run", "preview", "e2e", "secrets", "syntax"], ok = SUBS.includes(cmd);
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
// Browsers for this run: Chromium, plus the repo's (and overlay's) extra browsers on promotion PRs only (plan sets GATE_BROWSERS).
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

if (cmd === "plan") {
  // full: build and test this head. cheap: a draft (the check, the secret scan and a syntax pass); the full gate
  // runs from ready_for_review.
  const get = ghApi();
  let mode = "full", why = "build and test this head";
  const pr = prNumber ? await get(`/pulls/${prNumber}`) : null;
  if (pr?.draft) { mode = "cheap"; why = "draft: the full gate runs from ready_for_review"; }
  let list = ["chromium"];
  if (pr) {
    const info = (await get("", { need: false })) ?? {}, flow = std.flow ?? info.custom_properties?.flow;
    if (flow === "staged" && pr.head?.repo?.full_name === env.GITHUB_REPOSITORY && pr.head.ref === info.default_branch && pr.base.ref !== info.default_branch)
      list = [...new Set([...list, ...(e2eCfg.browsers ?? []), ...(pack.e2e_promotion_browsers ?? [])])];
  }
  console.log(`plan: ${mode} (${why})`);
  output("mode", mode);
  output("browsers", list.join(","));
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
  else { console.log(`run: ${pm} run ${s}`); must(pm, ["run", s]); }
} else if (cmd === "e2e") {
  // "e2e": false skips this step and the preview step (docs and static repos, and repos whose Workers Builds run on every PR without an e2e suite).
  if (std.e2e === false) { console.log('::warning::e2e skipped; standards.json sets "e2e": false'); process.exit(0); }
  // standards.json "e2e": "<command>" names the suite; else a script, a tests/e2e or e2e dir, or a root Playwright config.
  const script = ["test:e2e", "e2e"].find((s) => pkg?.scripts?.[s]), dir = ["tests/e2e", "e2e"].find(has);
  const rootPw = ls(".").some((f) => /^playwright\.config\.[cm]?[jt]s$/.test(f)), pw = rootPw || (dir && ls(dir).some((f) => /^playwright\.config\.[cm]?[jt]s$/.test(f)));
  // Playwright runs this run's browsers only (Chromium unless a promotion opts in more), when the config defines
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
  if (run) {
    console.log(`e2e: ${run[0]} ${run[1].map((a) => (a.includes("*") ? `"${a}"` : a)).join(" ")}${url ? ` against ${url}` : ""} (budget ${mins} min)`);
    const r = spawnSync(run[0], run[1], { stdio: "inherit", timeout: ms, killSignal: "SIGKILL",
      env: { ...env, PW_GLOBAL_TIMEOUT: String(ms), ...(url && { PLAYWRIGHT_BASE_URL: url, BASE_URL: url }) } });
    if (r.error?.code === "ETIMEDOUT" || r.signal) fail(`e2e exceeded its ${mins}-minute budget`, "make the slow tests faster (fewer navigations, the preview URL), then move the slow tail to promotion PRs; do not shard");
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
