#!/usr/bin/env node
// org-apply: make an organization's rulesets and `flow` property match org/rulesets.json, and create the org App.
//   org-apply --overlay <org.json> --dry-run        print the diff against the live org; sends only GETs
//   org-apply --overlay <org.json>                  apply it: property, repo flows, create/update rulesets, then delete unlisted ones
//   org-apply create-app --overlay <org.json>       print the one-click link that registers the org App
// Run by an org admin with their own gh login (GH_TOKEN, or `gh auth token`).
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { client } from "../lib/sync.mjs";

const DEF = JSON.parse(readFileSync(new URL("./rulesets.json", import.meta.url), "utf8"));
const MANIFEST = JSON.parse(readFileSync(new URL("./app-manifest.json", import.meta.url), "utf8"));
const byName = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const sorted = (a) => [...(a ?? [])].sort((x, y) => byName(JSON.stringify(x), JSON.stringify(y)));
const PROPERTY_FIELDS = ["value_type", "allowed_values", "required", "default_value", "values_editable_by", "description"];

// Fill `$` placeholders from overlay.org_admin; a placeholder inside an array spreads a list value.
export function render(overlay) {
  const oa = overlay.org_admin ?? {};
  if (!Number.isInteger(oa.app?.id) || !oa.app?.slug) throw new Error("overlay org_admin.app.id (number) and org_admin.app.slug are required");
  const vars = {
    review_thread_resolution: oa.review_thread_resolution === true,
    "extra_checks.staged_main": oa.extra_checks?.staged_main ?? [],
    extra_restricted_paths: oa.extra_restricted_paths ?? [],
    max_file_size_mb: oa.max_file_size_mb ?? 50,
  };
  const fill = (v) => {
    if (typeof v === "string" && v.startsWith("$")) {
      if (!(v.slice(1) in vars)) throw new Error(`org/rulesets.json: unknown placeholder ${v}`);
      return vars[v.slice(1)];
    }
    if (Array.isArray(v)) return v.flatMap((x) => (typeof x === "string" && x.startsWith("$") && Array.isArray(fill(x)) ? fill(x) : [fill(x)]));
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, fill(x)]));
    return v;
  };
  // Org admins bypass only through a PR (break-glass merge): local agent sessions run on an admin's
  // gh login, and "always" would let them push or force-push to protected branches. Push rulesets
  // refuse the pull_request mode, so there the App alone bypasses.
  const app = { actor_id: oa.app.id, actor_type: "Integration", bypass_mode: "always" };
  const admin = { actor_id: null, actor_type: "OrganizationAdmin", bypass_mode: "pull_request" };
  const bypass = (r) => (r.target === "push" ? [app] : [app, admin]);
  const prDefaults = { required_review_thread_resolution: vars.review_thread_resolution };
  return {
    property: DEF.property,
    rulesets: DEF.rulesets.map((r) => canon({ ...fill(r), enforcement: "active", bypass_actors: bypass(r) }, prDefaults)),
  };
}

// One comparable shape for desired and live rulesets: read-only fields dropped, defaults filled,
// lists sorted, rules keyed by type (a ruleset holds each rule type once).
export function canon(r, prDefaults = {}) {
  const cond = {};
  for (const [k, v] of Object.entries(r.conditions ?? {})) {
    if (!v) continue;
    cond[k] = { include: sorted(v.include), exclude: sorted(v.exclude) };
    if (k === "repository_name") cond[k].protected = v.protected ?? false;
  }
  const rules = {};
  for (const { type, parameters: p } of r.rules ?? []) {
    let q = p ?? {};
    if (type === "pull_request") {
      q = {
        required_approving_review_count: 0, dismiss_stale_reviews_on_push: true, require_code_owner_review: false,
        require_last_push_approval: false, required_review_thread_resolution: false,
        require_extra_approval_for_unattributed_changes: false, required_reviewers: [], allowed_merge_methods: ["merge", "squash", "rebase"],
        ...prDefaults, ...q,
      };
      q.allowed_merge_methods = sorted(q.allowed_merge_methods);
    } else if (type === "required_status_checks") {
      q = {
        strict_required_status_checks_policy: q.strict_required_status_checks_policy ?? false,
        do_not_enforce_on_create: q.do_not_enforce_on_create ?? false,
        required_status_checks: sorted((q.required_status_checks ?? []).map((c) => (c.integration_id ? { context: c.context, integration_id: c.integration_id } : { context: c.context }))),
      };
    } else if (type === "file_path_restriction") {
      q = { restricted_file_paths: sorted(q.restricted_file_paths), ...(q.ignored_file_paths?.length && { ignored_file_paths: sorted(q.ignored_file_paths) }) };
    } else if (type === "max_file_size") {
      q = { max_file_size: q.max_file_size, ...(q.ignored_file_paths?.length && { ignored_file_paths: sorted(q.ignored_file_paths) }) };
    }
    rules[type] = q;
  }
  // GitHub reads an org-admin actor back with actor_id null.
  const bypass = (r.bypass_actors ?? []).map((b) => ({ actor_id: b.actor_type === "OrganizationAdmin" ? null : b.actor_id, actor_type: b.actor_type, bypass_mode: b.bypass_mode }));
  return { name: r.name, target: r.target, enforcement: r.enforcement, bypass_actors: sorted(bypass), conditions: cond, rules };
}

