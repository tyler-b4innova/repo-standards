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
    const scope = p.startsWith("/actions/") ? "actions" : /^\/commits\/[^/]+\/check-runs$/.test(p) ? "checks" : p.startsWith("/pulls") || p === "/graphql" ? "pull-requests" : p.startsWith("/issues") ? "issues" : null;
    if (st.perms && scope && !st.perms.includes(scope)) return send(403, { message: "Resource not accessible by integration" });
    // graphqlFail: the thread query errors; threadsLater: threads after the first query (opened mid-run)
    if (p === "/graphql" && st.graphqlFail) return send(502, { message: "Bad Gateway" });
    if (p === "/graphql" && st.threadsLater) { st.gq = (st.gq ?? 0) + 1; writeFileSync(stateFile, JSON.stringify(st)); return send(200, { data: { repository: { pullRequest: { reviewThreads: { nodes: st.gq > 1 ? st.threadsLater : st.threads ?? [] } } } } }); }
    if (p === "/graphql") return send(200, { data: { repository: { pullRequest: { reviewThreads: { nodes: st.threads ?? [] } } } } });
    const save = () => writeFileSync(stateFile, JSON.stringify(st));
    if (p === "") return send(200, st.info ?? { default_branch: "main" });
    if ((m = p.match(/^\/actions\/runs\/(\d+)\/attempts\/(\d+)\/jobs$/))) return send(200, { jobs: [{ name: "gate", steps: (st.attempts ?? {})[m[2]] ?? [] }] });
    if (p === "/actions/workflows/std-gate.yml/runs") return send(200, { workflow_runs: st.gateRuns ?? [] });
    if ((m = p.match(/^\/actions\/runs\/(\d+)\/rerun$/)) && req.method === "POST") { st.reruns = [...(st.reruns ?? []), Number(m[1])]; save(); return send(201, {}); }
    if ((m = p.match(/^\/actions\/runs\/(\d+)$/))) return send(200, (st.gateRuns ?? []).find((r) => r.id === Number(m[1])) ?? {});
    if ((m = p.match(/^\/statuses\/([0-9a-f]+)$/)) && req.method === "POST") {
      if (st.statusForbidden) return send(403, { message: "Resource not accessible by integration" });
      st.statuses = [...(st.statuses ?? []), { sha: m[1], ...JSON.parse(raw) }]; save(); return send(201, {});
    }
    if ((m = p.match(/^\/commits\/([0-9a-f]+)\/check-runs$/))) return send(200, { check_runs: st.checks ?? [] });
    if ((m = p.match(/^\/contents\/(.+)$/))) { const f = st.files?.[`${m[1]}@${url.searchParams.get("ref")}`] ?? st.files?.[m[1]]; return f ? send(200, f) : send(404, { message: "Not Found" }); }
    // retargetAfter: n reads of the PR see its base; later reads see it retargeted (a base change mid-run)
    if (p === "/pulls/7" && st.retargetAfter !== undefined) { st.reads = (st.reads ?? 0) + 1; save(); return send(200, st.reads > st.retargetAfter ? (st.newHead ? { ...st.pr, head: { ...st.pr.head, sha: st.newHead } } : { ...st.pr, base: st.advance ? { ...st.pr.base, sha: "f".repeat(40) } : { ref: "elsewhere" } }) : st.pr); }
    if (p === "/pulls/7" && st.fail7) { st.fail7--; writeFileSync(stateFile, JSON.stringify(st)); return send(502, { message: "Bad Gateway" }); }
    if (p === "/pulls/7") return send(200, st.pr);
    // moveSibling: the second read of that PR sees it retargeted
    if ((m = p.match(/^\/pulls\/(\d+)$/)) && st.prs?.[m[1]]) {
      if (st.moveSibling === Number(m[1])) { st.sreads = (st.sreads ?? 0) + 1; save(); if (st.sreads > 1) return send(200, { ...st.prs[m[1]], base: { ref: "elsewhere" } }); }
      return send(200, st.prs[m[1]]);
    }
    if ((m = p.match(/^\/pulls\/(\d+)\/files$/))) return send(200, (st.prFiles ?? {})[m[1]] ?? []);
    if (p === "/pulls") return send(200, url.searchParams.get("state") === "open" ? st.open ?? (st.pr ? [st.pr] : []) : st.recent ?? []);
    if ((m = p.match(/^\/issues\/(\d+)\/comments$/))) return send(200, (st.comments ?? {})[m[1]] ?? []);
    if ((m = p.match(/^\/pulls\/\d+\/reviews$/))) return send(200, st.reviews ?? []);
    if (p === "/actions/runs") return send(200, { workflow_runs: [{ created_at: st.pushed }] });
    if ((m = p.match(/^\/issues\/\d+\/timeline$/))) return send(200, st.timeline ?? []);
    if ((m = p.match(/^\/commits\/([0-9a-f]+)$/))) return send(200, { commit: { committer: { date: st.pushed } } });
    send(404, { message: `stub: no route ${req.method} ${p}` });
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
