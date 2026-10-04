// Render the pack for one organization overlay and profile, and apply it to a repository checkout.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, renameSync, rmSync, statSync, symlinkSync, chmodSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { codexPins, stripClaudePins } from "../template/scripts/agent/pins.mjs";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const DEFAULTS = JSON.parse(readFileSync(join(ROOT, "defaults.json"), "utf8"));
const PKG = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
export const ENGINE_VERSION = PKG.version;
// "breaking": this release can stop a repository's gate or check from passing (a new required step, a trigger change,
// a new --check failure class). Sync then lands it on one repository until run with --proven.
export const ENGINE_BREAKING = PKG.breaking === true;
export const PROFILES = ["internal", "client"];
export const END = "<!-- std:end -->";
const CODEOWNERS = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"];
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
  const e2eBudget = o.gate?.budget?.e2e;
  if (o.gate && Object.keys(o.gate).some((k) => k !== "budget")) bad.push("gate takes only budget (pack landings run no gate, so there are no canaries)");
  if (e2eBudget !== undefined && !(typeof e2eBudget === "number" && e2eBudget > 0 && e2eBudget <= DEFAULTS.gate_budget.e2e)) bad.push(`gate.budget.e2e must be minutes in (0, ${DEFAULTS.gate_budget.e2e}] (it may only tighten)`);
  // Removed settings: the conversation is no longer a required status (review threads must be resolved instead).
  for (const [k, v] of [["review", o.review], ["org_admin.review_status", o.org_admin?.review_status], ["codex.verdict", o.codex?.verdict]])
    if (v !== undefined) bad.push(`${k} is gone: gate checks code only, the org rulesets require resolved review threads, and the review rule stays exported for the launcher; remove the key`);
  for (const k of ["ui_owners", "risk_owners"])
    if (o[k] !== undefined && !(Array.isArray(o[k]) && o[k].every((x) => typeof x === "string" && /^(@[\w.-]+(\/[\w.-]+)?|[^@\s]+@[^@\s]+)$/.test(x))))
      bad.push(`${k} must list code owners (@user, @org/team or an email), e.g. ["@octocat"]`);
  for (const k of ["check_name", "comment_author"]) if (o.preview?.[k] !== undefined && !(typeof o.preview[k] === "string" && o.preview[k].trim())) bad.push(`preview.${k} must be a non-empty string`);
  if (o.e2e?.promotion_browsers !== undefined && !(Array.isArray(o.e2e.promotion_browsers) && o.e2e.promotion_browsers.every((b) => ["chromium", "firefox", "webkit"].includes(b)))) bad.push("e2e.promotion_browsers must list chromium, firefox or webkit");
  if (bad.length) throw new Error(`overlay ${file}:\n  ${bad.join("\n  ")}`);
  return o;
}

