#!/usr/bin/env node
// Workers Builds deploy commands and PR Preview clean-up (the Worker's trigger settings call these):
//   main      production trigger: deploy the staging Worker (wrangler deploy --env staging), upload the production version
//   preview   preview trigger: deploy this branch's Preview (wrangler preview --name <slug>)
//   slug <branch>                          the Preview name for a branch
//   cleanup --pr-branch <branch> | --sweep  delete a closed pull request's Preview (std-preview-cleanup.yml)
// Secrets (standards.json "secrets": {"required": [...], "store": "1password" | "secrets_store"}) are re-supplied on every
// staging and Preview deploy (a Preview drops secrets set on it when it is redeployed), and a deployed Worker missing a
// required secret fails the build. Secret values are never printed.
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse, findings as stagingFindings, resourceFindings } from "./staging.mjs";
import { build, rootFile, readConfig, effectiveConfig, assertStaging, assertReleaseAccounts, workerFiles, buildProductionConfigs } from "./release-config.mjs";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["main", "preview", "slug", "cleanup", "verify-release-check"];
if (!SUBS.includes(cmd) || args.includes("--help")) {
  console.log(readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 6).map((l) => l.slice(3)).join("\n"));
  process.exit(SUBS.includes(cmd) || cmd === "--help" ? 0 : 2);
}
const fail = (msg, fix) => { console.log(`::error::${msg}\nfix: ${fix}`); process.exit(1); };
const json = (f) => { try { return JSON.parse(readFileSync(f, "utf8")); } catch { return null; } };

// The Preview name Workers Builds' preview trigger has always used: the branch lowercased, every run of other characters
// one "-", the first 30 characters, then leading and trailing "-" removed (tr | tr -cs | cut -c1-30 | sed).
export const slug = (branch) => branch.toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 30).replace(/^-+|-+$/g, "");

if (cmd === "slug") {
  if (!args[0]) fail("no branch named", "release.mjs slug <branch>");
  console.log(slug(args[0]));
  process.exit(0);
}

// verify-release-check <sha>: the one rule a promotion applies before accepting a `release-check` for a version's commit
// (the agent deploy path and the portal use it): a successful check-run named release-check on that commit, created by
// GitHub Actions, whose external_id is the id of a workflow run of .github/workflows/std-release-check.yml, completed
// successfully, that ran for the default branch (head_branch), on a workflow_dispatch, titled `release-check <sha>`.
// Anything else (another workflow, a fork or feature-branch run, a push, a lookalike check) is refused. Exit 0 or 1.
if (cmd === "verify-release-check") {
  const sha = args[0] ?? "";
  if (!/^[0-9a-f]{40}$/.test(sha)) fail(`verify-release-check needs the version's full 40-character lowercase hex commit sha (got ${JSON.stringify(sha)})`, "release.mjs verify-release-check <sha>");
  const base = `${env.GITHUB_API_URL || "https://api.github.com"}/repos/${env.GITHUB_REPOSITORY}`;
  const headers = { Authorization: `Bearer ${env.GH_TOKEN || env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json" };
  const get = async (path) => { const r = await fetch(`${base}${path}`, { headers }); if (!r.ok) fail(`GET ${path || "/"}: ${r.status}`, "check the token can read checks and actions"); return r.json(); };
  const def = (await get("")).default_branch;
  const checks = [];
  for (let page = 1; ; page++) {
    const batch = (await get(`/commits/${sha}/check-runs?per_page=100&page=${page}`)).check_runs ?? [];
    checks.push(...batch);
    if (batch.length < 100) break;
  }
  const wrong = [];
  for (const c of checks.filter((x) => x.name === "release-check" && x.status === "completed" && x.conclusion === "success")
    .sort((a, b) => String(b.completed_at).localeCompare(String(a.completed_at)))) {
    const id = /^\d+$/.test(c.external_id ?? "") ? c.external_id : null;
    if (c.app?.slug !== "github-actions" || !id) { wrong.push(`check-run ${c.id} has no workflow run id (external_id) or is not GitHub Actions'`); continue; }
    const run = await get(`/actions/runs/${id}`);
    const why = run.path !== ".github/workflows/std-release-check.yml" ? `run ${id} is workflow ${run.path}` : run.event !== "workflow_dispatch" ? `run ${id} was a ${run.event}, not a workflow_dispatch`
      : run.head_branch !== def ? `run ${id} ran for ${run.head_branch}, not the default branch (${def})` : run.status !== "completed" || run.conclusion !== "success" ? `run ${id} did not complete successfully`
      : run.display_title !== `release-check ${sha}` ? `run ${id} was for another commit (${run.display_title})` : "";
    if (!why) { console.log(`release-check verified for ${sha.slice(0, 7)}: workflow run ${id} on ${def}`); process.exit(0); }
    wrong.push(why);
  }
  fail(`no verified release-check for ${sha.slice(0, 7)}${wrong.length ? `: ${wrong.join("; ")}` : " (none succeeded)"}`, "dispatch std-release-check for the version's commit on the default branch and wait for it to succeed");
}

