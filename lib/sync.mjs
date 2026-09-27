// Fleet sync, run from an organization's standards repository with its overlay and release tag. Per fleet repository:
// commit the pack on the default branch head, push it to `standards/v<version>`, run that repository's own `gate` on
// the branch, and fast-forward the default branch when it passes (the App bypasses the rulesets). Red, or the default
// branch moved: re-apply on the current head and run gate once more. Still not landed: one PR for a person.
// One pinned compliance issue keeps a row per repository.
// Needs GH_TOKEN (the standards App installation token); without it sync is idle.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { apply, ENGINE_VERSION, ROOT, sha256 } from "./engine.mjs";

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
        if (attempt > 1) throw new Error(`${method} ${path}: ${why}`);
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
  const org = overlay.org, branch = `standards/v${version}`, title = `chore: standards v${version}`;
  const say = (msg) => console.log(`${dryRun ? "[dry-run] " : ""}${msg}`);
  const scrub = (s) => String(s).replaceAll(token, "***");
  const pollMs = Number(process.env.SYNC_POLL_MS || 15000), timeoutMs = Number(process.env.SYNC_GATE_TIMEOUT_MS || 40 * 60 * 1000);
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

  // Repositories run concurrently (each waits on its own gate), so the fleet finishes well inside the App token's hour.
  const rows = [], queue = [...fleet], width = Math.max(1, Number(process.env.SYNC_CONCURRENCY || 6));
  await Promise.all(Array.from({ length: Math.min(width, queue.length) }, async () => {
    for (let f; (f = queue.shift()); ) {
      try {
        rows.push([f.repo, ...(await one(f))]);
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
      const pr = mine.find((p) => p.state === "open");
      if (dryRun) {
        say(`commit ${tree.slice(0, 7)} on ${base} (${r.changed.length} managed paths), push ${branch} (its push starts gate); green: fast-forward ${base}; else re-apply once, then a PR`);
        return row(`would land v${version} on ${base} when gate passes${pr ? `; #${pr.number} open` : ""}`);
      }

      const msg = [title, `Engine ${ENGINE_VERSION}, ${overlay.pack} v${version}, profile ${r.profile}.\n\n${RELEASE_URL}`];
      let run, kind, detail;
      for (let attempt = 0; ; attempt++) {
        let head;
        try { head = git("rev-parse", "HEAD"); } catch { return row("empty repository: push a first commit, then sync"); }
        const sha = push(tree, head, msg);
        ({ run, kind, detail } = await gate(sha, run));
        // A staged repository lands on its integration branch; its production branch only takes promotions.
        if (!kind && base === "main" && (JSON.parse(readFileSync(join(dir, "standards.json"), "utf8")).flow ?? (await gh("GET", `repos/${repo}`))?.custom_properties?.flow) === "staged")
          ({ kind, detail } = { kind: "staged repo defaults to main", detail: `flow is staged but the default branch is main; set the default to the integration branch` });
        // Land only on the exact commit the candidate was built on: a rewind or any other move takes the retry path.
        if (!kind && (await gh("GET", `repos/${repo}/git/ref/heads/${base}`))?.object?.sha !== head)
          ({ kind, detail } = { kind: "default branch moved", detail: `${base} is no longer ${head.slice(0, 7)}` });
        if (!kind) {
          try { await gh("PATCH", `repos/${repo}/git/refs/heads/${base}`, { sha, force: false }); }
          catch (e) { if (e.status !== 422) throw e; kind = "default branch moved"; detail = `gate passed, but ${base} could not be fast-forwarded: ${scrub(e.message)}`; }
        }
        if (!kind) {
          for (const p of mine.filter((p) => p.state === "open")) {
            await gh("POST", `repos/${repo}/issues/${p.number}/comments`, { body: `Landed on ${base} as ${sha.slice(0, 7)} after gate passed: ${run.html_url}` });
            await gh("PATCH", `repos/${repo}/pulls/${p.number}`, { state: "closed" });
          }
          await dropBranch();
          return row(`landed ${sha.slice(0, 7)} (gate ${run.html_url})`, version);
        }
        console.log(`${kind}: ${detail}${run ? ` (${run.html_url})` : ""}`);
        if (attempt === 1 || !["gate red", "default branch moved"].includes(kind)) break;
        say(`re-applying v${version} on the current ${base} and running gate once more`);
        git("fetch", "-q", "origin", `refs/heads/${base}`);
        git("reset", "-q", "--hard", "FETCH_HEAD");
        git("clean", "-qfdx");
        r = apply({ target: dir, overlay, profile: r.profile, version });
        git("add", "-A");
        if (git("status", "--porcelain") === "") { await dropBranch(); return row("current", version); }
        tree = git("write-tree");
        content = sha256(git("diff", "--cached", "--full-index", "--binary"));
      }

      const body = [
        `\`sync\` could not land ${overlay.pack} standards v${version} (engine ${ENGINE_VERSION}, profile \`${r.profile}\`) on \`${base}\` by itself: ${kind}.`,
        "", `- ${detail}`, ...(run ? [`- gate run: ${run.html_url}`] : []), "",
        `Opened by \`sync\` in ${overlay.standards_repo}; auto-merge is not armed. Closing it leaves this content alone; the next release tries again.`,
        "", `<!-- std:sync tree=${tree} content=${content} -->`,
      ].join("\n");
      // Re-read: re-creating the branch closes a PR that was open on it.
      const still = (await gh("GET", `repos/${repo}/pulls?state=open&per_page=100&head=${repo.split("/")[0]}:${encodeURIComponent(branch)}`)).find(ours);
      const n = still ?? (await gh("POST", `repos/${repo}/pulls`, { title: `${title} (needs a person)`, head: branch, base, body }));
      if (still && still.body !== body) await gh("PATCH", `repos/${repo}/pulls/${still.number}`, { body });
      return row(`PR #${n.number}: ${kind}`);

      // The landing commit's only parent is the default head, so nothing pushed to the branch meanwhile can reach the
      // default branch. An older branch head is reused when identical, else the branch is deleted and re-created.
      function push(tree, head, msg) {
        let remote = null;
        try { git("fetch", "-q", "origin", `refs/heads/${branch}`); remote = git("rev-parse", "FETCH_HEAD"); } catch {}
        if (remote && git("rev-parse", `${remote}^{tree}`) === tree && git("rev-list", "--parents", "-n", "1", remote).split(" ").slice(1).join(" ") === head) return remote;
        const c = git("commit-tree", tree, "-p", head, ...msg.flatMap((m) => ["-m", m]));
        if (remote) git("push", "-q", "origin", `:refs/heads/${branch}`);
        git("push", "-q", "origin", `${c}:refs/heads/${branch}`);
        return c;
      }
      // The push to `branch` starts the repository's own gate (std-gate runs on pushes to standards/v*). Wait for it:
      // { run } when green, else { run?, kind, detail }. Retrying the same commit re-runs its gate run.
      async function gate(sha, prev) {
        const find = async () => ((await gh("GET", `repos/${repo}/actions/runs?branch=${encodeURIComponent(branch)}&head_sha=${sha}&event=push&per_page=100`))?.workflow_runs ?? [])
          .filter((x) => x.head_sha === sha && x.path === ".github/workflows/std-gate.yml").sort((a, b) => b.id - a.id)[0];
        let attempt = 0;
        if (prev?.head_sha === sha) {
          attempt = prev.run_attempt ?? 1;
          try { await gh("POST", `repos/${repo}/actions/runs/${prev.id}/rerun`); }
          catch (e) { return { run: prev, kind: "gate not run", detail: `could not re-run gate: ${scrub(e.message)}` }; }
        }
        for (const until = Date.now() + timeoutMs; ;) {
          const run = prev?.head_sha === sha ? await gh("GET", `repos/${repo}/actions/runs/${prev.id}`) : await find();
          if (run?.status === "completed" && (run.run_attempt ?? 1) > attempt)
            return run.conclusion === "success" ? { run } : { run, kind: "gate red", detail: `gate concluded ${run.conclusion}` };
          if (Date.now() > until) return { run, kind: run ? "gate timed out" : "gate not run", detail: run ? `gate did not finish in ${Math.round(timeoutMs / 60000)} min` : `no gate run started for ${sha.slice(0, 7)} on ${branch}` };
          await sleep(pollMs);
        }
      }
      async function dropBranch() {
        await gh("DELETE", `repos/${repo}/git/refs/heads/${branch}`, null, { allow404: true })
          .catch((e) => console.log(`::warning::could not delete ${branch}: ${scrub(e.message)}`));
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