// `launcher`: this org's launcher settings (its own lanes only), read by the org's launcher deployment. Data only:
// accounts are ids, never credentials. Unknown keys are refused so a typo cannot silently fall back to a default.
const RUNNERS = ["t3", "claude-cloud", "codex-cloud"], AGENT_PROVIDERS = ["claudeAgent", "codex"], CLOUD_VENDOR = { "claude-cloud": "claude", "codex-cloud": "codex" };
export function launcherErrors(l) {
  const bad = [], at = (k) => `launcher.${k}`;
  const strs = (v) => Array.isArray(v) && v.every((x) => typeof x === "string" && x.trim());
  const int = (v) => Number.isInteger(v) && v > 0;
  const only = (obj, keys, where) => Object.keys(obj).filter((k) => !keys.includes(k)).forEach((k) => bad.push(`${where}.${k} is not a launcher setting (${keys.join(", ")})`));
  if (!l || typeof l !== "object" || Array.isArray(l)) return ["launcher must be an object"];
  only(l, ["repos", "unassigned", "lanes", "review", "dispatch", "sections", "bodyBudget", "uiPaths", "duplicates", "revert"], "launcher");
  if (l.repos !== undefined && l.repos !== "*" && !strs(l.repos)) bad.push(`${at("repos")} must be "*" or a list of repository names`);
  const lanes = l.lanes ?? [];
  if (!Array.isArray(lanes)) bad.push(`${at("lanes")} must be a list`);
  else lanes.forEach((x, i) => {
    const w = `launcher.lanes[${i}]`;
    if (!x || typeof x !== "object") return bad.push(`${w} must be an object`);
    only(x, ["name", "runner", "vendor", "provider", "model", "effort", "slots", "accounts", "base", "timeoutMin", "github"], w);
    if (!/^[a-z0-9][a-z0-9-]*$/.test(x.name ?? "")) bad.push(`${w}.name must match ^[a-z0-9][a-z0-9-]*$`);
    if (x.runner !== undefined && !RUNNERS.includes(x.runner)) bad.push(`${w}.runner must be ${RUNNERS.join(", ")}`);
    if (x.runner === "t3") {
      // a T3 lane runs a provider's agent directly: provider, model and optional effort (any non-empty string), no vendor
      if (!AGENT_PROVIDERS.includes(x.provider)) bad.push(`${w}.provider must be ${AGENT_PROVIDERS.join(" or ")} on a t3 lane`);
      if (!(typeof x.model === "string" && x.model.trim())) bad.push(`${w}.model must be a non-empty string on a t3 lane`);
      if (x.effort !== undefined && !(typeof x.effort === "string" && x.effort.trim())) bad.push(`${w}.effort must be a non-empty string`);
      if (x.vendor !== undefined) bad.push(`${w}.vendor must be omitted on a t3 lane (it names a cloud lane's vendor)`);
    } else {
      // a cloud lane (or one with no runner, which is one) names its vendor, or a cloud runner implies it; it takes no provider, model or effort
      if (x.vendor === undefined && CLOUD_VENDOR[x.runner]) {}
      else if (!["claude", "codex"].includes(x.vendor)) bad.push(`${w}.vendor must be claude or codex`);
      else if (RUNNERS.includes(x.runner) && x.runner !== `${x.vendor}-cloud`) bad.push(`${w}.runner ${x.runner} needs vendor ${x.runner.replace("-cloud", "")}, not ${x.vendor}`);
      for (const k of ["provider", "model", "effort"]) if (x[k] !== undefined) bad.push(`${w}.${k} is for a t3 lane; a cloud lane sets runner and vendor only`);
    }
    if (x.slots !== undefined && !int(x.slots)) bad.push(`${w}.slots must be a positive integer`);
    if (x.timeoutMin !== undefined && !int(x.timeoutMin)) bad.push(`${w}.timeoutMin must be a positive integer`);
    if (x.accounts !== undefined && !strs(x.accounts)) bad.push(`${w}.accounts must be a list of account ids`);
    for (const k of ["base", "github"]) if (x[k] !== undefined && !(typeof x[k] === "string" && x[k].trim())) bad.push(`${w}.${k} must be a non-empty string`);
  });
  const names = Array.isArray(lanes) ? lanes.map((x) => x?.name) : [];
  names.filter((n, i) => n && names.indexOf(n) !== i).forEach((n) => bad.push(`launcher.lanes: duplicate lane ${n}`));
  // review: the reviewer for T3 lanes' work; required with any t3 lane, and never the provider that wrote the change
  const t3 = Array.isArray(lanes) ? lanes.filter((x) => x?.runner === "t3") : [];
  if (l.review === undefined) { if (t3.length) bad.push(`${at("review")} is required when a lane runs on t3: {provider, model, effort?} of a provider that runs no t3 lane`); }
  else if (!l.review || typeof l.review !== "object" || Array.isArray(l.review)) bad.push(`${at("review")} must be an object`);
  else {
    only(l.review, ["provider", "model", "effort"], "launcher.review");
    if (!AGENT_PROVIDERS.includes(l.review.provider)) bad.push(`${at("review.provider")} must be ${AGENT_PROVIDERS.join(" or ")}`);
    else if (t3.some((x) => x.provider === l.review.provider)) bad.push(`${at("review.provider")} ${l.review.provider} also runs a t3 lane; review must be a different provider from every t3 lane`);
    if (!(typeof l.review.model === "string" && l.review.model.trim())) bad.push(`${at("review.model")} must be a non-empty string`);
    if (l.review.effort !== undefined && !(typeof l.review.effort === "string" && l.review.effort.trim())) bad.push(`${at("review.effort")} must be a non-empty string`);
  }
  if (l.unassigned !== undefined) {
    if (!strs(l.unassigned)) bad.push(`${at("unassigned")} must be a list of lane names`);
    else l.unassigned.filter((n) => !names.includes(n)).forEach((n) => bad.push(`${at("unassigned")} names ${n}, which is not a lane`));
  }
  if (l.dispatch !== undefined) {
    if (!Array.isArray(l.dispatch)) bad.push(`${at("dispatch")} must be a list`);
    else l.dispatch.forEach((d, i) => {
      const w = `launcher.dispatch[${i}]`;
      if (!d || typeof d !== "object") return bad.push(`${w} must be an object`);
      only(d, ["repo", "workflow", "every", "ref", "when"], w);
      if (d.ref !== undefined && !(typeof d.ref === "string" && d.ref.trim())) bad.push(`${w}.ref must be a non-empty string`);
      if (!(typeof d.repo === "string" && /^[A-Za-z0-9._-]+$/.test(d.repo))) bad.push(`${w}.repo must be a repository name in this org`);
      if (!/^[A-Za-z0-9._-]+\.ya?ml$/.test(d.workflow ?? "")) bad.push(`${w}.workflow must be a workflow file name`);
      if (!/^\d+[mhd]$/.test(d.every ?? "")) bad.push(`${w}.every must look like 30m, 1h or 1d`);
      // "drift": dispatch only when some repository's standards.lock is missing or behind the entry repo's latest release
      if (d.when !== undefined && d.when !== "drift") bad.push(`${w}.when must be "drift" when set`);
    });
  }
  for (const k of ["sections", "uiPaths"]) if (l[k] !== undefined && !strs(l[k])) bad.push(`${at(k)} must be a list of strings`);
  if (l.bodyBudget !== undefined && !int(l.bodyBudget)) bad.push(`${at("bodyBudget")} must be a positive integer`);
  if (l.duplicates !== undefined) {
    if (!l.duplicates || typeof l.duplicates !== "object" || Array.isArray(l.duplicates)) bad.push(`${at("duplicates")} must be an object`);
    else { only(l.duplicates, ["apps"], "launcher.duplicates"); if (l.duplicates.apps !== undefined && !strs(l.duplicates.apps)) bad.push(`${at("duplicates.apps")} must be a list of App slugs`); }
  }
  // revert: when the launcher reverts a production deploy (new issue events, event growth factor after the deploy)
  if (l.revert !== undefined) {
    if (!l.revert || typeof l.revert !== "object" || Array.isArray(l.revert)) bad.push(`${at("revert")} must be an object`);
    else {
      only(l.revert, ["newIssueEvents", "eventFactor"], "launcher.revert");
      for (const k of ["newIssueEvents", "eventFactor"]) if (l.revert[k] !== undefined && !(typeof l.revert[k] === "number" && l.revert[k] > 0)) bad.push(`launcher.revert.${k} must be a positive number`);
    }
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
    codex_top: DEFAULTS.codex_top, permissions_deny: DEFAULTS.permissions_deny,
    evidence_trusted_authors: [...new Set([...DEFAULTS.evidence_trusted_authors, ...(o.evidence?.trusted_authors ?? [])])],
    preview_host_pattern: o.preview_host_pattern ?? null, design_signoff: o.design_signoff ?? true, sync_app_login: o.sync?.app_login ?? null,
    gate_budget: { e2e: o.gate?.budget?.e2e ?? DEFAULTS.gate_budget.e2e },
    e2e_promotion_browsers: o.e2e?.promotion_browsers ?? [],
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
  // Repositories never pin a model or effort (scripts/agent/pins.mjs); earlier packs wrote some of these.
  stripClaudePins(s);
  s.permissions ??= {};
  // allow applies only outside bypass and is additive; deny binds even under bypass and is replaced wholesale.
  const allow = [...new Set([...(s.permissions.allow ?? []), ...DEFAULTS.permissions_allow, ...(o.permissions_allow ?? [])])];
  if (allow.length) s.permissions.allow = allow;
  s.permissions.deny = [...DEFAULTS.permissions_deny];
  return s;
}

// Codex reads this file only in trusted projects. Sets the engine's top-level keys (before the first table: a key
// after a table header belongs to that table) and keeps every other key, except model and effort pins
// (scripts/agent/pins.mjs), which are removed, along with a table they leave empty.
export function codexConfigFor(text) {
  let lines = (text ?? "").split("\n");
  while (lines.length && lines.at(-1) === "") lines.pop();
  const tableAt = () => { const i = lines.findIndex((l) => /^\s*\[/.test(l)); return i < 0 ? lines.length : i; };
  // A pin inside an inline table stays for a person to remove (the check names it): its line holds other keys too.
  const pins = codexPins(lines.join("\n")).filter((p) => !p.inline), drop = new Set(pins.map((p) => p.line));
  for (const h of new Set(pins.map((p) => p.table).filter((h) => h >= 0))) {
    let end = lines.findIndex((l, i) => i > h && /^\s*\[/.test(l));
    if (end < 0) end = lines.length;
    if (lines.slice(h + 1, end).every((l, j) => drop.has(h + 1 + j) || !l.trim() || l.trim().startsWith("#")))
      for (let i = h; i < end; i++) drop.add(i);
  }
  lines = lines.filter((_, i) => !drop.has(i));
  while (lines.length && lines.at(-1) === "") lines.pop();
  const firstTable = tableAt(), add = [];
  for (const [k, v] of Object.entries(DEFAULTS.codex_top)) {
    const at = lines.findIndex((l, i) => i < firstTable && new RegExp(`^\\s*${k}\\s*=`).test(l));
    if (at >= 0) lines[at] = `${k} = "${v}"`;
    else add.push(`${k} = "${v}"`);
  }
  lines.splice(0, 0, ...add, ...(add.length && lines.length && lines[0] !== "" ? [""] : []));
  return lines.join("\n") + "\n";
}

// Apply returns the list of changed paths. It validates everything before writing anything.
// The managed CODEOWNERS block: the overlay's ui_owners own the repo's UI paths (standards.json ui_paths, else the
// engine defaults) and its risk_owners the risky paths (standards.json risk_paths, else the defaults: workflows, auth,
// payments, secrets and env handling, migrations, infra config, CODEOWNERS itself, the agent instructions and their
// enforcement), so the org rulesets' code-owner
// review on main is the approval for those changes. Ignored UI paths get owner-less lines (no approval, as for
// evidence); risk lines come last, so they win over both. The block goes last in the file, so it wins over repo
// lines for those paths; repo lines stay. A part is left out without its owners or paths ([] opts out; UI also with
// design_signoff off); no block when both are.
export const CO_END = "# std:end";
export function codeownersBlock(o, std) {
  const ui = std.ui_paths, include = Array.isArray(ui) ? ui : ui?.include ?? DEFAULTS.ui_paths, risk = std.risk_paths ?? DEFAULTS.risk_paths;
  const uiOn = Boolean(o.ui_owners?.length && include.length) && (std.design_signoff ?? o.design_signoff ?? true) !== false;
  const riskOn = Boolean(o.risk_owners?.length && risk.length);
  if (!uiOn && !riskOn) return null;
  const expand = (g) => { const m = g.match(/\{([^{}]*)\}/); return m ? m[1].split(",").flatMap((x) => expand(g.replace(m[0], x))) : [g]; };
  const line = (key) => (g) => {
    if (/[\s!#\[\]\\]/.test(g)) throw new Error(`${key} glob ${JSON.stringify(g)} cannot be written to CODEOWNERS (no spaces, !, #, [ ] or \\); rewrite it in standards.json`);
    return g.startsWith("/") || g.startsWith("**/") ? g : `/${g}`;
  };
  return [`# std:begin ${o.pack} (managed: UI and risky paths need a code owner's approval on main; set them with standards.json ui_paths and risk_paths)`,
    ...(uiOn ? [...include.flatMap(expand).map((g) => `${line("ui_paths")(g)} ${o.ui_owners.join(" ")}`),
      ...[...DEFAULTS.ui_ignore, ...(ui?.ignore ?? [])].flatMap(expand).map(line("ui_paths"))] : []),
    ...(riskOn ? risk.flatMap(expand).map((g) => `${line("risk_paths")(g)} ${o.risk_owners.join(" ")}`) : []),
    CO_END, ""].join("\n");
}

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

  // CODEOWNERS: GitHub reads the first of .github/, the root, docs/; the block goes in whichever exists.
  // Worked out before anything is written, so a glob CODEOWNERS cannot hold stops apply with nothing changed.
  const coPath = CODEOWNERS.find((p) => lstat(p)) ?? CODEOWNERS[0], coText = read(coPath);
  const coBlock = codeownersBlock(overlay, prior);
  const coBegin = coText?.match(/^# std:begin [a-z0-9-]+.*$/m);
  let co = coText ?? "";
  if (coBegin) {
    const end = co.indexOf(`\n${CO_END}`, coBegin.index);
    if (end < 0) throw new Error(`${coPath} has a std:begin line without ${CO_END}; delete the partial block, then re-run`);
    co = co.slice(0, coBegin.index) + co.slice(end + CO_END.length + 2);
  }

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
  const generated = [".claude/settings.json", ".claude/skills", ".codex/config.toml", ".gitignore", "AGENTS.md", "standards.json", "standards.lock", ...CODEOWNERS];
  // Lock lines are `<sha256>  <path>` (older packs: `sha256 <hash> <path>`); header and key lines name no path.
  const retired = (read("standards.lock") ?? "").split("\n").map((l) => l.match(/^(?:sha256 )?[0-9a-f]{64}\s+(\S+)\s*$/)?.[1])
    .filter((p) => p && !p.includes("#") && p.split("/").every((s) => s && s !== "." && s !== "..") // normalized paths only
      && !shipped.has(p) && !generated.includes(p) && MANAGED.test(p)); // never a repo-owned path
  // Paths early packs shipped without a lock line (defaults.json orphans), so the lock cannot retire them.
  const orphanRes = DEFAULTS.orphans.map((g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\{}]/g, "\\$&").replace(/\*\*/g, "\0").replace(/\*/g, "[^/]*").replace(/\0/g, ".*") + "$"));
  const orphans = [...new Set(DEFAULTS.orphans.map((g) => dirname(g.slice(0, g.indexOf("*") + 1))))]
    .filter((d) => lstat(d)?.isDirectory()).flatMap((d) => walk(T, d))
    .filter((p) => orphanRes.some((r) => r.test(p)) && !shipped.has(p));
  const touched = [...shipped, ...retired, ...orphans, ...generated, ...moves.flatMap((e) => [join(".claude/skills", e), join(".agents/skills", e)])];
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

  for (const p of [...retired, ...orphans]) if (lstat(p)) { rmSync(at(p)); changed.push(`-${p}`); }
  for (const d of new Set(orphans.map(dirname))) if (lstat(d)?.isDirectory() && !readdirSync(at(d)).length) rmSync(at(d), { recursive: true });
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
    agents = `# ${basename(T)}\n\n${block}`; // no repo section: a placeholder invites lines nobody needs
  else if (anyBegin && agents.includes(END)) agents = agents.slice(0, agents.indexOf(anyBegin)) + block.slice(0, -1) + agents.slice(agents.indexOf(END) + END.length);
  else agents = agents.replace(/^(# .*\n\n?)?/, (h) => `${h || ""}${block}\n`);
  write("AGENTS.md", agents);

  co = co.replace(/\n*$/, co.trim() ? "\n" : "");
  if (coBlock) write(coPath, co + (co ? "\n" : "") + coBlock);
  else if (coBegin) { if (co.trim()) write(coPath, co); else { rmSync(at(coPath)); changed.push(`-${coPath}`); } }

  const { pack: _p, version: _v, profile: _pr, dispatch: d, sensitive: s, ...rest } = prior;
  const std = { pack: overlay.pack, version, profile, dispatch: dispatch ?? d ?? "manual", sensitive: s ?? false, ...rest };
  write("standards.json", JSON.stringify(std, null, 2) + "\n");
  const lock = [
    `# ${overlay.pack} v${version} ${profile} engine ${ENGINE_VERSION}`,
    ...files.map(([p]) => `${sha256(readFileSync(at(p)))}  ${p}`),
    `${sha256(block)}  AGENTS.md#std`,
    ...(coBlock ? [`${sha256(coBlock)}  ${coPath}#std`] : []),
  ];
  write("standards.lock", lock.join("\n") + "\n");
  return { changed, profile, version, begin: BEGIN };
}

export const relativeTo = (a, b) => relative(a, b);