const toApi = (c) => ({
  ...c,
  bypass_actors: c.bypass_actors.map((b) => (b.actor_type === "OrganizationAdmin" ? { ...b, actor_id: 1 } : b)),
  rules: Object.entries(c.rules).map(([type, p]) => (Object.keys(p).length ? { type, parameters: p } : { type })),
});

// Leaf-level differences between two canonical objects, as "path: old -> new" lines.
function fieldDiff(a, b, path = "") {
  const leaf = (v) => v === null || typeof v !== "object" || Array.isArray(v);
  if (leaf(a) || leaf(b)) return JSON.stringify(a) === JSON.stringify(b) ? [] : [`${path || "."}: ${JSON.stringify(a) ?? "(none)"} -> ${JSON.stringify(b) ?? "(none)"}`];
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].sort().flatMap((k) => fieldDiff(a[k], b[k], path ? `${path}.${k}` : k));
}

// Everything that would change, in apply order: property, repo flows, create/update rulesets, deletes last.
export async function plan(gh, overlay) {
  const org = overlay.org;
  const want = render(overlay);
  const steps = [];

  const liveProp = await gh("GET", `orgs/${org}/properties/schema/${want.property.property_name}`, null, { allow404: true });
  const pick = (p) => Object.fromEntries(PROPERTY_FIELDS.map((k) => [k, k === "allowed_values" ? sorted(p?.[k]) : p?.[k] ?? null]));
  const propDiff = liveProp ? fieldDiff(pick(liveProp), pick(want.property)) : ["(absent) -> defined"];
  if (propDiff.length) {
    const { property_name: name, ...body } = want.property;
    steps.push({ what: `property ${name}: ${liveProp ? "update" : "create"}`, detail: propDiff, call: ["PUT", `orgs/${org}/properties/schema/${name}`, body] });
  }

  const repos = (await gh("GET", `orgs/${org}/repos?per_page=100&type=all`)).filter((r) => !r.archived).map((r) => r.name);
  const staged = new Set(overlay.org_admin.staged ?? []);
  for (const s of staged) if (!repos.includes(s)) console.error(`warning: org_admin.staged names ${s}, which is not an active repository in ${org}`);
  const values = await gh("GET", `orgs/${org}/properties/values?per_page=100`);
  const current = Object.fromEntries(values.map((v) => [v.repository_name, v.properties.find((p) => p.property_name === "flow")?.value ?? null]));
  const moves = {};
  for (const r of repos) {
    const to = staged.has(r) ? "staged" : "direct";
    if (current[r] !== to) (moves[to] ??= []).push(r);
  }
  for (const [to, names] of Object.entries(moves)) {
    for (let i = 0; i < names.length; i += 30) {
      const chunk = names.slice(i, i + 30);
      steps.push({
        what: `flow=${to}: ${chunk.join(", ")}`, detail: chunk.map((r) => `${r}: ${current[r] ?? "(unset)"} -> ${to}`),
        call: ["PATCH", `orgs/${org}/properties/values`, { repository_names: chunk, properties: [{ property_name: "flow", value: to }] }],
      });
    }
  }

  const listed = await gh("GET", `orgs/${org}/rulesets?per_page=100`);
  const live = [];
  for (const s of listed.filter((x) => (x.source_type ?? "Organization") === "Organization")) live.push(await gh("GET", `orgs/${org}/rulesets/${s.id}`));
  // A live ruleset matches by name, else by identical target and conditions (a rename keeps its id).
  const used = new Set();
  const same = (l, w) => l.target === w.target && JSON.stringify(canon(l).conditions) === JSON.stringify(w.conditions);
  const match = want.rulesets.map((w) => live.find((l) => l.name === w.name));
  match.forEach((l) => l && used.add(l.id));
  want.rulesets.forEach((w, i) => {
    match[i] ??= live.find((l) => !used.has(l.id) && !want.rulesets.some((x) => x.name === l.name) && same(l, w));
    if (match[i]) used.add(match[i].id);
  });
  const deletes = [];
  for (const [i, w] of want.rulesets.entries()) {
    const l = match[i];
    if (!l) steps.push({ what: `ruleset "${w.name}": create`, detail: [], call: ["POST", `orgs/${org}/rulesets`, toApi(w)] });
    else {
      const d = fieldDiff(canon(l), w);
      if (d.length) steps.push({ what: `ruleset "${w.name}" #${l.id}: update${l.name === w.name ? "" : ` (was "${l.name}")`}`, detail: d, call: ["PUT", `orgs/${org}/rulesets/${l.id}`, toApi(w)] });
    }
  }
  for (const l of live) {
    if (!used.has(l.id)) deletes.push({ what: `ruleset "${l.name}" #${l.id}: delete (not in org/rulesets.json)`, detail: [], call: ["DELETE", `orgs/${org}/rulesets/${l.id}`] });
  }
  return [...steps, ...deletes];
}

