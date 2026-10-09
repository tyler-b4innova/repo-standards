#!/usr/bin/env node
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { dirname, resolve } from "node:path";
import { parse } from "../../template/scripts/agent/staging.mjs";
const incomingEnv = { ...process.env };
const rawArgs = process.argv.slice(2);
const controlled = rawArgs.find((arg) => arg.startsWith("--env-file="))?.slice(11);
const args = rawArgs.filter((arg) => !arg.startsWith("--env-file="));
const option = (key) => args.includes(key) ? args[args.indexOf(key) + 1] : undefined;
// Wrangler's system dotenv loader runs before config/name resolution. CI values take precedence.
const dotenvFiles = controlled ? [controlled] : [".env", ".env.local", ...(option("--env") ? [`.env.${option("--env")}`, `.env.${option("--env")}.local`] : [])];
const loaded = {};
for (const file of dotenvFiles) if (existsSync(file)) for (const line of readFileSync(file, "utf8").split("\n")) {
  const match = line.match(/^([A-Z_]+)=(.*)$/);
  if (match) loaded[match[1]] = match[2];
}
for (const [key, value] of Object.entries(loaded)) if (process.env[key] === undefined) process.env[key] = value;
const controlledEmpty = Boolean(controlled && existsSync(controlled) && readFileSync(controlled, "utf8") === "");
let redirected = false;
const explicitConfig = option("--config") ?? option("-c");
let file = explicitConfig ?? "wrangler.jsonc";
if (!explicitConfig && existsSync(".wrangler/deploy/config.json")) {
  redirected = true;
  const redirect = ".wrangler/deploy/config.json";
  file = resolve(dirname(redirect), JSON.parse(readFileSync(redirect, "utf8")).configPath);
}
let cfg = file.endsWith(".toml")
  ? JSON.parse(spawnSync("python3", ["-c", "import json,sys,tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))", file], { encoding: "utf8" }).stdout)
  : parse(readFileSync(file, "utf8"));
const stage = option("--env");
// Wrangler rejects generated-only legacy_env metadata if redirect discovery was bypassed.
if ("legacy_env" in cfg && !redirected) { console.error("The legacy_env field is no longer supported"); process.exit(1); }
if (redirected && cfg.targetEnvironment && stage && cfg.targetEnvironment !== stage) { console.error("targetEnvironment does not match --env"); process.exit(1); }
if (stage && cfg.env?.[stage]) cfg = { ...cfg, ...cfg.env[stage], name: cfg.env[stage].name ?? `${cfg.name}-${stage}` };
let name = process.env.WRANGLER_CI_OVERRIDE_NAME ?? option("--name") ?? cfg.name;
// Secret commands append the environment to an explicit --name.
if (args[0] === "secret" && stage && option("--name")) name += `-${stage}`;
// Optional local proof: the actual Wrangler parser/bundler and dotenv handling, dry-run only.
// Normalize its structured result into the stub's output contract so release can finish offline.
if (process.env.REAL_WRANGLER && process.env.MALICIOUS_DOTENV && ["deploy", "versions"].includes(args[0])) {
  const output = resolve(`.wrangler/real-${randomUUID()}.jsonl`);
  const result = spawnSync(process.env.REAL_WRANGLER, [...rawArgs, "--dry-run"], { encoding: "utf8", env: { ...incomingEnv, WRANGLER_SEND_METRICS: "false", WRANGLER_OUTPUT_FILE_PATH: output } });
  if (result.status) { process.stderr.write(result.stdout + result.stderr); process.exit(result.status ?? 1); }
  const rows = readFileSync(output, "utf8").trim().split("\n").map(JSON.parse);
  const deployed = rows.find((row) => row.worker_name !== undefined);
  if (!deployed?.worker_name) { console.error("real Wrangler did not identify its dry-run target"); process.exit(1); }
  name = deployed.worker_name;
}
appendFileSync(process.env.RELEASE_LOG, JSON.stringify({ args, controlledEmpty, account: process.env.CLOUDFLARE_ACCOUNT_ID ?? null, name, configName: cfg.name, env: process.env.CLOUDFLARE_ENV ?? null, overrideName: process.env.WRANGLER_CI_OVERRIDE_NAME ?? null, matchTag: process.env.WRANGLER_CI_MATCH_TAG ?? null, routes: cfg.routes }) + "\n");
if (args[0] === "deploy") {
  if (process.env.MISSING_STAGING && !option("--secrets-file") && cfg.secrets?.required?.length) {
    console.error("required secrets have not been set");
    process.exit(1);
  }
  if (process.env.MISSING_STAGING && option("--secrets-file")) {
    const file = option("--secrets-file");
    const values = JSON.parse(readFileSync(file, "utf8"));
    if (cfg.secrets.required.some((key) => !values[key])) process.exit(1);
  }
  console.log(`Uploaded ${process.env.WRONG_OUTPUT ? "site" : name} (1.0 sec)`);
  console.log(`Deployed ${process.env.WRONG_OUTPUT ? "site" : name} triggers (1.0 sec)`);
}

if (args[0] === "versions" && args[1] === "list") console.log(process.env.RELEASE_VERSIONS ?? "[]");

if (args[0] === "secret" && args[1] === "list") {
  const listed = process.env.RELEASE_SECRET_LIST ? JSON.parse(readFileSync(process.env.RELEASE_SECRET_LIST, "utf8"))[name] ?? [] : [];
  console.log(JSON.stringify(listed.map((name) => ({ name }))));
}
