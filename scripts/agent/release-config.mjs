// Resolve and check the configuration used by a release, including adapter-generated redirects.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { parse, resourceFindings } from "./staging.mjs";

export const redirectFile = ".wrangler/deploy/config.json";
export const rootFile = () => ["wrangler.json", "wrangler.jsonc", "wrangler.toml"].find(existsSync);
const read = (file) => readFileSync(file, "utf8");

// TOML is parsed by the standard-library parser, not by regexes that could miss a route or a quoted env table.
// Fail closed if the build image cannot parse it; JSONC needs no extra runtime.
export function readConfig(file) {
  let cfg;
  if (file.endsWith(".toml")) {
    const r = spawnSync("python3", ["-c", "import json,sys,tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))", file], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    if (r.status !== 0) throw new Error(`${file}: cannot safely parse TOML; install Python 3.11+ or convert to wrangler.jsonc`);
    cfg = parse(r.stdout);
  } else cfg = parse(read(file));
  if (!cfg || typeof cfg !== "object" || Array.isArray(cfg)) throw new Error(`${file}: invalid Wrangler config`);
  return cfg;
}

export function effectiveConfig(root, staging = false, { redirect = true } = {}) {
  let file = root;
  if (redirect && existsSync(redirectFile)) {
    const redirect = parse(read(redirectFile));
    if (typeof redirect?.configPath !== "string" || !redirect.configPath) throw new Error(`${redirectFile}: missing configPath`);
    file = resolve(dirname(redirectFile), redirect.configPath);
  }
  if (!file) throw new Error("no Wrangler config");
  const cfg = readConfig(file), stage = cfg.env?.staging;
  // A flattened config has no environment table: --env is ignored by Wrangler.
  const target = staging && stage ? { ...cfg, ...stage, name: stage.name ?? `${cfg.name}-staging` } : cfg;
  return { file: resolve(file), cfg: target, redirected: resolve(file) !== resolve(root) };
}

// Name-only follow-up commands reload the root account. Cross-account releases
// need explicit account selection throughout; until then, reject them before remote work.
export function assertReleaseAccounts(root, configs = [root]) {
  for (const cfg of configs) if (cfg.account_id !== root.account_id ||
    (cfg.env?.staging?.account_id !== undefined && cfg.env.staging.account_id !== root.account_id))
    throw new Error(`cross-account staging isn't supported yet: ${cfg.name ?? "Worker"} and its env.staging must use the root account_id`);
}

function routes(cfg) {
  if (cfg.routes !== undefined && !Array.isArray(cfg.routes)) throw new Error("routes must be an array");
  return [...(cfg.routes ?? []), ...(cfg.route ? [cfg.route] : [])].filter((r) => r?.enabled !== false).map((r) => {
    const pattern = typeof r === "string" ? r : r?.pattern;
    if (typeof pattern !== "string" || !pattern) throw new Error("cannot safely read a route/custom domain");
    return pattern.toLowerCase();
  });
}
export function assertStaging(root, resolved, productionConfigs = [root]) {
  assertReleaseAccounts(productionConfigs[0], [root, resolved.cfg]);
  if (typeof root.name !== "string" || !root.name) throw new Error("production Worker name is missing");
  const expected = `${root.name}-staging`;
  if (resolved.cfg.name !== expected) throw new Error(`unsafe staging target ${JSON.stringify(resolved.cfg.name)}; expected ${expected}. The build must honor CLOUDFLARE_ENV=staging`);
  if (productionConfigs.some((cfg) => cfg.name === expected))
    throw new Error(`unsafe staging target ${expected}; names a production Worker from another config`);
  if (resolved.redirected && resolved.cfg.targetEnvironment && resolved.cfg.targetEnvironment !== "staging")
    throw new Error(`unsafe staging build environment ${resolved.cfg.targetEnvironment}; expected staging`);
  // Compare hosts, including wildcard hosts: different paths or route/custom-domain syntax
  // must not let staging take traffic from a production hostname.
  const host = (route) => route.replace(/^https?:\/\//, "").split("/")[0];
  const matches = (pattern, value) => new RegExp(`^${pattern.split("*").map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`).test(value);
  for (const route of routes(resolved.cfg)) for (const prod of productionConfigs.flatMap(routes)) {
    const a = host(route), b = host(prod);
    if (matches(a, b) || matches(b, a) || (a.includes("*") && b.includes("*")))
      throw new Error(`unsafe staging route/custom domain ${route}: overlaps production ${prod}`);
  }
  const isolation = resourceFindings(resolved.cfg, productionConfigs);
  if (isolation.length) throw new Error(`unsafe staging resources in ${resolved.file}: ${isolation.join("; ")}`);
  // route and routes are independently inherited; an empty routes array must not hide a production route.
  return expected;
}

export function buildCommand(std, pkg) {
  if (typeof std.build === "string" && std.build.trim()) return ["sh", ["-c", std.build]];
  if (!pkg?.scripts?.build) return null;
  const pm = existsSync("pnpm-lock.yaml") ? "pnpm" : existsSync("yarn.lock") ? "yarn" : "npm";
  return [pm, ["run", "build"]];
}
export function build(std, pkg, staging = false, { quiet = false, command = buildCommand(std, pkg), env = process.env } = {}) {
  if (!command) {
    if (existsSync(redirectFile)) throw new Error("generated Wrangler config requires a build command supporting CLOUDFLARE_ENV=staging; set standards.json build or package.json scripts.build");
    return;
  }
  const buildEnv = { ...env };
  delete buildEnv.CLOUDFLARE_ENV;
  delete buildEnv.WRANGLER_CI_OVERRIDE_NAME;
  delete buildEnv.WRANGLER_CI_MATCH_TAG;
  if (staging) {
    buildEnv.CLOUDFLARE_ENV = "staging";
  }
  if (!quiet) console.log(`release: build (${staging ? "CLOUDFLARE_ENV=staging" : "CLOUDFLARE_ENV unset"})`);
  const r = spawnSync(command[0], command[1], { env: buildEnv, stdio: quiet ? "pipe" : "inherit" });
  if (r.status !== 0) throw new Error(`${staging ? "staging" : "production"} build failed; ensure the build supports CLOUDFLARE_ENV staging selection`);
}

// Resolve production after a build before staging can mutate any remote resource.
// Parsing creates independent in-memory snapshots that the staging build cannot overwrite.
export function buildProductionConfigs(std, pkg, workers, { quiet = false } = {}) {
  build(std, pkg, false, { quiet });
  const configs = workers.map((worker) => {
    const resolved = effectiveConfig(worker.file, false, { redirect: Boolean(worker.primary) });
    if (resolved.cfg.name !== worker.cfg.name) throw new Error(`production build does not target ${worker.cfg.name}`);
    return resolved.cfg;
  });
  assertReleaseAccounts(workers[0].cfg, configs);
  return configs;
}

// On clean CI checkouts the redirect appears only after build. Both --check and gate's
// build entry point probe that same artifact and leave a production build behind.
export function verifyGeneratedBuild(std, pkg, root = rootFile()) {
  if (!root || std.staging === false || !existsSync(redirectFile)) return;
  const production = readConfig(root);
  if (!production.env?.staging) return; // legacy Preview releases do not select env.staging
  const extras = workerFiles(std, root).map((file) => ({ file, cfg: readConfig(file) }));
  const workers = [{ file: root, cfg: production, primary: true }, ...extras];
  const productionConfigs = [...workers.map((worker) => worker.cfg), ...buildProductionConfigs(std, pkg, workers, { quiet: true })];
  let stagingError;
  try { build(std, pkg, true, { quiet: true }); assertStaging(production, effectiveConfig(root, true), productionConfigs); }
  catch (e) { stagingError = e; }
  try { build(std, pkg, false, { quiet: true }); }
  catch (e) { throw new Error(stagingError ? `${stagingError.message}; production restore also failed: ${e.message}` : e.message); }
  if (stagingError) throw stagingError;
  if (effectiveConfig(root).cfg.name !== production.name) throw new Error("build without CLOUDFLARE_ENV did not restore production");
}

// Additional Workers are explicit repo-owned config paths, never shell commands or external files.
export function workerFiles(std, primary = rootFile()) {
  const files = std.release_workers === undefined ? [] : std.release_workers;
  if (!Array.isArray(files) || files.some((f) => typeof f !== "string" || !f || isAbsolute(f) || f.split(/[\\/]/).includes("..") || !/\.(jsonc?|toml)$/.test(f)))
    throw new Error("standards.json release_workers must be a list of relative Wrangler config paths within this repo");
  if (!files.length) return [];
  if (!primary) throw new Error("release_workers requires a primary root Wrangler config");
  const repo = realpathSync("."), seen = new Set([realpathSync(primary)]), names = new Set([readConfig(primary).name]);
  return files.map((file) => {
    const path = realpathSync(file), rel = relative(repo, path);
    if ((rel === ".." || rel.startsWith(`..${sep}`)) || isAbsolute(rel) || seen.has(path)) throw new Error(`release_workers has an external or duplicate config: ${file}`);
    seen.add(path);
    const cfg = readConfig(path);
    if (typeof cfg.name !== "string" || !cfg.name || names.has(cfg.name)) throw new Error(`release_workers must use distinct production Worker names: ${file}`);
    names.add(cfg.name);
    return path;
  });
}
