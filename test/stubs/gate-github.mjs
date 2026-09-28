#!/usr/bin/env node
// GitHub REST stand-in for the review rule's evidence part. Re-reads the fixture on every request, logs requests as JSON lines.
//   node test/stubs/gate-github.mjs <port-file> <log-file> <fixture.json>
// fixture: { "repo": "o/r", "files": { "<pr>": [path...] }, "comments": { "<pr>": [comment...] }, "contents": ["<sha>:<path>"],
//            "head": "<sha>", "gitDir": "<clone>" } — pulls/<n>, compare and commits are answered from gitDir.
import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, logFile, fixture] = process.argv.slice(2);
const server = createServer((req, res) => {
  const url = new URL(req.url, "http://stub"), p = decodeURIComponent(url.pathname);
  appendFileSync(logFile, JSON.stringify({ method: req.method, path: p, query: url.search, accept: req.headers.accept, auth: !!req.headers.authorization }) + "\n");
  const fx = JSON.parse(readFileSync(fixture, "utf8"));
  const send = (status, data) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(req.method === "HEAD" ? undefined : JSON.stringify(data)); };
  const page = (list) => {
    const per = Number(url.searchParams.get("per_page") || 30), n = Number(url.searchParams.get("page") || 1);
    return send(200, list.slice((n - 1) * per, n * per));
  };
  const base = `/repos/${fx.repo}/`;
  const git = (...a) => { try { return execFileSync("git", ["-C", fx.gitDir, ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { return null; } };
  if (p === `/repos/${fx.repo}`) return send(200, { default_branch: "main" });
  if (!p.startsWith(base)) return send(404, { message: "Not Found" });
  const rest = p.slice(base.length);
  let m;
  if ((m = rest.match(/^branches\/(.+)$/))) return send(200, { commit: { sha: git("rev-parse", m[1]) ?? fx.head } });
  if ((m = rest.match(/^pulls\/(\d+)$/))) return send(200, { number: Number(m[1]), state: "open", draft: false, html_url: `https://github.com/${fx.repo}/pull/${m[1]}`, user: { login: "alice" }, head: { sha: fx.head, ref: "feat" }, base: { ref: "main" } });
  if ((m = rest.match(/^compare\/([0-9a-f]+)\.\.\.([0-9a-f]+)$/))) {
    if (git("cat-file", "-e", `${m[1]}^{commit}`) === null) return send(404, { message: "Not Found" });
    const anc = git("merge-base", "--is-ancestor", m[1], m[2]) !== null;
    return send(200, { status: m[1] === m[2] ? "identical" : anc ? "ahead" : "diverged", commits: anc ? (git("rev-list", "--reverse", `${m[1]}..${m[2]}`) || "").split("\n").filter(Boolean).map((sha) => ({ sha })) : [] });
  }
  if ((m = rest.match(/^commits\/([0-9a-f]{40})$/))) return send(200, { sha: m[1], files: (git("diff", "--name-only", `${m[1]}^1`, m[1]) ?? "").split("\n").filter(Boolean).map((filename) => ({ filename })) });
  if ((m = rest.match(/^pulls\/(\d+)\/files$/))) return page((fx.files[m[1]] ?? []).map((filename) => ({ filename, status: "modified" })));
  if ((m = rest.match(/^issues\/(\d+)\/comments$/))) return page(fx.comments?.[m[1]] ?? []);
  if ((m = rest.match(/^contents\/(.+)$/))) {
    const ref = url.searchParams.get("ref"), have = (fx.contents ?? []).filter((c) => c.startsWith(`${ref}:`)).map((c) => c.slice(ref.length + 1));
    if (have.includes(m[1])) return send(200, { path: m[1] });
    const inDir = have.filter((f) => f.startsWith(`${m[1]}/`) && !f.slice(m[1].length + 1).includes("/"));
    return inDir.length ? send(200, inDir.map((path) => ({ path, name: path.split("/").pop(), type: "file" }))) : send(404, { message: "Not Found" });
  }
  send(404, { message: `stub: no route for ${req.method} ${p}` });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
