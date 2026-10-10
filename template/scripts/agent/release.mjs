#!/usr/bin/env node
// Workers Builds deploy commands and PR Preview clean-up (the Worker's trigger settings call these):
//   main      production trigger: deploy the staging Worker (wrangler deploy --env staging), upload the production version
//   preview   preview trigger: deploy this branch's Preview (wrangler preview --name <slug>); on a release/<40-hex sha> branch
//             (created only by the portal App) it promotes that commit to production instead
//   slug <branch>                          the Preview name for a branch
//   cleanup --pr-branch <branch> | --sweep  delete a closed pull request's Preview (std-preview-cleanup.yml)
// Secrets (standards.json "secrets": {"required": [...], "store": "1password" | "secrets_store"}) are re-supplied on every
// staging and Preview deploy (a Preview drops secrets set on it when it is redeployed), and a deployed Worker missing a
// required secret fails the build. Secret values are never printed.
// With standards.json "workers" declared, the Worker a main/preview build releases is WRANGLER_CI_OVERRIDE_NAME, or --worker <name> locally.
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse, findings as stagingFindings, resourceFindings } from "./staging.mjs";
import { build, rootFile, readConfig, effectiveConfig, assertStaging, assertReleaseAccounts, workerFiles, declaredWorkers, selectDeclared, buildProductionConfigs, doLifecycle } from "./release-config.mjs";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["main", "preview", "slug", "cleanup", "verify-release-check"];
if (!SUBS.includes(cmd) || args.includes("--help")) {
  console.log(readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 7).map((l) => l.slice(3)).join("\n"));
  process.exit(SUBS.includes(cmd) || cmd === "--help" ? 0 : 2);
}
const fail = (msg, fix) => { console.log(`::error::${msg}\nfix: ${fix}`); process.exit(1); };
// A preview build of the branch release/<40-hex commit sha> is a production release of that commit: the portal's App creates the branch
// (the org ruleset lets nothing else) for a commit a person approved and that main released, and deletes it after the build.
const RELEASE_SHA = cmd === "preview" ? /^release\/([0-9a-f]{40})$/.exec(env.WORKERS_CI_BRANCH ?? "")?.[1] ?? null : null;
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
// Declared Workers (standards.json "workers"): each has its own Builds trigger running from the repository root, and the build releases
// the one it is for (WRANGLER_CI_OVERRIDE_NAME, or --worker <name> in a local run). Without the key the root config is the one Worker.
let declared = null, lead = null;
try {
  declared = declaredWorkers(std);
  if (declared && cmd !== "cleanup") {
    const at = args.indexOf("--worker"), asked = at >= 0 ? args[at + 1] : undefined;
    if (at >= 0 && !asked) throw new Error("--worker needs a Worker name");
    if (asked && env.WRANGLER_CI_OVERRIDE_NAME && asked !== env.WRANGLER_CI_OVERRIDE_NAME)
      throw new Error(`--worker ${asked} disagrees with this build's WRANGLER_CI_OVERRIDE_NAME ${env.WRANGLER_CI_OVERRIDE_NAME}`);
    lead = selectDeclared(declared, asked ?? env.WRANGLER_CI_OVERRIDE_NAME);
  }
} catch (e) { fail(e.message, "declare each Worker in standards.json workers and give each Worker's Builds trigger its own name (WRANGLER_CI_OVERRIDE_NAME)"); }
const configFile = declared ? lead?.file ?? null : rootFile();
// Wrangler finds the root default config (and the adapter redirect beside it) by itself; any other declared config is named with --config.
const leadRedirect = !declared || configFile === rootFile();
const leadArgs = leadRedirect || !configFile ? [] : ["--config", configFile];
// A declared Worker's own build command replaces the repository's.
const buildStd = lead?.build ? { ...std, build: lead.build } : std;
const supportingFiles = () => (declared ? lead.extras : workerFiles(std, configFile));
function config() {
  if (!configFile) fail("no wrangler config (wrangler.jsonc, wrangler.json or wrangler.toml)", "run this from a Worker repository");
  if (cmd !== "main" && !RELEASE_SHA && configFile.endsWith(".toml")) return {};
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

// Live production state, read from Cloudflare's API with the Builds token (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID), never from commit history.
const CF_API = (env.CLOUDFLARE_API_BASE || "https://api.cloudflare.com/client/v4").replace(/\/$/, "");
async function cf(method, path, body) {
  if (!env.CLOUDFLARE_API_TOKEN) throw new Error("no CLOUDFLARE_API_TOKEN in this build: live production state cannot be read");
  const r = await fetch(`${CF_API}${path}`, { method, headers: { Authorization: `Bearer ${env.CLOUDFLARE_API_TOKEN}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(30000) });
  const b = await r.json().catch(() => null);
  if (!r.ok || !b?.success) throw new Error(`Cloudflare API ${method} ${path}: ${r.status}`);
  return b.result;
}
// The account that owns the Worker: its config, CLOUDFLARE_ACCOUNT_ID, else the one account the build's token can see.
let discovered;
async function accountOf(cfg) {
  const id = cfg.account_id || env.CLOUDFLARE_ACCOUNT_ID;
  if (id) return id;
  const accounts = discovered ??= await cf("GET", "/accounts");
  if (accounts.length !== 1) throw new Error("cannot tell which Cloudflare account owns this Worker: set CLOUDFLARE_ACCOUNT_ID");
  return accounts[0].id;
}
const sameSet = (a, b) => a.length === b.length && a.every((x) => b.includes(x));

// Does this Worker need a full `wrangler deploy` instead of a version? Cloudflare cannot upload a version that creates, deletes, renames
// or transfers a Durable Object class (exports or migrations), so the answer comes from production's LIVE state: the script's
// `migration_tag` in the Workers scripts list (https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/list/)
// against the config's last migration tag; a Worker with DO `exports` always does (Cloudflare reconciles those on every deploy).
// Unreadable live state throws: it is never taken for "none".
async function needsFullDeploy(name, cfg) {
  const lc = doLifecycle(cfg);
  if (lc.exports) return "it declares Durable Object exports";
  if (!lc.tag) return null;
  const script = (await cf("GET", `/accounts/${await accountOf(cfg)}/workers/scripts`)).find((s) => s.id === name);
  if (!script) throw new Error(`${name} is not in the Cloudflare account's scripts, so its live migration state is unknown`);
  return (script.migration_tag ?? null) === lc.tag ? null : `migration ${lc.tag} is not applied in production (live: ${script.migration_tag ?? "none"})`;
}

// Declared Worker-level settings that `versions upload` never applies, compared with production's live ones. Triggers (crons, queue
// consumers, routes, custom domains) are applied by `wrangler triggers deploy`; observability, logpush and tail consumers by the Worker
// settings API (https://developers.cloudflare.com/workers/configuration/multipart-upload-metadata/ lists logpush and tail_consumers as
// not available to version uploads; https://developers.cloudflare.com/workers/versions-and-deployments/deployment-management/ sends
// routes, domains and crons to `triggers deploy`). Routes cannot be read without a zone, so a Worker that declares them, or declares an empty `routes`, always re-applies.
async function settingsDrift(name, cfg) {
  const account = await accountOf(cfg), drift = [], base = `/accounts/${account}/workers`;
  let triggers = false;
  if (Array.isArray(cfg.triggers?.crons)) {
    const live = (await cf("GET", `${base}/scripts/${name}/schedules`)).schedules?.map((s) => s.cron) ?? [];
    if (!sameSet(live, cfg.triggers.crons)) { drift.push(`cron triggers [${live}] -> [${cfg.triggers.crons}]`); triggers = true; }
  }
  const declared = [...(cfg.routes ?? []), ...(cfg.route ? [cfg.route] : [])];
  const domains = declared.filter((r) => r?.custom_domain).map((r) => r.pattern);
  // `routes`/`route` present in the config, even empty, is the source of truth: removals must reach production too.
  const explicit = "routes" in cfg || "route" in cfg;
  if (domains.length || explicit) {
    const live = (await cf("GET", `${base}/domains?service=${encodeURIComponent(name)}`)).map((d) => d.hostname);
    if (!sameSet(live, domains)) { drift.push(`custom domains [${live}] -> [${domains}]`); triggers = true; }
  }
  const consumers = (Array.isArray(cfg.queues?.consumers) ? cfg.queues.consumers : []).map((c) => c?.queue).filter(Boolean);
  if (consumers.length) {
    const queues = await cf("GET", `/accounts/${account}/queues`);
    for (const queue of consumers) {
      const q = queues.find((x) => x.queue_name === queue);
      const has = q && (await cf("GET", `/accounts/${account}/queues/${q.queue_id}/consumers`)).some((c) => (c.script ?? c.script_name) === name);
      if (!has) { drift.push(`queue consumer for ${queue} is not registered`); triggers = true; }
    }
  }
  // Zone routes cannot be read without a zone: a declared one, or an explicitly empty list (a removal), always re-applies.
  const routes = declared.some((r) => typeof r === "string" || (r && !r.custom_domain)) || (explicit && declared.length === 0);
  const live = cfg.observability || typeof cfg.logpush === "boolean" || cfg.tail_consumers ? await cf("GET", `${base}/scripts/${name}/script-settings`) : {}, patch = {};
  const o = cfg.observability, enabled = o?.enabled ?? o?.logs?.enabled;
  if (o && ((enabled !== undefined && live.observability?.enabled !== enabled) || (o.head_sampling_rate !== undefined && live.observability?.head_sampling_rate !== o.head_sampling_rate))) {
    patch.observability = o;
    drift.push(`observability enabled=${live.observability?.enabled ?? false} -> ${enabled}`);
  }
  if (typeof cfg.logpush === "boolean" && (live.logpush ?? false) !== cfg.logpush) { patch.logpush = cfg.logpush; drift.push(`logpush ${live.logpush ?? false} -> ${cfg.logpush}`); }
  if (Array.isArray(cfg.tail_consumers)) {
    const want = cfg.tail_consumers.map((t) => t.service), have = (live.tail_consumers ?? []).map((t) => t.service);
    if (!sameSet(have, want)) { patch.tail_consumers = cfg.tail_consumers; drift.push(`tail consumers [${have}] -> [${want}]`); }
  }
  return { drift, triggers: triggers || routes, routes, patch: Object.keys(patch).length ? patch : null };
}

// Sentry: when the build has the SENTRY_AUTH_TOKEN secret and the repo was set up with sentry-setup (the public DSN it commits
// is in the Worker config), create the release for the commit after the Worker uploads succeeded and upload the source maps of
// the primary's final bundle: its production `versions upload` writes the bundle and maps to a clean --outdir with
// --upload-source-maps (https://developers.cloudflare.com/workers/wrangler/commands/workers/: "--outdir: Output directory for
// the bundled Worker", "--upload-source-maps: Include source maps when uploading this Worker"), never framework build directories.
// Org comes from pack.json, the project from the DSN's project id. A repository not set up for Sentry prints nothing; one set up but without the token prints one notice. Every Sentry request and
// the sentry-cli run are bounded (RELEASE_SENTRY_TIMEOUT_S, default 60): an expiry or any failure is a warning, and the
// already-finished release exits 0.
const SENTRY_MS = Number(env.RELEASE_SENTRY_TIMEOUT_S ?? 60) * 1000;
function sentryPlan(file) {
  const et = json(fileURLToPath(new URL("pack.json", import.meta.url)))?.modules?.error_tracker;
  const dsn = (() => { try { const v = readConfig(file)?.vars?.SENTRY_DSN; return typeof v === "string" && /^https:\/\/[^/]+\/\d+$/.test(v) ? v : null; } catch { return null; } })();
  if (et?.kind !== "sentry" || !et.org || !dsn) return null; // not set up for Sentry: nothing Sentry-related is printed
  const token = env.SENTRY_AUTH_TOKEN;
  if (!token) { console.log("release: Sentry skipped: no SENTRY_AUTH_TOKEN build secret (set it once on the Builds trigger to create Sentry releases)"); return null; }
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
// A declared Worker requires what its own config lists: a repository-wide list cannot know which Worker needs which secret.
const required = [...new Set([...(Array.isArray(secrets.required) && !declared ? secrets.required : []), ...wranglerRequired])].filter((s) => typeof s === "string" && s);
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

// The part of the staging validation a deploy must not skip: nothing non-production names a production resource.
const isolationFindings = (worker, productionConfigs) => stagingFindings(worker.cfg, { file: worker.file, std: { staging: true }, productionConfigs })
  .fails.filter(([message]) => /names the production resource|consumes the production queue/.test(message)).map(([message]) => message);

// Pending D1 migrations for the databases the `previews` block dedicates to Previews, applied before the Preview deploys. Wrangler's d1
// commands read only a config's top-level d1_databases, never `previews`, so those bindings are written to a generated config (absolute
// migrations_dir, account_id copied) that the apply is pointed at. A database that is a production database of any Worker is refused;
// one that is a staging database of any Worker (or the database of the legacy staging Preview, which has no env.staging) is never migrated
// here: main migrates staging.
function migratePreviewDatabases(dir, cfg) {
  const dbs = (c) => (Array.isArray(c?.d1_databases) ? c.d1_databases.filter((d) => d && typeof d === "object") : []);
  const same = (a, b) => (a.database_id && a.database_id === b.database_id) || (a.database_name && a.database_name === b.database_name);
  const workers = declared ? declared.flatMap((w) => [w.cfg, ...w.extraConfigs]) : [cfg];
  const production = workers.flatMap(dbs);
  const staging = workers.flatMap((w) => (w.env?.staging ? dbs(w.env.staging) : dbs(w.previews)));
  const dedicated = [];
  for (const d of dbs(cfg.previews)) {
    const hit = production.find((p) => same(d, p));
    if (hit) fail(`previews d1_databases ${d.binding ?? ""} names the production resource ${hit.database_id ?? hit.database_name}`, "bind a Preview database of its own, or staging's; Previews never reach production");
    if (typeof d.database_id === "string" && d.binding && !staging.some((x) => same(d, x))) dedicated.push(d);
  }
  const pending = dedicated.map((d) => ({ ...d, migrations_dir: resolve(dirname(configFile), d.migrations_dir ?? "migrations") })).filter((d) => existsSync(d.migrations_dir));
  if (!pending.length) return;
  const file = join(dir, "preview-d1.json");
  writeFileSync(file, JSON.stringify({ ...(cfg.account_id ? { account_id: cfg.account_id } : {}), d1_databases: pending }));
  for (const d of pending) must(["d1", "migrations", "apply", d.binding, "--remote", "--config", file]);
}

async function deploy() {
  // The secrets file goes with its directory on every exit, including a failed step's process.exit.
  const dir = mkdtempSync(join(tmpdir(), "release-"));
  process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
  {
    if (RELEASE_SHA) return promote(RELEASE_SHA);
    if (cmd === "preview") {
      // A Preview inherits no top-level secrets (Wrangler reads previews.secrets.required), and the vault's staging secrets must not land on a PR
      // Preview, which runs unreviewed code: a config with previews.secrets.required, even empty, supplies and verifies exactly that list.
      const pc = configFile && !configFile.endsWith(".toml") ? parse(readFileSync(configFile, "utf8")) : null;
      const previewNames = Array.isArray(pc?.previews?.secrets?.required) ? [...new Set(pc.previews.secrets.required.filter((s) => typeof s === "string" && s))] : required;
      const f = await secretsFile(dir, previewNames), sf = f ? ["--secrets-file", f] : [];
      const branch = env.WORKERS_CI_BRANCH || execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim(), name = slug(branch);
      if (!name || name === "staging") fail(`branch ${branch} has no usable Preview name (${name || "empty"})`, "rename the branch");
      const cfg = config();
      // A declared Worker's Preview is held to the staging isolation too, against every declared Worker's production resources.
      if (declared) {
        const isolation = isolationFindings({ file: configFile, cfg: readConfig(configFile) }, declared.flatMap((w) => [w.cfg, ...w.extraConfigs]));
        if (isolation.length) throw new Error(isolation.join("; "));
      }
      migratePreviewDatabases(dir, cfg);
      must(["preview", "--name", name, ...leadArgs, ...sf]);
      secretCheck(`Preview ${name}`, ["preview", "secret", "list", "--name", name, ...leadArgs, "--json"], previewNames);
      return;
    }
    const cfg = config(), staged = Boolean(cfg.env?.staging);
    const extras = supportingFiles().map((file) => ({ file, cfg: readConfig(file) }));
    assertReleaseAccounts(cfg, [cfg, ...extras.map((worker) => worker.cfg)]);
    const productionName = env.WRANGLER_CI_OVERRIDE_NAME || cfg.name;
    // Every declared Worker is production to this one's staging: its resources are never staging's either.
    const productionConfigs = [cfg, ...extras.map((w) => w.cfg), { name: productionName }, ...(declared ?? []).filter((w) => w !== lead).flatMap((w) => [w.cfg, ...w.extraConfigs])];
    for (const worker of [...(staged ? [{ file: configFile, cfg }] : []), ...extras]) {
      const isolation = isolationFindings(worker, productionConfigs);
      if (isolation.length) throw new Error(isolation.join("; "));
    }
    const builtProduction = buildProductionConfigs(buildStd, pkg, [{ file: configFile, cfg, primary: true, redirect: leadRedirect }, ...extras]);
    productionConfigs.push(...builtProduction);
    if (!staged) {
      const preview = builtProduction[0].previews ?? {};
      const isolation = resourceFindings({ ...preview, migrations: preview.migrations ?? builtProduction[0].migrations }, productionConfigs);
      if (isolation.length) throw new Error(`unsafe staging Preview resources: ${isolation.join("; ")}`);
    }
    if (staged) build(buildStd, pkg, true);
    // Validate every staging target before deploying any of them. Secondary explicit configs
    // bypass the primary adapter redirect, exactly as Wrangler -c does.
    // Supporting Workers (release_workers) go first, in their listed order, then the primary: the primary binds Durable Objects and
    // Workflows that live on them, so a new class must exist there before the primary's deploy needs it.
    const targets = [...extras, ...(staged ? [{ file: configFile, cfg, primary: true, redirect: leadRedirect }] : [])].map((worker) => {
      const resolved = effectiveConfig(worker.file, true, { redirect: worker.redirect ?? Boolean(worker.primary) });
      const name = assertStaging(worker.cfg, resolved, productionConfigs);
      const configArgs = resolved.redirected ? [] : ["--config", resolved.file];
      const names = worker.primary ? required : [...new Set((Array.isArray(worker.cfg.secrets?.required) ? worker.cfg.secrets.required : []).filter((name) => typeof name === "string" && name))];
      return { ...worker, resolved, name, configArgs, names };
    });
    // A Worker whose Durable Object lifecycle differs from production's live state cannot be uploaded as a version: promote deploys it.
    const noUpload = new Map();
    const productionNames = [productionName, ...extras.map((w) => w.cfg.name)];
    for (const [i, c] of builtProduction.entries()) {
      const why = await needsFullDeploy(productionNames[i], c);
      if (why) noUpload.set(productionNames[i], why);
    }
    state.stagingPlan = [...targets.map((t) => t.name), ...(staged ? [] : ["the staging Preview"])];
    state.productionPlan = [...extras.map((w) => w.cfg.name), productionName].filter((n) => !noUpload.has(n));
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
      must(["preview", "--name", "staging", ...leadArgs, ...sf]);
      state.staged.push("the staging Preview");
      secretCheck("the staging Preview", ["preview", "secret", "list", "--name", "staging", ...leadArgs, "--json"]);
    }
    build(buildStd, pkg);
    const production = effectiveConfig(configFile, false, { redirect: leadRedirect });
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
      if (noUpload.has(name)) { console.log(`release: no production version uploaded for ${name}: ${noUpload.get(name)}; promote deploys it in full`); return; }
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
    upload(productionName, ["versions", "upload", ...leadArgs, ...(outdir ? ["--outdir", outdir, "--upload-source-maps"] : []), ...tags]);
    secretCheck("the production Worker", ["secret", "list", ...leadArgs, "--name", productionName, "--format", "json"]);
    state.done = true;
    // Settings a version upload never applies: warn where live production differs from the config (read-only; promote applies them).
    if (!env.CLOUDFLARE_API_TOKEN) console.log("release: settings drift not checked: no CLOUDFLARE_API_TOKEN in this build");
    else for (const [i, c] of builtProduction.entries()) {
      if (noUpload.has(productionNames[i])) continue;
      try {
        const d = await settingsDrift(productionNames[i], c);
        if (d.drift.length) console.log(`::warning::production ${productionNames[i]} differs from its config: ${d.drift.join("; ")} | fix: promotion applies these (wrangler triggers deploy, Worker settings API)`);
      } catch (e) { console.log(`::warning::production ${productionNames[i]} settings drift not checked: ${e.message}`); }
    }
    if (sentry) await sentryRelease(sha, sentry, outdir);
  }
}

// promote <sha>: a production release of a commit a person approved in the portal, run by the Workers Builds preview trigger on the branch
// release/<sha> (the portal App created it pointing at a commit already on main; the build checked out and built exactly that commit
// with this Worker's own Builds variables, so nothing is rebuilt here). No GitHub token exists in the build: the portal ran the
// release-check before it created the branch, and main's own record is the evidence below. Everything is verified and validated before
// the first remote change; then the pending production D1 migrations are applied, and each Worker is deployed (supporting Workers in
// release_workers order, the primary last): a version deploy of the version main uploaded for this commit, or a full `wrangler deploy`
// where production's live Durable Object state needs one; then its triggers and settings.
async function promote(sha) {
  const short = sha.slice(0, 7), git = (...a) => spawnSync("git", a, { encoding: "utf8" });
  if (env.WORKERS_CI_COMMIT_SHA !== sha || git("rev-parse", "HEAD").stdout.trim() !== sha)
    fail(`the release branch names ${short} but this build is of ${(env.WORKERS_CI_COMMIT_SHA ?? "no commit").slice(0, 7)}`, "the portal creates release/<sha> pointing at <sha> and starts nothing else; delete the branch and approve the version again");
  config();
  const primary = effectiveConfig(configFile, false, { redirect: leadRedirect });
  const extras = supportingFiles().map((file) => ({ file, cfg: effectiveConfig(file, false, { redirect: false }).cfg }));
  assertReleaseAccounts(primary.cfg, [primary.cfg, ...extras.map((w) => w.cfg)]);
  // Builds sets WRANGLER_CI_OVERRIDE_NAME for the production trigger only; a name that disagrees with the config is not guessed at.
  if (env.WRANGLER_CI_OVERRIDE_NAME && env.WRANGLER_CI_OVERRIDE_NAME !== primary.cfg.name)
    fail(`this build renames the Worker (WRANGLER_CI_OVERRIDE_NAME=${env.WRANGLER_CI_OVERRIDE_NAME}, config ${primary.cfg.name})`, "promote deploys the names in the commit's wrangler configs");
  const workers = [...extras.map((w) => ({ name: w.cfg.name, cfg: w.cfg, file: w.file, cfgArgs: ["--config", w.file] })),
    { name: primary.cfg.name, cfg: primary.cfg, file: primary.file, cfgArgs: leadArgs }];

  // 1. Production's live state is readable, and main released this commit: each Worker that deploys as a version has the version main
  //    uploaded for it (tagged with the commit), and a commit no Worker has a version for (all deploy in full) is an ancestor of main
  //    in the checkout's git history. Anything unproven refuses.
  const plan = [];
  for (const w of workers) {
    const full = await needsFullDeploy(w.name, w.cfg);
    const version = full ? null : await uploadedVersion(w, sha);
    if (!full && !version) fail(`${w.name} has no uploaded version for ${short}`, "main uploads it; approve a commit whose main build succeeded");
    plan.push({ ...w, full, version });
  }
  if (plan.every((w) => w.full)) {
    const why = gitProof(sha, git);
    if (why) fail(`cannot prove ${short} came from main: no Worker has a version uploaded for it and ${why}`, "approve a commit whose main build uploaded a version, or make main's history available to the build");
  }

  // 2. Every Worker's bundle validates (wrangler deploy --dry-run, production config) and every live read succeeds before anything changes.
  for (const w of plan) {
    const r = wrangler(["deploy", "--dry-run", ...w.cfgArgs, "--name", w.name], { capture: true });
    if (r.status) { process.stdout.write(r.out); fail(`${w.name} does not bundle with its production config; nothing was deployed`, "fix the build and approve a new commit"); }
    if (!w.full) w.settings = await settingsDrift(w.name, w.cfg);
  }

  const done = [], report = [];
  process.on("exit", (code) => {
    if (code && done.length) console.log(`::error::promotion incomplete: Workers are in a mixed state\n  promoted: ${done.join(", ")}\n  not promoted: ${plan.map((w) => w.name).filter((n) => !done.includes(n)).join(", ")}\n  Approve ${short} again to promote the rest; nothing was rolled back.`);
  });

  // 3. Pending production D1 migrations, before any code that needs them.
  for (const w of plan) for (const d of Array.isArray(w.cfg.d1_databases) ? w.cfg.d1_databases : []) {
    if (!d?.binding || !existsSync(resolve(dirname(w.file), d.migrations_dir ?? "migrations"))) continue;
    const r = wrangler(["d1", "migrations", "apply", d.binding, ...w.cfgArgs, "--remote"], { capture: true });
    process.stdout.write(r.out);
    if (r.status) process.exit(r.status);
    report.push(`${w.name}: D1 ${d.binding}: ${/No migrations to apply/i.test(r.out) ? "no pending migrations" : "migrations applied"}`);
  }

  // 4. Supporting Workers first, then the primary: a version deploy (or a full deploy), then triggers and settings.
  for (const w of plan) {
    if (w.full) {
      const tags = ["--tag", sha, "--message", `promote ${sha}`, "--var", `SENTRY_RELEASE:${sha}`];
      const r = wrangler(["deploy", ...w.cfgArgs, "--name", w.name, ...tags], { capture: true });
      process.stdout.write(r.out);
      if (r.status) process.exit(r.status);
      report.push(`${w.name}: full wrangler deploy of ${short} (${w.full}); triggers and settings applied by the deploy`);
    } else {
      must(["versions", "deploy", `${w.version}@100%`, ...w.cfgArgs, "--name", w.name, "--yes", "--message", `promote ${sha}`]);
      report.push(`${w.name}: version ${w.version} deployed`);
      const s = w.settings;
      if (s.triggers) {
        const r = wrangler(["triggers", "deploy", ...w.cfgArgs, "--name", w.name], { capture: true });
        process.stdout.write(r.out);
        if (r.status) process.exit(r.status);
      }
      if (s.patch) await cf("PATCH", `/accounts/${await accountOf(w.cfg)}/workers/scripts/${w.name}/script-settings`, s.patch);
      report.push(`${w.name}: ${s.drift.length ? `applied ${s.drift.join("; ")}` : "settings already match"}${s.routes ? "; routes re-applied" : ""}`);
    }
    done.push(w.name);
  }
  console.log(`release: promoted ${short} to production\n  ${report.join("\n  ")}`);
}

// The version main's release uploaded for the commit (its `workers/tag` annotation is the full sha; main passes `--tag <sha>`), from the
// Worker's versions in the Cloudflare API, which pages 10 at a time unless per_page is set.
async function uploadedVersion(w, sha) {
  const account = await accountOf(w.cfg);
  for (let page = 1; ; page++) {
    const items = (await cf("GET", `/accounts/${account}/workers/scripts/${w.name}/versions?per_page=100&page=${page}`)).items ?? [];
    const hit = items.find((v) => v?.annotations?.["workers/tag"] === sha);
    if (hit) return hit.id;
    if (items.length < 100) return null;
  }
}

// Without a version to look for, the evidence is git's: the commit is an ancestor of main in the build checkout's history, after a fetch of main
// from the remote the checkout came from (readable in a Builds checkout with no GitHub token; a remote that needs one refuses). "" when proven,
// else why not. A shallow checkout that cannot reach the commit from main refuses; it never passes.
function gitProof(sha, git) {
  // Workers Builds clones shallow (depth 1, one remote `origin`, readable without a token: `git fetch origin main` succeeded in a live build), so
  // main's whole history is fetched with --unshallow; proven live: afterwards an older main commit is an ancestor of origin/main.
  const shallow = git("rev-parse", "--is-shallow-repository").stdout.trim() === "true";
  const fetched = git("fetch", "--no-tags", "--quiet", ...(shallow ? ["--unshallow"] : []), "origin", "+refs/heads/main:refs/remotes/origin/main");
  const r = git("merge-base", "--is-ancestor", sha, "refs/remotes/origin/main");
  if (r.status === 0) return "";
  if (r.status === 1) return "it is not in main's history";
  return `main's history is not in the build's checkout (${(fetched.stderr || r.stderr || "git failed").trim().split("\n")[0]})`;
}

// Delete Previews whose pull request closed: one branch's (--pr-branch), or every pull request closed in the last 30
// days (--sweep), except a branch an open pull request still uses. Never the legacy "staging" Preview; a Preview
// already gone is fine.
async function cleanup() {
  if (!declared) config();
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
  // A Preview belongs to a Worker: each declared Worker's is deleted with its own config, from the repository root.
  const owners = declared ? declared.map((w) => ({ args: ["--config", w.file], of: ` of ${w.name}` })) : [{ args: [], of: "" }];
  for (const name of [...names].filter(Boolean).sort()) {
    if (keep.has(name)) { console.log(`cleanup: keep ${name} (${name === "staging" ? "staging" : "an open pull request uses it"})`); continue; }
    for (const owner of owners) {
      const r = wrangler(["preview", "delete", "--name", name, "--skip-confirmation", ...owner.args], { capture: true });
      if (!r.status) console.log(`cleanup: deleted Preview ${name}${owner.of}`);
      else if (/not (been )?found|does not exist/i.test(r.out)) console.log(`cleanup: Preview ${name}${owner.of} is already gone`);
      else { process.stdout.write(r.out); console.log(`::error::could not delete Preview ${name}${owner.of}`); bad++; }
    }
  }
  if (bad) process.exit(1);
  console.log(`cleanup: ${names.size ? "done" : "no closed pull requests"}`);
}

try { await (cmd === "cleanup" ? cleanup() : deploy()); }
catch (e) { fail(e.message, RELEASE_SHA ? "nothing was deployed unless the report above says so; fix the cause and approve the version again" : "fix the build/config before retrying; staging must target only <production name>-staging with no production routes or custom domains"); }
