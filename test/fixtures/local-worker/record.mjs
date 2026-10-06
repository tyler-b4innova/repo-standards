// A later entry point fails if an earlier configured gate command never ran.
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
export function record(step) {
  const order = ["typecheck", "build", "repo", "e2e"], at = order.indexOf(step);
  assert.ok(at >= 0);
  // setup also builds for rollback inventory before typecheck initializes this trace.
  if (step === "build" && !existsSync(".gate-order")) return;
  const before = existsSync(".gate-order") ? JSON.parse(readFileSync(".gate-order", "utf8")) : [];
  assert.deepEqual(before, order.slice(0, at), `commands before ${step}`);
  writeFileSync(".gate-order", JSON.stringify([...before, step]));
}
if (process.argv[1]?.endsWith("/record.mjs")) record(process.argv[2]);
