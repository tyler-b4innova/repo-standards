#!/usr/bin/env node
// Offline standards self-check (run by `scripts/agent/setup.sh --check`, at session start and in `gate`).
// One line per failure, each with its fix; warnings never fail. Exit 1 on any failure.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

if (process.argv.includes("--help")) {
  console.log("usage: node scripts/agent/check.mjs   (offline standards self-check; exit 1 on failure)");
  process.exit(0);
}
process.chdir(execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim());
const git = (...a) => execFileSync("git", a, { encoding: "utf8", maxBuffer: 1 << 26 });
const read = (f) => { try { return readFileSync(f, "utf8"); } catch { return null; } };
const json = (f) => { try { return JSON.parse(read(f)); } catch { return null; } };
const sha = (s) => createHash("sha256").update(s).digest("hex");
const fails = [], warns = [];
const fail = (msg, fix) => fails.push(`FAIL: ${msg} | fix: ${fix}`);
const warn = (msg) => warns.push(`WARN: ${msg}`);

const pack = json("scripts/agent/pack.json");
if (!pack) {
  console.log("FAIL: scripts/agent/pack.json missing or invalid | fix: re-apply the pack from your org's standards repository");
  process.exit(1);
}
const tracked = git("ls-files", "-z").split("\0").filter(Boolean);
const pin = git("log", "-1", "--format=%h", "--", "standards.lock").trim() || "HEAD";
const restore = (p) => `git checkout ${pin} -- ${p}`;

