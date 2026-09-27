#!/usr/bin/env node
// GitHub REST stand-in for gate.mjs evidence. Re-reads the fixture on every request, logs requests as JSON lines.
//   node test/stubs/gate-github.mjs <port-file> <log-file> <fixture.json>
// fixture: { "repo": "o/r", "files": { "<pr>": [path...] }, "comments": { "<pr>": [comment...] }, "contents": ["<sha>:<path>"] }
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
  if (!p.startsWith(base)) return send(404, { message: "Not Found" });
  const rest = p.slice(base.length);
  let m;
  if ((m = rest.match(/^pulls\/(\d+)\/files$/))) return page((fx.files[m[1]] ?? []).map((filename) => ({ filename, status: "modified" })));
  if ((m = rest.match(/^issues\/(\d+)\/comments$/))) return page(fx.comments?.[m[1]] ?? []);
  if ((m = rest.match(/^contents\/(.+)$/))) return (fx.contents ?? []).includes(`${url.searchParams.get("ref")}:${m[1]}`) ? send(200, {}) : send(404, { message: "Not Found" });
  send(404, { message: `stub: no route for ${req.method} ${p}` });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
