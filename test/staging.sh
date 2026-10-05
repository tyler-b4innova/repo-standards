#!/usr/bin/env bash
# Staging is a Wrangler environment (its own Worker and resources); PR Previews point at staging; nothing outside
# production names a production resource. Through apply (the brochure migration) and scripts/agent/setup.sh --check.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}" >/dev/null; }
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "${OVERLAY:-$OV}" --version 0.1.0 --target "$1" >/dev/null; }
check() { (cd "$1" && scripts/agent/setup.sh --check) 2>&1; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
# repo <name> <wrangler.jsonc text>: a Worker repository with the pack applied over its config
repo() { local d=$T/$1; git init -q -b main "$d"; printf '%s\n' "$2" >"$d/wrangler.jsonc"; apply "$d"; commit "$d" init; echo "$d"; }
# with <repo> <node expression on cfg>: rewrite the config as JSON
with() { jset "$1/wrangler.jsonc" "$2"; commit "$1"; }

# A data app: production D1, KV, R2, a queue (produced and consumed), a Workflow, a service binding and cron.
DATA='{
  "name": "app",
  "main": "src/index.ts",
  "vars": { "ENVIRONMENT": "production" },
  "routes": [{ "pattern": "app.example.com", "custom_domain": true }],
  "d1_databases": [{ "binding": "DB", "database_name": "app-db", "database_id": "d1-prod" }],
  "kv_namespaces": [{ "binding": "KV", "id": "kv-prod" }],
  "r2_buckets": [{ "binding": "FILES", "bucket_name": "app-files" }],
  "queues": { "producers": [{ "binding": "JOBS", "queue": "app-jobs" }], "consumers": [{ "queue": "app-jobs" }] },
  "workflows": [{ "binding": "FLOW", "name": "app-flow", "class_name": "Flow" }],
  "services": [{ "binding": "API", "service": "api" }],
  "triggers": { "crons": ["0 5 * * *"] }
}'
GOOD='o.env={staging:{vars:{ENVIRONMENT:"staging"},routes:[{pattern:"staging.app.example.com",custom_domain:true}],
  d1_databases:[{binding:"DB",database_name:"app-db-staging",database_id:"d1-staging"}],kv_namespaces:[{binding:"KV",id:"kv-staging"}],
  r2_buckets:[{binding:"FILES",bucket_name:"app-files-staging"}],queues:{producers:[{binding:"JOBS",queue:"app-jobs-staging"}],consumers:[{queue:"app-jobs-staging"}]},
  workflows:[{binding:"FLOW",name:"app-flow-staging",class_name:"Flow"}],services:[{binding:"API",service:"api-staging"}]}};
  o.previews={vars:{ENVIRONMENT:"preview"},d1_databases:[{binding:"DB",database_name:"app-db-staging",database_id:"d1-staging"}],kv_namespaces:[{binding:"KV",id:"kv-staging"}],
  r2_buckets:[{binding:"FILES",bucket_name:"app-files-staging"}],queues:{producers:[{binding:"JOBS",queue:"app-jobs-staging"}]},
  workflows:[{binding:"FLOW",name:"app-flow-staging",class_name:"Flow"}],services:[{binding:"API",service:"api-staging"}]}'

# ---- env.staging is required; a data app is never auto-migrated (its staging resources must be created)
why=""
A=$(repo app "$DATA"); grep -q '"env"' "$A/wrangler.jsonc" && why="data app migrated"
o=$(check "$A"); has "has no env.staging" "$o" && has "create them with the cf CLI" "$o" || why="$why; data app without env.staging: $o"
with "$A" "$GOOD"; o=$(check "$A") || why="$why; isolated data app failed: $o"
# a staging Worker named like production, inherited production routes, or a production route
with "$A" 'o.env.staging.name="app"'; o=$(check "$A"); has "env.staging.name is the production Worker" "$o" || why="$why; same name: $o"
with "$A" 'delete o.env.staging.name; delete o.env.staging.routes'; o=$(check "$A"); has "inherits the production routes" "$o" || why="$why; inherited routes: $o"
with "$A" 'o.env.staging.routes=[{pattern:"app.example.com",custom_domain:true}]'; o=$(check "$A"); has "a production route" "$o" || why="$why; prod route: $o"
with "$A" 'o.env.staging.routes=[]; o.env.staging.workers_dev=true'
# bindings and vars are not inherited: each must be re-declared
with "$A" 'delete o.env.staging.kv_namespaces; delete o.env.staging.vars'; o=$(check "$A"); has "env.staging lacks kv_namespaces KV" "$o" && has "env.staging lacks vars ENVIRONMENT" "$o" || why="$why; not inherited: $o"
# a TOML config is not checked, but says so
D=$T/toml; git init -q -b main "$D"; printf 'name = "t"\n' >"$D/wrangler.toml"; apply "$D"; commit "$D"; o=$(check "$D") && has "wrangler.toml is not checked" "$o" || why="$why; toml: $o"
# staging: false opts a Worker out of the staging environment (previews are still checked below)
jset "$A/standards.json" 'o.staging=false'; with "$A" 'delete o.env'; o=$(check "$A") || why="$why; staging false: $o"
jset "$A/standards.json" 'delete o.staging'; with "$A" "$GOOD"
if [ -z "$why" ]; then ok staging-env-required; else fail staging-env-required "$why"; fi

