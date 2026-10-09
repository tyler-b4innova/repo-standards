#!/usr/bin/env node
// Workers Builds deploy commands and PR Preview clean-up (the Worker's trigger settings call these):
//   main      production trigger: deploy the staging Worker (wrangler deploy --env staging), upload the production version
//   preview   preview trigger: deploy this branch's Preview (wrangler preview --name <slug>)
//   promote <sha>                          make that commit's uploaded version live (a version deploy, or a full deploy for a Durable Object migration)
//   slug <branch>                          the Preview name for a branch
//   cleanup --pr-branch <branch> | --sweep  delete a closed pull request's Preview (std-preview-cleanup.yml)
// Secrets (standards.json "secrets": {"required": [...], "store": "1password" | "secrets_store"}) are re-supplied on every
// staging and Preview deploy (a Preview drops secrets set on it when it is redeployed), and a deployed Worker missing a
// required secret fails the build. Secret values are never printed.
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { parse, findings as stagingFindings, resourceFindings } from "./staging.mjs";
import { build, installBuildDependencies, parseConfigText, rootFile, readConfig, effectiveConfig, assertStaging, assertReleaseAccounts, workerFiles, buildProductionConfigs } from "./release-config.mjs";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["main", "preview", "slug", "cleanup", "verify-release-check", "promote"];
if (!SUBS.includes(cmd) || args.includes("--help")) {
  console.log(readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 7).map((l) => l.slice(3)).join("\n"));
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

// A Workers Builds trigger runs from its root directory. A Worker that keeps its own config there (workers/<name>/wrangler.jsonc)
// is released from that directory; anywhere else the repository root is used, as before. standards.json is the repository's.
const here = process.cwd();
let top = here;
try { top = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: "pipe" }).trim(); } catch {}
if (!rootFile() && top !== here) process.chdir(top);
const std = json(join(top, "standards.json")) ?? {};
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

// Durable Object lifecycle. A commit changes it when its Worker config's `migrations` tags or the Durable Object entries of the
// declarative `exports` field differ from the commit before it. Cloudflare cannot upload such a version (`versions upload`
// fails); only a full `wrangler deploy` applies it. So the main release does not upload a production version for a Worker whose
// commit changes it (staging, which deploys normally, applies it), and `promote` deploys that exact commit. What a commit
// carries is read from git, never assumed: an unreadable commit or config is an error, not "no migration".
const topGit = (...a) => execFileSync("git", a, { encoding: "utf8", stdio: "pipe", cwd: top });
const showAt = (rev, path) => { try { return topGit("show", `${rev}:${path}`); } catch { return null; } };
const hasCommit = (rev) => { try { topGit("cat-file", "-e", `${rev}^{commit}`); return true; } catch { return false; } };
function lifecycleEntries(text, path) {
  const cfg = parseConfigText(text, path.endsWith(".toml"), path), out = new Set();
  for (const m of Array.isArray(cfg.migrations) ? cfg.migrations : []) if (typeof m?.tag === "string" && m.tag) out.add(`migration ${m.tag}`);
  for (const [name, e] of Object.entries(cfg.exports && typeof cfg.exports === "object" ? cfg.exports : {}))
    if (e?.type === "durable-object") out.add(`export ${name} ${e.storage ?? ""} ${e.state ?? "created"}`);
  return out;
}
// The labels that differ between the config at `path` in `rev` and in its first parent; throws when that cannot be established.
function lifecycleChange(path, rev) {
  if (!hasCommit(rev)) throw new Error(`commit ${rev.slice(0, 7)} is not readable here`);
  let now = showAt(rev, path), untracked = false;
  // The build's own checkout can hold a config git does not track (generated): it can be read, but not compared with a previous one.
  if (now === null && rev === "HEAD" && existsSync(resolve(top, path))) { now = readFileSync(resolve(top, path), "utf8"); untracked = true; }
  if (now === null) throw new Error(`${path} is not readable at ${rev.slice(0, 7)}`);
  const cur = lifecycleEntries(now, path);
  if (untracked) { if (cur.size) throw new Error(`${path} is not tracked by git, so what it changes cannot be established`); return []; }
  // A shallow clone's boundary commit lists no parents, which is not the same as having none.
  const boundary = (r) => { try { return topGit("rev-parse", "--is-shallow-repository").trim() === "true" && readFileSync(resolve(top, topGit("rev-parse", "--git-path", "shallow").trim()), "utf8").split("\n").includes(topGit("rev-parse", r).trim()); } catch { return false; } };
  if (boundary(rev)) { try { topGit("fetch", "--quiet", "--deepen=1"); } catch {} }
  const parents = topGit("rev-list", "--parents", "-n", "1", rev).trim().split(" ").slice(1);
  let before = new Set();
  if (boundary(rev)) { if (cur.size) throw new Error(`${rev.slice(0, 7)} is a shallow-clone boundary, so what ${path} changes cannot be established`); }
  else if (parents.length) {
    if (!hasCommit(parents[0])) { try { topGit("fetch", "--quiet", "--deepen=1"); } catch {} }
    if (hasCommit(parents[0])) { const prev = showAt(parents[0], path); before = prev === null ? new Set() : lifecycleEntries(prev, path); }
    else if (cur.size) throw new Error(`the parent of ${rev.slice(0, 7)} is not readable here (shallow clone?), so what ${path} changes cannot be established`);
  }
  return [...cur].filter((t) => !before.has(t)).concat([...before].filter((t) => !cur.has(t)));
}

