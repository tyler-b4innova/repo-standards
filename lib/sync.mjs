// Fleet sync, run from an organization's standards repository with its overlay and release tag:
// open or refresh one `chore: standards v<version>` PR per fleet repository, arm auto-merge only where
// `gate` is a required check, and keep one pinned compliance issue with a row per repository.
// Needs GH_TOKEN (the standards App installation token); without it sync is idle.
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { apply, ENGINE_VERSION, sha256 } from "./engine.mjs";

export const API = () => (process.env.GITHUB_API_URL || "https://api.github.com").replace(/\/$/, "");

// REST helper: gh(method, path, body) → parsed JSON, or null on 404 when allow404.
export function client(token) {
  const call = async (method, path, body, { allow404 = false } = {}) => {
    const res = await fetch(path.startsWith("http") ? path : `${API()}/${path.replace(/^\//, "")}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", ...(body && { "Content-Type": "application/json" }) },
      body: body && JSON.stringify(body),
    });
    if (allow404 && res.status === 404) return null;
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text.slice(0, 200)}`);
    const data = text ? JSON.parse(text) : null;
    const next = res.headers.get("link")?.match(/<([^>]+)>;\s*rel="next"/)?.[1];
    return next && Array.isArray(data) ? [...data, ...(await call(method, next))] : data;
  };
  // Auto-merge and pinning exist only in GraphQL; sync runs in Actions where GraphQL is reachable.
  call.graphql = async (query, variables) => {
    const url = process.env.GITHUB_GRAPHQL_URL || `${API().replace(/\/v3$/, "")}/graphql`;
    const out = await call("POST", url, { query, variables });
    if (out?.errors?.length) throw new Error(out.errors.map((e) => e.message).join("; "));
    return out?.data;
  };
  return call;
}

const readJson = (file) => (file?.content ? JSON.parse(Buffer.from(file.content, "base64").toString("utf8")) : null);
const cell = (s) => String(s).replace(/[|\n]/g, " ");

