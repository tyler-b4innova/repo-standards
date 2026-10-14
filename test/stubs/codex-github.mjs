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
    if (p === "/graphql") return send(200, { data: { repository: { pullRequest: { reviewThreads: { nodes: st.threads ?? [] } } } } });
    const save = () => writeFileSync(stateFile, JSON.stringify(st));
    if (p === "") return send(200, st.info ?? { default_branch: "main" });
    if ((m = p.match(/^\/branches\/(.+)$/))) return send(200, { commit: { sha: st.branchHeads?.[decodeURIComponent(m[1])] ?? decodeURIComponent(m[1]) } });
    // the verdict check-runs this workflow creates (POST), completes (PATCH) and reads (GET)
    if (p === "/check-runs" && req.method === "POST") { st.runs = [...(st.runs ?? []), { id: (st.runs?.length ?? 0) + 1, ...JSON.parse(raw) }]; save(); return send(201, { id: st.runs.length }); }
    if ((m = p.match(/^\/check-runs\/(\d+)$/)) && req.method === "PATCH") { const r = st.runs?.find((x) => x.id === Number(m[1])); Object.assign(r, JSON.parse(raw)); save(); return send(200, r); }
    if ((m = p.match(/^\/check-runs\/(\d+)$/))) return send(200, st.runs?.find((x) => x.id === Number(m[1])) ?? {});
    // compareCommits: the commits after a commit on the branch (newer pushes)
    if (/^\/compare\/[0-9a-f]+\.\.\.[^/]+$/.test(p)) return st.compareFail ? send(503, { message: "Service Unavailable" }) : send(200, { status: st.compareStatuses?.[p.slice("/compare/".length)] ?? st.compareStatus ?? "ahead", commits: (st.compareCommits ?? []).map((sha) => ({ sha })) });
    if ((m = p.match(/^\/actions\/runs\/(\d+)\/(cancel|force-cancel)$/)) && req.method === "POST") {
      st[m[2] === "cancel" ? "cancelled" : "forced"] = [...(st[m[2] === "cancel" ? "cancelled" : "forced"] ?? []), Number(m[1])]; save();
      return send((m[2] === "cancel" ? st.cancelFail : st.forceFail) ? 403 : 202, {});
    }
    if ((m = p.match(/^\/actions\/runs\/(\d+)$/))) return send(200, (st.gateRuns ?? []).find((r) => r.id === Number(m[1])) ?? {});
    // checksBy: check runs per commit (the base tip's and the head's differ); checks: the same list for every commit
    // 100 check-runs per page (page=N), as the real API
    if ((m = p.match(/^\/commits\/([0-9a-f]+)\/check-runs$/))) return send(200, { check_runs: (st.checksBy?.[m[1]] ?? st.checks ?? []).slice((Number(url.searchParams.get("page") ?? 1) - 1) * 100, Number(url.searchParams.get("page") ?? 1) * 100).map((c) => ("app" in c ? c : { ...c, app: { slug: "cloudflare-workers-and-pages" } })) });
    if ((m = p.match(/^\/contents\/(.+)$/))) { const f = st.files?.[`${m[1]}@${url.searchParams.get("ref")}`] ?? st.files?.[m[1]]; return f ? send(200, f) : send(404, { message: "Not Found" }); }
    if (p === "/pulls/7") return send(200, st.pr);
    if (/^\/pulls\/\d+\/files$/.test(p)) return send(200, []);
    if (p === "/pulls") return send(200, url.searchParams.get("state") === "open" ? st.open ?? (st.pr ? [st.pr] : []) : st.recent ?? []);
    if ((m = p.match(/^\/issues\/(\d+)\/comments$/))) return send(200, (st.comments ?? {})[m[1]] ?? []);
    if ((m = p.match(/^\/pulls\/\d+\/reviews$/))) return send(200, st.reviews ?? []);
    if ((m = p.match(/^\/issues\/\d+\/timeline$/))) return send(200, st.timeline ?? []);
    send(404, { message: `stub: no route ${req.method} ${p}` });
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
