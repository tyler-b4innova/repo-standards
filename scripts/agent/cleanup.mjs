#!/usr/bin/env node
// Local clean-up of merged work, run by `setup.sh --check` at session start (never in CI). Conservative: a local
// branch, and the worktree holding it, go only when ALL hold, and anything unsure stays:
//   - GitHub says the branch's pull request merged (asked of GitHub: squash merges look unmerged to git);
//   - the local tip is the PR's merged head or an ancestor of it (no local work the PR lacks);
//   - its worktree has no uncommitted or untracked changes (ignored files are fine), is not locked, is not the main
//     worktree or the session's own directory, and is not under an app-managed root (~/.codex/worktrees,
//     ~/.t3/worktrees, .claude/worktrees): those apps clean their own.
// One batched GitHub call with a short timeout; a network or auth failure removes nothing. Prints one line when
// something was removed. usage: node scripts/agent/cleanup.mjs [session-dir]
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { sep } from "node:path";

const git = (...a) => execFileSync("git", a, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
const tryGit = (...a) => { try { return git(...a); } catch { return null; } };
const real = (p) => { try { return realpathSync(p); } catch { return p; } };
const within = (p, root) => p === root || p.startsWith(root.endsWith(sep) ? root : root + sep);
const env = process.env;

async function main() {
  const top = real(git("rev-parse", "--show-toplevel").trim());
  const session = [top, real(process.argv[2] ?? process.cwd())];
  const url = tryGit("remote", "get-url", "origin")?.trim() ?? "";
  const slug = url.replace(/\/+$/, "").replace(/\.git$/, "").match(/[:/]([^/:]+)\/([^/:]+)$/);
  if (!slug) return;
  const [, owner, name] = slug;

  // Worktrees (the first is the main one) and local branches.
  const trees = [];
  for (const b of git("worktree", "list", "--porcelain").split("\n\n").filter(Boolean)) {
    const t = Object.fromEntries(b.split("\n").map((l) => [l.split(" ")[0], l.slice(l.indexOf(" ") + 1)]));
    trees.push({ path: real(t.worktree), branch: t.branch?.replace(/^refs\/heads\//, ""), locked: "locked" in t, prunable: "prunable" in t });
  }
  const mainTree = trees[0]?.path;
  const current = tryGit("symbolic-ref", "-q", "--short", "HEAD")?.trim();
  const branches = git("for-each-ref", "refs/heads", "--format=%(refname:short) %(objectname)").trim().split("\n").filter(Boolean).map((l) => l.split(" "));
  const apps = [`${homedir()}/.codex/worktrees`, `${homedir()}/.t3/worktrees`].map(real);
  const appManaged = (p) => apps.some((r) => within(p, r)) || p.split(sep).join("/").includes("/.claude/worktrees/");
  const cands = branches.filter(([b]) => b !== current && !["main", "master", "staging", "develop"].includes(b));
  if (!cands.length) return;

  let token = env.GH_TOKEN || env.GITHUB_TOKEN;
  if (!token) try { token = execFileSync("gh", ["auth", "token"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 1000 }).trim(); } catch { return; }
  const q = cands.map(([b], i) => `b${i}: pullRequests(headRefName: ${JSON.stringify(b)}, states: MERGED, first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { headRefOid headRepository { nameWithOwner } } }`).join("\n");
  const api = (env.GITHUB_GRAPHQL_URL || `${(env.GITHUB_API_URL || "https://api.github.com").replace(/\/$/, "")}/graphql`);
  let data;
  try {
    const r = await fetch(api, { method: "POST", signal: AbortSignal.timeout(Number(env.STD_CLEANUP_TIMEOUT_MS ?? 1500)),
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query: `query($o: String!, $n: String!) { repository(owner: $o, name: $n) { defaultBranchRef { name } ${q} } }`, variables: { o: owner, n: name } }) });
    if (!r.ok) return;
    data = (await r.json())?.data?.repository;
  } catch { return; }
  if (!data) return;

  const removed = [];
  for (const [i, [b, tip]] of cands.entries()) {
    if (b === data.defaultBranchRef?.name) continue;
    const heads = (data[`b${i}`]?.nodes ?? []).filter((p) => p.headRepository?.nameWithOwner?.toLowerCase() === `${owner}/${name}`.toLowerCase()).map((p) => p.headRefOid);
    // the tip is a merged head, or an ancestor of one we have locally
    if (!heads.some((h) => h === tip || (tryGit("cat-file", "-e", `${h}^{commit}`) !== null && tryGit("merge-base", "--is-ancestor", tip, h) !== null))) continue;
    const tree = trees.find((t) => t.branch === b);
    if (tree) {
      if (tree.path === mainTree || tree.locked || session.some((s) => within(s, tree.path)) || appManaged(tree.path)) continue;
      if (!tree.prunable) {
        const status = tryGit("-C", tree.path, "status", "--porcelain", "--untracked-files=all");
        if (status === null || status.trim()) continue;
        if (tryGit("worktree", "remove", tree.path) === null) continue; // refuses a dirty tree itself too
      } else tryGit("worktree", "prune");
      removed.push(`${b} (worktree ${tree.path})`);
    } else removed.push(b);
    if (tryGit("branch", "-D", b) === null) removed.pop();
  }
  if (removed.length) console.log(`cleanup: removed merged ${removed.join(", ")}`);
}
await main().catch(() => {});
