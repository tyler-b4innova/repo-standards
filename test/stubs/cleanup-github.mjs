#!/usr/bin/env node
// GitHub GraphQL stand-in for the session-start clean-up. State is re-read from <state.json> on every request:
//   { "merged": { "<branch>": [{ "oid": "<sha>", "repo": "acme/demo" }] }, "hang": false }
// Logs one line per request to <log>. Usage: node test/stubs/cleanup-github.mjs <port-file> <state.json> <log>
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, stateFile, logFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    const st = JSON.parse(readFileSync(stateFile, "utf8"));
    appendFileSync(logFile, `${req.method} ${req.url}\n`);
    if (st.hang) return; // never answers
    const { query } = JSON.parse(raw || "{}");
    const repository = { defaultBranchRef: { name: "main" } };
    for (const [, alias, branch] of (query ?? "").matchAll(/(b\d+): pullRequests\(headRefName: ("(?:[^"\\]|\\.)*")/g))
      repository[alias] = { nodes: (st.merged[JSON.parse(branch)] ?? []).map((p) => ({ headRefOid: p.oid, headRepository: { nameWithOwner: p.repo ?? "acme/demo" } })) };
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ data: { repository } }));
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