// Sentry: when the build has the SENTRY_AUTH_TOKEN secret and the repo was set up with sentry-setup (the public DSN it commits
// is in the Worker config), create the release for the commit and upload source maps. Org comes from pack.json, the project from
// the DSN's project id. Without the token this is one notice; a failure is a warning (the version is already uploaded).
async function sentryRelease(sha, file) {
  const token = env.SENTRY_AUTH_TOKEN;
  if (!token) { console.log("release: Sentry skipped: no SENTRY_AUTH_TOKEN build secret (set it once on the Builds trigger to create Sentry releases)"); return; }
  const et = json(fileURLToPath(new URL("pack.json", import.meta.url)))?.modules?.error_tracker;
  const dsn = (() => { try { const v = parse(readFileSync(file, "utf8"))?.vars?.SENTRY_DSN; return typeof v === "string" && /^https:\/\/[^/]+\/\d+$/.test(v) ? v : null; } catch { return null; } })();
  if (et?.kind !== "sentry" || !et.org || !dsn) { console.log("release: Sentry skipped: this repository is not set up for Sentry (scripts/agent/sentry-setup commits the DSN)"); return; }
  const base = String(et.api_base ?? "https://sentry.io").replace(/\/$/, ""), headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  try {
    const projectId = dsn.split("/").pop(), pr = await fetch(`${base}/api/0/projects/${et.org}/${projectId}/`, { headers });
    if (!pr.ok) throw new Error(`project ${projectId}: ${pr.status}`);
    const project = (await pr.json()).slug;
    const rel = await fetch(`${base}/api/0/organizations/${et.org}/releases/`, { method: "POST", headers, body: JSON.stringify({ version: sha, projects: [project] }) });
    if (!rel.ok && rel.status !== 208) throw new Error(`create release: ${rel.status}`);
    console.log(`release: Sentry release ${sha.slice(0, 7)} created for ${et.org}/${project}`);
    const cli = ["node_modules/.bin/sentry-cli"].find(existsSync), dirs = ["dist", ".svelte-kit/cloudflare", ".svelte-kit/output", ".open-next", "build"].filter((d) => existsSync(d));
    if (!cli || !dirs.length) { console.log("release: Sentry: no sentry-cli in node_modules or no build output directory; source maps not uploaded"); return; }
    const r = spawnSync(cli, ["sourcemaps", "upload", "--org", et.org, "--project", project, "--release", sha, ...dirs], { stdio: "inherit", env: { ...env, SENTRY_URL: base } });
    console.log(r.status === 0 ? "release: Sentry source maps uploaded" : `::warning::Sentry source map upload failed (exit ${r.status ?? 1}); the release exists without them`);
  } catch (e) { console.log(`::warning::Sentry release skipped: ${e.message}`); }
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
      secretCheck("the staging Worker", stagingCommand(name, resolved, ["secret", "list", ...configArgs, "--name", name, "--format", "json"]), names);
    }
    if (!staged) {
      console.log(`::warning::${configFile} has no env.staging; deploying staging as the legacy "staging" Preview. Add env.staging (a separate <name>-staging Worker with its own data): see the standards README`);
      must(["preview", "--name", "staging", ...sf]);
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
    // A Worker whose commit changes Durable Object lifecycle gets no production version: Cloudflare cannot upload one.
    const uploadTags = sha ? ["--tag", sha, "--message", `main ${sha}`, "--var", `SENTRY_RELEASE:${sha}`] : [];
    const migrating = (file) => {
      let change;
      try { change = lifecycleChange(relative(top, resolve(file)).split(sep).join("/"), "HEAD"); }
      catch (e) { fail(`cannot tell whether ${file} changes Durable Object lifecycle: ${e.message}`, "fetch more history (git fetch --deepen=1) or re-run; the release will not guess"); }
      if (change.length) console.log(`::notice::${file} changes Durable Object lifecycle (${change.join("; ")}): staging applied it with its normal deploy; NO production version is uploaded for ${sha ?? "this commit"}. Production goes live only through \`release.mjs promote ${sha ?? "<sha>"}\`, which runs wrangler deploy of this exact commit.`);
      return change.length > 0;
    };
    for (const worker of extras) {
      if (!migrating(worker.file)) must(["versions", "upload", "-c", worker.file, "--name", worker.cfg.name, ...uploadTags]);
      const names = [...new Set((Array.isArray(worker.cfg.secrets?.required) ? worker.cfg.secrets.required : []).filter((name) => typeof name === "string" && name))];
      secretCheck("the production Worker", ["secret", "list", "--config", worker.file, "--name", worker.cfg.name, "--format", "json"], names);
    }
    if (!migrating(configFile)) must(["versions", "upload", ...uploadTags]);
    secretCheck("the production Worker", ["secret", "list", "--name", productionName, "--format", "json"]);
    if (sha) await sentryRelease(sha, configFile);
  }
}

