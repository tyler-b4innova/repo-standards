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
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parse } from "./staging.mjs";

const [cmd, ...args] = process.argv.slice(2), env = process.env;
const SUBS = ["main", "preview", "slug", "cleanup"];
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

try { process.chdir(execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: "pipe" }).trim()); } catch {}
const std = json("standards.json") ?? {};
const configFile = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"].find(existsSync);
// The root wrangler config, parsed (JSON with comments and trailing commas); a TOML config only by its env tables.
function config() {
  if (!configFile) fail("no wrangler config (wrangler.jsonc, wrangler.json or wrangler.toml)", "run this from a Worker repository");
  const text = readFileSync(configFile, "utf8");
  if (configFile.endsWith(".toml")) return { env: /^\s*\[env\.staging[\].]/m.test(text) ? { staging: {} } : {} };
  return parse(text) ?? fail(`${configFile} does not parse`, "fix the config (JSON with comments and trailing commas)");
}
const wrangler = (a, { capture = false } = {}) => {
  console.log(`release: npx wrangler ${a.map((x) => (/^\//.test(x) ? "<file>" : x)).join(" ")}`);
  // The repository's own wrangler where it is installed (the build), else the current major (the clean-up job installs nothing).
  const bin = existsSync("node_modules/.bin/wrangler") ? ["wrangler"] : ["-y", "wrangler@4"];
  const r = spawnSync("npx", [...bin, ...a], { encoding: "utf8", stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit" });
  return { status: r.status ?? 1, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
};
const must = (a) => { const r = wrangler(a); if (r.status) process.exit(r.status); };

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
async function secretsFile(dir) {
  if (!required.length) return null;
  if (store === "secrets_store") { console.log("release: secrets come from Secrets Store bindings; nothing to re-supply"); return null; }
  // Without the vault the deploy keeps whatever secrets the Worker has; the post-deploy check still fails a missing one.
  if (!env.OP_VAULT || !env.OP_SERVICE_ACCOUNT_TOKEN) {
    console.log(`::warning::secrets (${required.join(", ")}) are not re-supplied: the build has no ${!env.OP_VAULT ? "OP_VAULT variable" : "OP_SERVICE_ACCOUNT_TOKEN secret"} | fix: set the Worker's Builds variable OP_VAULT (the client's 1Password vault) and secret OP_SERVICE_ACCOUNT_TOKEN (the org's CI-only service account) on both triggers`);
    return null;
  }
  const op = await opCli(dir), values = {};
  for (const name of required) {
    const r = spawnSync(op, ["read", "--no-newline", `op://${env.OP_VAULT}/staging/${name}`], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    if (r.status) fail(`1Password has no readable ${name} in the vault's "staging" item`, `add the field ${name} to the item "staging" in vault ${env.OP_VAULT} (the service account needs read access)`);
    values[name] = r.stdout;
  }
  const f = join(dir, "secrets.json");
  writeFileSync(f, JSON.stringify(values), { mode: 0o600 });
  return f;
}

// Post-deploy: every required secret is on the deployed Worker (names only; a JSON list of {name}).
function secretCheck(what, a) {
  if (!required.length) return;
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
  const missing = required.filter((n) => !names.includes(n));
  if (missing.length) fail(`${what} is missing required secret(s): ${missing.join(", ")}`,
    store === "1password" && what !== "the production Worker" ? `add them to the "staging" item of vault ${env.OP_VAULT ?? "(OP_VAULT)"}` : "set them on the production Worker once: npx wrangler secret put <NAME>");
  console.log(`release: ${what} has its ${required.length} required secret(s)`);
}

async function deploy() {
  // The secrets file goes with its directory on every exit, including a failed step's process.exit.
  const dir = mkdtempSync(join(tmpdir(), "release-"));
  process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
  {
    const f = await secretsFile(dir), sf = f ? ["--secrets-file", f] : [];
    if (cmd === "preview") {
      const branch = env.WORKERS_CI_BRANCH || execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim(), name = slug(branch);
      if (!name || name === "staging") fail(`branch ${branch} has no usable Preview name (${name || "empty"})`, "rename the branch");
      config();
      must(["preview", "--name", name, ...sf]);
      secretCheck(`Preview ${name}`, ["preview", "secret", "list", "--name", name, "--json"]);
      return;
    }
    const cfg = config(), staged = Boolean(cfg.env?.staging);
    if (staged) {
      // staging's own databases take this commit's migrations first (production's run when its version goes live)
      for (const d of Array.isArray(cfg.env.staging.d1_databases) ? cfg.env.staging.d1_databases : [])
        if (d?.binding && existsSync(d.migrations_dir ?? "migrations")) must(["d1", "migrations", "apply", d.binding, "--env", "staging", "--remote"]);
      must(["deploy", "--env", "staging", ...sf]);
      secretCheck("the staging Worker", ["secret", "list", "--env", "staging", "--format", "json"]);
    } else {
      console.log(`::warning::${configFile} has no env.staging; deploying staging as the legacy "staging" Preview. Add env.staging (a separate <name>-staging Worker with its own data): see the standards README`);
      must(["preview", "--name", "staging", ...sf]);
      secretCheck("the staging Preview", ["preview", "secret", "list", "--name", "staging", "--json"]);
    }
    const sha = env.WORKERS_CI_COMMIT_SHA;
    must(["versions", "upload", ...(sha ? ["--tag", sha, "--message", `main ${sha}`, "--var", `SENTRY_RELEASE:${sha}`] : [])]);
    secretCheck("the production Worker", ["secret", "list", "--format", "json"]);
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

await (cmd === "cleanup" ? cleanup() : deploy());