export async function run({ overlay, repo: only, dryRun = false, version }) {
  version = String(version ?? "").replace(/^v/, "");
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("--version <X.Y.Z> (the standards repository's release tag) is required; unreleased heads never ship");
  if (overlay.engine !== ENGINE_VERSION) throw new Error(`overlay pins engine ${overlay.engine}, this is engine ${ENGINE_VERSION}; run the pinned engine release`);
  const token = process.env.GH_TOKEN;
  if (!token) {
    console.log("::notice::sync idle: GH_TOKEN (the standards App installation token) is not set; nothing written");
    return;
  }
  const gh = client(token);
  const org = overlay.org, branch = `chore/standards-v${version}`, title = `chore: standards v${version}`;
  const say = (msg) => console.log(`${dryRun ? "[dry-run] " : ""}${msg}`);
  const scrub = (s) => String(s).replaceAll(token, "***");
  const host = new URL(process.env.GITHUB_SERVER_URL || "https://github.com").host;
  const gitBase = process.env.SYNC_GIT_BASE || `https://x-access-token:${token}@${host}`;
  const { APP_SLUG: slug = "standards-sync" } = process.env; // the App slug names the commit author
  const who = { name: `${slug}[bot]`, email: `${slug}[bot]@users.noreply.github.com` };
  const gitEnv = { GIT_AUTHOR_NAME: who.name, GIT_AUTHOR_EMAIL: who.email, GIT_COMMITTER_NAME: who.name, GIT_COMMITTER_EMAIL: who.email, ...process.env, GIT_TERMINAL_PROMPT: "0" };

  // Fleet: which repositories, with which bootstrap profile.
  const norm = (r) => (r.includes("/") ? r : `${org}/${r}`);
  const include = new Map((overlay.fleet?.include ?? []).map((e) => [norm(e.repo), e.profile]));
  const exclude = new Set((overlay.fleet?.exclude ?? []).map(norm));
  let candidates, live = null;
  if (only) candidates = [norm(only)];
  else if (overlay.fleet?.mode === "list") candidates = [...include.keys()];
  else {
    live = new Set((await gh("GET", `orgs/${org}/repos?per_page=100&type=all`)).filter((r) => !r.archived).map((r) => r.full_name));
    candidates = [...new Set([...live, ...include.keys()])];
  }
  const fleet = [];
  for (const r of candidates.sort()) {
    if (r.split("/")[0].toLowerCase() !== org.toLowerCase()) { console.log(`skip ${r}: owned by another org (sync-org-isolated)`); continue; }
    if (r === overlay.standards_repo || exclude.has(r)) continue;
    const meta = live ? live.has(r) : await gh("GET", `repos/${r}`, null, { allow404: true }).then((m) => m && !m.archived);
    if (!meta) { console.log(`skip ${r}: archived or not found`); continue; }
    const std = readJson(await gh("GET", `repos/${r}/contents/standards.json`, null, { allow404: true }));
    if (std?.pack && std.pack !== overlay.pack) { console.log(`skip ${r}: standards.json names pack "${std.pack}" (sync-org-isolated)`); continue; }
    if (!std?.pack && !include.has(r)) continue; // not in this pack's fleet
    fleet.push({ repo: r, std, want: include.get(r) });
  }

  const rows = [];
  for (const f of fleet) {
    console.log(`::group::${f.repo}`);
    try {
      rows.push([f.repo, ...(await one(f))]);
    } catch (e) {
      console.log(`::error::${f.repo}: ${scrub(e.message)}`);
      rows.push([f.repo, f.std?.profile ?? f.want ?? "?", f.std?.version ?? "none", "sync failed, see run log"]);
      process.exitCode = 1;
    }
    console.log("::endgroup::");
  }
  await compliance(rows);

  async function one({ repo, std, want }) {
    const pinned = std?.version ?? "none";
    const tmp = mkdtempSync(join(tmpdir(), "std-sync-")), dir = join(tmp, repo.split("/")[1]); // apply titles a new AGENTS.md after the dir
    const git = (...a) => execFileSync("git", a, { cwd: dir, env: gitEnv, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    try {
      try { execFileSync("git", ["clone", "-q", "--depth", "1", `${gitBase}/${repo}.git`, dir], { env: gitEnv, stdio: ["ignore", "ignore", "pipe"] }); }
      catch (e) { throw new Error(`clone failed: ${scrub(e.stderr ?? e.message).trim()}`); }
      const base = git("branch", "--show-current");
      const r = apply({ target: dir, overlay, profile: std?.profile ?? want ?? "internal", version });
      const note = want && want !== r.profile ? `; profile ${r.profile} differs from fleet.include ${want} (repo value kept)` : "";
      git("add", "-A");
      const ours = (p) => p.head?.repo?.full_name === repo && p.head.ref.startsWith("chore/standards-v");
      const open = (await gh("GET", `repos/${repo}/pulls?state=open&per_page=100`)).filter(ours);
      const changed = git("status", "--porcelain") !== "";
      for (const p of open.filter((p) => !changed || p.head.ref !== branch)) {
        say(`close #${p.number} (${p.head.ref}): ${p.head.ref === branch ? "base already current" : `superseded by v${version}`}`);
        if (dryRun) continue;
        await gh("POST", `repos/${repo}/issues/${p.number}/comments`, { body: p.head.ref === branch ? `Not needed: ${base} already carries v${version}.` : `Superseded by v${version}.` });
        await gh("PATCH", `repos/${repo}/pulls/${p.number}`, { state: "closed" });
        await gh("DELETE", `repos/${repo}/git/refs/heads/${p.head.ref}`, null, { allow404: true }).catch(() => {});
      }
      if (!changed) return [r.profile, pinned, `current${note}`];

      const tree = git("write-tree");
      const content = sha256(git("diff", "--cached", "--full-index", "--binary"));
      const marker = `<!-- std:sync tree=${tree} content=${content} -->`;
      const mine = (await gh("GET", `repos/${repo}/pulls?state=all&per_page=100&head=${repo.split("/")[0]}:${encodeURIComponent(branch)}`)).filter(ours);
      const refused = mine.find((p) => p.state === "closed" && !p.merged_at && (p.body ?? "").match(new RegExp(`tree=${tree}|content=${content}`)));
      if (refused) return [r.profile, pinned, `v${version} closed by a person in #${refused.number}; not reopened${note}`];

      let remote = null;
      try { git("fetch", "-q", "--depth", "1", "origin", `refs/heads/${branch}`); remote = git("rev-parse", "FETCH_HEAD"); } catch {}
      if (dryRun) say(`${remote ? "fast-forward" : "push"} ${branch} (${r.changed.length} managed paths)`);
      else if (!remote) {
        git("commit", "-q", "-m", title, "-m", `Engine ${ENGINE_VERSION}, ${overlay.pack} v${version}, profile ${r.profile}.`);
        git("push", "-q", "origin", `HEAD:refs/heads/${branch}`);
      } else if (git("rev-parse", "FETCH_HEAD^{tree}") !== tree) {
        // Only ever move the branch forward: the new commit has the old branch head as a parent.
        const c = git("commit-tree", tree, "-p", remote, "-p", "HEAD", "-m", `${title} (refresh)`);
        git("push", "-q", "origin", `${c}:refs/heads/${branch}`);
      }

      const body = [
        `Applies ${overlay.pack} standards v${version} with engine ${ENGINE_VERSION} (profile \`${r.profile}\`): managed paths only, pinned in \`standards.lock\`.`,
        "", `Opened by \`sync\` in ${overlay.standards_repo}. Closing it leaves this content alone; the next release opens a new PR.`, "", marker,
      ].join("\n");
      let pr = mine.find((p) => p.state === "open");
      if (dryRun) return [r.profile, pinned, `${pr ? `refresh #${pr.number}` : "open PR"} for v${version}${note}`];
      if (!pr) pr = await gh("POST", `repos/${repo}/pulls`, { title, head: branch, base, body });
      else if (pr.body !== body) await gh("PATCH", `repos/${repo}/pulls/${pr.number}`, { body });
      const link = `[#${pr.number}](${pr.html_url})`;

      // Without a required `gate` check, auto-merge would merge at once, before gate finishes.
      const rules = (await gh("GET", `repos/${repo}/rules/branches/${encodeURIComponent(base)}`, null, { allow404: true })) ?? [];
      const gated = rules.some((x) => x.type === "required_status_checks" && x.parameters?.required_status_checks?.some((c) => c.context === "gate"));
      if (!gated) return [r.profile, pinned, `${link} v${version}; auto-merge not armed: gate is not a required check on ${base}${note}`];
      if (pr.auto_merge) return [r.profile, pinned, `${link} v${version}; auto-merge armed${note}`];
      try {
        await gh.graphql("mutation($id: ID!) { enablePullRequestAutoMerge(input: { pullRequestId: $id, mergeMethod: SQUASH }) { clientMutationId } }", { id: pr.node_id });
        return [r.profile, pinned, `${link} v${version}; auto-merge armed${note}`];
      } catch (e) {
        return [r.profile, pinned, `${link} v${version}; auto-merge not armed: ${scrub(e.message)}${note}`];
      }
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  }

  async function compliance(rows) {
    const t = overlay.sync?.compliance_issue_title || "Standards compliance";
    const repo = overlay.standards_repo;
    const issue = (await gh("GET", `repos/${repo}/issues?state=open&per_page=100`)).find((i) => i.title === t && !i.pull_request);
    let lines = rows.map((r) => `| ${r.map(cell).join(" | ")} |`);
    if (only && issue) { // a single-repo run keeps the other rows
      const keep = (issue.body ?? "").split("\n").filter((l) => /^\| [^ |]+\/[^ |]+ \|/.test(l) && !rows.some((r) => l.startsWith(`| ${r[0]} |`)));
      lines = [...keep, ...lines].sort();
    }
    const { GITHUB_SERVER_URL: s, GITHUB_REPOSITORY: gr, GITHUB_RUN_ID: id } = process.env;
    const by = s && gr && id ? `[sync](${s}/${gr}/actions/runs/${id})` : "sync";
    const body = `# ${t}\n\n${overlay.pack} v${version}, engine ${ENGINE_VERSION}; updated ${new Date().toISOString().slice(0, 19)}Z by ${by}.\n\n| Repo | Profile | Pinned | State |\n|---|---|---|---|\n${lines.join("\n")}\n`;
    if (dryRun) return say(`compliance issue in ${repo}:\n${body}`);
    if (issue) await gh("PATCH", `repos/${repo}/issues/${issue.number}`, { body });
    else {
      const created = await gh("POST", `repos/${repo}/issues`, { title: t, body });
      await gh.graphql("mutation($id: ID!) { pinIssue(input: { issueId: $id }) { issue { number } } }", { id: created.node_id })
        .catch((e) => console.log(`::warning::could not pin the compliance issue: ${scrub(e.message)}`));
      console.log(`compliance: ${created.html_url}`);
    }
  }
}
