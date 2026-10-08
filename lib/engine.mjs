// Render the pack for one organization overlay and profile, and apply it to a repository checkout.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, renameSync, rmSync, statSync, symlinkSync, chmodSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { codexPins, stripClaudePins } from "../template/scripts/agent/pins.mjs";
import { migrate as migrateStaging } from "../template/scripts/agent/staging.mjs";

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
export const WRANGLER = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"];
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
    const sp = o.profiles[p].source_platforms;
    if (sp !== undefined && !(Array.isArray(sp) && sp.every((x) => typeof x === "string" && /^[\w .-]+$/.test(x)))) bad.push(`profiles.${p}.source_platforms must list platform names`);
  }
  if (o.launcher !== undefined) { bad.push(...launcherErrors(o.launcher)); launcherNotices(o.launcher).forEach((n) => console.error(`notice: ${n}`)); }
  const e2eBudget = o.gate?.budget?.e2e;
  if (o.gate && Object.keys(o.gate).some((k) => !["budget", "timeout_minutes"].includes(k))) bad.push("gate takes only budget and timeout_minutes (pack landings run no gate, so there are no canaries)");
  const gateTimeout = o.gate?.timeout_minutes;
  if (gateTimeout !== undefined && !(Number.isInteger(gateTimeout) && gateTimeout >= 5 && gateTimeout <= 120)) bad.push("gate.timeout_minutes must be an integer from 5 to 120");
  if (e2eBudget !== undefined && !(typeof e2eBudget === "number" && e2eBudget > 0 && e2eBudget <= DEFAULTS.gate_budget.e2e)) bad.push(`gate.budget.e2e must be minutes in (0, ${DEFAULTS.gate_budget.e2e}] (it may only tighten)`);
  // Removed settings: the conversation is no longer a required status (review threads must be resolved instead).
  for (const [k, v] of [["review", o.review], ["org_admin.review_status", o.org_admin?.review_status], ["codex.verdict", o.codex?.verdict]])
    if (v !== undefined) bad.push(`${k} is gone: gate checks code only, the org rulesets require resolved review threads, and the review rule stays exported for the launcher; remove the key`);
  for (const k of ["ui_owners", "risk_owners"])
    if (o[k] !== undefined && !(Array.isArray(o[k]) && o[k].every((x) => typeof x === "string" && /^(@[\w.-]+(\/[\w.-]+)?|[^@\s]+@[^@\s]+)$/.test(x))))
      bad.push(`${k} must list code owners (@user, @org/team or an email), e.g. ["@octocat"]`);
  for (const k of ["check_name", "comment_author"]) if (o.preview?.[k] !== undefined && !(typeof o.preview[k] === "string" && o.preview[k].trim())) bad.push(`preview.${k} must be a non-empty string`);
  const opRef = (v) => typeof v === "string" && /^op:\/\/[^/\s'"$`]+\/[^/\s'"$`]+\/[^\s'"$`]+$/.test(v);
  // preview.cleanup: the 1Password references of the narrowly scoped Cloudflare token (Workers Scripts edit, previews
  // only) and its account id, read at runtime by std-preview-cleanup.yml through the org's CI-only service account.
  // null (or absent) leaves the workflow inert with a notice.
  if (o.preview?.cleanup != null) {
    const c = o.preview.cleanup;
    if (typeof c !== "object" || Array.isArray(c)) bad.push("preview.cleanup must be an object {token_ref, account_ref}, or null until the CI vault exists");
    else {
      Object.keys(c).filter((k) => !["token_ref", "account_ref"].includes(k)).forEach((k) => bad.push(`preview.cleanup.${k} is not a cleanup setting (token_ref, account_ref)`));
      for (const k of ["token_ref", "account_ref"]) if (!opRef(c[k])) bad.push(`preview.cleanup.${k} must be a 1Password reference op://<vault>/<item>/<field>`);
    }
  }
  // portal: the org's client portal, which signs the short-lived passes every staging and preview Worker requires
  // (scripts/agent/portal-pass.mjs). Absent: sites keep their current gate and --check does not ask for the pass check.
  if (o.portal !== undefined) {
    const p = o.portal, https = (u) => { try { return new URL(u).protocol === "https:"; } catch { return false; } };
    if (!p || typeof p !== "object" || Array.isArray(p)) bad.push("portal must be an object {issuer, jwks_url}");
    else {
      Object.keys(p).filter((k) => !["issuer", "jwks_url"].includes(k)).forEach((k) => bad.push(`portal.${k} is not a portal setting (issuer, jwks_url)`));
      if (!(https(p.issuer) && new URL(p.issuer).origin === p.issuer)) bad.push("portal.issuer must be the portal's https origin, e.g. https://portal.example.com");
      if (!https(p.jwks_url)) bad.push("portal.jwks_url must be the https URL of the portal's JWKS");
    }
  }
  if (o.e2e?.promotion_browsers !== undefined) bad.push("e2e.promotion_browsers is gone (there are no promotions): name extra browsers in e2e.release_browsers; they run on main, against staging");
  if (o.e2e?.release_browsers !== undefined && !(Array.isArray(o.e2e.release_browsers) && o.e2e.release_browsers.every((b) => ["chromium", "firefox", "webkit"].includes(b)))) bad.push("e2e.release_browsers must list chromium, firefox or webkit");
  // cloud_env: the org's cloud-env action (owner/repo[/path]@ref, rendered into std-cloud-env.yml) and the 1Password
  // reference of the Cloudflare token its apply step reads on main (null leaves it inert). Data only, never a credential.
  const ce = o.cloud_env;
  if (ce !== undefined) {
    if (!ce || typeof ce !== "object" || Array.isArray(ce)) bad.push("cloud_env must be an object {action, token_ref}");
    else {
      Object.keys(ce).filter((k) => !["action", "token_ref"].includes(k)).forEach((k) => bad.push(`cloud_env.${k} is not a cloud_env setting (action, token_ref)`));
      if (!(typeof ce.action === "string" && /^[\w.-]+\/[\w.-]+(\/[\w./-]+)?@[\w./-]+$/.test(ce.action))) bad.push("cloud_env.action must name a GitHub action, <owner>/<repo>[/<path>]@<ref>");
      if (ce.token_ref != null && !opRef(ce.token_ref))
        bad.push("cloud_env.token_ref must be a 1Password reference op://<vault>/<item>/<field>, or null until the CI vault exists");
    }
  }
  if (bad.length) throw new Error(`overlay ${file}:\n  ${bad.join("\n  ")}`);
  return o;
}

