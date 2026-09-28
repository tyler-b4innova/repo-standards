// Fleet sync, run from an organization's standards repository with its overlay and release tag. A pack landing runs no
// gate: the engine's own CI is the release gate. Per fleet repository: commit the pack on the default branch head,
// require the repository's offline check (setup.sh --check) to pass on that commit, and fast-forward the default
// branch (the App bypasses the rulesets). The branch moved: re-apply on the new head once. A failing check, or a
// staged repository whose default branch is main: one PR for a person. A release the engine marks breaking lands only
// with --repo (prove it there) until it is run with --proven.
// One pinned compliance issue keeps a row per repository.
// Needs GH_TOKEN (the standards App installation token); without it sync is idle.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { apply, ENGINE_BREAKING, ENGINE_VERSION, ROOT, sha256 } from "./engine.mjs";

const PKG = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const ENGINE_REPO = String(PKG.repository?.url ?? PKG.repository ?? "https://github.com/tyler-b4innova/repo-standards").replace(/^git\+/, "").replace(/\.git$/, "");
export const RELEASE_URL = `${ENGINE_REPO}/releases/tag/v${ENGINE_VERSION}`;
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

export const API = () => (process.env.GITHUB_API_URL || "https://api.github.com").replace(/\/$/, "");

// REST helper: gh(method, path, body) → parsed JSON, or null on 404 when allow404.
export function client(token) {
  const call = async (method, path, body, { allow404 = false } = {}) => {
    const url = path.startsWith("http") ? path : `${API()}/${path.replace(/^\//, "")}`;
    const init = {
      method,
      headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", ...(body && { "Content-Type": "application/json" }) },
      body: body && JSON.stringify(body),
    };
    // A network error ("fetch failed") names its real cause in err.cause; log it and retry once after a pause.
    let res;
    for (let attempt = 1; ; attempt++) {
      try { res = await fetch(url, init); break; }
      catch (e) {
        const why = [e.cause?.code, e.cause?.message ?? e.message].filter(Boolean).join(" ");
        if (attempt > 1 || method === "POST") throw new Error(`${method} ${path}: ${why}`); // a POST may have landed
        console.log(`::warning::${method} ${path}: ${why}; retrying in 5s`);
        await sleep(Number(process.env.SYNC_RETRY_MS ?? 5000));
      }
    }
    if (allow404 && res.status === 404) return null;
    const text = await res.text();
    if (!res.ok) throw Object.assign(new Error(`${method} ${path}: ${res.status} ${text.slice(0, 200)}`), { status: res.status });
    const data = text ? JSON.parse(text) : null;
    const next = res.headers.get("link")?.match(/<([^>]+)>;\s*rel="next"/)?.[1];
    return next && Array.isArray(data) ? [...data, ...(await call(method, next))] : data;
  };
  // Pinning exists only in GraphQL; sync runs in Actions where GraphQL is reachable.
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

export async function run({ overlay, repo: only, dryRun = false, version, proven = false }) {
  version = String(version ?? "").replace(/^v/, "");
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("--version <X.Y.Z> (the standards repository's release tag) is required; unreleased heads never ship");
  if (overlay.engine !== ENGINE_VERSION) throw new Error(`overlay pins engine ${overlay.engine}, this is engine ${ENGINE_VERSION}; run the pinned engine release`);

  const token = process.env.GH_TOKEN;
  if (!token) {
    console.log("::notice::sync idle: GH_TOKEN (the standards App installation token) is not set; nothing written");
    return;
  }
  const gh = client(token);
  const org = overlay.org, branch = `standards/v${version}`, title = `chore: standards v${version}`;
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
    const all = await gh("GET", `orgs/${org}/repos?per_page=100&type=all`); // gh() follows Link: rel="next"
    live = new Set(all.filter((r) => !r.archived).map((r) => r.full_name));
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

  // A breaking engine lands only with --repo until a person, having proven it there, runs the fleet with --proven.
  // That proof is recorded in the compliance issue, so the scheduled syncs that follow roll it without the flag;
  // until then they sync nothing (a notice, not a failure: the release is waiting on a person).
  const mark = `<!-- std:proven engine=${ENGINE_VERSION} -->`;
  let provenMark = false;
  if (ENGINE_BREAKING && !only) {
    const t = overlay.sync?.compliance_issue_title || "Standards compliance";
    const issue = (await gh("GET", `repos/${overlay.standards_repo}/issues?state=open&per_page=100`)).find((i) => i.title === t && !i.pull_request);
    provenMark = proven || (issue?.body ?? "").includes(mark);
    if (!provenMark && !dryRun) {
      console.log(`::warning::engine ${ENGINE_VERSION} is marked breaking and not proven here: land it on one repository (--repo <owner/name>), prove it there, then run sync --proven; nothing synced`);
      return;
    }
  }
  // Repositories run concurrently, so the fleet finishes well inside the App token's hour.
  const rows = [], queue = [...fleet], width = Math.max(1, Number(process.env.SYNC_CONCURRENCY || 6));
  await Promise.all(Array.from({ length: Math.min(width, queue.length) }, async () => {
    for (let f; (f = queue.shift()); ) {
      try {
        const res = await one(f);
        say(`${f.repo}: ${res[2]}`); // one line per repository in the job log: landed, PR, current, skipped
        rows.push([f.repo, ...res]);
      } catch (e) {
        console.log(`::error::${f.repo}: ${scrub(e.message)}`);
        rows.push([f.repo, f.std?.profile ?? f.want ?? "?", f.std?.version ?? "none", "sync failed, see run log"]);
        process.exitCode = 1;
      }
    }
  }));
  rows.sort((a, b) => a[0].localeCompare(b[0]));
  await compliance(rows);

  async function one({ repo, std, want }) {
    const pinned = std?.version ?? "none";
    const tmp = mkdtempSync(join(tmpdir(), "std-sync-")), dir = join(tmp, repo.split("/")[1]); // apply titles a new AGENTS.md after the dir
    const git = (...a) => execFileSync("git", a, { cwd: dir, env: gitEnv, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    const has = (a, b) => { try { git("merge-base", "--is-ancestor", a, b); return true; } catch { return false; } };
    try {
      try { execFileSync("git", ["clone", "-q", "--filter=blob:none", `${gitBase}/${repo}.git`, dir], { env: gitEnv, stdio: ["ignore", "ignore", "pipe"] }); }
      catch (e) { throw new Error(`clone failed: ${scrub(e.stderr ?? e.message).trim()}`); }
      const base = git("branch", "--show-current"); // the repository's default branch, as it reports it
      let r = apply({ target: dir, overlay, profile: std?.profile ?? want ?? "internal", version });
      const note = want && want !== r.profile ? `; profile ${r.profile} differs from fleet.include ${want} (repo value kept)` : "";
      const row = (state, now = pinned) => [r.profile, now, `${state}${note}`];
      git("add", "-A");
      const ours = (p) => p.head?.repo?.full_name === repo && /^(standards\/v|chore\/standards-v)\d+\.\d+\.\d+$/.test(p.head.ref);
      const open = (await gh("GET", `repos/${repo}/pulls?state=open&per_page=100`)).filter(ours);
      const changed = git("status", "--porcelain") !== "";
      for (const p of open.filter((p) => !changed || p.head.ref !== branch)) {
        say(`close #${p.number} (${p.head.ref}): ${p.head.ref === branch ? "base already current" : `superseded by v${version}`}`);
        if (dryRun) continue;
        await gh("POST", `repos/${repo}/issues/${p.number}/comments`, { body: p.head.ref === branch ? `Not needed: ${base} already carries v${version}.` : `Superseded by v${version}.` });
        await gh("PATCH", `repos/${repo}/pulls/${p.number}`, { state: "closed" });
        await gh("DELETE", `repos/${repo}/git/refs/heads/${p.head.ref}`, null, { allow404: true }).catch(() => {});
      }
      if (!changed) return row("current");

      let tree = git("write-tree"), content = sha256(git("diff", "--cached", "--full-index", "--binary"));
      const mine = (await gh("GET", `repos/${repo}/pulls?state=all&per_page=100&head=${repo.split("/")[0]}:${encodeURIComponent(branch)}`)).filter(ours);
      const refused = mine.find((p) => p.state === "closed" && !p.merged_at && (p.body ?? "").match(new RegExp(`tree=${tree}|content=${content}`)));
      if (refused) return row(`v${version} closed by a person in #${refused.number}; not reopened`);
      const msg = [title, `Engine ${ENGINE_VERSION}, ${overlay.pack} v${version}, profile ${r.profile}.\n\n${RELEASE_URL}`];
      // A pack landing runs no gate: the engine's own CI is the release gate. Sync commits on the default head,
      // requires the repository's offline check to pass on that tree, and fast-forwards the default branch.
      // A staged repository lands on its integration branch; its production branch only takes promotions.
      const staged = (JSON.parse(readFileSync(join(dir, "standards.json"), "utf8")).flow ?? (await gh("GET", `repos/${repo}`))?.custom_properties?.flow) === "staged";
      let kind = "", detail = "", sha = "";
      for (let attempt = 0; ; attempt++) {
        let head;
        try { head = git("rev-parse", "HEAD"); } catch { return row("empty repository: push a first commit, then sync"); }
        sha = git("commit-tree", tree, "-p", head, ...msg.flatMap((m) => ["-m", m]));
        const fails = check(sha);
        if (staged && base === "main") ({ kind, detail } = { kind: "staged repo defaults to main", detail: "flow is staged but the default branch is main; set the default to the integration branch" });
        else if (fails) ({ kind, detail } = { kind: "offline check failed", detail: fails });
        if (kind) break;
        if (dryRun) {
          say(`commit ${sha.slice(0, 7)} on ${base} (${r.changed.length} managed paths); offline check passes; fast-forward ${base}`);
          return row(`would land v${version} on ${base}`);
        }
        try { git("push", "-q", "origin", `${sha}:refs/heads/${base}`); }
        catch (e) {
          const err = scrub(e.stderr ?? e.message).trim(), why = err.split("\n").find((l) => /rejected|error|denied/i.test(l)) ?? err.split("\n")[0];
          if (attempt === 1 || !/non-fast-forward|fetch first/i.test(err)) { ({ kind, detail } = { kind: `push to ${base} failed`, detail: why.trim() }); break; }
          say(`${base} moved; re-applying v${version} on its new head once`);
          git("fetch", "-q", "origin", `refs/heads/${base}`);
          git("reset", "-q", "--hard", "FETCH_HEAD");
          git("clean", "-qfdx");
          r = apply({ target: dir, overlay, profile: r.profile, version });
          git("add", "-A");
          if (git("status", "--porcelain") === "") { await closeMine(`Not needed: ${base} already carries v${version}.`); return row("current", version); }
          tree = git("write-tree");
          content = sha256(git("diff", "--cached", "--full-index", "--binary"));
          continue;
        }
        await closeMine(`Landed on ${base} as ${sha.slice(0, 7)}.`);
        return row(`landed ${sha.slice(0, 7)}`, version);
      }
      if (dryRun) {
        say(`${kind}: ${detail}`);
        return row(`would open a PR for a person: ${kind}`);
      }

      console.log(`${kind}: ${detail}`);
      const body = [
        `\`sync\` could not land ${overlay.pack} standards v${version} (engine ${ENGINE_VERSION}, profile \`${r.profile}\`) on \`${base}\` by itself: ${kind}.`,
        "", ...detail.split("\n").map((l) => `- ${l}`), "",
        `To fix it: only the sync App may push \`${branch}\`, so branch from it (\`git fetch origin ${branch} && git switch -c fix/${branch.replace("/", "-")} FETCH_HEAD\`), commit the fix, open your own PR, and close this one.`,
        "", `Opened by \`sync\` in ${overlay.standards_repo}; auto-merge is not armed. Closing it leaves this content alone; the next release tries again.`,
        "", `<!-- std:sync tree=${tree} content=${content} -->`,
      ].join("\n");
      let remote = null;
      try { git("fetch", "-q", "origin", `refs/heads/${branch}`); remote = git("rev-parse", "FETCH_HEAD"); } catch {}
      if (!remote || git("rev-parse", `${remote}^{tree}`) !== tree) {
        if (remote) git("push", "-q", "origin", `:refs/heads/${branch}`);
        git("push", "-q", "origin", `${sha}:refs/heads/${branch}`);
      }
      // Re-read: re-creating the branch closes a PR that was open on it.
      const still = (await gh("GET", `repos/${repo}/pulls?state=open&per_page=100&head=${repo.split("/")[0]}:${encodeURIComponent(branch)}`)).find(ours);
      const n = still ?? (await gh("POST", `repos/${repo}/pulls`, { title: `${title} (needs a person)`, head: branch, base, body }));
      if (still && still.body !== body) await gh("PATCH", `repos/${repo}/pulls/${still.number}`, { body });
      return row(`PR #${n.number}: ${kind}`);

      // This version's open fallback PRs are obsolete once the default branch carries it.
      async function closeMine(why) {
        for (const p of mine.filter((p) => p.state === "open")) {
          await gh("POST", `repos/${repo}/issues/${p.number}/comments`, { body: why });
          await gh("PATCH", `repos/${repo}/pulls/${p.number}`, { state: "closed" });
        }
        await gh("DELETE", `repos/${repo}/git/refs/heads/${branch}`, null, { allow404: true }).catch(() => {});
      }
      // The repository's own offline check (setup.sh --check) on the candidate commit: its FAIL lines, or "".
      function check(commit) {
        const wt = mkdtempSync(join(tmpdir(), "std-check-"));
        try {
          git("worktree", "add", "-q", "--detach", wt, commit);
          const res = spawnSync("node", ["scripts/agent/check.mjs"], { cwd: wt, encoding: "utf8", env: { ...process.env, HOME: wt, CLAUDE_CONFIG_DIR: join(wt, ".none"), CODEX_HOME: join(wt, ".none") } });
          return res.status === 0 ? "" : (res.stdout + res.stderr).split("\n").filter((l) => l.startsWith("FAIL")).join("\n") || `check exited ${res.status}`;
        } finally {
          try { git("worktree", "remove", "--force", wt); } catch {}
          rmSync(wt, { recursive: true, force: true });
        }
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
    const keepMark = provenMark || (only && (issue?.body ?? "").includes(mark));
    const body = `# ${t}\n\n${overlay.pack} v${version}, engine ${ENGINE_VERSION}${keepMark ? " (breaking; proven)" : ""}; updated ${new Date().toISOString().slice(0, 19)}Z by ${by}.\n\n| Repo | Profile | Pinned | State |\n|---|---|---|---|\n${lines.join("\n")}\n${keepMark ? `\n${mark}\n` : ""}`;
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
