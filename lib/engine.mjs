// Render the pack for one organization overlay and profile, and apply it to a repository checkout.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, renameSync, rmSync, statSync, symlinkSync, chmodSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const DEFAULTS = JSON.parse(readFileSync(join(ROOT, "defaults.json"), "utf8"));
export const ENGINE_VERSION = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")).version;
export const PROFILES = ["internal", "client"];
export const END = "<!-- std:end -->";
// Paths the pack can own; a lock line naming anything else is never deleted.
export const MANAGED = /^(\.agents\/skills\/std-[^/]+\/|scripts\/agent\/|\.github\/workflows\/std-[^/]+$|\.github\/(PULL_REQUEST_TEMPLATE\.md|ISSUE_TEMPLATE\/agent-task\.md)$|\.codex\/rules\/)/;
export const HOOK = '"$CLAUDE_PROJECT_DIR"/scripts/agent/setup.sh --check';
export const sha256 = (s) => createHash("sha256").update(s).digest("hex");
const TEMPLATE = join(ROOT, "template");

const walk = (dir, rel = "") =>
  readdirSync(join(dir, rel), { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(dir, join(rel, e.name)) : [join(rel, e.name)]));

export function loadOverlay(file) {
  const o = JSON.parse(readFileSync(file, "utf8"));
  const bad = [];
  if (o.schema !== 1) bad.push(`schema must be 1 (got ${o.schema})`);
  if (!/^[a-z0-9-]+$/.test(o.pack ?? "")) bad.push("pack must match ^[a-z0-9-]+$");
  if (typeof o.title !== "string" || !o.title) bad.push("title must be a non-empty string");
  if (!["forbid", "import-only"].includes(o.claude_md ?? "import-only")) bad.push("claude_md must be forbid|import-only");
  for (const p of PROFILES) {
    if (!o.profiles?.[p]) { bad.push(`profiles.${p} missing`); continue; }
    if (!bad.length) {
      const size = Buffer.byteLength(renderBlock(o, p));
      if (size > DEFAULTS.limits.block) bad.push(`rendered ${p} block is ${size} bytes (max ${DEFAULTS.limits.block}); shorten title or profiles.${p}.block_lines`);
    }
  }
  if (o.launcher !== undefined) bad.push(...launcherErrors(o.launcher));
  const canary = o.gate?.canary ?? {}, e2eBudget = o.gate?.budget?.e2e;
  for (const [p, r] of Object.entries(canary)) if (!PROFILES.includes(p) || !/^[A-Za-z0-9._-]+$/.test(r ?? "")) bad.push(`gate.canary.${p} must name one repository for profile ${PROFILES.join(" or ")}`);
  if (e2eBudget !== undefined && !(typeof e2eBudget === "number" && e2eBudget > 0 && e2eBudget <= DEFAULTS.gate_budget.e2e)) bad.push(`gate.budget.e2e must be minutes in (0, ${DEFAULTS.gate_budget.e2e}] (it may only tighten)`);
  if (!["gate", "status", undefined].includes(o.codex?.verdict)) bad.push('codex.verdict must be "gate" (gate\'s codex step) or "status" (the App posts codex-verdict)');
  for (const k of ["check_name", "comment_author"]) if (o.preview?.[k] !== undefined && !(typeof o.preview[k] === "string" && o.preview[k].trim())) bad.push(`preview.${k} must be a non-empty string`);
  if (o.e2e?.promotion_browsers !== undefined && !(Array.isArray(o.e2e.promotion_browsers) && o.e2e.promotion_browsers.every((b) => ["chromium", "firefox", "webkit"].includes(b)))) bad.push("e2e.promotion_browsers must list chromium, firefox or webkit");
  if (bad.length) throw new Error(`overlay ${file}:\n  ${bad.join("\n  ")}`);
  return o;
}

