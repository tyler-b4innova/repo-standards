import assert from "node:assert/strict";
import { record } from "./record.mjs";
record("e2e");
assert.equal(process.env.CLOUDFLARE_API_TOKEN, undefined);
assert.equal(process.env.GATE_PREVIEW_URL, undefined);
const { BASE_URL, PLAYWRIGHT_BASE_URL, FAIL_E2E, NO_WORKER } = process.env;
if (NO_WORKER) {
  assert.equal(BASE_URL, undefined);
  assert.equal(PLAYWRIGHT_BASE_URL, undefined);
  console.log("same e2e suite: no Worker requested");
} else {
  assert.equal(BASE_URL, PLAYWRIGHT_BASE_URL);
  assert.ok(BASE_URL.startsWith("http://127.0.0.1:"));
  assert.equal((await fetch(`${BASE_URL}/value`, { method: "PUT", body: "real local KV" })).status, 200);
  assert.equal(await (await fetch(`${PLAYWRIGHT_BASE_URL}/value`)).text(), "real local KV");
  assert.equal(await (await fetch(`${BASE_URL}/local-vars`)).text(), "dummy");
  console.log(`same e2e suite: HTTP entry point + local KV at ${BASE_URL}`);
}
if (process.env.LINGER) await new Promise((r) => setTimeout(r, 30000));
assert.ok(!FAIL_E2E, "deliberately failing e2e");
