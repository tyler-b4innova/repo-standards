#!/usr/bin/env node
// GitHub GraphQL stand-in for the session-start clean-up. State is re-read from <state.json> on every request:
//   { "merged": { "<branch>": [{ "oid": "<sha>", "repo": "acme/demo" }] }, "hang": false,
//     "advance": { "repo": "<path>", "branch": "<name>" },   advance: a commit lands on that branch before the answer
//     "switch": { "worktree": "<path>", "to": "<branch>" } }  switch: that worktree checks out another branch first
// Logs one line per request to <log>. Usage: node test/stubs/cleanup-github.mjs <port-file> <state.json> <log>
import { execFileSync } from "node:child_process";
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
    if (st.switch) execFileSync("git", ["-C", st.switch.worktree, "checkout", "-q", st.switch.to]);
    if (st.advance) {
      const git = (...a) => execFileSync("git", ["-C", st.advance.repo, ...a], { encoding: "utf8" }).trim(), ref = `refs/heads/${st.advance.branch}`;
      git("update-ref", ref, git("commit-tree", `${ref}^{tree}`, "-p", ref, "-m", "work landed meanwhile"));
    }
    const { query } = JSON.parse(raw || "{}");
    const repository = { defaultBranchRef: { name: "main" } };
    for (const [, alias, branch] of (query ?? "").matchAll(/(b\d+): pullRequests\(headRefName: ("(?:[^"\\]|\\.)*")/g))
      repository[alias] = { nodes: (st.merged[JSON.parse(branch)] ?? []).map((p) => ({ headRefOid: p.oid, headRepository: { nameWithOwner: p.repo ?? "acme/demo" } })) };
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ data: { repository } }));
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