function token() {
  let t = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  try { t ||= execFileSync("gh", ["auth", "token"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch {}
  if (!t) throw new Error("no GH_TOKEN, GITHUB_TOKEN or gh login: run as an org admin");
  return t;
}

export async function reconcile({ overlay, dryRun }) {
  if (!overlay.org) throw new Error("overlay org is required");
  const gh = client(token());
  const steps = await plan(gh, overlay);
  console.log(`org-apply ${overlay.org}${dryRun ? " (dry run: nothing sent)" : ""}`);
  for (const s of steps) {
    console.log(`${dryRun ? "would" : "do"}: ${s.what}`);
    for (const d of s.detail) console.log(`    ${d}`);
    if (!dryRun) await gh(...s.call);
  }
  console.log(steps.length ? `${steps.length} change(s)${dryRun ? " pending" : " applied"}` : "no changes: the org matches org/rulesets.json");
  return steps.length;
}

export function manifest(overlay) {
  const oa = overlay.org_admin ?? {};
  if (!oa.app?.name) throw new Error("overlay org_admin.app.name is required to create the App");
  const vars = { $app_name: oa.app.name, $org: overlay.org };
  const out = JSON.parse(JSON.stringify(MANIFEST, (k, v) => (typeof v === "string" ? v.replace(/\$[a-z_]+/g, (m) => vars[m] ?? m) : v)));
  delete out.$comment;
  return out;
}

// GitHub's URL-parameter registration: one link, opened by an org owner, prefilled with the manifest.
export function appLink(overlay) {
  const m = manifest(overlay);
  const q = new URLSearchParams({ name: m.name, url: m.url, description: m.description, public: String(m.public), webhook_active: "false", ...m.default_permissions });
  return `https://github.com/organizations/${encodeURIComponent(overlay.org)}/settings/apps/new?${q}`;
}

export async function run({ overlay, dryRun, cmd = "reconcile" }) {
  if (cmd === "create-app") {
    console.log(`Open as an owner of ${overlay.org}, check the prefilled form, and press "Create GitHub App":\n${appLink(overlay)}`);
    console.log(`Then: generate a private key, store it as the standards repo secret, install the App on all repositories, and set org_admin.app.id and .slug in the overlay.`);
    return;
  }
  return reconcile({ overlay, dryRun });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { values: o, positionals } = parseArgs({ args: process.argv.slice(2), allowPositionals: true, options: { overlay: { type: "string" }, "dry-run": { type: "boolean" } } });
  const cmd = positionals[0] ?? "reconcile";
  try {
    if (!o.overlay) throw new Error("--overlay <org.json> is required");
    const overlay = JSON.parse(readFileSync(o.overlay, "utf8"));
    if (!["create-app", "reconcile"].includes(cmd)) throw new Error(`unknown command ${cmd}`);
    await run({ overlay, dryRun: o["dry-run"], cmd });
  } catch (e) {
    console.error(`org-apply: ${e.message}`);
    process.exit(1);
  }
}
