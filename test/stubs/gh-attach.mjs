#!/usr/bin/env node
// A gh stand-in for test/pr.sh: only `--version` and `pr comment --attach`. gh's upload needs github.com and a person's
// token, so the upload is faked as gh documents it: each attachment becomes a user-attachments asset URL, `![alt](./file)`
// references are rewritten to it, unreferenced files are appended, and the comment is posted to the REST stand-in.
// Usage (from a shell shim on PATH): node test/stubs/gh-attach.mjs "$@"; env: GITHUB_API_URL, GH_TOKEN, GH_SHIM_LOG, GH_SHIM_VERSION.
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, readFileSync } from "node:fs";

const args = process.argv.slice(2);
if (args[0] === "--version") {
  console.log(`gh version ${process.env.GH_SHIM_VERSION ?? "2.102.0"} (test)`);
  process.exit(0);
}
if (args[0] !== "pr" || args[1] !== "comment") { console.error(`gh shim: unsupported: ${args.join(" ")}`); process.exit(2); }

const pr = args[2];
let repo, bodyFile, attach = [];
for (let i = 3; i < args.length; i++) {
  if (args[i] === "-R") repo = args[++i];
  else if (args[i] === "--body-file") bodyFile = args[++i];
  else if (args[i] === "--attach") attach.push(args[++i]);
  else { console.error(`gh shim: unknown flag ${args[i]}`); process.exit(2); }
}
appendFileSync(process.env.GH_SHIM_LOG, JSON.stringify({ args }) + "\n");

let body = readFileSync(bodyFile, "utf8");
const tail = [];
for (const spec of attach) {
  const [file] = spec.split("#"); // the alt text after # is only for references the body does not already carry
  if (!existsSync(file)) { console.error(`gh shim: no such file ${file}`); process.exit(1); }
  const url = `https://github.com/user-attachments/assets/${randomUUID()}`;
  if (body.includes(`](${file})`)) body = body.replaceAll(`](${file})`, `](${url})`);
  else tail.push(url);
}
if (tail.length) body = `${body.replace(/\n*$/, "\n")}\n${tail.join("\n\n")}\n`;

const res = await fetch(`${process.env.GITHUB_API_URL}/repos/${repo}/issues/${pr}/comments`, {
  method: "POST",
  headers: { Authorization: `Bearer ${process.env.GH_TOKEN}`, Accept: "application/vnd.github+json", "Content-Type": "application/json" },
  body: JSON.stringify({ body }),
});
const data = await res.json().catch(() => ({}));
if (!res.ok) { console.error(`gh shim: HTTP ${res.status}: ${data.message ?? ""}`); process.exit(1); }
// GH_SHIM_PARTIAL: the comment is posted, then the command fails before it reports the URL (a partial upload)
if (process.env.GH_SHIM_PARTIAL) { console.error("gh shim: connection lost after posting"); process.exit(1); }
console.log(`https://github.com/${repo}/pull/${pr}#issuecomment-${data.id}`);
