#!/usr/bin/env node
// GitHub stand-in for the PR Preview sweep: GET /repos/acme/demo/pulls?state=open|closed from <state.json>
// ({"open": [...], "closed": [...]}), paginated by per_page and page.
// Usage: node test/stubs/previews-github.mjs <port-file> <state.json>
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, stateFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  const st = JSON.parse(readFileSync(stateFile, "utf8")), url = new URL(req.url, "http://stub");
  const send = (code, body) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };
  if (url.pathname !== "/repos/acme/demo/pulls") return send(404, { message: "Not Found" });
  if (!/^Bearer .+/.test(req.headers.authorization ?? "")) return send(401, { message: "Bad credentials" });
  const all = st[url.searchParams.get("state")] ?? [], per = Number(url.searchParams.get("per_page") ?? 30), page = Number(url.searchParams.get("page") ?? 1);
  send(200, all.slice((page - 1) * per, page * per));
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