// standards.json and the lock
const std = json("standards.json");
const allowed = { profile: ["internal", "client"], dispatch: ["auto", "manual", "off"] };
if (!std) fail("standards.json missing or not JSON", restore("standards.json"));
else {
  if (std.pack !== pack.pack) fail(`standards.json pack is ${JSON.stringify(std.pack)}, not "${pack.pack}"`, `set "pack": "${pack.pack}"`);
  if (!/^\d+\.\d+\.\d+/.test(std.version ?? "")) fail("standards.json version is not X.Y.Z", restore("standards.json"));
  for (const [k, vals] of Object.entries(allowed)) if (!vals.includes(std[k])) fail(`standards.json ${k} is ${JSON.stringify(std[k])}`, `use one of ${vals.join("|")}`);
  if (typeof std.sensitive !== "boolean") fail("standards.json sensitive must be true or false", `set "sensitive": false`);
  if (!(std.e2e === undefined || std.e2e === false)) fail("standards.json e2e may only be false (docs/static repos)", `delete "e2e" or set it to false`);
  const ui = std.ui_paths;
  const uiOk = ui === undefined || (Array.isArray(ui) && ui.every((g) => typeof g === "string")) ||
    (ui && typeof ui === "object" && ["include", "ignore"].every((k) => ui[k] === undefined || (Array.isArray(ui[k]) && ui[k].every((g) => typeof g === "string"))));
  if (!uiOk) fail("standards.json ui_paths must be a glob list or {include, ignore} glob lists", `fix "ui_paths" or delete it for the engine defaults`);
}
const lock = read("standards.lock");
const agents = read("AGENTS.md");
const begin = `<!-- std:begin ${pack.pack} -->`, end = "<!-- std:end -->";
const blockText = () => {
  const lines = (agents ?? "").split("\n"), i = lines.indexOf(begin), j = lines.indexOf(end, i);
  return i < 0 || j < 0 ? null : lines.slice(i, j + 1).join("\n") + "\n";
};
if (!lock) fail("standards.lock missing", restore("standards.lock"));
else {
  const [, lockVersion] = lock.split("\n")[0].match(/^# \S+ v(\S+)/) ?? [];
  if (std && lockVersion !== std.version) fail(`standards.json version ${std.version} differs from standards.lock ${lockVersion}`, restore("standards.json standards.lock"));
  for (const line of lock.split("\n")) {
    const [want, path] = line.split(/\s+/);
    if (!want || want.startsWith("#")) continue;
    if (path === "AGENTS.md#std") {
      const b = blockText();
      if (b === null) fail(`AGENTS.md has no ${begin} … ${end} block`, `restore the block from: git show ${pin}:AGENTS.md`);
      else if (sha(b) !== want) fail("the managed AGENTS.md block was edited", `restore it from: git show ${pin}:AGENTS.md`);
    } else if (!existsSync(path)) fail(`managed file missing: ${path}`, restore(path));
    else if (sha(readFileSync(path)) !== want) fail(`managed file changed: ${path}`, `${restore(path)}   (change it upstream in the org standards repository)`);
  }
}

// AGENTS.md and agent config
if (agents === null) fail("AGENTS.md missing", restore("AGENTS.md"));
else {
  const size = Buffer.byteLength(agents);
  if (size > 4096) fail(`AGENTS.md is ${size} bytes (limit 4096)`, "cut the repo-owned part to local footguns and commands");
  const n = (agents.match(/<!-- std:begin [a-z0-9-]+ -->/g) ?? []).length, m = agents.split(end).length - 1;
  if (n !== 1 || m !== 1) fail(`AGENTS.md has ${n} std:begin and ${m} std:end markers (need exactly one each)`, "delete the duplicate managed block");
}
const claude = read("CLAUDE.md");
if (claude !== null && claude.trim() !== "@AGENTS.md") fail("CLAUDE.md holds its own content", "move rules to AGENTS.md; CLAUDE.md may only be absent or the single line @AGENTS.md");
let linkOk = false;
try { linkOk = lstatSync(".claude/skills").isSymbolicLink() && readlinkSync(".claude/skills") === "../.agents/skills"; } catch {}
if (!linkOk) fail(".claude/skills is not a link to ../.agents/skills", "rm -rf .claude/skills && ln -s ../.agents/skills .claude/skills");
const settings = json(".claude/settings.json");
const hooked = settings?.hooks?.SessionStart?.some((m) => m.hooks?.some((h) => h.command?.includes("scripts/agent/setup.sh --check")));
if (!hooked) fail(".claude/settings.json lacks the SessionStart setup.sh --check hook", restore(".claude/settings.json"));
if (settings && (settings.model !== pack.models.claude.model || settings.env?.CLAUDE_CODE_SUBAGENT_MODEL !== pack.models.claude.subagent))
  fail(`.claude/settings.json model keys differ from "${pack.models.claude.model}"/"${pack.models.claude.subagent}"`, restore(".claude/settings.json"));
const codex = read(".codex/config.toml") ?? "";
const [codexTop, ...codexTables] = codex.split(/^(?=\s*\[)/m);
const codexAgents = codexTables.find((t) => /^\s*\[agents\]/.test(t)) ?? "";
if (!new RegExp(`^\\s*model\\s*=\\s*"${pack.models.codex.model}"`, "m").test(codexTop) || !new RegExp(`^\\s*default_subagent_model\\s*=\\s*"${pack.models.codex.subagent}"`, "m").test(codexAgents))
  fail(`.codex/config.toml lacks model = "${pack.models.codex.model}" and [agents] default_subagent_model`, restore(".codex/config.toml"));

// Forbidden paths and content
const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
for (const f of tracked) {
  const name = f.split("/").pop();
  if (f === "CONTEXT.md") fail("CONTEXT.md at the root is forbidden", `git rm ${f}   (rules: AGENTS.md; history: issues and PRs)`);
  if (f === ".mcp.json") fail(".mcp.json is committed", "git rm --cached .mcp.json && echo .mcp.json >> .gitignore");
  if (/^\.env(\..+)?$/.test(name) && name !== ".env.example" || name === ".dev.vars" || name.endsWith(".pem"))
    fail(`secret-bearing file tracked: ${f}`, `git rm --cached ${f} && echo ${name} >> .gitignore`);
  if (f.startsWith(".evidence/")) fail(`.evidence/ is tracked (${f})`, "git rm -r .evidence   (scripts/agent/pr.sh evidence removes it after posting)");
  const dirs = f.split("/").slice(0, -1).map((d) => d.toLowerCase());
  if (/\.(md|markdown)$/i.test(name) && dirs.some((d) => pack.decision_dirs.includes(d)) || /^ADR-.*\.md$/i.test(name))
    fail(`decision record tracked: ${f}`, `git rm ${f}   (decisions live in issues labelled decision)`);
  for (const g of pack.forbid_paths) if (glob(g).test(f)) fail(`${f} matches the org's forbidden path ${g}`, `git rm -r --cached ${f}`);
}
const scanPatterns = std?.profile === "client" || std?.sensitive === true ? [...new Set([...pack.forbid_patterns, ...pack.client_forbid_patterns])] : pack.forbid_patterns;
for (const pat of scanPatterns) {
  let hit = "";
  try { hit = git("grep", "-nIiE", pat, "--", ".", ":!scripts/agent/pack.json").split("\n")[0]; } catch {}
  if (hit) fail(`forbidden internal reference /${pat}/ at ${hit.split(":").slice(0, 2).join(":")}`, "remove the internal reference");
}
for (const host of pack.shared_preview_hosts) {
  const re = new RegExp(`(^|[^a-z0-9-])${host.replace(/\./g, "\\.")}`);
  for (const f of tracked.filter((f) => /(^|\/)wrangler\.(jsonc?|toml)$/.test(f)))
    if (re.test(read(f) ?? "")) fail(`${f} uses the shared preview host ${host} (a Previews hostname binds to one Worker)`, "use a per-Worker host, e.g. preview.<zone> or preview-<worker>.<domain>");
}

// Drift that shadows the repo's model defaults (warn only)
for (const v of ["ANTHROPIC_MODEL", "CLAUDE_CODE_EFFORT_LEVEL"]) if (process.env[v]) warn(`shell sets ${v}; it overrides the repo's Claude model/effort defaults`);
const userClaude = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "settings.json");
for (const [file, s] of [[userClaude, json(userClaude)], [".claude/settings.local.json", json(".claude/settings.local.json")]]) {
  if (!s) continue;
  const keys = ["modelSettings", ...(file === userClaude ? [] : ["model"])].filter((k) => k in s);
  for (const v of ["ANTHROPIC_MODEL", "CLAUDE_CODE_EFFORT_LEVEL"]) if (s.env?.[v]) keys.push(`env.${v}`);
  if (keys.length) warn(`${file} sets ${keys.join(", ")}; it overrides the repo's Claude model/effort defaults`);
}
const codexHome = process.env.CODEX_HOME || join(homedir(), ".codex");
const userCodex = read(join(codexHome, "config.toml"));
if (userCodex !== null) {
  const root = process.cwd();
  const esc = root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if (!new RegExp(`^\\[projects\\."${esc}"\\]\\s*\\n(?:(?!\\[).*\\n)*?\\s*trust_level\\s*=\\s*"trusted"`, "m").test(userCodex))
    warn(`Codex: project not trusted, so the repo model/permissions in .codex/config.toml are inactive here | fix: run codex here once and trust the folder, or add [projects."${root}"] trust_level = "trusted" to ${join(codexHome, "config.toml")}`);
  const effort = userCodex.match(/^\s*(model_reasoning_effort|default_subagent_reasoning_effort)\s*=.*/gm);
  if (effort) warn(`${join(codexHome, "config.toml")} sets ${effort.map((l) => l.trim()).join(", ")}; it overrides the provider default effort`);
}

for (const w of warns) console.log(w);
for (const f of fails) console.log(f);
if (fails.length) {
  console.log(`standards check: ${fails.length} failure(s)`);
  process.exit(1);
}
console.log(`standards ok: ${pack.pack} v${std.version} ${std.profile} (engine ${pack.engine}) dispatch=${std.dispatch}`);
