#!/usr/bin/env bash
# org-apply cases against a GitHub stand-in (org/stub-github.mjs); every request is logged.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
PID=""
trap '[ -z "$PID" ] || { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }; rm -rf "$T"' EXIT
start() { # start <state.json>: (re)start the stub with a fresh log
  [ -z "$PID" ] || { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }
  rm -f "$T/port" && : >"$T/log"
  node org/stub-github.mjs "$T/port" "$T/log" "$1" &
  PID=$!
  for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
  export GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GH_TOKEN=test-token
}
run() { node org/apply.mjs --overlay "$T/org.json" "$@" 2>&1; }
writes() { grep -vc '"method":"GET"' "$T/log"; }

cat >"$T/org.json" <<'JSON'
{ "schema": 1, "pack": "example", "title": "Example", "org": "acme", "standards_repo": "acme/standards",
  "sync": { "app_client_id_var": "STANDARDS_APP_CLIENT_ID", "app_key_secret": "STANDARDS_APP_PRIVATE_KEY" },
  "org_admin": { "app": { "id": 4242, "slug": "acme-bot", "name": "acme-bot" },
                 "staged": ["site"], "extra_restricted_paths": ["vault/**"] } }
JSON
# Today's org: one hand-made main ruleset (admin bypass, rebase allowed), one stray ruleset, no flow property.
cat >"$T/state.json" <<'JSON'
{ "org": "acme",
  "repos": [{"name":"app"},{"name":"site"},{"name":"gone","archived":true}],
  "property": null, "values": {},
  "rulesets": [
    { "name": "hand-made main", "target": "branch", "enforcement": "active",
      "bypass_actors": [{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}],
      "conditions": { "ref_name": {"include": ["refs/heads/main", "~DEFAULT_BRANCH"], "exclude": []}, "repository_name": {"include": ["~ALL"], "exclude": []} },
      "rules": [ {"type": "deletion"}, {"type": "non_fast_forward"},
                 {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "allowed_merge_methods": ["merge","squash","rebase"]}},
                 {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "do_not_enforce_on_create": true, "required_status_checks": [{"context": "gate", "integration_id": 15368}]}} ] },
    { "name": "stray", "target": "branch", "enforcement": "active", "bypass_actors": [],
      "conditions": { "ref_name": {"include": ["refs/heads/release"], "exclude": []}, "repository_name": {"include": ["~ALL"], "exclude": []} },
      "rules": [ {"type": "deletion"} ] } ] }
JSON

