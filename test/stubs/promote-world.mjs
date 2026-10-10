#!/usr/bin/env node
// GitHub (/gh/repos/acme/demo) and Cloudflare API (/cf) stand-ins for promote. State is re-read from <state.json> on every request.
// Usage: node test/stubs/promote-world.mjs <port-file> <state.json>
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, stateFile] = process.argv.slice(2);
createServer((req, res) => {
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    const st = JSON.parse(readFileSync(stateFile, "utf8")), url = new URL(req.url, "http://stub"), p = url.pathname;
    const send = (code, body) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };
    const ok = (result) => send(200, { success: true, result });
    let m;
    if (p.startsWith("/gh/repos/acme/demo")) {
      const q = p.slice("/gh/repos/acme/demo".length);
      if (q === "") return send(200, { default_branch: "main" });
      if ((m = q.match(/^\/compare\/main\.\.\.([0-9a-f]+)$/))) return send(200, { status: (st.compare ?? {})[m[1]] ?? "behind" });
      if (/^\/commits\/[0-9a-f]+\/check-runs$/.test(q)) return send(200, { check_runs: st.checks ?? [] });
      if ((m = q.match(/^\/actions\/runs\/(\d+)$/))) return send(200, (st.runs ?? {})[m[1]] ?? {});
      return send(404, {});
    }
    if (p === "/cf/accounts") return ok([{ id: "acct" }]);
    if (!(m = p.match(/^\/cf\/accounts\/[^/]+\/(.*)$/))) return send(404, {});
    const q = m[1], live = st.live ?? {};
    if (q === "workers/scripts") return st.scriptsFail ? send(500, { success: false }) : ok(st.scripts ?? []);
    if ((m = q.match(/^workers\/scripts\/([^/]+)\/schedules$/))) return ok({ schedules: (live[m[1]]?.crons ?? []).map((cron) => ({ cron })) });
    if (q === "workers/domains") return ok((live[url.searchParams.get("service")]?.domains ?? []).map((hostname) => ({ hostname })));
    if (q === "queues") return ok(st.queues ?? []);
    if ((m = q.match(/^queues\/([^/]+)\/consumers$/))) return ok((st.consumers ?? {})[m[1]] ?? []);
    if ((m = q.match(/^workers\/scripts\/([^/]+)\/script-settings$/))) {
      if (req.method === "PATCH") { st.patches = [...(st.patches ?? []), { name: m[1], body: JSON.parse(raw) }]; writeFileSync(stateFile, JSON.stringify(st)); return ok({}); }
      return ok(live[m[1]]?.settings ?? {});
    }
    return send(404, {});
  });
}).listen(0, "127.0.0.1", function () { writeFileSync(portFile, String(this.address().port)); });
