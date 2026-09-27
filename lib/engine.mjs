// Render the pack for one organization overlay and profile, and apply it to a repository checkout.
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, renameSync, rmSync, statSync, symlinkSync, chmodSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const DEFAULTS = JSON.parse(readFileSync(join(ROOT, "defaults.json"), "utf8"));
export const ENGINE_VERSION = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")).version;
export const PROFILES = ["internal", "client"];
export const END = "<!-- std:end -->";
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
  if (bad.length) throw new Error(`overlay ${file}:\n  ${bad.join("\n  ")}`);
  return o;
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
    preview_host_pattern: o.preview_host_pattern ?? null, design_signoff: o.design_signoff ?? true,
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
  const others = (s.hooks.SessionStart ?? []).filter((m) => !m.hooks?.some((h) => h.command?.includes("scripts/agent/setup.sh --check")));
  s.hooks.SessionStart = [...others, { matcher: "startup|resume", hooks: [{ type: "command", command: HOOK, timeout: 60 }] }];
  s.model = DEFAULTS.models.claude.model;
  s.env = { ...s.env, CLAUDE_CODE_SUBAGENT_MODEL: DEFAULTS.models.claude.subagent };
  s.permissions ??= {};
  // allow applies only outside bypass and is additive; deny binds even under bypass and is replaced wholesale.
  const allow = [...new Set([...(s.permissions.allow ?? []), ...DEFAULTS.permissions_allow, ...(o.permissions_allow ?? [])])];
  if (allow.length) s.permissions.allow = allow;
  s.permissions.deny = [...DEFAULTS.permissions_deny];
  return s;
}

// Codex reads this file only in trusted projects. Sets the engine's top-level keys (before the first table:
// a key after a table header belongs to that table) and [agents] default_subagent_model; keeps every other key.
export function codexConfigFor(text) {
  const lines = (text ?? "").split("\n");
  while (lines.length && lines.at(-1) === "") lines.pop();
  const top = { model: DEFAULTS.models.codex.model, ...DEFAULTS.codex_top };
  let firstTable = lines.findIndex((l) => /^\s*\[/.test(l));
  if (firstTable < 0) firstTable = lines.length;
  const add = [];
  for (const [k, v] of Object.entries(top)) {
    const at = lines.findIndex((l, i) => i < firstTable && new RegExp(`^\\s*${k}\\s*=`).test(l));
    if (at >= 0) lines[at] = `${k} = "${v}"`;
    else add.push(`${k} = "${v}"`);
  }
  lines.splice(0, 0, ...add, ...(add.length && lines.length && lines[0] !== "" ? [""] : []));
  const sub = `default_subagent_model = "${DEFAULTS.models.codex.subagent}"`;
  const agents = lines.findIndex((l) => /^\s*\[agents\]\s*$/.test(l));
  if (agents < 0) lines.push(...(lines.length ? [""] : []), "[agents]", sub);
  else {
    let end = lines.findIndex((l, i) => i > agents && /^\s*\[/.test(l));
    if (end < 0) end = lines.length;
    const at = lines.findIndex((l, i) => i > agents && i < end && /^\s*default_subagent_model\s*=/.test(l));
    if (at >= 0) lines[at] = sub;
    else lines.splice(agents + 1, 0, sub);
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

  const files = renderFiles(overlay, profile, version);
  const shipped = new Set(files.map(([p]) => p));
  for (const line of (read("standards.lock") ?? "").split("\n")) {
    const p = line.startsWith("#") ? null : line.split(/\s+/)[1];
    if (p && !p.includes("#") && !shipped.has(p) && existsSync(at(p))) {
      rmSync(at(p));
      changed.push(`-${p}`);
    }
  }
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
  const want = [".claude/*", "!.claude/settings.json", "!.claude/skills"].filter((l) => !ignore.split("\n").includes(l));
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
