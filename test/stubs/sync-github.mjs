#!/usr/bin/env node
// Stand-in for the GitHub REST (and the pinIssue GraphQL mutation) backed by local bare repositories.
// Usage: node sync-github.mjs <port-file> <log-file> <config.json>
// config: { remotes: "<dir holding owner/name.git>", repos: [{full_name, archived}], variables: {repo: {NAME: value}},
//           files: {repo: {path: text}}, gate: {repo: conclusion of every std-gate run, or a list by dispatch order (the last repeats); default "success"},
//           move: {repo: ref whose first gate dispatch also commits moved.txt on the default branch} }
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [portFile, logFile, configFile] = process.argv.slice(2);
const cfg = JSON.parse(readFileSync(configFile, "utf8"));
const items = {}; // repo -> [pull or issue]; one numbering per repo, as on GitHub
const comments = {}; // "repo#n" -> [comment]
const nodes = {}; // node_id -> item
let seq = 1;
const bare = (r) => join(cfg.remotes, `${r}.git`);
const git = (r, ...a) => execFileSync("git", ["--git-dir", bare(r), ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
const gitIn = (r, env, input, ...a) => execFileSync("git", ["--git-dir", bare(r), ...a], { encoding: "utf8", input, env: { ...process.env, ...env } }).trim();
const ok = (r, ...a) => { try { git(r, ...a); return true; } catch { return false; } };
const defaultBranch = (r) => (existsSync(bare(r)) ? git(r, "symbolic-ref", "--short", "HEAD").trim() : "main");
const runs = {}, starts = {}; // repo -> [workflow run], repo -> gate starts
// Someone else lands a commit on the default branch (a file moved.txt) while sync waits for gate.
function moveDefault(r) {
  const b = defaultBranch(r), head = git(r, "rev-parse", `refs/heads/${b}`).trim(), tmp = mkdtempSync(join(tmpdir(), "stub-idx-"));
  const env = { GIT_INDEX_FILE: join(tmp, "index"), GIT_AUTHOR_NAME: "p", GIT_AUTHOR_EMAIL: "p@example.com", GIT_COMMITTER_NAME: "p", GIT_COMMITTER_EMAIL: "p@example.com" };
  const blob = gitIn(r, env, "moved\n", "hash-object", "-w", "--stdin");
  gitIn(r, env, "", "read-tree", head);
  gitIn(r, env, "", "update-index", "--add", "--cacheinfo", `100644,${blob},moved.txt`);
  const c = gitIn(r, env, "", "commit-tree", gitIn(r, env, "", "write-tree"), "-p", head, "-m", "someone else landed first");
  git(r, "update-ref", `refs/heads/${b}`, c, head);
  rmSync(tmp, { recursive: true, force: true });
}
const list = (r) => (items[r] ??= []);
const add = (r, item) => {
  const it = { number: list(r).length + 1, node_id: `N_${seq++}`, state: "open", labels: [], ...item };
  it.html_url = `https://github.com/${r}/${it.pull ? "pull" : "issues"}/${it.number}`;
  list(r).push(it);
  nodes[it.node_id] = it;
  return it;
};
const pullView = (it) => ({ ...it, head: { ref: it.head, repo: { full_name: it.repo } }, base: { ref: it.base } });

createServer((req, res) => {
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    const url = new URL(req.url, "http://stub");
    const body = raw ? JSON.parse(raw) : null;
    appendFileSync(logFile, JSON.stringify({ method: req.method, path: url.pathname, query: url.search, body }) + "\n");
    const send = (status, data) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(data === undefined ? "" : JSON.stringify(data));
    };
    const q = (k) => url.searchParams.get(k);
    const p = decodeURIComponent(url.pathname);
    let m;
    if (p === "/graphql") {
      const v = body.variables ?? {};
      const it = nodes[v.id];
      if (!it) return send(200, { errors: [{ message: "stub: unknown node" }] });
      if (body.query.includes("pinIssue")) it.pinned = true;
      return send(200, { data: {} });
    }
    if ((m = p.match(/^\/orgs\/([^/]+)\/repos$/))) return send(200, cfg.repos.filter((r) => r.full_name.startsWith(`${m[1]}/`)));
    if (!(m = p.match(/^\/repos\/([^/]+\/[^/]+)(?:\/(.*))?$/))) return send(404, { message: `stub: no route ${p}` });
    const [, r, rest = ""] = m;
    if (rest === "") return send(200, { full_name: r, default_branch: defaultBranch(r), archived: !!cfg.repos.find((x) => x.full_name === r)?.archived });
    if ((m = rest.match(/^contents\/(.+)$/))) {
      const f = m[1];
      if (req.method === "PUT") {
        ((cfg.branchFiles ??= {})[`${r}@${body.branch}`] ??= {})[f] = Buffer.from(body.content, "base64").toString();
        return send(200, { content: { path: f } });
      }
      let text = cfg.files?.[r]?.[f];
      if (text === undefined && existsSync(bare(r))) try { text = git(r, "show", `${q("ref") ?? "HEAD"}:${f}`); } catch {}
      return text === undefined ? send(404, { message: "Not Found" }) : send(200, { path: f, sha: `blob-${f}`, content: Buffer.from(text).toString("base64"), encoding: "base64" });
    }
    if ((m = rest.match(/^git\/ref\/heads\/(.+)$/)) && req.method === "GET") {
      const ref = `refs/heads/${decodeURIComponent(m[1])}`;
      if (existsSync(bare(r))) return ok(r, "rev-parse", "--verify", ref) ? send(200, { ref, object: { sha: git(r, "rev-parse", ref).trim() } }) : send(404, { message: "Not Found" });
      if (cfg.refs?.includes(`${r}:${ref}`)) return send(200, { ref, object: { sha: "1".repeat(40) } });
      if (m[1] === "main") return send(200, { object: { sha: "0".repeat(40) } });
    }
    if (rest === "git/refs" && req.method === "POST") {
      if (!existsSync(bare(r))) { if (cfg.refs?.includes(`${r}:${body.ref}`)) return send(422, { message: "Reference already exists" }); (cfg.refs ??= []).push(`${r}:${body.ref}`); }
      return send(201, { ref: body.ref });
    }
    if ((m = rest.match(/^git\/refs\/heads\/(.+)$/)) && req.method === "PATCH") { // as GitHub: fast-forward only unless force
      const ref = `refs/heads/${m[1]}`, old = ok(r, "rev-parse", "--verify", ref) ? git(r, "rev-parse", ref).trim() : null;
      if (!old) return send(422, { message: "Reference does not exist" });
      if (!ok(r, "cat-file", "-e", `${body.sha}^{commit}`)) return send(422, { message: "Object does not exist" });
      if (!body.force && !ok(r, "merge-base", "--is-ancestor", old, body.sha)) return send(422, { message: "Update is not a fast forward" });
      git(r, "update-ref", ref, body.sha, old);
      return send(200, { ref, object: { sha: body.sha, type: "commit" } });
    }
    // As GitHub: a push to a branch whose std-gate.yml lists it under push.branches starts a run (created here on first
    // listing); POST runs/{id}/rerun starts a new attempt. Each start is logged as a GATE line and takes the next
    // configured conclusion.
    const start = (x) => {
      const g = [cfg.gate?.[r] ?? "success"].flat(), n = (starts[r] = (starts[r] ?? 0) + 1);
      Object.assign(x, { status: "queued", conclusion: null, polls: 0, want: g[Math.min(n - 1, g.length - 1)] });
      appendFileSync(logFile, JSON.stringify({ method: "GATE", path: `/repos/${r}/gate-start`, query: "", body: { sha: x.head_sha } }) + "\n");
      if (cfg.move?.[r] === x.head_branch) { delete cfg.move[r]; moveDefault(r); }
    };
    const tick = (x) => { if (x.polls++ >= 1) Object.assign(x, { status: "completed", conclusion: x.want }); else x.status = "in_progress"; return x; };
    const view = ({ polls, want, ...x }) => x;
    if (rest === "actions/runs" && req.method === "GET") {
      const br = q("branch"), sha = q("head_sha"), rs = (runs[r] ??= []);
      if (br && sha && q("event") === "push" && ok(r, "rev-parse", "--verify", `refs/heads/${br}`) && git(r, "rev-parse", `refs/heads/${br}`).trim() === sha && !rs.some((x) => x.head_sha === sha)) {
        let wf = "";
        try { wf = git(r, "show", `${sha}:.github/workflows/std-gate.yml`); } catch {}
        const listed = (wf.match(/^\s+branches:\s*\[(.*)\]/m)?.[1] ?? "").split(",").map((b) => b.trim().replace(/^"|"$/g, ""));
        if (listed.some((g) => new RegExp("^" + g.replace(/\*/g, ".*") + "$").test(br))) {
          const x = { id: seq++, name: "std-gate", path: ".github/workflows/std-gate.yml", event: "push", head_branch: br, head_sha: sha, run_attempt: 1, html_url: `https://github.com/${r}/actions/runs/${seq - 1}` };
          rs.push(x); start(x);
        }
      }
      const found = rs.filter((x) => (!br || x.head_branch === br) && (!sha || x.head_sha === sha) && (!q("event") || x.event === q("event")));
      return send(200, { total_count: found.length, workflow_runs: found.map((x) => view(tick(x))) });
    }
    if ((m = rest.match(/^actions\/runs\/(\d+)\/rerun$/)) && req.method === "POST") {
      const x = (runs[r] ?? []).find((y) => y.id == m[1]);
      if (!x) return send(404, { message: "Not Found" });
      x.run_attempt = (x.run_attempt ?? 1) + 1; start(x);
      return send(201, {});
    }
    if ((m = rest.match(/^actions\/runs\/(\d+)$/)) && req.method === "GET") {
      const x = (runs[r] ?? []).find((y) => y.id == m[1]);
      return x ? send(200, view(tick(x))) : send(404, { message: "Not Found" });
    }
    if ((m = rest.match(/^git\/refs\/heads\/(.+)$/)) && req.method === "DELETE") {
      if (existsSync(bare(r))) try { git(r, "update-ref", "-d", `refs/heads/${m[1]}`); } catch { return send(422, { message: "Reference does not exist" }); }
      else cfg.refs = (cfg.refs ?? []).filter((x) => x !== `${r}:refs/heads/${m[1]}`);
      return send(204);
    }
    if ((m = rest.match(/^actions\/variables\/(.+)$/))) {
      const vars = ((cfg.variables ??= {})[r] ??= {});
      if (req.method === "PATCH") { vars[m[1]] = body.value; return send(204); }
      return m[1] in vars ? send(200, { name: m[1], value: vars[m[1]] }) : send(404, { message: "Not Found" });
    }
    if (rest === "pulls" && req.method === "GET") {
      const st = q("state") ?? "open", head = q("head");
      // Someone else lands on the default branch after sync cloned (sync looks up its own PRs before pushing).
      if (head && cfg.move?.[r] && head.endsWith(`:${cfg.move[r]}`) && st === "all") { delete cfg.move[r]; moveDefault(r); }
      return send(200, list(r).filter((x) => x.pull && (st === "all" || x.state === st) && (!head || `${r.split("/")[0]}:${x.head}` === head)).map(pullView));
    }
    if (rest === "pulls" && req.method === "POST") return send(201, pullView(add(r, { pull: true, repo: r, title: body.title, body: body.body, head: body.head, base: body.base, merged_at: null, auto_merge: null })));
    if ((m = rest.match(/^(pulls|issues)\/(\d+)$/))) {
      const it = list(r).find((x) => x.number === +m[2]);
      if (!it) return send(404, { message: "Not Found" });
      if (req.method === "PATCH") Object.assign(it, body);
      return send(200, it.pull ? pullView(it) : it);
    }
    if (rest === "issues" && req.method === "GET") {
      const st = q("state") ?? "open", lab = q("labels");
      return send(200, list(r).filter((x) => !x.pull && (st === "all" || x.state === st) && (!lab || x.labels.some((l) => l.name === lab))));
    }
    if (rest === "issues" && req.method === "POST") return send(201, add(r, { title: body.title, body: body.body, labels: (body.labels ?? []).map((name) => ({ name })) }));
    if ((m = rest.match(/^issues\/(\d+)\/comments$/))) {
      const c = (comments[`${r}#${m[1]}`] ??= []);
      if (req.method === "GET") return send(200, c);
      c.push({ id: seq++, body: body.body });
      return send(201, c.at(-1));
    }
    if (rest === "_state") return send(200, { items: list(r), comments: Object.fromEntries(Object.entries(comments).filter(([k]) => k.startsWith(`${r}#`))), files: cfg.branchFiles ?? {}, runs: runs[r] ?? [] });
    send(404, { message: `stub: no route ${req.method} ${p}` });
  });
}).listen(0, "127.0.0.1", function () {
  writeFileSync(portFile, String(this.address().port));
});
