#!/usr/bin/env node
// Stand-in for the GitHub REST (and the two GraphQL mutations sync uses) backed by local bare repositories.
// Usage: node sync-github.mjs <port-file> <log-file> <config.json>
// config: { remotes: "<dir holding owner/name.git>", repos: [{full_name, archived}], rules: {repo: [..]},
//           variables: {repo: {NAME: value}}, files: {repo: {path: text}} }
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";

const [portFile, logFile, configFile] = process.argv.slice(2);
const cfg = JSON.parse(readFileSync(configFile, "utf8"));
const items = {}; // repo -> [pull or issue]; one numbering per repo, as on GitHub
const comments = {}; // "repo#n" -> [comment]
const nodes = {}; // node_id -> item
let seq = 1;
const bare = (r) => join(cfg.remotes, `${r}.git`);
const git = (r, ...a) => execFileSync("git", ["--git-dir", bare(r), ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
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
      if (body.query.includes("enablePullRequestAutoMerge")) it.auto_merge = { merge_method: v.method ?? "SQUASH" };
      if (body.query.includes("pinIssue")) it.pinned = true;
      return send(200, { data: {} });
    }
    if ((m = p.match(/^\/orgs\/([^/]+)\/repos$/))) return send(200, cfg.repos.filter((r) => r.full_name.startsWith(`${m[1]}/`)));
    if (!(m = p.match(/^\/repos\/([^/]+\/[^/]+)(?:\/(.*))?$/))) return send(404, { message: `stub: no route ${p}` });
    const [, r, rest = ""] = m;
    if (rest === "") return send(200, { full_name: r, default_branch: "main", archived: !!cfg.repos.find((x) => x.full_name === r)?.archived });
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
    if (rest === "git/ref/heads/main") return send(200, { object: { sha: "0".repeat(40) } });
    if (rest === "git/refs" && req.method === "POST") return send(201, { ref: body.ref });
    if ((m = rest.match(/^git\/refs\/heads\/(.+)$/)) && req.method === "DELETE") {
      if (existsSync(bare(r))) try { git(r, "update-ref", "-d", `refs/heads/${m[1]}`); } catch { return send(422, { message: "Reference does not exist" }); }
      return send(204);
    }
    if ((m = rest.match(/^rules\/branches\/(.+)$/))) return send(200, cfg.rules?.[r] ?? []);
    if ((m = rest.match(/^actions\/variables\/(.+)$/))) {
      const vars = ((cfg.variables ??= {})[r] ??= {});
      if (req.method === "PATCH") { vars[m[1]] = body.value; return send(204); }
      return m[1] in vars ? send(200, { name: m[1], value: vars[m[1]] }) : send(404, { message: "Not Found" });
    }
    if (rest === "pulls" && req.method === "GET") {
      const st = q("state") ?? "open", head = q("head");
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
    if (rest === "_state") return send(200, { items: list(r), comments: Object.fromEntries(Object.entries(comments).filter(([k]) => k.startsWith(`${r}#`))), files: cfg.branchFiles ?? {} });
    send(404, { message: `stub: no route ${req.method} ${p}` });
  });
}).listen(0, "127.0.0.1", function () {
  writeFileSync(portFile, String(this.address().port));
});
