// Staging and PR Previews never touch production (setup.sh --check, through check.mjs; apply's migration).
// Staging is a Wrangler environment: env.staging deploys a separate <name>-staging Worker with its own data, queues,
// Workflows, cron and keys. PR Previews (the `previews` block) point every binding at those staging resources: a
// Preview inherits nothing, and its service bindings and Workflows reach the bound Worker's production deployment.

// Bindings by kind: where they sit, and the keys naming the resource they reach (none: a binding with no resource).
const KINDS = [
  ["d1_databases", ["database_id", "database_name"]], ["kv_namespaces", ["id"]], ["r2_buckets", ["bucket_name"]],
  ["queues.producers", ["queue"]], ["workflows", ["name"]], ["services", ["service"]], ["hyperdrive", ["id"]],
  ["vectorize", ["index_name"]], ["analytics_engine_datasets", ["dataset"]], ["durable_objects.bindings", ["script_name"]],
  ["secrets_store_secrets", []], ["send_email", []], ["mtls_certificates", []], ["dispatch_namespaces", ["namespace"]],
];
// Single-object API bindings: nothing to isolate, but not inherited either.
const SINGLE = ["ai", "browser", "images", "version_metadata"];
// A data binding: one whose resource holds state a staging run could change.
const DATA = new Set(["d1_databases", "kv_namespaces", "r2_buckets", "queues.producers", "workflows", "services", "hyperdrive", "vectorize", "analytics_engine_datasets", "dispatch_namespaces"]);

const at = (o, path) => path.split(".").reduce((v, k) => (v && typeof v === "object" ? v[k] : undefined), o);
const list = (v) => (Array.isArray(v) ? v.filter((x) => x && typeof x === "object") : []);
const nameOf = (b) => b.binding ?? b.name;

// JSONC: the text's structural characters (outside strings and comments) by index, for parsing and for finding the
// config's closing brace.
function structure(text) {
  const out = [];
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') { const j = i; for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === "\\") i++; out.push([j, text.slice(j, i + 1)]); }
    else if (c === "/" && text[i + 1] === "/") { while (i < text.length && text[i] !== "\n") i++; }
    else if (c === "/" && text[i + 1] === "*") { i = text.indexOf("*/", i + 2); if (i < 0) i = text.length; else i++; }
    else if (!/\s/.test(c)) out.push([i, c]);
  }
  return out;
}
// Parsed JSONC (comments and trailing commas allowed; strings untouched), or null.
export function parse(text) {
  const t = structure(text ?? "");
  const kept = t.filter(([, x], k) => !(x === "," && ["}", "]"].includes(t[k + 1]?.[1])));
  try { return JSON.parse(kept.map(([, x]) => x).join("")); } catch { return null; }
}

export const hasData = (cfg) => KINDS.some(([k]) => DATA.has(k) && list(at(cfg, k)).length) || list(at(cfg, "queues.consumers")).length > 0
  || list(at(cfg, "durable_objects.bindings")).some((b) => b.script_name) || Boolean(at(cfg, "triggers.crons")?.length);

