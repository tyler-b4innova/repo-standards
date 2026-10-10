#!/usr/bin/env node
// Cloudflare API (/cf) stand-in for promote and the live-state reads. State is re-read from <state.json> on every request.
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
    if (p === "/cf/accounts") return ok([{ id: "acct" }]);
    if (!(m = p.match(/^\/cf\/accounts\/[^/]+\/(.*)$/))) return send(404, {});
    const q = m[1], live = st.live ?? {};
    if (q === "workers/scripts") return st.scriptsFail ? send(500, { success: false }) : ok(st.scripts ?? []);
    // a Worker's versions, newest first, paged like the real API (10 unless per_page is given)
    if ((m = q.match(/^workers\/scripts\/([^/]+)\/versions$/))) {
      const per = Number(url.searchParams.get("per_page") ?? 10), page = Number(url.searchParams.get("page") ?? 1), all = (st.versions ?? {})[m[1]] ?? [];
      return ok({ items: all.slice((page - 1) * per, page * per) });
    }
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