# ---- a brochure site (no data bindings) is migrated by apply: env.staging and previews, comments kept, check passes
why=""
B=$(repo site '{
  // brochure
  "name": "site",
  "main": "src/index.ts",
  "assets": { "directory": "./dist" }, // static
  "vars": { "SENTRY_ENVIRONMENT": "production", "CONTACT_TO": "a@example.com" },
  "send_email": [{ "name": "SEND_EMAIL" }],
  "routes": [{ "pattern": "site.example.com", "custom_domain": true }]
  // the end
}')
grep -q '// the end' "$B/wrangler.jsonc" && grep -q '// static' "$B/wrangler.jsonc" || why="comments lost"
node --input-type=module -e 'const {parse}=await import(process.argv[1]);const c=parse((await import("node:fs")).readFileSync(process.argv[2],"utf8"));const s=c.env.staging;
if(!(s.routes.length===0&&s.workers_dev===true&&s.vars.SENTRY_ENVIRONMENT==="staging"&&s.vars.CONTACT_TO==="a@example.com"&&s.send_email[0].name==="SEND_EMAIL"&&c.previews.vars.SENTRY_ENVIRONMENT==="preview"))process.exit(1)' "$ENGINE/template/scripts/agent/staging.mjs" "$B/wrangler.jsonc" || why="$why; migrated config: $(cat "$B/wrangler.jsonc")"
o=$(check "$B") && has "staging Worker is on workers.dev" "$o" || why="$why; migrated brochure check: $o"
before=$(cat "$B/wrangler.jsonc"); apply "$B"; [ "$before" = "$(cat "$B/wrangler.jsonc")" ] || why="$why; second apply changed the config"
if [ -z "$why" ]; then ok staging-brochure-migrated; else fail staging-brochure-migrated "$why"; fi

# ---- nothing outside production names a production resource
why=""
for c in 'o.env.staging.d1_databases[0].database_id="d1-prod"' 'o.env.staging.kv_namespaces[0].id="kv-prod"' 'o.previews.r2_buckets[0].bucket_name="app-files"' \
  'o.previews.queues.producers[0].queue="app-jobs"' 'o.env.staging.queues.consumers[0].queue="app-jobs"' 'o.previews.workflows[0].name="app-flow"' \
  'o.env.staging.services[0].service="api"' 'o.previews.services[0].service="app"'; do
  with "$A" "$c"; o=$(check "$A"); has "production" "$o" && has "| fix: " "$o" || why="$why; [$c] passed: $o"
  with "$A" "$GOOD"
done
# previews never carry consumers, cron or routes (they target production only)
for c in 'o.previews.queues.consumers=[{queue:"app-jobs-staging"}]' 'o.previews.triggers={crons:["0 1 * * *"]}' 'o.previews.routes=[]'; do
  with "$A" "$c"; o=$(check "$A"); has "never target Previews" "$o" || why="$why; [$c] passed: $o"
  with "$A" "$GOOD"
done
if [ -z "$why" ]; then ok staging-no-production-resources; else fail staging-no-production-resources "$why"; fi

