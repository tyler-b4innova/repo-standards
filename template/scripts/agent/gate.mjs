#!/usr/bin/env node
// Steps of the `gate` job (std-gate.yml), also runnable locally:
//   classify [base] | install | run <script>... | e2e | evidence | codex | secrets
// UI paths: pack.json defaults; standards.json "ui_paths" as a list replaces the include globs,
// as {include, ignore} replaces include and adds ignore. e2e: none fails unless "e2e": false.
// evidence: PR UI changes need a comment by the author or an app whose .evidence/ images exist at a pinned SHA.
import { execFileSync as ex, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync as has, mkdtempSync, readdirSync as ls, readFileSync as rd, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["classify", "install", "run", "e2e", "evidence", "codex", "secrets"], ok = SUBS.includes(cmd);
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
function ui(files) {
  const p = json("scripts/agent/pack.json") ?? {}, o = std.ui_paths;
  const inc = (Array.isArray(o) ? o : o?.include ?? p.ui_paths ?? []).map(glob), ign = [...(p.ui_ignore ?? []), ...(o?.ignore ?? [])].map(glob);
  return files.filter((f) => inc.some((r) => r.test(f)) && !ign.some((r) => r.test(f)));
}

if (cmd === "classify") {
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
    if (d.playwright || d["@playwright/test"]) must("npx", ["playwright", "install", "--with-deps", "chromium"]);
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
  const run = typeof std.e2e === "string" ? ["bash", ["-c", std.e2e]] : script ? [pm, ["run", script]] : dir && pw ? ["npx", ["playwright", "test", dir]]
    : rootPw ? ["npx", ["playwright", "test"]]
    : dir && ls(dir, { recursive: true }).some((f) => /\.test\.[cm]?js$/.test(f)) ? ["node", ["--test", `${dir}/**/*.test.*js`]] : null;
  if (run) { console.log(`e2e: ${run[0]} ${run[1].map((a) => (a.includes("*") ? `"${a}"` : a)).join(" ")}`); must(...run); }
  else if (std.e2e === false) console.log('::warning::no e2e suite; standards.json sets "e2e": false (docs and static repos only)');
  else fail("no e2e suite (test:e2e or e2e script; tests/e2e/ or e2e/ with playwright.config.* or *.test.*js)",
    'add an end-to-end suite through the real entry point; docs/static repos only: "e2e": false in standards.json');
} else if (cmd === "evidence") {
  const t = git("ls-files", "--", ".evidence").split("\n")[0];
  if (t) fail(`.evidence/ is tracked (${t}); it would reach the default branch`, "git rm -r --cached .evidence and commit");
  const event = env.GITHUB_EVENT_PATH ? json(env.GITHUB_EVENT_PATH) ?? {} : {}, pr = event.pull_request;
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
  const docsOnly = changed.every((f) => /\.(docx|pptx|xlsx|odt|odp|ods|pdf)$/i.test(f));
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
    // a PR changing only documents needs before and after page images (pdftoppm's before-N/after-N).
    const img = (n, st) => new RegExp(`(^|[/_-])${st}[_-]`, "i").test(n) && !new RegExp(`(^|[/_-])${st === "before" ? "after" : "before"}[_-]`, "i").test(n);
    const shot = (state, w) => names.some((n) => img(n, state) && new RegExp(`(^|[^0-9])${w}\\.(png|jpe?g|webp|gif)$`, "i").test(n));
    // Document pages pair up by number: at least one page has both a before and an after image.
    const pages = (state) => new Set(names.filter((n) => img(n, state)).map((n) => n.match(/[_-]0*(\d+)\.(png|jpe?g|webp|gif)$/i)?.[1]).filter(Boolean));
    const [pb, pa] = [pages("before"), pages("after")], paired = [...pb].some((x) => pa.has(x));
    const gaps = docsOnly ? (paired ? [] : [!pb.size ? "before pages" : !pa.size ? "after pages" : "a page with both before and after"])
      : ["before", "after"].flatMap((st) => [400, 1280].filter((w) => !shot(st, w)).map((w) => `${st} ${w}px`));
    if (gaps.length) { bad.push(`${who}: needs ${docsOnly ? "before and after page images (before-N, after-N)" : "before and after captures at 400 and 1280px"} (missing ${gaps.join(", ")})`); continue; }
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
  const event = env.GITHUB_EVENT_PATH ? json(env.GITHUB_EVENT_PATH) ?? {} : {};
  if (!event.pull_request) { console.log("codex: not a pull request"); process.exit(0); }
  const pk = json("scripts/agent/pack.json") ?? {};
  if (std.codex_review === false || pk.codex_review === false) { console.log("codex: review is off for this repo"); process.exit(0); }
  const repo = env.GITHUB_REPOSITORY, base = env.GITHUB_API_URL || "https://api.github.com", API = `${base}/repos/${repo}`;
  const auth = { Authorization: `Bearer ${env.GH_TOKEN || env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json" };
  const get = async (p) => { const r = await fetch(`${API}${p}`, { headers: auth }); if (!r.ok) fail(`GET ${p}: ${r.status}`, "grant the job actions, pull-requests and issues read"); return r.json(); };
  const n = event.pull_request.number, pr = await get(`/pulls/${n}`), head = pr.head.sha;
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
