#!/usr/bin/env node
// Steps of the `gate` job (std-gate.yml), also runnable locally:
//   classify [base] | install | run <script>... | e2e | evidence | secrets
// UI paths: pack.json defaults; standards.json "ui_paths" as a list replaces the include globs,
// as {include, ignore} replaces include and adds ignore. e2e: none fails unless "e2e": false.
// evidence: PR UI changes need a comment by the author or an app whose .evidence/ images exist at a pinned SHA.
import { execFileSync as ex, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync as has, mkdtempSync, readdirSync as ls, readFileSync as rd, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["classify", "install", "run", "e2e", "evidence", "secrets"], ok = SUBS.includes(cmd);
if (!ok || args.includes("--help")) {
  console.log(rd(new URL(import.meta.url), "utf8").split("\n").slice(1, 6).map((l) => l.slice(3)).join("\n"));
  process.exit(ok || cmd === "--help" ? 0 : 2);
}
const git = (...a) => ex("git", a, { encoding: "utf8", stdio: "pipe" });
try { process.chdir(git("rev-parse", "--show-toplevel").trim()); } catch {}
const json = (f) => { try { return JSON.parse(rd(f, "utf8")); } catch { return null; } };
const pkg = json("package.json"), std = json("standards.json") ?? {};
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
  const b = args[0] ?? "origin/HEAD";
  let base;
  try { base = git("merge-base", b, "HEAD").trim(); } catch { fail(`base ${b} not found`, "git fetch origin, or pass a base ref"); }
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
  const script = ["test:e2e", "e2e"].find((s) => pkg?.scripts?.[s]), dir = ["tests/e2e", "e2e"].find(has);
  const pw = [".", dir].some((d) => d && ls(d).some((f) => /^playwright\.config\.[cm]?[jt]s$/.test(f)));
  const run = script ? [pm, ["run", script]] : dir && pw ? ["npx", ["playwright", "test", dir]]
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
    if (event.sender?.type !== "Bot") fail(`${env.GITHUB_REF_NAME} was pushed by @${event.sender?.login}, not an App`, "only the org's sync App pushes standards/v branches; open a pull request instead");
    const def = event.repository?.default_branch ?? "main", paths = (t) => (t ?? "").split("\n").filter((l) => l && !l.startsWith("#")).map((l) => l.split(/\s+/)[1]);
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
  const trusted = pk.evidence_trusted_authors ?? ["pr_author", "app"];
  const trust = (c) => (trusted.includes("pr_author") && c.user?.login === pr.user.login) || (trusted.includes("app") && c.performed_via_github_app) || trusted.includes(c.user?.login);
  const esc = (s) => s.replace(/[.]/g, "\\.");
  const pin = new RegExp(`^${esc(env.GITHUB_SERVER_URL || "https://github.com")}/${esc(repo)}/(?:blob|raw)/([0-9a-f]{40})/(\\.evidence/[^?#]+)(?:[?#].*)?$`, "i");
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
    if (!miss.length) { console.log(`evidence: accepted ${c.html_url}`); process.exit(0); }
    bad.push(`${who}: unresolved (need this repo, a 40-hex SHA, the file):\n    ${miss.join("\n    ")}`);
  }
  fail(`UI paths changed but no accepted evidence comment${bad.length ? `; rejected:\n  ${bad.join("\n  ")}` : ""}`, "PR author or an app: scripts/agent/pr.sh evidence (skill std-evidence)");
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
  const r = env.RANGE;
  console.log(`secrets: gitleaks ${r ? `git --log-opts=${r}` : "dir ."}`);
  if (sh(`${dir}/gitleaks`, [...(r ? ["git", `--log-opts=${r}`] : ["dir"]), "--redact", "--no-banner", "-v", "."]))
    fail("gitleaks found a secret (redacted above)", "rotate it and remove it from the branch history; false positive: its fingerprint in .gitleaksignore");
}
