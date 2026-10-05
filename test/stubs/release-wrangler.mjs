#!/usr/bin/env node
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { parse } from "../../template/scripts/agent/staging.mjs";
const args = process.argv.slice(2);
const option = (key) => args.includes(key) ? args[args.indexOf(key) + 1] : undefined;
let redirected = false;
const explicitConfig = option("--config") ?? option("-c");
let file = explicitConfig ?? "wrangler.jsonc";
if (!explicitConfig && existsSync(".wrangler/deploy/config.json")) {
  redirected = true;
  const redirect = ".wrangler/deploy/config.json";
  file = resolve(dirname(redirect), JSON.parse(readFileSync(redirect, "utf8")).configPath);
}
let cfg = parse(readFileSync(file, "utf8"));
const stage = option("--env");
// Wrangler rejects generated-only legacy_env metadata if redirect discovery was bypassed.
if ("legacy_env" in cfg && !redirected) { console.error("The legacy_env field is no longer supported"); process.exit(1); }
if (redirected && cfg.targetEnvironment && stage && cfg.targetEnvironment !== stage) { console.error("targetEnvironment does not match --env"); process.exit(1); }
if (stage && cfg.env?.[stage]) cfg = { ...cfg, ...cfg.env[stage], name: cfg.env[stage].name ?? `${cfg.name}-${stage}` };
const name = process.env.WRANGLER_CI_OVERRIDE_NAME ?? option("--name") ?? cfg.name;
appendFileSync(process.env.RELEASE_LOG, JSON.stringify({ args, name, configName: cfg.name, env: process.env.CLOUDFLARE_ENV ?? null, overrideName: process.env.WRANGLER_CI_OVERRIDE_NAME ?? null, matchTag: process.env.WRANGLER_CI_MATCH_TAG ?? null, routes: cfg.routes }) + "\n");
if (args[0] === "deploy") {
  console.log(`Uploaded ${process.env.WRONG_OUTPUT ? "site" : name} (1.0 sec)`);
  console.log(`Deployed ${process.env.WRONG_OUTPUT ? "site" : name} triggers (1.0 sec)`);
}

if (args[0] === "secret" && args[1] === "list") {
  const listed = process.env.RELEASE_SECRET_LIST ? JSON.parse(readFileSync(process.env.RELEASE_SECRET_LIST, "utf8"))[name] ?? [] : [];
  console.log(JSON.stringify(listed.map((name) => ({ name }))));
}
