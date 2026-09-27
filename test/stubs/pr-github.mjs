#!/usr/bin/env node
// GitHub REST stand-in for test/pr.sh. Repository acme/demo; branches and commits come from a local bare repo.
// Usage: node test/stubs/pr-github.mjs <port-file> <log-file> <bare-origin>
// Every API request is logged as a JSON line. POST /__state merges test fixtures; GET /__state returns state.
import { execFileSync } from "node:child_process";
import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, logFile, origin] = process.argv.slice(2);
const R = "/repos/acme/demo";
const git = (...a) => { try { return execFileSync("git", ["--git-dir", origin, ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { return null; } };
const S = { pulls: [], issueComments: {}, reviewComments: {}, reviews: {}, checks: {} };
let nextId = 1000;

const pr = (x) => ({ ...x, html_url: `https://github.com/acme/demo/pull/${x.number}`, head: { ref: x.head, sha: git("rev-parse", `refs/heads/${x.head}`), repo: { full_name: "acme/demo" } }, base: { ref: x.base } });

createServer((req, res) => {
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    const url = new URL(req.url, "http://stub"), p = url.pathname, body = raw ? JSON.parse(raw) : null;
    const send = (status, data) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(data ?? {})); };
    if (p === "/__state") {
      if (req.method === "POST") for (const [k, v] of Object.entries(body)) S[k] = v;
      return send(200, S);
    }
    appendFileSync(logFile, JSON.stringify({ method: req.method, path: p, query: url.search, auth: !!req.headers.authorization, body }) + "\n");
    let m;
    if (p === "/user") return send(200, { login: "agent" });
    if (p === R) return send(200, { full_name: "acme/demo", default_branch: "main" });
    if ((m = p.match(/^\/repos\/acme\/demo\/branches\/(.+)$/))) {
      const name = decodeURIComponent(m[1]), sha = git("rev-parse", "--verify", `refs/heads/${name}`);
      return sha ? send(200, { name, commit: { sha } }) : send(404, { message: "Branch not found" });
    }
    if (p === `${R}/pulls` && req.method === "GET")
      return send(200, S.pulls.filter((x) => x.state === "open" && `acme:${x.head}` === url.searchParams.get("head")
        && (!url.searchParams.has("base") || x.base === url.searchParams.get("base"))).map(pr));
    if (p === `${R}/pulls` && req.method === "POST") {
      const x = { number: S.pulls.length + 1, title: body.title, body: body.body, head: body.head, base: body.base, draft: !!body.draft, state: "open", merged: false };
      S.pulls.push(x);
      return send(201, { number: x.number }); // no html_url: the helper must read the PR back
    }
    if ((m = p.match(/^\/repos\/acme\/demo\/pulls\/(\d+)$/))) {
      const x = S.pulls.find((y) => y.number == m[1]);
      if (!x) return send(404, { message: "Not Found" });
      if (req.method === "PATCH") { Object.assign(x, body); return send(200, { number: x.number }); }
      return send(200, pr(x));
    }
    if ((m = p.match(/^\/repos\/acme\/demo\/commits\/([0-9a-f]{40})\/check-runs$/))) return send(200, { check_runs: S.checks[m[1]] ?? [] });
    if ((m = p.match(/^\/repos\/acme\/demo\/commits\/([0-9a-f]{40})$/))) {
      const date = git("show", "-s", "--format=%cI", m[1]);
      return date ? send(200, { sha: m[1], commit: { committer: { date: new Date(date).toISOString().replace(/\.000Z$/, "Z") } } }) : send(404, {});
    }
    if ((m = p.match(/^\/repos\/acme\/demo\/issues\/(\d+)\/comments$/))) {
      const list = (S.issueComments[m[1]] ??= []);
      if (req.method === "GET") return send(200, list);
      if (S.failComments) return send(502, { message: "stub: posting fails" });
      const now = new Date().toISOString();
      const c = { id: nextId++, body: body.body, user: { login: "agent" }, created_at: now, updated_at: now, html_url: `https://github.com/acme/demo/pull/${m[1]}#issuecomment-${nextId - 1}` };
      list.push(c);
      return send(201, c);
    }
    if ((m = p.match(/^\/repos\/acme\/demo\/issues\/comments\/(\d+)$/)) && req.method === "PATCH") {
      const c = Object.values(S.issueComments).flat().find((x) => x.id == m[1]);
      if (!c) return send(404, {});
      if (S.failComments) return send(502, { message: "stub: posting fails" });
      c.body = body.body;
      c.updated_at = new Date().toISOString();
      return send(200, c);
    }
    if ((m = p.match(/^\/repos\/acme\/demo\/pulls\/(\d+)\/comments$/))) return send(200, S.reviewComments[m[1]] ?? []);
    if ((m = p.match(/^\/repos\/acme\/demo\/pulls\/(\d+)\/comments\/(\d+)\/replies$/))) {
      const list = S.reviewComments[m[1]] ?? [];
      const parent = list.find((c) => c.id == m[2]);
      if (!parent) return send(404, { message: "Not Found" });
      const c = { id: nextId++, in_reply_to_id: parent.id, path: parent.path, body: body.body, user: { login: "agent" }, html_url: `https://github.com/acme/demo/pull/${m[1]}#discussion_r${nextId - 1}` };
      list.push(c);
      return send(201, c);
    }
    if ((m = p.match(/^\/repos\/acme\/demo\/pulls\/(\d+)\/reviews$/))) return send(200, S.reviews[m[1]] ?? []);
    // github.com blob URLs, served from the bare origin: 200 only if the path exists at that commit
    if ((m = p.match(/^\/acme\/demo\/blob\/([0-9a-f]{40})\/(.+)$/)))
      return git("cat-file", "-e", `${m[1]}:${decodeURIComponent(m[2])}`) === null ? send(404, {}) : send(200, {});
    send(404, { message: `stub: no route for ${req.method} ${p}` });
  });
}).listen(0, "127.0.0.1", function () { writeFileSync(portFile, String(this.address().port)); });