// `launcher`: this org's launcher settings (its own lanes only), read by the org's launcher deployment. Data only:
// accounts are ids, never credentials. Unknown keys are refused so a typo cannot silently fall back to a default.
export function launcherErrors(l) {
  const bad = [], at = (k) => `launcher.${k}`;
  const strs = (v) => Array.isArray(v) && v.every((x) => typeof x === "string" && x.trim());
  const int = (v) => Number.isInteger(v) && v > 0;
  const only = (obj, keys, where) => Object.keys(obj).filter((k) => !keys.includes(k)).forEach((k) => bad.push(`${where}.${k} is not a launcher setting (${keys.join(", ")})`));
  if (!l || typeof l !== "object" || Array.isArray(l)) return ["launcher must be an object"];
  only(l, ["repos", "unassigned", "lanes", "dispatch", "sections", "bodyBudget", "uiPaths", "duplicates"], "launcher");
  if (l.repos !== undefined && l.repos !== "*" && !strs(l.repos)) bad.push(`${at("repos")} must be "*" or a list of repository names`);
  const lanes = l.lanes ?? [];
  if (!Array.isArray(lanes)) bad.push(`${at("lanes")} must be a list`);
  else lanes.forEach((x, i) => {
    const w = `launcher.lanes[${i}]`;
    if (!x || typeof x !== "object") return bad.push(`${w} must be an object`);
    only(x, ["name", "vendor", "slots", "accounts", "base", "timeoutMin", "github"], w);
    if (!/^[a-z0-9][a-z0-9-]*$/.test(x.name ?? "")) bad.push(`${w}.name must match ^[a-z0-9][a-z0-9-]*$`);
    if (!["claude", "codex"].includes(x.vendor)) bad.push(`${w}.vendor must be claude or codex`);
    if (x.slots !== undefined && !int(x.slots)) bad.push(`${w}.slots must be a positive integer`);
    if (x.timeoutMin !== undefined && !int(x.timeoutMin)) bad.push(`${w}.timeoutMin must be a positive integer`);
    if (x.accounts !== undefined && !strs(x.accounts)) bad.push(`${w}.accounts must be a list of account ids`);
    for (const k of ["base", "github"]) if (x[k] !== undefined && !(typeof x[k] === "string" && x[k].trim())) bad.push(`${w}.${k} must be a non-empty string`);
  });
  const names = Array.isArray(lanes) ? lanes.map((x) => x?.name) : [];
  names.filter((n, i) => n && names.indexOf(n) !== i).forEach((n) => bad.push(`launcher.lanes: duplicate lane ${n}`));
  if (l.unassigned !== undefined) {
    if (!strs(l.unassigned)) bad.push(`${at("unassigned")} must be a list of lane names`);
    else l.unassigned.filter((n) => !names.includes(n)).forEach((n) => bad.push(`${at("unassigned")} names ${n}, which is not a lane`));
  }
  if (l.dispatch !== undefined) {
    if (!Array.isArray(l.dispatch)) bad.push(`${at("dispatch")} must be a list`);
    else l.dispatch.forEach((d, i) => {
      const w = `launcher.dispatch[${i}]`;
      if (!d || typeof d !== "object") return bad.push(`${w} must be an object`);
      only(d, ["repo", "workflow", "every"], w);
      if (!(typeof d.repo === "string" && /^[A-Za-z0-9._-]+$/.test(d.repo))) bad.push(`${w}.repo must be a repository name in this org`);
      if (!/^[A-Za-z0-9._-]+\.ya?ml$/.test(d.workflow ?? "")) bad.push(`${w}.workflow must be a workflow file name`);
      if (!/^\d+[mhd]$/.test(d.every ?? "")) bad.push(`${w}.every must look like 30m, 1h or 1d`);
    });
  }
  for (const k of ["sections", "uiPaths"]) if (l[k] !== undefined && !strs(l[k])) bad.push(`${at(k)} must be a list of strings`);
  if (l.bodyBudget !== undefined && !int(l.bodyBudget)) bad.push(`${at("bodyBudget")} must be a positive integer`);
  if (l.duplicates !== undefined) {
    if (!l.duplicates || typeof l.duplicates !== "object" || Array.isArray(l.duplicates)) bad.push(`${at("duplicates")} must be an object`);
    else { only(l.duplicates, ["apps"], "launcher.duplicates"); if (l.duplicates.apps !== undefined && !strs(l.duplicates.apps)) bad.push(`${at("duplicates.apps")} must be a list of App slugs`); }
  }
  const secret = /^(gh[pousr]_|github_pat_|sk-|xox[abpr]-|AKIA|-----BEGIN|ops_ey)/;
  const scan = (v, w) => (typeof v === "string" ? secret.test(v.trim()) && bad.push(`${w} looks like a credential; the overlay holds data only`)
    : v && typeof v === "object" ? Object.entries(v).forEach(([k, x]) => scan(x, `${w}.${k}`)) : null);
  scan(l, "launcher");
  return bad;
}