# org-rulesets-render: placeholders filled from the overlay (thread resolution and strict checks off unless set); bypass is the org App (always) and org admins
# (pull_request only, branch rulesets; GitHub refuses that mode on push rulesets); thread resolution off
# unless the overlay turns it on; extra paths and checks spread into their lists; no App id is refused.
out=$(node --input-type=module -e '
  import { render } from "./org/apply.mjs";
  import { readFileSync } from "node:fs";
  const o = JSON.parse(readFileSync(process.argv[1], "utf8"));
  const a = render(o);
  o.org_admin.review_thread_resolution = true; o.org_admin.strict_status_checks = true; o.org_admin.extra_checks = { default: [{ context: "lint" }], staged_main: [{ context: "promote-main" }], staging: [{ context: "preview" }] }; o.org_admin.push_ignored_paths = [".env.example"]; o.org_admin.max_file_size_mb = 20;
  const b = render(o);
  const rs = (x, n) => x.rulesets.find((r) => r.name.includes(n)).rules;
  let refused = false; try { render({ org_admin: {} }); } catch { refused = true; }
  console.log(JSON.stringify({
    bypass: [...new Set(a.rulesets.map((r) => `${r.target}:${JSON.stringify(r.bypass_actors)}`))].sort(),
    threadOff: rs(a, "default branch").pull_request.required_review_thread_resolution, threadOn: rs(b, "default branch").pull_request.required_review_thread_resolution,
    stagingThreadOn: rs(b, "org: staging").pull_request.required_review_thread_resolution,
    direct: rs(a, "direct").pull_request.allowed_merge_methods, staged: rs(a, "staged main").pull_request.allowed_merge_methods,
    vault: rs(a, "push").file_path_restriction.restricted_file_paths.includes("vault/**"),
    size: [rs(a, "push").max_file_size.max_file_size, rs(b, "push").max_file_size.max_file_size],
    strict: [a, b].map((x) => [...new Set(x.rulesets.flatMap((r) => r.rules.required_status_checks ? [r.rules.required_status_checks.strict_required_status_checks_policy] : []))]),
    checks: ["default branch", "staged main", "org: staging"].map((n) => rs(b, n).required_status_checks.required_status_checks.map((c) => c.context).join("+")),
    ignored: [rs(a, "push").file_path_restriction.ignored_file_paths ?? null, rs(b, "push").file_path_restriction.ignored_file_paths],
    placeholders: JSON.stringify(a).includes("\"$"), refused }));' "$T/org.json" 2>&1)
want='{"bypass":["branch:[{\"actor_id\":4242,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"},{\"actor_id\":null,\"actor_type\":\"OrganizationAdmin\",\"bypass_mode\":\"pull_request\"}]","push:[{\"actor_id\":4242,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]"],"threadOff":false,"threadOn":true,"stagingThreadOn":true,"direct":["squash"],"staged":["merge"],"vault":true,"size":[50,20],"strict":[[false],[true]],"checks":["gate+lint","gate+promote-main","gate+preview"],"ignored":[null,[".env.example"]],"placeholders":false,"refused":true}'
[ "$out" = "$want" ] && ok org-rulesets-render || fail org-rulesets-render "$out"

# engine-org-dry-run-diff: a dry run names each change (field diffs for a matched ruleset, its old name, creates,
# the stray delete, the property and the repo flows) and sends only GETs.
start "$T/state.json"
out=$(run --dry-run)
if [ "$(writes)" = 0 ] && grep -q 'update (was "hand-made main")' <<<"$out" && grep -q 'rules.pull_request.allowed_merge_methods: \["merge","rebase","squash"\] -> \["merge","squash"\]' <<<"$out" \
  && grep -q 'bypass_actors: .*OrganizationAdmin.* -> \[{"actor_id":4242' <<<"$out" && grep -q '"stray" #[0-9]*: delete' <<<"$out" \
  && grep -q 'property flow: create' <<<"$out" && grep -q 'flow=staged: site' <<<"$out" && grep -q 'flow=direct: app$' <<<"$out" && ! grep -q gone <<<"$out"; then
  ok engine-org-dry-run-diff
else fail engine-org-dry-run-diff "$out"; fi

# engine-org-apply-order: apply writes the property first, then repo flows, then creates and updates, and deletes last,
# so no branch loses its required check mid-apply.
out=$(run)
order=$(grep -v '"method":"GET"' "$T/log" | node -e 'for (const l of require("fs").readFileSync(0,"utf8").trim().split("\n")) { const {method:m,path:p}=JSON.parse(l); console.log(p.includes("schema")?"property":p.endsWith("values")?"values":m==="DELETE"?"delete":"ruleset"); }' | uniq | tr '\n' ' ')
[ "$order" = "property values ruleset delete " ] && ok engine-org-apply-order || fail engine-org-apply-order "$order :: $out"

# org-apply-idempotent: after apply, a dry run reports no changes and a second apply sends no writes,
# even though the stand-in answers with GitHub's read-only fields, null admin ids and reordered rules.
: >"$T/log"
out=$(run --dry-run; run)
if grep -q 'no changes' <<<"$out" && [ "$(writes)" = 0 ] && [ "$(grep -c 'no changes' <<<"$out")" = 2 ]; then ok org-apply-idempotent; else fail org-apply-idempotent "$out"; fi

# engine-org-flow-property: the `flow` property is defined (direct|staged, required, default direct); overlay-staged
# repos are staged, every other active repo direct, archived repos untouched.
got=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(JSON.stringify([s.property.allowed_values,s.property.required,s.property.default_value,Object.fromEntries(Object.entries(s.values).sort())]))' "$T/state.json")
[ "$got" = '[["direct","staged"],true,"direct",{"app":"direct","site":"staged"}]' ] && ok engine-org-flow-property || fail engine-org-flow-property "$got"

# engine-org-push-external: with push_ruleset "external" the org's own push ruleset is neither updated nor
# deleted, a push ruleset org-apply made earlier is left alone too, and nothing else changes; managed mode would delete it.
node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8")); s.rulesets.push({name:"own push rules",target:"push",enforcement:"active",bypass_actors:[],conditions:{repository_name:{include:["~ALL"],exclude:[]}},rules:[{type:"file_path_restriction",parameters:{restricted_file_paths:[".env.*"]}}]}); require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
start "$T/state.json"
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8")); o.org_admin.push_ruleset="external"; require("fs").writeFileSync(f+".ext",JSON.stringify(o))' "$T/org.json"
ext=$(node org/apply.mjs --overlay "$T/org.json.ext" 2>&1; node org/apply.mjs --overlay "$T/org.json.ext" --dry-run 2>&1)
managed=$(run --dry-run)
if ! grep -qi push <<<"$ext" && grep -q 'no changes' <<<"$ext" && grep -q '"own push rules" #[0-9]*: delete' <<<"$managed" \
  && node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.exit(s.rulesets.filter(r=>r.target==="push").map(r=>r.name).sort().join()==="org: push hygiene (secret files, large files),own push rules"?0:1)' "$T/state.json"; then
  ok engine-org-push-external
else fail engine-org-push-external "$ext :: $managed"; fi

# engine-org-app-link: create-app prints GitHub's URL-parameter registration link for the org, prefilled with
# the overlay's App name, webhook off, and exactly the manifest's permissions.
link=$(run create-app | grep -o 'https://github.com/organizations/[^ ]*')
got=$(node -e 'const u=new URL(process.argv[1]); const q=Object.fromEntries(u.searchParams); const perms=Object.keys(q).filter(k=>!["name","url","description","public","webhook_active"].includes(k)).sort().map(k=>k+"="+q[k]).join(","); console.log(u.pathname, q.name, q.public, q.webhook_active, perms)' "$link" 2>&1)
[ "$got" = "/organizations/acme/settings/apps/new acme-bot false false actions=write,checks=read,contents=write,issues=write,metadata=read,pull_requests=write,statuses=read,workflows=write" ] && ok engine-org-app-link || fail engine-org-app-link "$got"

done_cases
