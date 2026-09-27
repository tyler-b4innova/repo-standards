#!/usr/bin/env node
// Stand-in for the error tracker API that sentry-setup calls. Logs requests as JSON lines.
// Usage: node sync-sentry.mjs <port-file> <log-file> <org> <workflow name>
import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, logFile, org, workflowName] = process.argv.slice(2);
const projects = {};
const workflow = { id: "7", name: workflowName, enabled: true, config: {}, environment: null, triggers: {}, actionFilters: [], detectorIds: ["d-other"] };
createServer((req, res) => {
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    const body = raw ? JSON.parse(raw) : null;
    const url = new URL(req.url, "http://stub");
    appendFileSync(logFile, JSON.stringify({ method: req.method, path: url.pathname, query: url.search, auth: !!req.headers.authorization, body }) + "\n");
    const send = (s, d) => { res.writeHead(s, { "Content-Type": "application/json" }); res.end(JSON.stringify(d)); };
    const p = url.pathname, o = `/api/0/organizations/${org}`;
    let m;
    if ((m = p.match(new RegExp(`^/api/0/projects/${org}/([^/]+)/$`)))) return projects[m[1]] ? send(200, projects[m[1]]) : send(404, { detail: "not found" });
    if ((m = p.match(new RegExp(`^/api/0/projects/${org}/([^/]+)/keys/$`)))) return send(200, [{ dsn: { public: `https://pub${projects[m[1]].id}@ingest.example.com/${projects[m[1]].id}` } }]);
    if (p === `/api/0/teams/${org}/${org}/projects/` && req.method === "POST") return send(201, (projects[body.slug] = { id: String(100 + Object.keys(projects).length), slug: body.slug, platform: body.platform }));
    if (p === `${o}/workflows/`) return send(200, [{ id: workflow.id, name: workflow.name }]);
    if (p === `${o}/workflows/7/` && req.method === "GET") return send(200, workflow);
    if (p === `${o}/workflows/7/` && req.method === "PUT") return send(200, Object.assign(workflow, body));
    if (p === `${o}/detectors/`) return send(200, [{ id: `d${url.searchParams.get("project")}`, type: "issue_stream" }, { id: "x", type: "metric" }]);
    send(404, { detail: `stub: no route ${req.method} ${p}` });
  });
}).listen(0, "127.0.0.1", function () {
  writeFileSync(portFile, String(this.address().port));
});