export function renderBlock(o, profile) {
  const lines = o.profiles[profile].block_lines ?? [];
  const block = readFileSync(join(TEMPLATE, "AGENTS.block.md"), "utf8")
    .replaceAll("{pack}", o.pack)
    .replaceAll("{title}", o.title)
    .replace("{overlay_lines}\n", lines.length ? lines.join("\n") + "\n" : "");
  return block; // ends with the end marker and a newline
}

// Everything the pack writes byte-for-byte, as [path, content, mode].
export function renderFiles(o, profile, version) {
  const p = o.profiles[profile];
  const files = [];
  for (const f of walk(TEMPLATE)) {
    if (f === "AGENTS.block.md") continue;
    let text = readFileSync(join(TEMPLATE, f), "utf8");
    if (f.endsWith("std-file-pr/SKILL.md"))
      text = text.replace("{pr_model_line}", p.pr_body_model_line ? " Last line: the model and harness that did the work." : " No model names, costs or agent narration.");
    files.push([f, text, statSync(join(TEMPLATE, f)).mode & 0o111 ? 0o755 : 0o644]);
  }
  for (const [mod, on] of Object.entries(o.modules ?? {})) {
    if (!on || !existsSync(join(ROOT, "modules", mod))) continue;
    for (const f of walk(join(ROOT, "modules", mod))) files.push([f, readFileSync(join(ROOT, "modules", mod, f), "utf8"), statSync(join(ROOT, "modules", mod, f)).mode & 0o111 ? 0o755 : 0o644]);
  }
  const data = {
    pack: o.pack, title: o.title, org: o.org, version, engine: ENGINE_VERSION, profile,
    claude_md: o.claude_md ?? "import-only",
    forbid_paths: [...new Set([...(o.forbid_paths ?? []), ...(p.forbid_paths ?? [])])],
    forbid_patterns: p.forbid_patterns ?? [],
    decision_record_globs: o.decision_record_globs ?? [],
    shared_preview_hosts: o.shared_preview_hosts ?? [],
    ui_paths: DEFAULTS.ui_paths, ui_ignore: DEFAULTS.ui_ignore,
    decision_dirs: DEFAULTS.decision_dirs,
    models: DEFAULTS.models, codex_top: DEFAULTS.codex_top, permissions_deny: DEFAULTS.permissions_deny,
    evidence_trusted_authors: [...new Set([...DEFAULTS.evidence_trusted_authors, ...(o.evidence?.trusted_authors ?? [])])],
    preview_host_pattern: o.preview_host_pattern ?? null, design_signoff: o.design_signoff ?? true, sync_app_login: o.sync?.app_login ?? null,
    gate_canary: Object.values(o.gate?.canary ?? {}), gate_budget: { e2e: o.gate?.budget?.e2e ?? DEFAULTS.gate_budget.e2e },
    codex_verdict: o.codex?.verdict ?? "gate", e2e_promotion_browsers: o.e2e?.promotion_browsers ?? [],
    preview: { check_name: o.preview?.check_name ?? DEFAULTS.preview.check_name, comment_author: o.preview?.comment_author ?? DEFAULTS.preview.comment_author },
    modules: moduleData(o),
  };
  files.push(["scripts/agent/pack.json", JSON.stringify(data) + "\n", 0o644]);
  return files.sort((a, b) => a[0].localeCompare(b[0]));
}