// `launcher`: this org's launcher settings (its own schedule, sections and retro; lanes, models and the reviewer are set on its dashboard), read by the org's launcher deployment. Data only:
// credential-looking values are refused. Unknown keys are refused so a typo cannot silently fall back to a default.
// Removed launcher settings that live overlays still set: ignored with a notice, never refused.
export const launcherNotices = (l) => (l && typeof l === "object" && l.bodyBudget !== undefined ? ["launcher.bodyBudget was removed (there is no issue size limit) and is ignored; remove the key"] : []);
export function launcherErrors(l) {
  const bad = [], at = (k) => `launcher.${k}`;
  const strs = (v) => Array.isArray(v) && v.every((x) => typeof x === "string" && x.trim());
  const only = (obj, keys, where) => Object.keys(obj).filter((k) => !keys.includes(k)).forEach((k) => bad.push(`${where}.${k} is not a launcher setting (${keys.join(", ")})`));
  if (!l || typeof l !== "object" || Array.isArray(l)) return ["launcher must be an object"];
  const { bodyBudget: _removed, ...known } = l; // removed: a notice (launcherNotices), not a refusal
  only(known, ["repos", "unassigned", "lanes", "review", "dispatch", "sections", "uiPaths", "duplicates", "revert", "retro"], "launcher");
  if (l.repos !== undefined && l.repos !== "*" && !strs(l.repos)) bad.push(`${at("repos")} must be "*" or a list of repository names`);
  // lanes, models, effort, the reviewer and the unassigned lanes belong to the org's launcher and are set on its dashboard
  for (const k of ["lanes", "review", "unassigned"]) if (l[k] !== undefined) bad.push(`${at(k)} is set on the launcher dashboard, not in standards; remove the key`);
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
  // retro: the weekly retro's rule approvers (repo and pack level; engine level) and its drafting model. Claude only:
  // the launcher refuses codex as the drafter.
  if (l.retro !== undefined) {
    if (!l.retro || typeof l.retro !== "object" || Array.isArray(l.retro)) bad.push(`${at("retro")} must be an object`);
    else {
      only(l.retro, ["approvers", "engineApprovers", "provider", "model", "effort", "repo"], "launcher.retro");
      const logins = (v) => Array.isArray(v) && v.length > 0 && v.every((x) => typeof x === "string" && /^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/.test(x));
      for (const k of ["approvers", "engineApprovers"]) if (!logins(l.retro[k])) bad.push(`launcher.retro.${k} must be a non-empty list of GitHub logins`);
      if (l.retro.provider !== "claudeAgent") bad.push(`${at("retro.provider")} must be claudeAgent (the launcher drafts the retro with Claude only)`);
      if (!(typeof l.retro.model === "string" && l.retro.model.trim())) bad.push(`${at("retro.model")} must be a non-empty string`);
      for (const k of ["effort", "repo"]) if (l.retro[k] !== undefined && typeof l.retro[k] !== "string") bad.push(`launcher.retro.${k} must be a string`);
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
    if (f.endsWith("workflows/std-release-check.yml")) text = text.replaceAll("{check_name}", String(o.preview?.check_name ?? DEFAULTS.preview.check_name).replaceAll("'", "''"));
    if (f.endsWith("workflows/std-gate.yml")) text = text.replaceAll("{gate_timeout_minutes}", String(o.gate?.timeout_minutes ?? 30));
    if (f.endsWith("workflows/std-cloud-env.yml") && o.cloud_env) text = text.replaceAll("{cloud_env_action}", o.cloud_env.action);
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
    ui_paths: DEFAULTS.ui_paths, ui_ignore: DEFAULTS.ui_ignore, non_deploy_paths: DEFAULTS.non_deploy_paths,
    source_platforms: [...new Set([...DEFAULTS.source_platforms, ...(p.source_platforms ?? [])])],
    decision_dirs: DEFAULTS.decision_dirs,
    codex_top: DEFAULTS.codex_top, permissions_deny: DEFAULTS.permissions_deny,
    evidence_trusted_authors: [...new Set([...DEFAULTS.evidence_trusted_authors, ...(o.evidence?.trusted_authors ?? [])])],
    preview_host_pattern: o.preview_host_pattern ?? null, design_signoff: o.design_signoff ?? true, sync_app_login: o.sync?.app_login ?? null,
    gate_budget: { e2e: o.gate?.budget?.e2e ?? DEFAULTS.gate_budget.e2e },
    e2e_release_browsers: o.e2e?.release_browsers ?? [],
    preview: { check_name: o.preview?.check_name ?? DEFAULTS.preview.check_name, comment_author: o.preview?.comment_author ?? DEFAULTS.preview.comment_author,
      cleanup: o.preview?.cleanup ? { token_ref: o.preview.cleanup.token_ref, account_ref: o.preview.cleanup.account_ref } : null },
    portal: o.portal ? { issuer: o.portal.issuer, jwks_url: o.portal.jwks_url } : null,
    modules: moduleData(o),
    cloud_env: o.cloud_env ? { action: o.cloud_env.action, token_ref: o.cloud_env.token_ref ?? null } : null,
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
  // The cloud-env workflow is opt-in: only where the overlay names the action and the repository has a cloud-env.json.
  const cloudEnv = Boolean(overlay.cloud_env?.action) && lstat("cloud-env.json")?.isFile();
  // The release check ships to every repository with a Worker (a root wrangler config) and an https staging_url, and
  // to one that names extra browsers (its own or the org's); never with "e2e": false.
  const worker = WRANGLER.some((f) => lstat(f)?.isFile());
  const httpsUrl = (u) => { try { return new URL(u).protocol === "https:"; } catch { return false; } };
  const releaseCheck = prior.e2e !== false && ((worker && httpsUrl(prior.staging_url)) || (Array.isArray(prior.e2e?.browsers) && prior.e2e.browsers.length > 0) || (overlay.e2e?.release_browsers ?? []).length > 0);
  // The PR Preview clean-up ships only to a repository with a Worker (a root wrangler config).
  const files = renderFiles(overlay, profile, version).filter(([p]) => (cloudEnv || p !== ".github/workflows/std-cloud-env.yml") && (releaseCheck || p !== ".github/workflows/std-release-check.yml")
    && (worker || p !== ".github/workflows/std-preview-cleanup.yml"));
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

  // A 0.6.x Worker with no data bindings (a brochure site) gets its staging environment and previews block here, so a
  // sync lands it; one with data bindings fails --check, naming the staging resources to create.
  const wf = WRANGLER.slice(0, 2).find((f) => lstat(f)?.isFile());
  if (wf && prior.staging !== false) { const t = migrateStaging(read(wf), { portal: overlay.portal ?? null }); if (t) write(wf, t); }

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