try { process.chdir(execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: "pipe" }).trim()); } catch {}
const std = json("standards.json") ?? {};
const configFile = rootFile();
function config() {
  if (!configFile) fail("no wrangler config (wrangler.jsonc, wrangler.json or wrangler.toml)", "run this from a Worker repository");
  if (cmd !== "main" && configFile.endsWith(".toml")) return {};
  return readConfig(configFile);
}
const pkg = json("package.json");
const productionEnv = { ...env };
delete productionEnv.CLOUDFLARE_ENV;
// Workers Builds targets the production Worker through WRANGLER_CI_OVERRIDE_NAME (and guards it with
// WRANGLER_CI_MATCH_TAG). Only the primary production versions upload receives them.
const ISOLATED_ENV = Object.fromEntries(Object.entries(productionEnv).filter(([k]) => !["WRANGLER_CI_OVERRIDE_NAME", "WRANGLER_CI_MATCH_TAG"].includes(k)));
const primaryUpload = (a) => {
  if (a[0] !== "versions" || a[1] !== "upload" || a.includes("--env") || a.includes("-e")) return false;
  const configs = [];
  for (let i = 0; i < a.length; i++) {
    if (["-c", "--config"].includes(a[i])) configs.push(a[++i]);
    else if (a[i].startsWith("--config=")) configs.push(a[i].slice(9));
  }
  return configs.length === 0 || (configs.length === 1 && resolve(configs[0]) === resolve(configFile));
};
// Explicitly replace Wrangler's default .env/.env.* search with a private empty file.
// Process environment comes only from CI, with Builds overrides limited to the primary upload.
const envDir = mkdtempSync(join(tmpdir(), "release-env-"));
const envFile = join(envDir, "controlled.env");
writeFileSync(envFile, "", { mode: 0o600 });
process.on("exit", () => rmSync(envDir, { recursive: true, force: true }));
const wrangler = (a, { capture = false } = {}) => {
  console.log(`release: npx wrangler ${a.map((x) => (/^\//.test(x) ? "<file>" : x)).join(" ")}`);
  // The repository's own wrangler where it is installed (the build), else the current major (the clean-up job installs nothing).
  const bin = existsSync("node_modules/.bin/wrangler") ? ["wrangler"] : ["-y", "wrangler@4"];
  const r = spawnSync("npx", [...bin, ...a, `--env-file=${envFile}`], { encoding: "utf8", stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit", env: primaryUpload(a) ? productionEnv : ISOLATED_ENV });
  return { status: r.status ?? 1, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
};
const must = (a) => { const r = wrangler(a); if (r.status) process.exit(r.status); };

// Sentry: when the build has the SENTRY_AUTH_TOKEN secret and the repo was set up with sentry-setup (the public DSN it commits
// is in the Worker config), create the release for the commit after the Worker uploads succeeded and upload the source maps of
// the primary's final bundle: its production `versions upload` writes the bundle and maps to a clean --outdir with
// --upload-source-maps (https://developers.cloudflare.com/workers/wrangler/commands/workers/: "--outdir: Output directory for
// the bundled Worker", "--upload-source-maps: Include source maps when uploading this Worker"), never framework build directories.
// Org comes from pack.json, the project from the DSN's project id. Without the token this is one notice. Every Sentry request and
// the sentry-cli run are bounded (RELEASE_SENTRY_TIMEOUT_S, default 60): an expiry or any failure is a warning, and the
// already-finished release exits 0.
const SENTRY_MS = Number(env.RELEASE_SENTRY_TIMEOUT_S ?? 60) * 1000;
function sentryPlan(file) {
  const token = env.SENTRY_AUTH_TOKEN;
  if (!token) { console.log("release: Sentry skipped: no SENTRY_AUTH_TOKEN build secret (set it once on the Builds trigger to create Sentry releases)"); return null; }
  const et = json(fileURLToPath(new URL("pack.json", import.meta.url)))?.modules?.error_tracker;
  const dsn = (() => { try { const v = readConfig(file)?.vars?.SENTRY_DSN; return typeof v === "string" && /^https:\/\/[^/]+\/\d+$/.test(v) ? v : null; } catch { return null; } })();
  if (et?.kind !== "sentry" || !et.org || !dsn) { console.log("release: Sentry skipped: this repository is not set up for Sentry (scripts/agent/sentry-setup commits the DSN)"); return null; }
  return { token, org: et.org, dsn, base: String(et.api_base ?? "https://sentry.io").replace(/\/$/, "") };
}
async function sentryRelease(sha, plan, outdir) {
  const { token, org, dsn, base } = plan, headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  const call = (path, init) => fetch(`${base}${path}`, { ...init, headers, signal: AbortSignal.timeout(SENTRY_MS) });
  try {
    const projectId = dsn.split("/").pop(), pr = await call(`/api/0/projects/${org}/${projectId}/`);
    if (!pr.ok) throw new Error(`project ${projectId}: ${pr.status}`);
    const project = (await pr.json()).slug;
    const rel = await call(`/api/0/organizations/${org}/releases/`, { method: "POST", body: JSON.stringify({ version: sha, projects: [project] }) });
    await rel.text();
    if (!rel.ok && rel.status !== 208) throw new Error(`create release: ${rel.status}`);
    console.log(`release: Sentry release ${sha.slice(0, 7)} created for ${org}/${project}`);
    const cli = ["node_modules/.bin/sentry-cli"].find(existsSync);
    const maps = outdir && existsSync(outdir) ? readdirSync(outdir, { recursive: true }).some((f) => String(f).endsWith(".map")) : false;
    if (!cli || !maps) { console.log("release: Sentry: no sentry-cli in node_modules or no source maps in Wrangler's bundle; source maps not uploaded"); return; }
    const r = spawnSync(cli, ["sourcemaps", "upload", "--org", org, "--project", project, "--release", sha, outdir], { stdio: "inherit", env: { ...env, SENTRY_URL: base }, timeout: SENTRY_MS, killSignal: "SIGKILL" });
    console.log(r.status === 0 ? "release: Sentry source maps uploaded" : r.error?.code === "ETIMEDOUT" || r.signal ? `::warning::Sentry source map upload timed out after ${SENTRY_MS / 1000}s; the release exists without them` : `::warning::Sentry source map upload failed (exit ${r.status ?? 1}); the release exists without them`);
  } catch (e) { console.log(`::warning::Sentry release skipped: ${e.name === "TimeoutError" || e.name === "AbortError" ? `timed out after ${SENTRY_MS / 1000}s` : e.message}`); }
}

const secrets = std.secrets && typeof std.secrets === "object" ? std.secrets : {};
// Required: standards.json secrets.required and the wrangler config's own secrets.required.
const wranglerRequired = (() => { const c = configFile && !configFile.endsWith(".toml") ? parse(readFileSync(configFile, "utf8")) : null; return Array.isArray(c?.secrets?.required) ? c.secrets.required : []; })();
const required = [...new Set([...(Array.isArray(secrets.required) ? secrets.required : []), ...wranglerRequired])].filter((s) => typeof s === "string" && s);
const store = secrets.store ?? "1password";

// The 1Password CLI the build reads secrets with: OP_CLI, else a pinned release, checksum-verified (the build image has none).
const OP = { version: "2.40.0", sum: "74277219e8da60958c00f9aee9d2023225e98fdda8bfd2156a5d9e85e0edaab3" };
async function opCli(dir) {
  if (env.OP_CLI) return env.OP_CLI;
  if (!(process.platform === "linux" && process.arch === "x64")) fail(`no OP_CLI and no pinned 1Password CLI for ${process.platform}-${process.arch}`, "set OP_CLI to the op binary");
  const res = await fetch(`https://cache.agilebits.com/dist/1P/op2/pkg/v${OP.version}/op_linux_amd64_v${OP.version}.zip`);
  if (!res.ok) fail(`1Password CLI download: ${res.status}`, "re-run the build");
  const zip = Buffer.from(await res.arrayBuffer()), got = createHash("sha256").update(zip).digest("hex");
  if (got !== OP.sum) fail(`1Password CLI checksum mismatch: got ${got}, want ${OP.sum}`, "do not run it; re-run, or pin a new version and checksum in the engine");
  writeFileSync(join(dir, "op.zip"), zip);
  const unzip = spawnSync("unzip", ["-q", "-o", join(dir, "op.zip"), "op", "-d", dir]).status === 0
    || spawnSync("python3", ["-c", "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extract('op', sys.argv[2])", join(dir, "op.zip"), dir]).status === 0;
  if (!unzip) fail("could not unpack the 1Password CLI (no unzip or python3)", "set OP_CLI to an op binary");
  chmodSync(join(dir, "op"), 0o755);
  return join(dir, "op");
}

// The staging secrets file (JSON, mode 600, in a private temp dir): every required secret from the per-client vault
// (Builds variable OP_VAULT, item "staging", one field per secret), read with the Builds secret OP_SERVICE_ACCOUNT_TOKEN.
// null when nothing is re-supplied: no required secrets, or a Secrets Store binding holds them (client-owned account).
async function secretsFile(dir, names = required, filename = "secrets.json") {
  if (!names.length) return null;
  if (store === "secrets_store") { console.log("release: secrets come from Secrets Store bindings; nothing to re-supply"); return null; }
  // Without the vault the deploy keeps whatever secrets the Worker has; the post-deploy check still fails a missing one.
  if (!env.OP_VAULT || !env.OP_SERVICE_ACCOUNT_TOKEN) {
    console.log(`::warning::secrets (${names.join(", ")}) are not re-supplied: the build has no ${!env.OP_VAULT ? "OP_VAULT variable" : "OP_SERVICE_ACCOUNT_TOKEN secret"} | fix: set the Worker's Builds variable OP_VAULT (the client's 1Password vault) and secret OP_SERVICE_ACCOUNT_TOKEN (the org's CI-only service account) on both triggers`);
    return null;
  }
  const op = await opCli(dir), values = {};
  for (const name of names) {
    const r = spawnSync(op, ["read", "--no-newline", `op://${env.OP_VAULT}/staging/${name}`], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    if (r.status) fail(`1Password has no readable ${name} in the vault's "staging" item`, `add the field ${name} to the item "staging" in vault ${env.OP_VAULT} (the service account needs read access)`);
    values[name] = r.stdout;
  }
  const f = join(dir, filename);
  writeFileSync(f, JSON.stringify(values), { mode: 0o600 });
  return f;
}

// Staging commands must resolve to the name approved by assertStaging. Only deploy
// selects an environment; follow-up commands use the exact name without --env.
function stagingCommand(name, resolved, args) {
  const explicitName = args[args.indexOf("--name") + 1];
  const selectsEnv = args.includes("--env") || args.includes("-e");
  const target = selectsEnv ? resolved.cfg.name : explicitName;
  if (explicitName !== name || target !== name || (selectsEnv && args[0] !== "deploy"))
    throw new Error(`unsafe staging command target ${target}; expected exactly ${name}`);
  return args;
}

// Post-deploy: every required secret is on the deployed Worker (names only; a JSON list of {name}).
function secretCheck(what, a, namesRequired = required) {
  if (!namesRequired.length) return;
  if (store === "secrets_store") { console.log(`release: ${what}: secrets are Secrets Store bindings (checked offline by setup.sh --check)`); return; }
  const r = wrangler(a, { capture: true });
  if (r.status) { process.stdout.write(r.out); fail(`could not list the secrets of ${what}`, "re-run the build; the deploy itself succeeded"); }
  let names;
  // The JSON list may follow a banner or warnings ("[WARNING] ..."): the first "[" from which the rest parses.
  const end = r.out.lastIndexOf("]") + 1;
  for (let i = r.out.indexOf("["); i >= 0 && !names; i = r.out.indexOf("[", i + 1)) {
    try { const v = JSON.parse(r.out.slice(i, end)); if (Array.isArray(v)) names = v.map((s) => s?.name); } catch {}
  }
  if (!names) fail(`could not read the secret list of ${what}`, "re-run the build");
  const missing = namesRequired.filter((n) => !names.includes(n));
  if (missing.length) fail(`${what} is missing required secret(s): ${missing.join(", ")}`,
    store === "1password" && what !== "the production Worker" ? `add them to the "staging" item of vault ${env.OP_VAULT ?? "(OP_VAULT)"}` : "set them on the production Worker once: npx wrangler secret put <NAME>");
  console.log(`release: ${what} has its ${namesRequired.length} required secret(s)`);
}

// What a main release has changed so far. A later failure leaves the release mixed (some Workers updated, some not); the report on
// exit says which, and that a re-run deploys and uploads them all again. Nothing is restored or rolled back automatically.
const state = { stagingPlan: [], staged: [], productionPlan: [], uploaded: [], done: false };
process.on("exit", (code) => {
  if (!code || state.done || !(state.staged.length || state.uploaded.length)) return;
  const list = (a) => (a.length ? a.join(", ") : "none");
  console.log(`::error::release incomplete: Workers are in a mixed state
  staging updated: ${list(state.staged)}
  staging not updated: ${list(state.stagingPlan.filter((n) => !state.staged.includes(n)))}
  production uploaded: ${list(state.uploaded.map((u) => `${u.name} (version ${u.id})`))}
  production not uploaded: ${list(state.productionPlan.filter((n) => !state.uploaded.some((u) => u.name === n)))}
  Re-running the build deploys and uploads all of them again; nothing was restored or rolled back.`);
});

async function deploy() {
  // The secrets file goes with its directory on every exit, including a failed step's process.exit.
  const dir = mkdtempSync(join(tmpdir(), "release-"));
  process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
  {
    if (cmd === "preview") {
      const f = await secretsFile(dir), sf = f ? ["--secrets-file", f] : [];
      const branch = env.WORKERS_CI_BRANCH || execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim(), name = slug(branch);
      if (!name || name === "staging") fail(`branch ${branch} has no usable Preview name (${name || "empty"})`, "rename the branch");
      config();
      must(["preview", "--name", name, ...sf]);
      secretCheck(`Preview ${name}`, ["preview", "secret", "list", "--name", name, "--json"]);
      return;
    }
    const cfg = config(), staged = Boolean(cfg.env?.staging);
    const extras = workerFiles(std, configFile).map((file) => ({ file, cfg: readConfig(file) }));
    assertReleaseAccounts(cfg, [cfg, ...extras.map((worker) => worker.cfg)]);
    const productionName = env.WRANGLER_CI_OVERRIDE_NAME || cfg.name;
    const productionConfigs = [cfg, ...extras.map((w) => w.cfg), { name: productionName }];
    for (const worker of [...(staged ? [{ file: configFile, cfg }] : []), ...extras]) {
      const result = stagingFindings(worker.cfg, { file: worker.file, std: { staging: true }, productionConfigs });
      const isolation = result.fails.filter(([message]) => /names the production resource|consumes the production queue/.test(message));
      if (isolation.length) throw new Error(isolation.map(([message]) => message).join("; "));
    }
    const builtProduction = buildProductionConfigs(std, pkg, [{ file: configFile, cfg, primary: true }, ...extras]);
    productionConfigs.push(...builtProduction);
    if (!staged) {
      const preview = builtProduction[0].previews ?? {};
      const isolation = resourceFindings({ ...preview, migrations: preview.migrations ?? builtProduction[0].migrations }, productionConfigs);
      if (isolation.length) throw new Error(`unsafe staging Preview resources: ${isolation.join("; ")}`);
    }
    if (staged) build(std, pkg, true);
    // Validate every staging target before deploying any of them. Secondary explicit configs
    // bypass the primary adapter redirect, exactly as Wrangler -c does.
    // Supporting Workers (release_workers) go first, in their listed order, then the primary: the primary binds Durable Objects and
    // Workflows that live on them, so a new class must exist there before the primary's deploy needs it.
    const targets = [...extras, ...(staged ? [{ file: configFile, cfg, primary: true }] : [])].map((worker) => {
      const resolved = effectiveConfig(worker.file, true, { redirect: Boolean(worker.primary) });
      const name = assertStaging(worker.cfg, resolved, productionConfigs);
      const configArgs = resolved.redirected ? [] : ["--config", resolved.file];
      const names = worker.primary ? required : [...new Set((Array.isArray(worker.cfg.secrets?.required) ? worker.cfg.secrets.required : []).filter((name) => typeof name === "string" && name))];
      return { ...worker, resolved, name, configArgs, names };
    });
    state.stagingPlan = [...targets.map((t) => t.name), ...(staged ? [] : ["the staging Preview"])];
    state.productionPlan = [...extras.map((w) => w.cfg.name), productionName];
    const f = await secretsFile(dir), sf = f ? ["--secrets-file", f] : [];
    for (let i = 0; i < targets.length; i++) {
      const target = targets[i];
      const file = target.primary ? f : await secretsFile(dir, target.names, `worker-${i}.json`);
      target.sf = file ? ["--secrets-file", file] : [];
    }
    for (const { resolved, name, configArgs, names, sf: workerSecrets } of targets) {
      for (const d of Array.isArray(resolved.cfg.d1_databases) ? resolved.cfg.d1_databases : [])
        if (d?.binding && existsSync(resolve(dirname(resolved.file), d.migrations_dir ?? "migrations"))) must(["d1", "migrations", "apply", d.binding, "--env", "staging", ...configArgs, "--remote"]);
      // Do not pass generated --config: that loses Wrangler's adapter metadata context.
      const deployed = wrangler(stagingCommand(name, resolved, ["deploy", "--env", "staging", ...configArgs, "--name", name, ...workerSecrets]), { capture: true });
      process.stdout.write(deployed.out);
      if (deployed.status) {
        if (store !== "secrets_store" && names.length && !workerSecrets.length && /required secrets.*(?:not.*set|missing)/is.test(deployed.out))
          fail(`staging Worker ${name} requires supplied secrets: ${names.join(", ")}; if it does not exist yet, bootstrap it once`,
            `configure Builds OP_VAULT and OP_SERVICE_ACCOUNT_TOKEN, or create a private JSON secrets file and a private empty env file; in the CI build context unset WRANGLER_CI_OVERRIDE_NAME, WRANGLER_CI_MATCH_TAG and CLOUDFLARE_ENV, then run from this guarded staging build: npx wrangler deploy --env staging --secrets-file <file> --dry-run --name ${name} --env-file <empty-env-file>${configArgs.length ? ` --config ${resolved.file}` : ""}; verify the target is exactly ${name}, then npx wrangler deploy --env staging --secrets-file <file> --name ${name} --env-file <empty-env-file>${configArgs.length ? ` --config ${resolved.file}` : ""}; remove the file and re-run the build`);
        process.exit(deployed.status);
      }
      const confirmed = [...deployed.out.replace(/\x1b\[[0-9;]*m/g, "").matchAll(/^\s*(?:Uploaded|Deployed) ([a-zA-Z0-9_-]+)(?: triggers)? \(/gm)].map((m) => m[1]);
      if (!confirmed.length || confirmed.some((n) => n !== name)) fail(`staging deploy output did not confirm ${name}`, "inspect the Wrangler deployment immediately; production upload aborted");
      state.staged.push(name);
      secretCheck("the staging Worker", stagingCommand(name, resolved, ["secret", "list", ...configArgs, "--name", name, "--format", "json"]), names);
    }
    if (!staged) {
      console.log(`::warning::${configFile} has no env.staging; deploying staging as the legacy "staging" Preview. Add env.staging (a separate <name>-staging Worker with its own data): see the standards README`);
      must(["preview", "--name", "staging", ...sf]);
      state.staged.push("the staging Preview");
      secretCheck("the staging Preview", ["preview", "secret", "list", "--name", "staging", "--json"]);
    }
    build(std, pkg);
    const production = effectiveConfig(configFile);
    if (production.cfg.name !== cfg.name) fail("production build does not target the production Worker", "build without CLOUDFLARE_ENV before uploading");
    for (const worker of extras) if (effectiveConfig(worker.file, false, { redirect: false }).cfg.name !== worker.cfg.name)
      fail("secondary production build targets a different Worker", "restore each secondary config's production name before uploading");
    // Every production version carries its full commit SHA as its tag: the portal maps a version to its commit (and its
    // release-check) through the tag. Workers Builds sets WORKERS_CI_COMMIT_SHA (a CI run, GITHUB_SHA).
    const sha = env.WORKERS_CI_COMMIT_SHA || env.GITHUB_SHA;
    if (!sha) console.log("::warning::no WORKERS_CI_COMMIT_SHA: this production version is untagged, so the portal cannot tie it to its release-check");
    const tags = sha ? ["--tag", sha, "--message", `main ${sha}`, "--var", `SENTRY_RELEASE:${sha}`] : [];
    // Sentry: the primary's final bundle and source maps go to a clean --outdir for the source map upload (only when it will run)
    const sentry = sha ? sentryPlan(configFile) : null;
    const outdir = sentry ? mkdtempSync(join(tmpdir(), "release-bundle-")) : null;
    if (outdir) process.on("exit", () => rmSync(outdir, { recursive: true, force: true }));
    const upload = (name, a) => {
      const r = wrangler(a, { capture: true });
      process.stdout.write(r.out);
      if (r.status) process.exit(r.status);
      state.uploaded.push({ name, id: /Worker Version ID:\s*([A-Za-z0-9-]+)/.exec(r.out)?.[1] ?? "id not reported" });
    };
    for (const worker of extras) {
      upload(worker.cfg.name, ["versions", "upload", "-c", worker.file, "--name", worker.cfg.name, ...tags]);
      const names = [...new Set((Array.isArray(worker.cfg.secrets?.required) ? worker.cfg.secrets.required : []).filter((name) => typeof name === "string" && name))];
      secretCheck("the production Worker", ["secret", "list", "--config", worker.file, "--name", worker.cfg.name, "--format", "json"], names);
    }
    upload(productionName, ["versions", "upload", ...(outdir ? ["--outdir", outdir, "--upload-source-maps"] : []), ...tags]);
    secretCheck("the production Worker", ["secret", "list", "--name", productionName, "--format", "json"]);
    state.done = true;
    if (sentry) await sentryRelease(sha, sentry, outdir);
  }
}

// Delete Previews whose pull request closed: one branch's (--pr-branch), or every pull request closed in the last 30
// days (--sweep), except a branch an open pull request still uses. Never the legacy "staging" Preview; a Preview
// already gone is fine.
async function cleanup() {
  config();
  const at = args.indexOf("--pr-branch"), names = new Set(), keep = new Set(["staging"]);
  if (at < 0 && !args.includes("--sweep")) fail("nothing to clean up", "release.mjs cleanup --pr-branch <branch> | --sweep");
  if (at >= 0 && !args[at + 1]) fail("--pr-branch needs a branch", "release.mjs cleanup --pr-branch <branch>");
  const base = `${env.GITHUB_API_URL || "https://api.github.com"}/repos/${env.GITHUB_REPOSITORY}`;
  const headers = { Authorization: `Bearer ${env.GH_TOKEN || env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json" };
  const get = async (p) => { const r = await fetch(`${base}${p}`, { headers }); if (!r.ok) fail(`GET ${p}: ${r.status}`, "grant the job pull-requests read"); return r.json(); };
  // a Preview an open pull request still uses (the same branch, or one with the same slug) stays, in both modes
  for (let page = 1; ; page++) {
    const b = await get(`/pulls?state=open&per_page=100&page=${page}`);
    b.forEach((p) => keep.add(slug(p.head.ref)));
    if (b.length < 100) break;
  }
  if (at >= 0) names.add(slug(args[at + 1]));
  else {
    const since = Date.now() - 30 * 864e5;
    for (let page = 1; ; page++) {
      const b = await get(`/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=${page}`);
      // a fork's branch never had a Preview here
      b.filter((p) => p.closed_at && Date.parse(p.closed_at) >= since && (!p.head.repo || p.head.repo.full_name === env.GITHUB_REPOSITORY)).forEach((p) => names.add(slug(p.head.ref)));
      if (b.length < 100 || b.some((p) => Date.parse(p.updated_at) < since)) break;
    }
  }
  let bad = 0;
  for (const name of [...names].filter(Boolean).sort()) {
    if (keep.has(name)) { console.log(`cleanup: keep ${name} (${name === "staging" ? "staging" : "an open pull request uses it"})`); continue; }
    const r = wrangler(["preview", "delete", "--name", name, "--skip-confirmation"], { capture: true });
    if (!r.status) console.log(`cleanup: deleted Preview ${name}`);
    else if (/not (been )?found|does not exist/i.test(r.out)) console.log(`cleanup: Preview ${name} is already gone`);
    else { process.stdout.write(r.out); console.log(`::error::could not delete Preview ${name}`); bad++; }
  }
  if (bad) process.exit(1);
  console.log(`cleanup: ${names.size ? "done" : "no closed pull requests"}`);
}

try { await (cmd === "cleanup" ? cleanup() : deploy()); }
catch (e) { fail(e.message, "fix the build/config before retrying; staging must target only <production name>-staging with no production routes or custom domains"); }
