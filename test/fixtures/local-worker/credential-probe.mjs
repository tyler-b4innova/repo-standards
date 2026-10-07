// Runs as Wrangler's actual build.command; its output is served by the real Worker.
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
const credentials = ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_API_KEY", "CLOUDFLARE_EMAIL", "CLOUDFLARE_ACCOUNT_ID"].map((key) => process.env[key] ?? null);
const oauth = [".wrangler/config/default.toml", "Library/Preferences/.wrangler/config/default.toml"].map((path) => existsSync(`${homedir()}/${path}`));
const probe = { credentials, oauth };
if (!process.env.PROBE_UNSAFE) {
  assert.deepEqual(probe, { credentials: ["", "", "", ""], oauth: [false, false] });
  assert.equal(process.env.USERPROFILE, homedir());
}
writeFileSync(".credential-build.mjs", `export default ${JSON.stringify(probe)};\n`);
console.log("Wrangler build.command credential probe:", JSON.stringify(probe));
