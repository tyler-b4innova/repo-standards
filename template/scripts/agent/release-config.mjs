// Resolve and check the configuration used by a release, including adapter-generated redirects.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep, join } from "node:path";
import { tmpdir } from "node:os";
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

// The Worker a repository releases and its supporting Workers, resolved the way release.mjs does: from the directory of the
// primary config, which is the repository root when it has a config there, else a subdirectory Worker (a Workers Builds
// trigger rooted at workers/<name>). The standards checks use this same resolver. Without release_workers, only a root
// config is a primary (nothing to resolve); with them, the first directory whose primary resolves every listed config.
export function releaseContext(std, tracked, top = process.cwd()) {
  const listed = Array.isArray(std.release_workers) && std.release_workers.length > 0;
  const configs = (dir) => ["wrangler.json", "wrangler.jsonc", "wrangler.toml"].map((f) => join(dir, f)).find(existsSync) ?? null;
  if (!listed) { const primary = configs(top); return { dir: top, primary, extras: workerFiles(std, primary) }; }
  const dirs = [...new Set(tracked.filter((f) => /(^|\/)wrangler\.(jsonc?|toml)$/.test(f) && !/(^|\/)(node_modules|\.wrangler)\//.test(f)).map((f) => resolve(top, dirname(f))))]
    .sort((a, b) => (a === top ? -1 : b === top ? 1 : a.localeCompare(b)));
  let first = null;
  for (const dir of dirs) {
    const primary = configs(dir);
    process.chdir(dir);
    try { return { dir, primary, extras: workerFiles(std, primary) }; } catch (e) { first ??= e; } finally { process.chdir(top); }
  }
  throw first ?? new Error("release_workers requires a primary Wrangler config (at the repository root, or in a Worker directory such as workers/<name>)");
}
