// Emulate the adapter's flattened config and redirect through the real build command.
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
const root = JSON.parse(readFileSync("wrangler.jsonc", "utf8"));
const staging = process.env.CLOUDFLARE_ENV === "staging";
const cfg = staging && !process.env.IGNORE_SELECTION ? { ...root, ...root.env.staging } : { ...root };
delete cfg.env;
cfg.legacy_env = true;
cfg.topLevelName = root.name;
cfg.definedEnvironments = Object.keys(root.env);
cfg.targetEnvironment = staging && !process.env.IGNORE_SELECTION ? "staging" : "";
for (const db of cfg.d1_databases ?? []) db.migrations_dir = "../../migrations";
if (process.env.PRODUCTION_ROUTE && staging) cfg.routes = ["https://site.example.com/private/*"];
mkdirSync("dist/server", { recursive: true });
mkdirSync(".wrangler/deploy", { recursive: true });
cfg.main = "./index.js";
writeFileSync("dist/server/index.js", "export default {fetch() {return new Response(\"fixture\")}};\n");
writeFileSync("dist/server/wrangler.json", JSON.stringify(cfg));
writeFileSync(".wrangler/deploy/config.json", JSON.stringify({ configPath: "../../dist/server/wrangler.json" }));
appendFileSync(process.env.RELEASE_LOG, JSON.stringify({ build: process.env.CLOUDFLARE_ENV ?? null, name: cfg.name, ...(process.env.RECORD_BUILD_CI ? { overrideName: process.env.WRANGLER_CI_OVERRIDE_NAME ?? null, matchTag: process.env.WRANGLER_CI_MATCH_TAG ?? null } : {}) }) + "\n");
