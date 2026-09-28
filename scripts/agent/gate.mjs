#!/usr/bin/env node
// Steps of the `gate` job (std-gate.yml), also runnable locally:
//   plan | classify [base] | install | run <script>... | preview | e2e | review | secrets | syntax
// UI paths: pack.json defaults; standards.json "ui_paths" as a list replaces the include globs,
// as {include, ignore} replaces include and adds ignore. e2e: none fails unless "e2e": false.
// evidence: PR UI changes need a comment by the author or an app whose .evidence/ images exist at a pinned SHA.
import { execFileSync as ex, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync as has, mkdtempSync, readdirSync as ls, readFileSync as rd, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["plan", "classify", "install", "run", "preview", "e2e", "review", "secrets", "syntax"], ok = SUBS.includes(cmd);
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
    if (flow === "staged" && pr.head.ref === info.default_branch && pr.base.ref !== info.default_branch)
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
  // The head's Workers Builds preview, when the repo has one: a failed Cloudflare build fails gate; a build still
  // running is waited on for at most 3 minutes; the URL comes from the Cloudflare bot's PR comment for this commit.
  if (!prNumber || e2eCfg.preview === false) { console.log("preview: none (not a pull request, or e2e.preview is false)"); output("url", ""); process.exit(0); }
  const get = ghApi(), pr = await get(`/pulls/${prNumber}`), head = pr.head.sha, short = head.slice(0, 7);
  const name = pack.preview?.check_name ?? "Workers Builds", author = pack.preview?.comment_author ?? "cloudflare-workers-and-pages[bot]";
  const wait = Number(env.GATE_PREVIEW_WAIT_S ?? 180) * 1000, start = Date.now();
  for (;;) {
    const runs = ((await get(`/commits/${head}/check-runs?per_page=100`))?.check_runs ?? []).filter((c) => c.name?.startsWith(name));
    const red = runs.find((c) => c.status === "completed" && !["success", "neutral", "skipped"].includes(c.conclusion));
    if (red) fail(`Cloudflare build failed for ${short}: ${red.name} ${red.conclusion} (${red.details_url})`, "fix the Worker build; gate tests the deployed preview");
    if (!runs.length) { console.log(`preview: no "${name}" check run on ${short}; e2e runs locally`); output("url", ""); process.exit(0); }
    if (runs.every((c) => c.status === "completed")) break;
    if (Date.now() - start >= wait) { console.log(`preview: the Cloudflare build for ${short} is still running after ${wait / 1000}s; e2e runs locally`); output("url", ""); process.exit(0); }
    await new Promise((r) => setTimeout(r, 15000));
  }
  const comments = [];
  for (let page = 1; ; page++) { const b = (await get(`/issues/${prNumber}/comments?per_page=100&page=${page}`)) ?? []; comments.push(...b); if (b.length < 100) break; }
  const url = comments.filter((c) => c.user?.login === author).reverse().flatMap((c) => c.body.split("\n"))
    .filter((l) => l.includes(short) && /https:\/\//.test(l)).map((l) => l.match(/https:\/\/[^\s,<>)"'|]+/)[0])[0] ?? "";
  console.log(url ? `preview: ${url} (${short})` : `preview: no preview URL for ${short} in the Cloudflare comment; e2e runs locally`);
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
  else if (std.e2e === false) console.log('::warning::no e2e suite; standards.json sets "e2e": false (docs and static repos only)');
  else fail("no e2e suite (test:e2e or e2e script; tests/e2e/ or e2e/ with playwright.config.* or *.test.*js)",
    'add an end-to-end suite through the real entry point; docs/static repos only: "e2e": false in standards.json');
} else if (cmd === "review") {
  // The pull request's conversation (Codex verdict and threads, evidence, a promotion's design sign-off) is the org
  // App's `review` status once the org turns it on (pack.json review_status); until then gate evaluates the same rule.
  if (!prNumber) { console.log("review: not a pull request"); process.exit(0); }
  if (pack.review_status) { console.log("review: the org App posts the `review` status (scripts/agent/review.mjs); gate checks the code only"); process.exit(0); }
  const { reviewStatus, restApi } = await import(new URL("./review.mjs", import.meta.url));
  let token = env.GH_TOKEN || env.GITHUB_TOKEN;
  try { token ||= ex("gh", ["auth", "token"], { encoding: "utf8", stdio: "pipe" }).trim(); } catch {}
  const [owner, name] = (env.GITHUB_REPOSITORY ?? "").split("/");
  let r;
  try { r = await reviewStatus({ api: restApi({ token }), owner, repo: name, pr: prNumber, files: { pack, std }, force: true, serverUrl: env.GITHUB_SERVER_URL || "https://github.com" }); }
  catch (e) { fail(`review: ${e.message}`, "grant the job actions, checks, pull-requests and issues read, then re-run"); }
  if (!r) { console.log("review: draft or closed; not evaluated"); process.exit(0); }
  for (const d of r.details ?? []) console.log(`review: ${d}`);
  if (r.state === "success") { console.log(`review: ${r.description}`); process.exit(0); }
  fail(`review: ${r.description}`, r.state === "pending" ? "the Codex review is still running; re-run gate (or push) once it has answered" : "fix it in the pull request (evidence: scripts/agent/pr.sh evidence; findings: fix or reply, then resolve), then re-run gate or push");
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