function moduleData(o) {
  const m = {};
  if (o.modules?.error_tracker) m.error_tracker = { ...o.accounts.error_tracker, secrets: o.accounts.secrets };
  if (o.modules?.deploy) m.deploy = true;
  return m;
}

export function settingsFor(existing, o) {
  const s = structuredClone(existing ?? {});
  s.hooks ??= {};
  // Drop only the engine's own hook entries (a group may also hold the repo's hooks), then add it once.
  const others = (s.hooks.SessionStart ?? [])
    .map((m) => ({ ...m, hooks: (m.hooks ?? []).filter((h) => !h.command?.includes("scripts/agent/setup.sh --check")) }))
    .filter((m) => m.hooks.length);
  s.hooks.SessionStart = [...others, { matcher: "startup|resume", hooks: [{ type: "command", command: HOOK, timeout: 60 }] }];
  // Model keys are defaults: a repo's own choice wins. The deny set is engine-owned.
  s.model ??= DEFAULTS.models.claude.model;
  s.env = { CLAUDE_CODE_SUBAGENT_MODEL: DEFAULTS.models.claude.subagent, ...s.env };
  s.permissions ??= {};
  // allow applies only outside bypass and is additive; deny binds even under bypass and is replaced wholesale.
  const allow = [...new Set([...(s.permissions.allow ?? []), ...DEFAULTS.permissions_allow, ...(o.permissions_allow ?? [])])];
  if (allow.length) s.permissions.allow = allow;
  s.permissions.deny = [...DEFAULTS.permissions_deny];
  return s;
}