# ---- previews point every data binding at the staging resources
why=""
with "$A" 'delete o.previews'; o=$(check "$A"); has "has no previews block" "$o" || why="no previews: $o"
with "$A" "$GOOD"; with "$A" 'o.previews.d1_databases=[]'; o=$(check "$A"); has "previews lacks d1_databases DB" "$o" || why="$why; missing: $o"
with "$A" "$GOOD"; with "$A" 'o.previews.kv_namespaces[0].id="kv-other"'; o=$(check "$A"); has "not staging's" "$o" || why="$why; other resource: $o"
with "$A" "$GOOD"
# the shipped example config is the standard shape and passes
E=$T/example; git init -q -b main "$E"; cp examples/wrangler.staging.jsonc "$E/wrangler.jsonc"; apply "$E"; jset "$E/standards.json" 'o.staging=undefined'; commit "$E"
o=$(check "$E") || why="$why; example config: $o"
if [ -z "$why" ]; then ok previews-point-at-staging; else fail previews-point-at-staging "$why"; fi

# ---- secrets: standards.json shape; a client-owned account binds every required secret from Secrets Store
why=""
jset "$A/standards.json" 'o.secrets={required:["bad name"]}'; commit "$A"; o=$(check "$A"); has "standards.json secrets" "$o" || why="bad shape: $o"
jset "$A/standards.json" 'o.secrets={required:["MAIL_KEY"],store:"secrets_store"}'; commit "$A"; o=$(check "$A")
has "top level has no secrets_store_secrets binding for MAIL_KEY" "$o" && has "env.staging has no" "$o" && has "previews has no" "$o" || why="$why; store: $o"
with "$A" 'const b={binding:"MAIL_KEY",store_id:"store-1",secret_name:"mail"};for(const s of [o,o.env.staging,o.previews])s.secrets_store_secrets=[b]'
o=$(check "$A") || why="$why; bound store failed: $o"
jset "$A/standards.json" 'o.secrets={required:["MAIL_KEY"],store:"1password"}'; with "$A" "delete o.secrets_store_secrets; $GOOD"; o=$(check "$A") || why="$why; 1password: $o"
if [ -z "$why" ]; then ok staging-secrets-declared; else fail staging-secrets-declared "$why"; fi

# ---- portal pass: with the overlay's portal, staging and previews carry its settings and the Worker calls the check
why=""
PO=$T/portal.json; node -e 'const o=require(process.argv[1]);o.portal={issuer:"https://portal.example.com",jwks_url:"https://portal.example.com/.well-known/jwks.json"};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$PO"
o=$(node -e 'const o=require(process.argv[1]);o.portal={issuer:"http://portal.example.com/x",jwks_url:"nope"};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/bad.json"; node bin/repo-standards.mjs apply --overlay "$T/bad.json" --target "$T/x" 2>&1) && why="bad portal accepted"
has "portal.issuer must be" "$o" && has "portal.jwks_url must be" "$o" || why="$why; [$o]"
OVERLAY=$PO apply "$A"; commit "$A"; o=$(check "$A")
has "env.staging.vars must set" "$o" && has "PORTAL_AUD \"app-staging\"" "$o" && has "previews.vars must set" "$o" && has "no Worker source calls the portal pass check" "$o" || why="$why; unwired: $o"
with "$A" 'const p={PORTAL_ISSUER:"https://portal.example.com",PORTAL_JWKS_URL:"https://portal.example.com/.well-known/jwks.json"};Object.assign(o.env.staging.vars,p,{PORTAL_AUD:"app-staging"});Object.assign(o.previews.vars,p,{PORTAL_AUD:"app"});o.assets={directory:"dist"}'
mkdir -p "$A/src"; printf 'import { portalPass } from "../scripts/agent/portal-pass.mjs";\nexport default { async fetch(request, env) { const denied = await portalPass(request, env); if (denied) return denied; return new Response("ok"); } };\n' >"$A/src/index.ts"; commit "$A"
o=$(check "$A"); has "assets before the Worker" "$o" || why="$why; assets first: $o"
with "$A" 'o.assets.run_worker_first=true'; o=$(check "$A") || why="$why; wired: $o"
# a brochure migrated under a portal overlay gets the settings itself
P=$T/psite; git init -q -b main "$P"; printf '{ "name": "ps", "main": "src/w.ts", "vars": {} }\n' >"$P/wrangler.jsonc"; OVERLAY=$PO apply "$P"
grep -q '"PORTAL_AUD": "ps-staging"' "$P/wrangler.jsonc" && grep -q '"PORTAL_AUD": "ps"' "$P/wrangler.jsonc" || why="$why; migration without portal vars: $(cat "$P/wrangler.jsonc")"
if [ -z "$why" ]; then ok portal-pass-wired; else fail portal-pass-wired "$why"; fi
done_cases