// promote <sha>: make that commit's production release live, the right way for what each Worker carries. A Worker whose commit
// changes Durable Object lifecycle goes live through a full `wrangler deploy` of that exact commit, built in a fresh isolated
// checkout of it (never the caller's working tree); any other Worker goes live by a version deploy of its uploaded version.
// Everything is resolved and checked before any remote change; supporting Workers (release_workers) go first in listed order,
// the primary last, as in the release. It does not verify the release-check (verify-release-check does).
async function promote() {
  const sha = args[0] ?? "";
  if (!/^[0-9a-f]{40}$/.test(sha)) fail(`promote needs the version's full 40-character lowercase hex commit sha (got ${JSON.stringify(sha)})`, "release.mjs promote <sha>");
  const refuse = (what) => fail(`cannot promote ${sha.slice(0, 7)}: ${what}`, "nothing was changed; fix it and run promote again");
  if (!hasCommit(sha)) refuse("the commit is not readable here (git fetch origin " + sha + ")");
  const rel = relative(top, process.cwd()).split(sep).join("/"), at = (p) => (rel ? `${rel}/${p}` : p);
  const primaryPath = ["wrangler.json", "wrangler.jsonc", "wrangler.toml"].map(at).find((p) => showAt(sha, p) !== null);
  if (!primaryPath) refuse(`no Wrangler config in ${rel || "the repository root"} at that commit`);
  let stdAt = {};
  const stdText = showAt(sha, "standards.json");
  if (stdText !== null) { try { stdAt = JSON.parse(stdText); } catch { refuse("standards.json at that commit is not valid JSON"); } }
  const listed = stdAt.release_workers === undefined ? [] : stdAt.release_workers;
  if (!Array.isArray(listed) || listed.some((f) => typeof f !== "string" || !f || f.startsWith("/") || f.split(/[\\/]/).includes("..") || !/\.(jsonc?|toml)$/.test(f))) refuse("standards.json release_workers at that commit is not a list of relative config paths");
  const plan = [...listed.map((f) => ({ path: at(f).replace(/\/\.\//g, "/"), primary: false })), { path: primaryPath, primary: true }];
  for (const w of plan) {
    const text = showAt(sha, w.path);
    if (text === null) refuse(`${w.path} is not readable at that commit`);
    try { w.cfg = parseConfigText(text, w.path.endsWith(".toml"), w.path); w.change = lifecycleChange(w.path, sha); } catch (e) { refuse(e.message); }
    if (typeof w.cfg.name !== "string" || !w.cfg.name) refuse(`${w.path} names no Worker`);
    w.name = w.primary ? (env.WRANGLER_CI_OVERRIDE_NAME || w.cfg.name) : w.cfg.name;
    w.local = relative(rel || ".", w.path).split("/").join(sep); // the config as seen from the trigger's root directory
  }
  // ordinary Workers: exactly one uploaded version tagged with the commit
  for (const w of plan.filter((x) => !x.change.length)) {
    const listedVersions = wrangler(["versions", "list", "--name", w.name, "--json"], { capture: true });
    if (listedVersions.status) { process.stdout.write(listedVersions.out); refuse(`could not list the versions of ${w.name}`); }
    let versions = null;
    const end = listedVersions.out.lastIndexOf("]") + 1;
    for (let i = listedVersions.out.indexOf("["); i >= 0 && !versions; i = listedVersions.out.indexOf("[", i + 1)) { try { const v = JSON.parse(listedVersions.out.slice(i, end)); if (Array.isArray(v)) versions = v; } catch {} }
    const found = (versions ?? []).filter((v) => Object.entries(v.annotations ?? {}).some(([k, val]) => /tag$/.test(k) && val === sha));
    if (found.length !== 1) refuse(`${w.name}: ${found.length ? "more than one" : "no"} uploaded version is tagged ${sha.slice(0, 7)}`);
    w.versionId = found[0].id;
  }
  // migrating Workers: a fresh checkout of the commit, clean, with a frozen install, built and its target verified before anything is deployed
  const migrating = plan.filter((x) => x.change.length);
  let wt = null;
  if (migrating.length) {
    const base = mkdtempSync(join(tmpdir(), "release-promote-"));
    wt = join(base, "checkout");
    process.on("exit", () => { try { topGit("worktree", "remove", "--force", wt); } catch {} rmSync(base, { recursive: true, force: true }); });
    try { topGit("worktree", "add", "--detach", wt, sha); } catch (e) { refuse(`could not check out the commit: ${String(e.message).split("\n")[0]}`); }
    const dirty = execFileSync("git", ["-C", wt, "status", "--porcelain", "--untracked-files=all"], { encoding: "utf8" }).trim();
    if (dirty || execFileSync("git", ["-C", wt, "rev-parse", "HEAD"], { encoding: "utf8" }).trim() !== sha) refuse("the fresh checkout is not clean at that commit");
    const root = join(wt, rel);
    const stdWt = json(join(wt, "standards.json")) ?? {};
    // install once, where the lockfile is (the trigger's directory, else the repository root)
    const lockDir = [root, wt].find((d) => ["pnpm-lock.yaml", "yarn.lock", "package-lock.json", "npm-shrinkwrap.json"].some((f) => existsSync(join(d, f))));
    const pkgDir = [root, wt].find((d) => existsSync(join(d, "package.json")));
    const wantsDeps = (p) => Object.keys({ ...p?.dependencies, ...p?.devDependencies, ...p?.optionalDependencies }).length > 0;
    if (!lockDir && pkgDir && wantsDeps(json(join(pkgDir, "package.json")))) refuse("the commit has dependencies but no lockfile, so a frozen install is impossible");
    const here0 = process.cwd();
    if (lockDir) { process.chdir(lockDir); try { installBuildDependencies(json("package.json") ?? {}, {}); } catch (e) { process.chdir(here0); refuse(e.message); } process.chdir(here0); }
    // dry build and target check for every migrating Worker (the deploy repeats the build right before it)
    const verify = (w) => {
      process.chdir(root);
      try {
        build(stdWt, json("package.json"));
        const eff = effectiveConfig(w.local, false, { redirect: w.primary });
        if (eff.cfg.name !== w.cfg.name) refuse(`${w.local} builds a Worker named ${eff.cfg.name}, not ${w.cfg.name}`);
        if (env.CLOUDFLARE_ENV) refuse("CLOUDFLARE_ENV is set; a production deploy must not select an environment");
      } finally { process.chdir(here0); }
    };
    for (const w of migrating) verify(w);
    plan.stdWt = stdWt; plan.root = root;
  }
  // every check passed: only now change anything, supporting Workers first, the primary last
  const here1 = process.cwd();
  for (const w of plan) {
    if (!w.change.length) {
      must(["versions", "deploy", "--name", w.name, `${w.versionId}@100%`, "--message", `promote ${sha}`, "--yes"]);
      continue;
    }
    console.log(`release: ${w.name}: full wrangler deploy of ${sha.slice(0, 7)} from a fresh checkout (changes Durable Object lifecycle: ${w.change.join("; ")})`);
    process.chdir(plan.root);
    try {
      build(plan.stdWt, json("package.json"));
      must(["deploy", ...(w.primary ? [] : ["--config", w.local]), "--name", w.name, "--tag", sha, "--message", `promote ${sha}`]);
    } finally { process.chdir(here1); }
  }
  console.log(`release: promoted ${sha.slice(0, 7)}`);
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

try { await (cmd === "cleanup" ? cleanup() : cmd === "promote" ? promote() : deploy()); }
catch (e) { fail(e.message, "fix the build/config before retrying; staging must target only <production name>-staging with no production routes or custom domains"); }