// Codex reads this file only in trusted projects. Sets the engine's top-level keys (before the first table:
// a key after a table header belongs to that table); adds model and [agents] default_subagent_model only when
// the repo has none (they are defaults); keeps every other key.
export function codexConfigFor(text) {
  const lines = (text ?? "").split("\n");
  while (lines.length && lines.at(-1) === "") lines.pop();
  let firstTable = lines.findIndex((l) => /^\s*\[/.test(l));
  if (firstTable < 0) firstTable = lines.length;
  const add = [];
  for (const [k, v] of [["model", DEFAULTS.models.codex.model], ...Object.entries(DEFAULTS.codex_top)]) {
    const at = lines.findIndex((l, i) => i < firstTable && new RegExp(`^\\s*${k}\\s*=`).test(l));
    if (at >= 0) { if (k !== "model") lines[at] = `${k} = "${v}"`; }
    else add.push(`${k} = "${v}"`);
  }
  lines.splice(0, 0, ...add, ...(add.length && lines.length && lines[0] !== "" ? [""] : []));
  const sub = `default_subagent_model = "${DEFAULTS.models.codex.subagent}"`;
  const agents = lines.findIndex((l) => /^\s*\[agents\]\s*(#.*)?$/.test(l));
  if (agents < 0) lines.push(...(lines.length ? [""] : []), "[agents]", sub);
  else {
    let end = lines.findIndex((l, i) => i > agents && /^\s*\[/.test(l));
    if (end < 0) end = lines.length;
    if (!lines.some((l, i) => i > agents && i < end && /^\s*default_subagent_model\s*=/.test(l))) lines.splice(agents + 1, 0, sub);
  }
  return lines.join("\n") + "\n";
}

// Apply returns the list of changed paths. It validates everything before writing anything.
export function apply({ target, overlay, profile, version, dispatch }) {
  const T = resolve(target);
  const at = (p) => join(T, p);
  const read = (p) => (existsSync(at(p)) ? readFileSync(at(p), "utf8") : null);
  const lstat = (p) => { try { return lstatSync(at(p)); } catch { return null; } };
  const prior = JSON.parse(read("standards.json") ?? "{}");
  if (prior.pack && prior.pack !== overlay.pack) throw new Error(`standards.json names pack "${prior.pack}", not "${overlay.pack}"; refusing`);
  profile = prior.profile ?? profile ?? "internal";
  if (!PROFILES.includes(profile)) throw new Error(`unknown profile "${profile}" (use ${PROFILES.join("|")})`);
  version ??= overlay.version ?? "0.0.0";

  const agentsText = lstat("AGENTS.md") ? (() => { try { return readFileSync(at("AGENTS.md"), "utf8"); } catch { return null; } })() : null;
  const BEGIN = `<!-- std:begin ${overlay.pack} -->`;
  const begins = (agentsText?.match(/<!-- std:begin [a-z0-9-]+ -->/g) ?? []).length;
  if (begins > 1 || (agentsText?.split(END).length ?? 1) > 2) throw new Error(`AGENTS.md has ${begins} std:begin markers; keep exactly one managed block, then re-run`);

  // Repo-owned skills under .claude/skills move to .agents/skills; a name clash stops apply.
  const moves = [];
  const link = lstat(".claude/skills");
  if (link?.isDirectory()) {
    for (const e of readdirSync(at(".claude/skills"))) {
      if (existsSync(at(join(".agents/skills", e)))) throw new Error(`.claude/skills/${e} also exists in .agents/skills; move or rename it, then re-run (nothing was changed)`);
      moves.push(e);
    }
  } else if (link?.isSymbolicLink() && readlinkSync(at(".claude/skills")) !== "../.agents/skills" && existsSync(at(".claude/skills"))) {
    throw new Error(`.claude/skills links to ${readlinkSync(at(".claude/skills"))}; move those skills into .agents/skills, then re-run (nothing was changed)`);
  }

  // Never write or delete through a symlink: every path apply touches stays inside the repository, and no
  // existing directory on the way to it is a link (a leaf link is replaced, never followed).
  const files = renderFiles(overlay, profile, version);
  const shipped = new Set(files.map(([p]) => p));
  const generated = [".claude/settings.json", ".claude/skills", ".codex/config.toml", ".gitignore", "AGENTS.md", "standards.json", "standards.lock"];
  // Lock lines are `<sha256>  <path>` (older packs: `sha256 <hash> <path>`); header and key lines name no path.
  const retired = (read("standards.lock") ?? "").split("\n").map((l) => l.match(/^(?:sha256 )?[0-9a-f]{64}\s+(\S+)\s*$/)?.[1])
    .filter((p) => p && !p.includes("#") && p.split("/").every((s) => s && s !== "." && s !== "..") // normalized paths only
      && !shipped.has(p) && !generated.includes(p) && MANAGED.test(p)); // never a repo-owned path
  const touched = [...shipped, ...retired, ...generated, ...moves.flatMap((e) => [join(".claude/skills", e), join(".agents/skills", e)])];
  for (const p of touched) {
    const rel = relative(T, resolve(T, p));
    if (!rel || rel.startsWith("..") || rel.split("/")[0] === ".git") throw new Error(`${p} is outside the working tree (standards.lock?); fix it, then re-run (nothing was changed)`);
    const parts = rel.split("/");
    for (let i = 1; i < parts.length; i++) {
      const d = parts.slice(0, i).join("/");
      if (lstat(d)?.isSymbolicLink())
        throw new Error(`${d} is a symlink, so writing ${p} would leave the repository; replace it with a directory, then re-run (nothing was changed)`);
    }
  }

  const changed = [];
  const write = (p, content, mode) => {
    if (read(p) !== content || lstat(p)?.isSymbolicLink()) {
      if (lstat(p)?.isSymbolicLink()) rmSync(at(p));
      mkdirSync(dirname(at(p)), { recursive: true });
      writeFileSync(at(p), content);
      changed.push(p);
    }
    if (mode) chmodSync(at(p), mode);
  };

  for (const p of retired) if (lstat(p)) { rmSync(at(p)); changed.push(`-${p}`); }
  for (const [p, content, mode] of files) write(p, content, mode);

  mkdirSync(at(".agents/skills"), { recursive: true });
  for (const e of moves) renameSync(at(join(".claude/skills", e)), at(join(".agents/skills", e)));
  if (!(link?.isSymbolicLink() && readlinkSync(at(".claude/skills")) === "../.agents/skills")) {
    rmSync(at(".claude/skills"), { recursive: true, force: true });
    mkdirSync(at(".claude"), { recursive: true });
    symlinkSync("../.agents/skills", at(".claude/skills"));
    changed.push(".claude/skills");
  }

  write(".claude/settings.json", JSON.stringify(settingsFor(JSON.parse(read(".claude/settings.json") ?? "{}"), overlay), null, 2) + "\n");
  write(".codex/config.toml", codexConfigFor(read(".codex/config.toml")));

  const ignore = read(".gitignore") ?? "";
  // .claude/ is local state except two paths; a repo that ignores .codex/ must still track the engine's Codex files.
  const codexIgnored = [".codex/config.toml", ".codex/rules/std.rules"].some((p) => spawnSync("git", ["-C", T, "check-ignore", "-q", "--no-index", p]).status === 0)
    || ignore.split("\n").some((l) => /^(\*\*\/|\/)?\.codex(\/|\/\*+)?$/.test(l.trim()));
  const want = [".claude/*", "!.claude/settings.json", "!.claude/skills", ...(codexIgnored ? ["!.codex/", ".codex/*", "!.codex/config.toml", "!.codex/rules/", ".codex/rules/*", "!.codex/rules/std.rules"] : [])]
    .filter((l) => !ignore.split("\n").includes(l));
  if (want.length) write(".gitignore", ignore + (ignore && !ignore.endsWith("\n") ? "\n" : "") + want.join("\n") + "\n");

  const block = renderBlock(overlay, profile);
  let agents = agentsText;
  if (lstat("AGENTS.md")?.isSymbolicLink()) rmSync(at("AGENTS.md"));
  const anyBegin = agents?.match(/<!-- std:begin [a-z0-9-]+ -->/)?.[0];
  if (agents === null)
    agents = `# ${basename(T)}\n\n${block}\n## Repo rules\n\nLocal footguns and commands only; the block above is managed.\n\n## Code Review Rules\n\n- \`.codex/config.toml\` targets Codex CLI ≥0.155; don't flag its model or [agents] keys against older CLIs.\n`;
  else if (anyBegin && agents.includes(END)) agents = agents.slice(0, agents.indexOf(anyBegin)) + block.slice(0, -1) + agents.slice(agents.indexOf(END) + END.length);
  else agents = agents.replace(/^(# .*\n\n?)?/, (h) => `${h || ""}${block}\n`);
  write("AGENTS.md", agents);

  const { pack: _p, version: _v, profile: _pr, dispatch: d, sensitive: s, ...rest } = prior;
  const std = { pack: overlay.pack, version, profile, dispatch: dispatch ?? d ?? "manual", sensitive: s ?? false, ...rest };
  write("standards.json", JSON.stringify(std, null, 2) + "\n");
  const lock = [
    `# ${overlay.pack} v${version} ${profile} engine ${ENGINE_VERSION}`,
    ...files.map(([p]) => `${sha256(readFileSync(at(p)))}  ${p}`),
    `${sha256(block)}  AGENTS.md#std`,
  ];
  write("standards.lock", lock.join("\n") + "\n");
  return { changed, profile, version, begin: BEGIN };
}

export const relativeTo = (a, b) => relative(a, b);
