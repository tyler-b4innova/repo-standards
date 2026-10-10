// Resolve and check the configuration used by a release, including adapter-generated redirects.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync, mkdtempSync, mkdirSync, statSync, writeFileSync, rmSync } from "node:fs";
import { dirname, isAbsolute, normalize, relative, resolve, sep, join } from "node:path";
import { tmpdir } from "node:os";
import { parse, resourceFindings } from "./staging.mjs";

export const redirectFile = ".wrangler/deploy/config.json";
const CONFIGS = ["wrangler.json", "wrangler.jsonc", "wrangler.toml"];
export const rootFile = () => CONFIGS.find(existsSync);
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
// A private package-manager bootstrap shared by rollback and generated-config probes.
export function installBuildDependencies(pkg, context) {
  const pm = existsSync("pnpm-lock.yaml") ? "pnpm" : existsSync("yarn.lock") ? "yarn" : "npm";
  let env = process.env;
  if (pm !== "npm") {
    if (!context.home) {
      context.home = mkdtempSync(join(tmpdir(), "rollback-corepack-"));
      const bin = join(context.home, "bin");
      mkdirSync(bin);
      for (const manager of ["pnpm", "yarn"])
        writeFileSync(join(bin, manager), `#!/bin/sh\nexec npx --yes --package corepack@0.34.6 corepack ${manager} "$@"\n`, { mode: 0o755 });
    }
    env = { ...process.env, PATH: `${join(context.home, "bin")}:${process.env.PATH ?? ""}`, COREPACK_HOME: context.home, COREPACK_ENABLE_AUTO_PIN: "0" };
  }
  if (Object.keys({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.optionalDependencies }).length && !existsSync("node_modules")) {
    const args = pm === "pnpm" ? ["install", "--frozen-lockfile"] : pm === "yarn" ? ["install", existsSync(".yarnrc.yml") ? "--immutable" : "--frozen-lockfile"] : existsSync("package-lock.json") ? ["ci"] : ["install", "--no-package-lock"];
    const result = spawnSync(pm, args, { stdio: "ignore", env });
    if (result.status !== 0) throw new Error("cannot install production build dependencies; resolved production rollback comparison is required");
  }
  return { env };
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
  const r = spawnSync(command[0], command[1], { env: buildEnv, stdio: quiet ? "ignore" : "inherit" });
  if (r.status !== 0) {
    const outcome = r.signal ? `signal ${r.signal}` : r.status !== null ? `exit ${r.status}` : `spawn ${r.error?.code ?? "failed"}`;
    const quote = (arg) => /^[a-zA-Z0-9_./-]+$/.test(arg) ? arg : `'${arg.replaceAll("'", "'\\''")}'`;
    const localCommand = command.map((part) => Array.isArray(part) ? part.map(quote).join(" ") : quote(part)).join(" ");
    const selection = staging ? "CLOUDFLARE_ENV=staging" : "env -u CLOUDFLARE_ENV";
    const bootstrap = env.COREPACK_HOME ? "a Corepack-bootstrapped package manager" : "the configured package manager";
    throw new Error(`${staging ? "staging" : "production"} build failed (${outcome}); reproduce locally with ${bootstrap}: ${selection} ${localCommand}`);
  }
}

