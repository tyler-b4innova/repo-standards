#!/usr/bin/env node
// Steps of the `gate` job (std-gate.yml), also runnable locally:
//   plan | classify [base] | install | run <script>... | preview | e2e | evidence | codex | secrets | syntax
// UI paths: pack.json defaults; standards.json "ui_paths" as a list replaces the include globs,
// as {include, ignore} replaces include and adds ignore. e2e: none fails unless "e2e": false.
// evidence: PR UI changes need a comment by the author or an app whose .evidence/ images exist at a pinned SHA.
import { execFileSync as ex, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync as has, mkdtempSync, readdirSync as ls, readFileSync as rd, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["plan", "classify", "install", "run", "preview", "e2e", "evidence", "codex", "secrets", "syntax"], ok = SUBS.includes(cmd);
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
  // full: build and test this head. reuse: a re-run of a run whose earlier attempt passed every build and test step
  // (same run = same SHA and workflow file), so only evidence, approval and the Codex verdict are checked again.
  // cheap: drafts, and pack-only landings (standards/v*) outside the profile's canary repository.
  const get = ghApi(), attempt = Number(env.GITHUB_RUN_ATTEMPT || 1), BUILD = ["standards", "secrets", "install", "typecheck", "build", "e2e", "repo checks"];
  let mode = "full", why = "first build of this head";
  for (let a = attempt - 1; a >= 1 && mode === "full"; a--) {
    const jobs = (await get(`/actions/runs/${env.GITHUB_RUN_ID}/attempts/${a}/jobs`, { need: false }))?.jobs ?? [];
    const steps = jobs.find((j) => j.name === "gate")?.steps ?? [];
    if (BUILD.every((n) => steps.find((x) => x.name === n)?.conclusion === "success")) { mode = "reuse"; why = `attempt ${a} of this run passed ${BUILD.join(", ")}`; }
  }
  const repoName = (env.GITHUB_REPOSITORY ?? "").split("/")[1];
  const pr = mode === "full" && prNumber ? await get(`/pulls/${prNumber}`) : null;
  if (mode === "full" && pr?.draft) { mode = "cheap"; why = "draft: the full gate runs from ready_for_review"; }
  if (mode === "full" && env.GITHUB_EVENT_NAME === "push" && /^standards\/v\d+\.\d+\.\d+$/.test(env.GITHUB_REF_NAME ?? "")) {
    if ((pack.gate_canary ?? []).includes(repoName)) why = "pack landing on this profile's canary: full gate";
    else { mode = "cheap"; why = "pack-only landing (the evidence step holds it to managed paths)"; }
  }
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
  const bad = [];
  for (const f of git("ls-files", "scripts/agent", ".github/workflows").split("\n").filter(Boolean)) {
    const text = rd(f, "utf8"), first = text.split("\n")[0];
    const r = /\.(sh)$/.test(f) || /^#!.*\bbash\b/.test(first) ? spawnSync("bash", ["-n", f], { encoding: "utf8" })
      : /\.(mjs|js)$/.test(f) || /^#!.*\bnode\b/.test(first) ? spawnSync("node", ["--check", ...(/\.(mjs|js)$/.test(f) ? [f] : ["--input-type=module"])], { encoding: "utf8", input: /\.(mjs|js)$/.test(f) ? undefined : text.replace(/^#!.*\n/, "") })
      : /\.ya?ml$/.test(f) ? spawnSync("python3", ["-c", "import sys,yaml; yaml.safe_load(open(sys.argv[1]))", f], { encoding: "utf8" }) : null;
    if (r && r.status && !(r.error && /\.ya?ml$/.test(f))) bad.push(`${f}: ${(r.stderr || r.stdout || "").trim().split("\n").slice(-1)[0]}`);
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
    const runs = ((await get(`/commits/${head}/check-runs?per_page=100`, { need: false }))?.check_runs ?? []).filter((c) => c.name?.startsWith(name));
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
  // Without --project Playwright runs every project, so a config whose projects are named otherwise is refused.
  if (!e2eCmd && !script && cfg && /\bprojects\s*:/.test(cfg) && !projects.length)
    fail(`${cfgFile} defines projects but none named ${browsers().join(" or ")}, so gate cannot pick the Chromium run`, 'name the Chromium project "chromium" (gate runs only that), or set standards.json e2e.command');
  const pwBin = has("node_modules/.bin/playwright") ? ["node_modules/.bin/playwright", []] : ["npx", ["--no-install", "playwright"]];
  const run = e2eCmd ? ["bash", ["-c", e2eCmd]] : script ? [pm, ["run", script]] : dir && pw ? [pwBin[0], [...pwBin[1], "test", dir, ...projects]]
    : rootPw ? [pwBin[0], [...pwBin[1], "test", ...projects]]
    : dir && ls(dir, { recursive: true }).some((f) => /\.test\.[cm]?js$/.test(f)) ? ["node", ["--test", `${dir}/**/*.test.*js`]] : null;
  // Budget: the whole suite within gate_budget.e2e minutes (standards.json e2e.budget may only tighten it).
  const mins = Math.min(Number(e2eCfg.budget ?? Infinity), pack.gate_budget?.e2e ?? 5), ms = Math.round(mins * 60000);
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
} else if (cmd === "evidence") {
  const t = git("ls-files", "--", ".evidence").split("\n")[0];
  if (t) fail(`.evidence/ is tracked (${t}); it would reach the default branch`, "git rm -r --cached .evidence and commit");
  let pr = event.pull_request;
  if (!pr && prNumber) pr = await ghApi()(`/pulls/${prNumber}`); // a workflow_dispatch re-gate of this pull request
  // A push to standards/vX.Y.Z is the sync's landing branch: that run skips the PR checks, so it must come from an App
  // and change only pack paths (those in the base or new lock, within the managed prefixes).
  if (!pr && env.GITHUB_EVENT_NAME === "push" && /^standards\/v\d+\.\d+\.\d+$/.test(env.GITHUB_REF_NAME ?? "")) {
    const app = (json("scripts/agent/pack.json") ?? {}).sync_app_login;
    if (!app || event.sender?.login !== app) fail(`${env.GITHUB_REF_NAME} was pushed by @${event.sender?.login}, not the sync App${app ? ` @${app}` : " (overlay sync.app_login unset)"}`, "only the org's sync App pushes standards/v branches; open a pull request instead");
    const def = event.repository?.default_branch ?? "main", paths = (t) => (t ?? "").split("\n").map((l) => l.match(/^(?:sha256 )?[0-9a-f]{64}\s+(\S+)\s*$/)?.[1]).filter(Boolean);
    let base = "";
    try { base = git("show", `origin/${def}:standards.lock`); } catch {}
    const prefix = /^(\.agents\/skills\/std-[^/]+\/|scripts\/agent\/|\.github\/workflows\/std-[^/]+$|\.github\/(PULL_REQUEST_TEMPLATE\.md|ISSUE_TEMPLATE\/agent-task\.md)$|\.codex\/rules\/)/;
    const managed = new Set([...paths(base), ...paths(rd("standards.lock", "utf8")).filter((f) => prefix.test(f)),
      "AGENTS.md", "standards.json", "standards.lock", ".gitignore", ".claude/settings.json", ".claude/skills", ".codex/config.toml"]);
    const other = git("diff", "--name-only", `origin/${def}...HEAD`).split("\n").filter((f) => f && !managed.has(f));
    if (other.length) fail(`standards/v branch changes non-pack paths: ${other.slice(0, 5).join(", ")}`, "open a pull request for these changes");
    console.log(`evidence: pack-only update on ${env.GITHUB_REF_NAME} by @${event.sender.login}`);
    process.exit(0);
  }
  if (!pr) { console.log("evidence: .evidence/ untracked; comment check runs on pull requests"); process.exit(0); }
  let token = env.GH_TOKEN || env.GITHUB_TOKEN;
  try { token ||= ex("gh", ["auth", "token"], { encoding: "utf8", stdio: "pipe" }).trim(); } catch {}
  const repo = env.GITHUB_REPOSITORY, API = `${env.GITHUB_API_URL || "https://api.github.com"}/repos/${repo}`, auth = { Authorization: `Bearer ${token}` };
  const list = async (path, out = []) => {
    for (let page = 1; ; page++) {
      const res = await fetch(`${API}/${path}?per_page=100&page=${page}`, { headers: auth });
      if (!res.ok) fail(`GET ${path}: ${res.status}`, "grant the job pull-requests: read and issues: read");
      const b = await res.json();
      out.push(...b);
      if (b.length < 100) return out;
    }
  };
  const get = async (path) => { const r = await fetch(`${API}${path}`, { headers: auth }); return r.ok ? r.json() : null; };
  const pk = json("scripts/agent/pack.json") ?? {}, info = (await get("")) ?? {}, live = (await get(`/pulls/${pr.number}`)) ?? pr;
  const changed = ui((await list(`pulls/${pr.number}/files`)).map((f) => f.filename));
  // A promotion (staged flow: default branch -> another branch) needs no evidence comment (it is on the original
  // PRs), but a design change needs an APPROVED review on the current head from a human with write access.
  const flow = std.flow ?? info.custom_properties?.flow;
  if (flow === "staged" && live.head.ref === info.default_branch && live.base.ref !== info.default_branch) {
    if (!changed.length || std.design_signoff === false || pk.design_signoff === false) { console.log("promotion: no design sign-off needed"); process.exit(0); }
    const latest = new Map();
    for (const r of await list(`pulls/${pr.number}/reviews`)) latest.set(r.user?.login, r);
    for (const r of latest.values()) {
      if (r.state !== "APPROVED" || r.commit_id !== live.head.sha || r.user?.type !== "User" || r.user.login === live.user?.login) continue;
      const perm = await get(`/collaborators/${r.user.login}/permission`);
      if (["admin", "maintain", "write"].includes(perm?.permission)) { console.log(`promotion: design change approved by @${r.user.login} on ${live.head.sha.slice(0, 7)}`); process.exit(0); }
    }
    fail(`design change in this promotion (${changed.slice(0, 5).join(", ")}) has no human approval on ${live.head.sha.slice(0, 7)}`, "design change: approve this promotion after checking the staging preview");
  }
  if (!changed.length) { console.log("evidence: no UI paths changed; not required"); process.exit(0); }
  console.log(`UI paths changed:\n  ${changed.join("\n  ")}`);
  const isDoc = (f) => /\.(docx|pptx|xlsx|odt|odp|ods|pdf)$/i.test(f), docs = changed.some(isDoc), web = changed.some((f) => !isDoc(f));
  const trusted = pk.evidence_trusted_authors ?? ["pr_author", "app"];
  const trust = (c) => (trusted.includes("pr_author") && c.user?.login === pr.user.login) || (trusted.includes("app") && c.performed_via_github_app) || trusted.includes(c.user?.login);
  const esc = (s) => s.replace(/[.]/g, "\\.");
  const pin = new RegExp(`^${esc(env.GITHUB_SERVER_URL || "https://github.com")}/${esc(repo)}/(?:blob|raw)/([0-9a-f]{40})/(\\.evidence/[^?#]+)(?:[?#].*)?$`, "i");
  // Accepted: a trusted comment whose images are all in this repo at a commit in the PR head's history, covering
  // before and after at 400 and 1280px, with no later first-parent commit touching a UI path (evidence goes stale when the UI changes).
  const head = live.head.sha, inHead = (c) => { try { git("merge-base", "--is-ancestor", c, head); return true; } catch { return false; } };
  const later = (c) => { try { return git("log", "--first-parent", "--format=%H", `${c}..${head}`).split("\n").filter(Boolean); } catch { return []; } };
  const bad = [];
  for (const c of await list(`issues/${pr.number}/comments`)) {
    const urls = [...new Set(c.body?.match(/https?:\/\/[^\s)"'<>]*\/\.evidence\/[^\s)"'<>]*/g) ?? [])];
    const who = `${c.html_url} by @${c.user?.login}`;
    if (!urls.length) continue;
    if (!trust(c)) { bad.push(`${who}: not a trusted author (${trusted.join(", ")}; PR author @${pr.user.login})`); continue; }
    const miss = [];
    for (const u of urls) {
      const m = u.match(pin);
      if (!m || (await fetch(`${API}/contents/${m[2]}?ref=${m[1]}`, { method: "HEAD", headers: { ...auth, Accept: "application/vnd.github.raw+json" } })).status !== 200) miss.push(u);
    }
    if (miss.length) { bad.push(`${who}: unresolved (need this repo, a 40-hex SHA, the file):\n    ${miss.join("\n    ")}`); continue; }
    const shas = [...new Set(urls.map((u) => u.match(pin)[1]))], names = urls.map((u) => decodeURIComponent(u.match(pin)[2]));
    // Distinct images: a file counts for one state only. Web changes need before and after at 400 and 1280px;
    // document changes need before and after page images (pdftoppm's before-N/after-N); a PR with both needs both.
    const img = (n, st) => new RegExp(`(^|[/_-])${st}[_-]`, "i").test(n) && !new RegExp(`(^|[/_-])${st === "before" ? "after" : "before"}[_-]`, "i").test(n);
    const shot = (state, w) => names.some((n) => img(n, state) && new RegExp(`(^|[^0-9])${w}\\.(png|jpe?g|webp|gif)$`, "i").test(n));
    // Document pages are pdftoppm's before-N/after-N files, paired by number: at least one page has both.
    // A file named like a viewport capture (…400 or …1280) is never also a document page.
    const pages = (state) => new Set(names.map((n) => n.split("/").pop().match(new RegExp(`^${state}-0*(\\d+)\\.(png|jpe?g|webp|gif)$`, "i"))?.[1]).filter((x) => x && !["400", "1280"].includes(x)));
    const [pb, pa] = [pages("before"), pages("after")], paired = [...pb].some((x) => pa.has(x));
    // Each kind that changed needs its own set: web captures at both widths, document pages.
    const gaps = [...(web ? ["before", "after"].flatMap((st) => [400, 1280].filter((w) => !shot(st, w)).map((w) => `${st} ${w}px`)) : []),
      ...(docs && !paired ? [!pb.size ? "before pages" : !pa.size ? "after pages" : "a page with both before and after"] : [])];
    const need = [web && "before and after captures at 400 and 1280px", docs && "before and after page images (before-N, after-N)"].filter(Boolean).join(" and ");
    if (gaps.length) { bad.push(`${who}: needs ${need} (missing ${gaps.join(", ")})`); continue; }
    const outside = shas.filter((x) => !inHead(x));
    if (outside.length) { bad.push(`${who}: evidence commit ${outside[0].slice(0, 7)} is not in this PR's history`); continue; }
    // Each first-parent commit against its first parent, so a merged side branch's UI changes count too.
    const touched = (x) => { try { return git("diff", "--name-only", `${x}^1`, x).split("\n").filter((f) => f && !f.startsWith(".evidence/")); } catch { return []; } };
    const stale = shas.flatMap(later).find((x) => ui(touched(x)).length);
    if (stale) { bad.push(`${who}: UI changed after the evidence (commit ${stale.slice(0, 7)}); capture again`); continue; }
    console.log(`evidence: accepted ${c.html_url}`);
    process.exit(0);
  }
  fail(`UI paths changed but no accepted evidence comment${bad.length ? `; rejected:\n  ${bad.join("\n  ")}` : ""}`, "PR author or an app: scripts/agent/pr.sh evidence (skill std-evidence)");
} else if (cmd === "codex") {
  // Codex verdict on the current head: its summary comment shows this head's short SHA as Completed and every
  // Codex review thread is resolved. Drafts are not evaluated; repos without Codex reviews and the sync's
  // fallback PRs are exempt. No verdict 20 min after the head was pushed or marked ready fails for the launcher.
  if (!prNumber) { console.log("codex: not a pull request"); process.exit(0); }
  const pk = pack;
  if (std.codex_review === false || pk.codex_review === false) { console.log("codex: review is off for this repo"); process.exit(0); }
  if (pk.codex_verdict === "status" && !env.GATE_CODEX_EVALUATE) { console.log("codex: the verdict is the codex-verdict commit status, posted by the org App (scripts/agent/verdict-recheck)"); process.exit(0); }
  const repo = env.GITHUB_REPOSITORY, base = env.GITHUB_API_URL || "https://api.github.com", API = `${base}/repos/${repo}`;
  const auth = { Authorization: `Bearer ${env.GH_TOKEN || env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json" };
  const get = async (p) => { const r = await fetch(`${API}${p}`, { headers: auth }); if (!r.ok) fail(`GET ${p}: ${r.status}`, "grant the job actions, pull-requests and issues read"); return r.json(); };
  const n = prNumber, pr = await get(`/pulls/${n}`), head = pr.head.sha;
  if (pr.draft) { console.log("codex: draft, not evaluated"); process.exit(0); }
  if (pk.sync_app_login && pr.user?.login === pk.sync_app_login && /^standards\/v\d+\.\d+\.\d+$/.test(pr.head.ref)) { console.log("codex: pack-sync fallback PR, exempt"); process.exit(0); }
  const bot = (u) => /codex/i.test(u?.login ?? "") && u?.type === "Bot", MARK = "<!-- codex-pull-request-review-summary -->";
  const comments = [];
  for (let page = 1; ; page++) { const b = await get(`/issues/${n}/comments?per_page=100&page=${page}`); comments.push(...b); if (b.length < 100) break; }
  const summary = comments.filter((c) => bot(c.user) && c.body?.includes(MARK)).at(-1);
  const row = summary?.body.match(/\|[^|\n]*Code Review[^|\n]*\|([^|\n]*)\|\s*`([0-9a-f]{7,40})`\s*\|/i);
  // The head's push time is server-recorded: its first pull_request gate run. A base edit changes the reviewed diff,
  // so the latest one moves that mark. A summary only counts when Codex completed it after the mark (the row shows a
  // 7-char SHA, so it is bound by time as well); a review naming the full SHA counts when submitted after the last base edit.
  const timeline = [];
  for (let page = 1; ; page++) { const b = await get(`/issues/${n}/timeline?per_page=100&page=${page}`); timeline.push(...b); if (b.length < 100) break; }
  const at = (ev) => timeline.filter((e) => e.event === ev).map((e) => Date.parse(e.created_at));
  const baseAt = Math.max(0, ...at("base_ref_changed"));
  const runs = (await get(`/actions/runs?head_sha=${head}&event=pull_request&per_page=100`)).workflow_runs ?? [];
  const pushedAt = Math.max(Math.min(...runs.map((r) => Date.parse(r.created_at)), Date.now()), baseAt);
  const reviews = await get(`/pulls/${n}/reviews?per_page=100`);
  const reviewed = (row && head.startsWith(row[2]) && /Completed/i.test(row[1]) && Date.parse(summary.updated_at) >= pushedAt)
    || reviews.some((r) => bot(r.user) && r.commit_id === head && Date.parse(r.submitted_at) >= baseAt);
  if (!summary && !reviewed) {
    let seen = false;
    // Codex skips drafts and may skip bot PRs, so sample up to 20 recent ready PRs by people.
    for (const p of (await get(`/pulls?state=all&per_page=40`)).filter((p) => p.number !== n && !p.draft && p.user?.type !== "Bot").slice(0, 20))
      if ((await get(`/issues/${p.number}/comments?per_page=100`)).some((c) => bot(c.user) && c.body?.includes(MARK))) { seen = true; break; }
    if (!seen) { console.log("::notice::codex: no Codex reviews on this repo's recent PRs; not required"); process.exit(0); }
  }
  if (reviewed) {
    const q = `query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:1){nodes{author{login} url}}}}}}}`;
    const gql = env.GITHUB_GRAPHQL_URL || (base.endsWith("/api/v3") ? base.replace(/\/v3$/, "/graphql") : `${base}/graphql`);
    const [o, r] = repo.split("/"), threads = [];
    for (let c = null; ; ) {
      const res = await fetch(gql, { method: "POST", headers: { ...auth, "Content-Type": "application/json" }, body: JSON.stringify({ query: q, variables: { o, r, n, c } }) });
      const page = (await res.json())?.data?.repository?.pullRequest?.reviewThreads;
      if (!page) fail("codex: could not read review threads", "re-run gate");
      threads.push(...page.nodes);
      if (!page.pageInfo?.hasNextPage) break;
      c = page.pageInfo.endCursor;
    }
    const open = threads.filter((t) => !t.isResolved && /codex/i.test(t.comments.nodes[0]?.author?.login ?? ""));
    if (open.length) fail(`codex: ${open.length} unresolved Codex thread(s): ${open.slice(0, 3).map((t) => t.comments.nodes[0].url).join(" ")}`, "fix each finding or reply with the reason and resolve the thread, then comment on the PR to re-run gate");
    console.log(`codex: verdict on ${head.slice(0, 7)}, no open findings`);
    process.exit(0);
  }
  // Codex skips drafts, so the clock starts at the later of the head's push and the PR becoming ready.
  const since = Math.max(pushedAt, ...at("ready_for_review"));
  const mins = Math.floor((Date.now() - since) / 60000);
  if (mins < 20) fail(`codex: awaiting a Codex verdict for ${head.slice(0, 7)} (${mins} min)`, "gate re-runs when the Codex summary updates");
  fail(`codex: no Codex verdict for ${head} — the launcher will request one`, "the launcher asks Codex to review; gate re-runs on its summary");
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
  // Always scan commits: PR base..head, merge group base..head, push before..sha. A new branch (or an unreachable
  // before) scans what the default branch lacks, or all of sha's history when it is the default branch; RANGE overrides.
  const ev = env.GITHUB_EVENT_PATH ? json(env.GITHUB_EVENT_PATH) ?? {} : {}, reach = (x) => { try { git("cat-file", "-e", `${x}^{commit}`); return true; } catch { return false; } };
  const def = ev.repository?.default_branch, fresh = (b) => !b || /^0+$/.test(b) || !reach(b);
  const pair = ev.pull_request ? [ev.pull_request.base.sha, ev.pull_request.head.sha] : ev.merge_group ? [ev.merge_group.base_sha, ev.merge_group.head_sha]
    : ev.after ? [fresh(ev.before) && def && ev.ref !== `refs/heads/${def}` && reach(`origin/${def}`) ? `origin/${def}` : ev.before, ev.after] : [null, env.GITHUB_SHA || "HEAD"];
  const r = env.RANGE || (pair[0] && !/^0+$/.test(pair[0]) && reach(pair[0]) ? `${pair[0]}..${pair[1]}` : pair[1]);
  console.log(`secrets: gitleaks git --log-opts=${r}`);
  if (sh(`${dir}/gitleaks`, ["git", `--log-opts=${r}`, "--redact", "--no-banner", "-v", "."]))
    fail("gitleaks found a secret (redacted above)", "rotate it and remove it from the branch history; false positive: its fingerprint in .gitleaksignore");
}
