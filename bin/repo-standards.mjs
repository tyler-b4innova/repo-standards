#!/usr/bin/env node
// repo-standards: org-neutral standards engine. Each org's standards repo runs it with its overlay.
//   repo-standards apply --target <repo> --overlay <org.json> [--profile internal|client] [--version X.Y.Z] [--dispatch auto|manual|off]
//   repo-standards block --overlay <org.json> --profile <p>      print the rendered managed block
//   repo-standards sync --overlay <org.json> --version X.Y.Z [--repo owner/name]  land the pack on each fleet repo when its gate passes
//   repo-standards expiry --overlay <org.json>                   credential expiry sentinel
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { apply, loadOverlay, renderBlock } from "../lib/engine.mjs";

const [cmd, ...rest] = process.argv.slice(2);
const { values: o } = parseArgs({
  args: rest,
  options: {
    target: { type: "string" }, overlay: { type: "string" }, profile: { type: "string" }, version: { type: "string" },
    dispatch: { type: "string" }, repo: { type: "string" }, "dry-run": { type: "boolean" }, help: { type: "boolean" },
  },
});
const usage = () => process.stdout.write(readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 6).map((l) => l.replace(/^\/\/ ?/, "")).join("\n") + "\n");
if (!cmd || o.help || cmd === "--help") { usage(); process.exit(cmd ? 0 : 2); }
if (!o.overlay) { console.error("--overlay <org.json> is required"); process.exit(2); }
const overlay = loadOverlay(o.overlay);
try {
  if (cmd === "apply") {
    if (!o.target) throw new Error("--target <repo> is required");
    const r = apply({ target: o.target, overlay, profile: o.profile, version: o.version, dispatch: o.dispatch });
    console.log(r.changed.length ? `applied ${overlay.pack} v${r.version} (${r.profile}):\n  ${r.changed.join("\n  ")}` : `${overlay.pack} v${r.version} (${r.profile}) already current`);
  } else if (cmd === "block") {
    process.stdout.write(renderBlock(overlay, o.profile ?? "internal"));
  } else if (cmd === "sync" || cmd === "expiry") {
    const { run } = await import(`../lib/${cmd}.mjs`);
    await run({ overlay, repo: o.repo, dryRun: o["dry-run"], version: o.version });
  } else {
    usage();
    process.exit(2);
  }
} catch (e) {
  console.error(`repo-standards ${cmd}: ${e.message}`);
  process.exit(1);
}
