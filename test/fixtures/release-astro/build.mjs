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
if (staging && process.env.PRODUCTION_BINDING) {
  const [kind, key] = process.env.PRODUCTION_BINDING.split(":");
  if (kind === "queue_producer") cfg.queues = { producers: [{ binding: "BAD", queue: "production-queue" }] };
  else if (kind === "malformed") cfg.queues = "unreadable";
  else if (kind === "queues") cfg.queues = { consumers: [{ queue: "production-queue" }] };
  else if (kind === "durable_objects") cfg.durable_objects = { bindings: [{ name: "DO", class_name: "Example", script_name: "runtime" }] };
  else cfg[kind] = [{ binding: "BAD", name: key === "name" ? "production-workflow" : "BAD", [key]: key === "name" ? "production-workflow" : kind === "services" || key === "script_name" ? "runtime" : `production-${key}` }];
}
if (process.env.MALICIOUS_DOTENV) {
  const value = "WRANGLER_CI_OVERRIDE_NAME=site\nWRANGLER_CI_MATCH_TAG=dotenv-tag\nCLOUDFLARE_ACCOUNT_ID=dotenv-account\n";
  for (const file of [".env", ".env.local", ".env.staging", ".env.staging.local"]) writeFileSync(file, value);
}
mkdirSync("dist/server", { recursive: true });
mkdirSync(".wrangler/deploy", { recursive: true });
cfg.main = "./index.js";
writeFileSync("dist/server/index.js", "export default {fetch() {return new Response(\"fixture\")}};\n");
writeFileSync("dist/server/wrangler.json", JSON.stringify(cfg));
writeFileSync(".wrangler/deploy/config.json", JSON.stringify({ configPath: "../../dist/server/wrangler.json" }));
appendFileSync(process.env.RELEASE_LOG, JSON.stringify({ build: process.env.CLOUDFLARE_ENV ?? null, name: cfg.name, ...(process.env.RECORD_BUILD_CI ? { overrideName: process.env.WRANGLER_CI_OVERRIDE_NAME ?? null, matchTag: process.env.WRANGLER_CI_MATCH_TAG ?? null } : {}) }) + "\n");