// Findings for a parsed root config: { fails: [[msg, fix]], warns: [msg] }. std: standards.json; pack: pack.json.
export function findings(cfg, { file, std = {}, pack = {}, required = [] }) {
  const fails = [], warns = [], F = (m, f) => fails.push([`${file}: ${m}`, f]);
  const prodName = cfg.name, prod = new Map(); // resource -> what names it in production
  for (const [k, keys] of KINDS) for (const b of list(at(cfg, k))) for (const key of keys) if (typeof b[key] === "string" && b[key]) prod.set(`${key}:${b[key]}`, `${k} ${nameOf(b) ?? ""}`.trim());
  for (const c of list(at(cfg, "queues.consumers"))) if (c.queue) prod.set(`queue:${c.queue}`, "queues.consumers");
  // production Workers: this one, and every Worker production binds to (a staging or Preview binding to one calls production)
  const prodWorkers = new Set([prodName, ...list(cfg.services).map((s) => s.service), ...list(at(cfg, "durable_objects.bindings")).map((b) => b.script_name)].filter(Boolean));
  const stage = at(cfg, "env.staging"), previews = cfg.previews, stagingName = stage?.name ?? (prodName ? `${prodName}-staging` : undefined);

  // No production resource outside production: env.staging and previews (and previews inside env.staging).
  const nonProd = [["env.staging", stage], ["previews", previews], ["env.staging.previews", stage?.previews]].filter(([, s]) => s && typeof s === "object");
  for (const [where, s] of nonProd) {
    for (const [k, keys] of KINDS) for (const b of list(at(s, k))) {
      for (const key of keys) {
        const v = b[key], hit = typeof v === "string" && (prod.get(`${key}:${v}`) || (["service", "script_name"].includes(key) && prodWorkers.has(v) && "a production Worker"));
        if (hit) F(`${where} ${k} ${nameOf(b) ?? ""} names the production resource ${v} (${hit})`.replace(/ {2,}/g, " "), `point it at the staging resource (${where === "env.staging" ? "create one with its own id" : "the one env.staging uses"}); staging and previews never reach production`);
      }
    }
    for (const c of list(at(s, "queues.consumers"))) if (c.queue && prod.has(`queue:${c.queue}`))
      F(`${where} consumes the production queue ${c.queue}`, "consume the staging queue");
  }
  if (previews && typeof previews === "object") {
    for (const k of ["routes", "route", "triggers"]) if (previews[k] !== undefined) F(`previews sets ${k}, which never target Previews`, `remove previews.${k}; cron and routes belong to production and env.staging`);
    if (at(previews, "queues.consumers") !== undefined) F("previews sets queues.consumers, which never target Previews", "remove it; env.staging consumes the staging queue");
  }

  if (std.staging === false) return { fails, warns };
  // env.staging: a separate Worker, every binding re-declared (bindings and vars are not inherited) on its own resources
  if (!stage || typeof stage !== "object") {
    F("has no env.staging (staging is its own <name>-staging Worker with its own data, deployed by scripts/agent/release.mjs main)",
      hasData(cfg) ? "add env.staging with its own D1/KV/R2/queues/Workflows/services (create them with the cf CLI), routes and vars, and a previews block pointing at them (see the standards README)"
        : "re-apply the pack (sync) to add it, or add env.staging with routes: [] and the top-level vars");
    return { fails, warns };
  }
  if (stage.name !== undefined && stage.name === prodName) F("env.staging.name is the production Worker's name", `name it ${prodName}-staging, or remove it (that is the default)`);
  const routes = (s) => [...(Array.isArray(s.routes) ? s.routes : []), ...(s.route ? [s.route] : [])].map((r) => (typeof r === "string" ? r : r?.pattern)).filter(Boolean);
  // routes and route are inherited separately, and an inherited routes wins over the staging route
  if ((cfg.routes !== undefined && stage.routes === undefined) || (cfg.route !== undefined && stage.route === undefined && stage.routes === undefined))
    F("env.staging inherits the production routes", 'set env.staging.routes to staging hosts only (or [] with "workers_dev": true)');
  // every production route except a Preview hostname that serves no production traffic (previews_enabled, enabled false)
  const prodRoutes = new Set([...(Array.isArray(cfg.routes) ? cfg.routes : []), ...(cfg.route ? [cfg.route] : [])]
    .filter((r) => !(r && typeof r === "object" && r.previews_enabled === true && r.enabled === false))
    .map((r) => (typeof r === "string" ? r : r?.pattern)).filter(Boolean));
  for (const p of routes(stage)) if (prodRoutes.has(p)) F(`env.staging routes ${p}, a production route`, "give staging its own host");
  for (const [k] of KINDS) {
    const want = list(at(cfg, k)).map(nameOf).filter(Boolean), have = new Set(list(at(stage, k)).map(nameOf));
    const missing = want.filter((n) => !have.has(n));
    if (missing.length) F(`env.staging lacks ${k} ${missing.join(", ")} (bindings are not inherited)`, `declare them in env.staging on staging resources`);
  }
  if (list(at(cfg, "queues.consumers")).length && !list(at(stage, "queues.consumers")).length)
    F("env.staging consumes no queue, but production does", "consume the staging queues in env.staging.queues.consumers");
  for (const k of SINGLE) if (cfg[k] !== undefined && stage[k] === undefined) F(`env.staging lacks ${k} (bindings are not inherited)`, `copy ${k} into env.staging`);
  const vars = Object.keys(cfg.vars ?? {}).filter((v) => !(v in (stage.vars ?? {})));
  if (vars.length) F(`env.staging lacks vars ${vars.join(", ")} (vars are not inherited)`, "declare them in env.staging.vars with staging values");

  // PR Previews: every production binding re-declared, on the resource env.staging uses
  if (!previews || typeof previews !== "object") F("has no previews block (PR Previews inherit nothing)", "add previews, pointing every binding at the staging resources");
  else {
    for (const [k, keys] of KINDS) for (const b of list(at(cfg, k))) {
      const n = nameOf(b), p = list(at(previews, k)).find((x) => nameOf(x) === n), s = list(at(stage, k)).find((x) => nameOf(x) === n);
      if (!n || !DATA.has(k)) continue;
      if (!p) F(`previews lacks ${k} ${n}`, `bind ${n} in previews to the staging resource env.staging uses`);
      else if (s) for (const key of keys) if (s[key] !== undefined && p[key] !== s[key]) F(`previews ${k} ${n} ${key} is ${JSON.stringify(p[key])}, not staging's ${JSON.stringify(s[key])}`, "point previews at the staging resources");
    }
  }

  // Secrets: required names (standards.json secrets.required and the wrangler config's secrets.required). On a
  // client-owned account they are Secrets Store bindings in every section.
  if (std.secrets?.store === "secrets_store") for (const [where, s] of [["top level", cfg], ["env.staging", stage], ["previews", previews ?? {}]]) {
    const have = new Set(list(s.secrets_store_secrets).map((b) => b.binding));
    const missing = required.filter((n) => !have.has(n));
    if (missing.length) F(`${where} has no secrets_store_secrets binding for ${missing.join(", ")}`, "bind each required secret from the account's Secrets Store (store_id, secret_name)");
  }

  // Portal pass: with the org's portal set, staging and previews refuse requests without a portal-signed pass.
  if (pack.portal) {
    const v = (s) => s?.vars ?? {};
    if (v(cfg).ENVIRONMENT !== "production") F('vars.ENVIRONMENT is not "production"', 'set top-level vars.ENVIRONMENT to "production" (production never asks for a pass)');
    for (const [where, s, aud] of [["env.staging", stage, stagingName], ["previews", previews, prodName]]) {
      const x = v(s), bad = [];
      if (!x.ENVIRONMENT || x.ENVIRONMENT === "production") bad.push("ENVIRONMENT (staging or preview)");
      if (x.PORTAL_AUD !== aud) bad.push(`PORTAL_AUD "${aud}"`);
      if (x.PORTAL_ISSUER !== pack.portal.issuer) bad.push(`PORTAL_ISSUER "${pack.portal.issuer}"`);
      if (x.PORTAL_JWKS_URL !== pack.portal.jwks_url) bad.push(`PORTAL_JWKS_URL "${pack.portal.jwks_url}"`);
      if (bad.length) F(`${where}.vars must set ${bad.join(", ")}`, "the portal pass check reads them (scripts/agent/portal-pass.mjs)");
    }
    if (!cfg.main) F("has no main, so nothing can check the portal pass", "add a Worker entry that calls portalPass first (static assets: assets.run_worker_first true)");
    else if (cfg.assets && cfg.assets.run_worker_first !== true) F("serves assets before the Worker, so they skip the portal pass", "set assets.run_worker_first to true");
  } else if (stage.workers_dev === true || (stage.workers_dev === undefined && cfg.workers_dev === true)) {
    warns.push(`${file}: the staging Worker is on workers.dev; keep it behind the org's Access until the org's portal gates staging`);
  }
  return { fails, warns };
}

