#!/usr/bin/env node
// GitHub stand-in for the Codex-verdict step. State is re-read from <state.json> on every request.
// Usage: node test/stubs/codex-github.mjs <port-file> <state.json>
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, stateFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    const st = JSON.parse(readFileSync(stateFile, "utf8"));
    const url = new URL(req.url, "http://stub"), p = url.pathname.replace(/^\/repos\/acme\/demo/, "");
    const send = (code, body) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };
    let m;
    // A private repository: the job token reads only what the workflow's permissions block grants.
    const scope = p.startsWith("/actions/") ? "actions" : p.startsWith("/pulls") || p === "/graphql" ? "pull-requests" : p.startsWith("/issues") ? "issues" : null;
    if (st.perms && scope && !st.perms.includes(scope)) return send(403, { message: "Resource not accessible by integration" });
    if (p === "/graphql") return send(200, { data: { repository: { pullRequest: { reviewThreads: { nodes: st.threads ?? [] } } } } });
    if (p === "/pulls/7") return send(200, st.pr);
    if (p === "/pulls") return send(200, st.recent ?? []);
    if ((m = p.match(/^\/issues\/(\d+)\/comments$/))) return send(200, (st.comments ?? {})[m[1]] ?? []);
    if (p === "/pulls/7/reviews") return send(200, st.reviews ?? []);
    if (p === "/actions/runs") return send(200, { workflow_runs: [{ created_at: st.pushed }] });
    if (p === "/issues/7/timeline") return send(200, st.timeline ?? []);
    if ((m = p.match(/^\/commits\/([0-9a-f]+)$/))) return send(200, { commit: { committer: { date: st.pushed } } });
    send(404, { message: `stub: no route ${req.method} ${p}` });
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