// Resolve production after a build before staging can mutate any remote resource.
// Parsing creates independent in-memory snapshots that the staging build cannot overwrite.
export function buildProductionConfigs(std, pkg, workers, { quiet = false, ...options } = {}) {
  build(std, pkg, false, { quiet, ...options });
  const configs = workers.map((worker) => {
    const resolved = effectiveConfig(worker.file, false, { redirect: worker.redirect ?? Boolean(worker.primary) });
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
  const context = {};
  try {
    const options = buildCommand(std, pkg) ? installBuildDependencies(pkg ?? {}, context) : {};
    const productionConfigs = [...workers.map((worker) => worker.cfg), ...buildProductionConfigs(std, pkg, workers, { quiet: true, ...options })];
    let stagingError;
    try { build(std, pkg, true, { quiet: true, ...options }); assertStaging(production, effectiveConfig(root, true), productionConfigs); }
    catch (e) { stagingError = e; }
    try { build(std, pkg, false, { quiet: true, ...options }); }
    catch (e) { throw new Error(stagingError ? `${stagingError.message}; production restore also failed: ${e.message}` : e.message); }
    if (stagingError) throw stagingError;
    if (effectiveConfig(root).cfg.name !== production.name) throw new Error("build without CLOUDFLARE_ENV did not restore production");
  } finally {
    if (context.home) rmSync(context.home, { recursive: true, force: true });
  }
}

// The Durable Object lifecycle a production config declares: any `durable-object` entry in the declarative `exports`, or the
// last tag of the legacy `migrations` array. Cloudflare cannot upload a version carrying either
// (https://developers.cloudflare.com/workers/versions-and-deployments/deployment-management/#durable-object-migrations).
export function doLifecycle(cfg) {
  const exp = cfg.exports && typeof cfg.exports === "object" ? Object.values(cfg.exports).some((e) => e?.type === "durable-object") : false;
  const migrations = Array.isArray(cfg.migrations) ? cfg.migrations : [];
  return { exports: exp, tag: migrations.length ? String(migrations[migrations.length - 1]?.tag ?? "") : null };
}

// Additional Workers are explicit repo-owned config paths, never shell commands or external files.
export function workerFiles(std, primary = rootFile(), base = ".") {
  const files = std.release_workers === undefined ? [] : std.release_workers;
  if (!Array.isArray(files) || files.some((f) => typeof f !== "string" || !f || isAbsolute(f) || f.split(/[\\/]/).includes("..") || !/\.(jsonc?|toml)$/.test(f)))
    throw new Error("standards.json release_workers must be a list of relative Wrangler config paths within this repo");
  if (!files.length) return [];
  if (!primary) throw new Error("release_workers requires a primary root Wrangler config");
  const repo = realpathSync(base), seen = new Set([realpathSync(join(base, primary))]), names = new Set([readConfig(join(base, primary)).name]);
  return files.map((file) => {
    const path = realpathSync(join(base, file)), rel = relative(repo, path);
    if ((rel === ".." || rel.startsWith(`..${sep}`)) || isAbsolute(rel) || seen.has(path)) throw new Error(`release_workers has an external or duplicate config: ${file}`);
    seen.add(path);
    const cfg = readConfig(path);
    if (typeof cfg.name !== "string" || !cfg.name || names.has(cfg.name)) throw new Error(`release_workers must use distinct production Worker names: ${file}`);
    names.add(cfg.name);
    return path;
  });
}

// Declared Workers: standards.json "workers" lists a repository's primary Workers, each a Wrangler config file or a directory holding
// exactly one, or {"config": <file or directory>, "release_workers": [...]} for a primary with supporting Workers. Primaries are declared,
// never discovered: a config that is not listed is not a primary, and nothing falls back to another directory. null when the key is absent
// (the repository's root config, and the top-level release_workers, keep their meaning). Every problem throws; none is skipped.
// "build" replaces standards.json build for that Worker's release. Returns [{ file, name, cfg, build, extras (absolute supporting config paths), extraConfigs }], `file` relative to base as Wrangler's -c takes it.
export function declaredWorkers(std, base = ".") {
  if (std?.workers === undefined) return null;
  if (!Array.isArray(std.workers) || !std.workers.length)
    throw new Error('standards.json workers must be a non-empty list of Wrangler config files or directories, or {"config": ..., "release_workers": [...]}');
  if (std.release_workers !== undefined)
    throw new Error('standards.json has workers and release_workers: give each declared Worker its own, {"config": ..., "release_workers": [...]}');
  const repo = realpathSync(base), within = (path) => { const rel = relative(repo, path); return !(rel === ".." || rel.startsWith(`..${sep}`)) && !isAbsolute(rel); };
  const seen = new Set(), names = new Map();
  const claim = (path, cfg, what) => {
    if (seen.has(path)) throw new Error(`workers has a duplicate config: ${what}`);
    seen.add(path);
    if (typeof cfg.name !== "string" || !cfg.name || names.has(cfg.name)) throw new Error(`workers must use distinct production Worker names: ${what}`);
    names.set(cfg.name, what);
  };
  return std.workers.map((entry) => {
    const object = entry && typeof entry === "object" && !Array.isArray(entry);
    if (object && Object.keys(entry).some((k) => !["config", "release_workers", "build"].includes(k))) throw new Error(`workers entry has an unknown key (config, release_workers, build): ${JSON.stringify(entry)}`);
    if (object && entry.build !== undefined && (typeof entry.build !== "string" || !entry.build.trim())) throw new Error(`workers entry build must be a non-empty command string: ${JSON.stringify(entry)}`);
    const path = object ? entry.config : entry;
    if (typeof path !== "string" || !path || isAbsolute(path) || path.split(/[\\/]/).includes("..")) throw new Error(`workers entry must be a relative path within this repo: ${JSON.stringify(path)}`);
    if (!existsSync(join(base, path))) throw new Error(`workers: ${path} does not exist`);
    const real = realpathSync(join(base, path));
    if (!within(real)) throw new Error(`workers: ${path} is outside this repo`);
    let configPath = real;
    if (statSync(real).isDirectory()) {
      const found = CONFIGS.filter((name) => existsSync(join(real, name)));
      if (found.length !== 1) throw new Error(`workers: ${path} must hold exactly one of ${CONFIGS.join(", ")} (found ${found.length ? found.join(", ") : "none"}); declare the config file itself to choose`);
      configPath = join(real, found[0]);
    } else if (!/\.(jsonc?|toml)$/.test(real)) throw new Error(`workers: ${path} is not a Wrangler config (.json, .jsonc, .toml) or a directory`);
    const file = normalize(relative(repo, configPath)), cfg = readConfig(configPath);
    claim(configPath, cfg, file);
    const extras = workerFiles({ release_workers: object ? entry.release_workers : undefined }, file, base), extraConfigs = extras.map((f) => {
      const c = readConfig(f);
      claim(f, c, relative(repo, f));
      return c;
    });
    return { file, name: cfg.name, cfg, extras, extraConfigs, build: object ? entry.build : undefined };
  });
}

// The one declared Worker a build is for: Workers Builds names it (WRANGLER_CI_OVERRIDE_NAME, the Worker's name), a local run says --worker <name>.
export function selectDeclared(workers, name) {
  if (!name) throw new Error("this repository declares several Workers and the build does not say which: Workers Builds sets WRANGLER_CI_OVERRIDE_NAME; a local run passes --worker <name>");
  const hit = workers.filter((w) => w.name === name);
  if (hit.length !== 1) throw new Error(hit.length ? `${hit.length} declared Workers are named ${name}` : `no declared Worker is named ${name} (declared: ${workers.map((w) => w.name).join(", ")}); a supporting Worker is not one`);
  return hit[0];
}
