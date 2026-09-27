#!/usr/bin/env node
// Stand-in for the GitHub org endpoints org-apply uses. It answers the way GitHub does: rulesets come back
// with ids, read-only fields, `actor_id: null` for org admins, empty ignored_file_paths and rules reordered.
// Usage: node stub-github.mjs <port-file> <log-file> <state.json>
// state: { org, repos: [{name, archived}], property: {...}|null, values: {repo: flow}, rulesets: [...] }
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, logFile, stateFile] = process.argv.slice(2);
const st = JSON.parse(readFileSync(stateFile, "utf8"));
let nextId = Math.max(999, ...(st.rulesets ?? []).map((r) => r.id ?? 0)) + 1;
st.rulesets = (st.rulesets ?? []).map((r) => (r.id ? r : { id: nextId++, ...r }));
const asGitHub = (r) => ({
  ...r, source_type: "Organization", source: st.org, node_id: `RRS_${r.id}`, created_at: "2000-01-01T00:00:00Z", _links: {},
  bypass_actors: (r.bypass_actors ?? []).map((b) => (b.actor_type === "OrganizationAdmin" ? { ...b, actor_id: null } : b)),
  rules: [...(r.rules ?? [])].reverse().map((x) => (["file_path_restriction", "max_file_size"].includes(x.type) ? { ...x, parameters: { ignored_file_paths: [], ...x.parameters } } : x)),
});

createServer((req, res) => {
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    const body = raw ? JSON.parse(raw) : null;
    const p = new URL(req.url, "http://stub").pathname;
    appendFileSync(logFile, JSON.stringify({ method: req.method, path: p, body }) + "\n");
    const send = (status, data) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(data === undefined ? "" : JSON.stringify(data)); };
    const save = () => writeFileSync(stateFile, JSON.stringify(st, null, 2));
    if (body?.target === "push" && body.bypass_actors?.some((b) => b.bypass_mode === "pull_request")) {
      return send(422, { message: "Validation Failed", errors: ["bypass mode must not be 'PULL_REQUEST' for push rulesets"] });
    }
    let m;
    if (!(m = p.match(/^\/orgs\/([^/]+)\/(.+)$/)) || m[1] !== st.org) return send(404, { message: `stub: no route ${p}` });
    const rest = m[2];
    if (rest === "repos") return send(200, st.repos.map((r) => ({ name: r.name, full_name: `${st.org}/${r.name}`, archived: !!r.archived })));
    if ((m = rest.match(/^properties\/schema\/(.+)$/))) {
      if (req.method === "GET") return st.property?.property_name === m[1] ? send(200, st.property) : send(404, { message: "Not Found" });
      if (req.method === "PUT") { st.property = { property_name: m[1], ...body }; save(); return send(200, st.property); }
    }
    if (rest === "properties/values") {
      if (req.method === "GET") return send(200, st.repos.map((r) => ({ repository_name: r.name, properties: st.values?.[r.name] ? [{ property_name: "flow", value: st.values[r.name] }] : [] })));
      if (req.method === "PATCH") { for (const n of body.repository_names) (st.values ??= {})[n] = body.properties[0].value; save(); return send(204); }
    }
    if (rest === "rulesets") {
      if (req.method === "GET") return send(200, st.rulesets.map((r) => ({ id: r.id, name: r.name, target: r.target, source_type: "Organization" })));
      if (req.method === "POST") { const r = { id: nextId++, ...body }; st.rulesets.push(r); save(); return send(201, asGitHub(r)); }
    }
    if ((m = rest.match(/^rulesets\/(\d+)$/))) {
      const i = st.rulesets.findIndex((r) => r.id === Number(m[1]));
      if (i < 0) return send(404, { message: "Not Found" });
      if (req.method === "GET") return send(200, asGitHub(st.rulesets[i]));
      if (req.method === "PUT") { st.rulesets[i] = { id: st.rulesets[i].id, ...body }; save(); return send(200, asGitHub(st.rulesets[i])); }
      if (req.method === "DELETE") { st.rulesets.splice(i, 1); save(); return send(204); }
    }
    send(404, { message: `stub: no route ${req.method} ${p}` });
  });
}).listen(0, "127.0.0.1", function () { writeFileSync(portFile, String(this.address().port)); });
