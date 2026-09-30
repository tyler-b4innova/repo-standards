#!/usr/bin/env node
// GitHub stand-in for promotion cases. State is re-read from <state.json> on every request.
// Usage: node test/stubs/promote-github.mjs <port-file> <state.json> <repo>   (<repo>'s working tree answers contents)
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, stateFile, repoDir] = process.argv.slice(2);
const server = createServer((req, res) => {
  const st = JSON.parse(readFileSync(stateFile, "utf8"));
  const p = new URL(req.url, "http://stub").pathname.replace(/^\/repos\/acme\/demo/, "");
  const send = (code, body) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };
  const page = new URL(req.url, "http://stub").searchParams.get("page");
  const list = (a) => send(200, page && page !== "1" ? [] : a);
  let m;
  if (p === "") return send(200, { default_branch: "staging", custom_properties: { flow: st.flow ?? "staged" } });
  if (p === "/pulls/7") return send(200, st.pr);
  if (p === "/pulls/7/files") return list(st.files.map((filename) => ({ filename })));
  if (p === "/pulls/7/reviews") return list(st.reviews);
  if (p === "/issues/7/comments") return list([]);
  if ((m = p.match(/^\/contents\/(.+)$/))) { try { return send(200, { content: readFileSync(`${repoDir}/${m[1]}`).toString("base64") }); } catch { return send(404, { message: "Not Found" }); } }
  if ((m = p.match(/^\/collaborators\/([^/]+)\/permission$/))) return send(200, { permission: st.perms[m[1]] ?? "read" });
  send(404, { message: `stub: no route ${req.method} ${p}` });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