// Apply's migration for a 0.6.x Worker with no data bindings (a brochure site): add env.staging (a separate Worker on
// workers.dev, its own vars and bindings, no production routes) and, when missing, a previews block, by inserting text
// before the config's closing brace, so comments and layout stay. Returns the new text, or null when it cannot (data
// bindings, an env block already, TOML, unparseable).
export function migrate(text, { portal = null } = {}) {
  const cfg = parse(text);
  if (!cfg || typeof cfg !== "object" || Array.isArray(cfg) || !cfg.name || cfg.env !== undefined || hasData(cfg)) return null;
  const vars = (env) => {
    const v = { ...(cfg.vars ?? {}) };
    for (const k of ["ENVIRONMENT", "SENTRY_ENVIRONMENT"]) if (k in v) v[k] = env;
    if (portal) Object.assign(v, { ENVIRONMENT: env, PORTAL_AUD: env === "staging" ? `${cfg.name}-staging` : cfg.name, PORTAL_ISSUER: portal.issuer, PORTAL_JWKS_URL: portal.jwks_url });
    return v;
  };
  const copy = {};
  for (const [k] of KINDS) if (at(cfg, k) !== undefined && !k.includes(".")) copy[k] = cfg[k];
  for (const k of [...SINGLE, "durable_objects"]) if (cfg[k] !== undefined) copy[k] = cfg[k];
  const staging = { ...(Object.keys(vars("staging")).length ? { vars: vars("staging") } : {}), ...copy, routes: [], workers_dev: true, preview_urls: false };
  const add = { env: { staging } };
  if (cfg.previews === undefined) add.previews = { ...(Object.keys(vars("preview")).length ? { vars: vars("preview") } : {}), ...copy };
  const body = Object.entries(add).map(([k, v]) => `  ${JSON.stringify(k)}: ${JSON.stringify(v, null, 2).replace(/\n/g, "\n  ")}`).join(",\n");
  // The comma goes right after the last property (before any trailing comment), the new keys before the closing brace.
  const t = structure(text), [end] = t.at(-1), [pos, prev] = t.at(-2); // the closing brace, and the token before it
  const head = prev === "," || prev === "{" ? text.slice(0, end) : text.slice(0, pos + prev.length) + "," + text.slice(pos + prev.length, end);
  return head.replace(/[ \t]*$/, "").replace(/\n?$/, "\n") + body + "\n" + text.slice(end);
}
