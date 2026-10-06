import assert from "node:assert/strict";
import { record } from "./record.mjs";
record("e2e");
for (const key of ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_API_KEY", "CLOUDFLARE_EMAIL", "CLOUDFLARE_ACCOUNT_ID"]) assert.equal(process.env[key], "");
assert.match(process.env.HOME, /gate-local-[^/]+$/);
assert.equal(process.env.USERPROFILE, process.env.HOME);
assert.match(process.env.WRANGLER_HOME, /gate-local-.*\/wrangler$/);
assert.match(process.env.XDG_CONFIG_HOME, /gate-local-.*\/xdg$/);
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
  const credentials = await (await fetch(`${BASE_URL}/credentials`)).json();
  assert.deepEqual(credentials, { build: { credentials: ["", "", "", ""], oauth: [false, false] }, worker: [null, null, null, null] });
  console.log(`same e2e suite: HTTP entry point + local KV at ${BASE_URL}`);
}
if (process.env.LINGER) await new Promise((r) => setTimeout(r, 30000));
assert.ok(!FAIL_E2E, "deliberately failing e2e");
