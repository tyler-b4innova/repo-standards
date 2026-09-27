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
  "org_admin": { "app": { "id": 4242, "slug": "acme-bot", "name": "acme-bot", "issued_var": "APP_KEY_ISSUED" },
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
      "rules": [ {"type": "deletion"} ] } ],
  "app": { "code": "good-code", "result": { "id": 777, "slug": "acme-bot", "client_id": "Iv0000", "pem": "PEM-SECRET-MATERIAL", "owner": {"login": "acme"} } } }
JSON

# org-rulesets-render: placeholders filled from the overlay; bypass is the org App only; thread resolution off
# unless the overlay turns it on; extra paths and checks spread into their lists; no App id is refused.
out=$(node --input-type=module -e '
  import { render } from "./org/apply.mjs";
  import { readFileSync } from "node:fs";
  const o = JSON.parse(readFileSync(process.argv[1], "utf8"));
  const a = render(o);
  o.org_admin.review_thread_resolution = true; o.org_admin.extra_checks = { staged_main: [{ context: "promote-main" }] }; o.org_admin.max_file_size_mb = 20;
  const b = render(o);
  const rs = (x, n) => x.rulesets.find((r) => r.name.includes(n)).rules;
  let refused = false; try { render({ org_admin: {} }); } catch { refused = true; }
  console.log(JSON.stringify({
    bypass: [...new Set(a.rulesets.map((r) => JSON.stringify(r.bypass_actors)))],
    threadOff: rs(a, "default branch").pull_request.required_review_thread_resolution, threadOn: rs(b, "default branch").pull_request.required_review_thread_resolution,
    stagingThreadOn: rs(b, "staged staging").pull_request.required_review_thread_resolution,
    direct: rs(a, "direct").pull_request.allowed_merge_methods, staged: rs(a, "staged main").pull_request.allowed_merge_methods,
    vault: rs(a, "push").file_path_restriction.restricted_file_paths.includes("vault/**"),
    size: [rs(a, "push").max_file_size.max_file_size, rs(b, "push").max_file_size.max_file_size],
    checks: rs(b, "staged main").required_status_checks.required_status_checks.map((c) => c.context),
    placeholders: JSON.stringify(a).includes("\"$"), refused }));' "$T/org.json" 2>&1)
want='{"bypass":["[{\"actor_id\":4242,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]"],"threadOff":false,"threadOn":true,"stagingThreadOn":true,"direct":["squash"],"staged":["merge"],"vault":true,"size":[50,20],"checks":["gate","promote-main"],"placeholders":false,"refused":true}'
[ "$out" = "$want" ] && ok org-rulesets-render || fail org-rulesets-render "$out"

# org-apply-dry-run-diff: a dry run names each change (field diffs for a matched ruleset, its old name, creates,
# the stray delete, the property and the repo flows) and sends only GETs.
start "$T/state.json"
out=$(run --dry-run)
if [ "$(writes)" = 0 ] && grep -q 'update (was "hand-made main")' <<<"$out" && grep -q 'rules.pull_request.allowed_merge_methods: \["merge","rebase","squash"\] -> \["merge","squash"\]' <<<"$out" \
  && grep -q 'bypass_actors: .*OrganizationAdmin.* -> \[{"actor_id":4242' <<<"$out" && grep -q '"stray" #[0-9]*: delete' <<<"$out" \
  && grep -q 'property flow: create' <<<"$out" && grep -q 'flow=staged: site' <<<"$out" && grep -q 'flow=direct: app$' <<<"$out" && ! grep -q gone <<<"$out"; then
  ok org-apply-dry-run-diff
else fail org-apply-dry-run-diff "$out"; fi

# org-apply-order: apply writes the property first, then repo flows, then creates and updates, and deletes last,
# so no branch loses its required check mid-apply.
out=$(run)
order=$(grep -v '"method":"GET"' "$T/log" | node -e 'for (const l of require("fs").readFileSync(0,"utf8").trim().split("\n")) { const {method:m,path:p}=JSON.parse(l); console.log(p.includes("schema")?"property":p.endsWith("values")?"values":m==="DELETE"?"delete":"ruleset"); }' | uniq | tr '\n' ' ')
[ "$order" = "property values ruleset delete " ] && ok org-apply-order || fail org-apply-order "$order :: $out"

# org-apply-idempotent: after apply, a dry run reports no changes and a second apply sends no writes,
# even though the stand-in answers with GitHub's read-only fields, null admin ids and reordered rules.
: >"$T/log"
out=$(run --dry-run; run)
if grep -q 'no changes' <<<"$out" && [ "$(writes)" = 0 ] && [ "$(grep -c 'no changes' <<<"$out")" = 2 ]; then ok org-apply-idempotent; else fail org-apply-idempotent "$out"; fi

# org-flow-property: the `flow` property is defined (direct|staged, required, default direct); overlay-staged
# repos are staged, every other active repo direct, archived repos untouched.
got=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(JSON.stringify([s.property.allowed_values,s.property.required,s.property.default_value,Object.fromEntries(Object.entries(s.values).sort())]))' "$T/state.json")
[ "$got" = '[["direct","staged"],true,"direct",{"app":"direct","site":"staged"}]' ] && ok org-flow-property || fail org-flow-property "$got"

# org-app-manifest: create-app writes a page that posts the manifest to the org's App form (overlay name, no
# webhook, only the listed permissions); --code stores the key through `gh secret set` stdin and never prints
# it; an App owned by another account is refused with nothing stored.
mkdir -p "$T/bin" && cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$* | stdin=\$(cat | shasum -a 256 | cut -c1-12)" >>"$T/gh.log"
EOF
chmod +x "$T/bin/gh"
page=$(run create-app | sed -n 's/^App manifest page: //p')
m=$(node -e 'const h=require("fs").readFileSync(process.argv[1],"utf8"); const v=h.match(/name="manifest" value="([^"]*)"/)[1].replace(/&quot;/g,"\"").replace(/&lt;/g,"<").replace(/&amp;/g,"&"); const a=h.match(/action="([^"]*)"/)[1]; const j=JSON.parse(v); console.log(a.split("?")[0], j.name, "hook" in j || "hook_attributes" in j, j.default_events.length, Object.keys(j.default_permissions).sort().join(","), j.redirect_url)' "$page" 2>&1)
pem_sha=$(printf 'PEM-SECRET-MATERIAL' | shasum -a 256 | cut -c1-12)
out=$(PATH="$T/bin:$PATH" run create-app --code good-code)
if [ "$m" = "https://github.com/organizations/acme/settings/apps/new acme-bot false 0 actions,actions_variables,checks,contents,issues,metadata,pull_requests,statuses,workflows https://github.com/acme/standards" ] \
  && ! grep -q PEM-SECRET <<<"$out" && grep -q "secret set STANDARDS_APP_PRIVATE_KEY -R acme/standards | stdin=$pem_sha" "$T/gh.log" \
  && grep -q 'variable set STANDARDS_APP_CLIENT_ID -R acme/standards --body Iv0000' "$T/gh.log" && grep -q 'variable set APP_KEY_ISSUED' "$T/gh.log" && grep -q '"id": 777' <<<"$out"; then
  : >"$T/gh.log"
  node -e 'const f=process.argv[1],s=JSON.parse(require("fs").readFileSync(f,"utf8")); s.app.result.owner.login="someone-else"; require("fs").writeFileSync(f,JSON.stringify(s))' "$T/state.json"
  start "$T/state.json"
  bad=$(PATH="$T/bin:$PATH" run create-app --code good-code)
  if grep -q 'not acme; nothing stored' <<<"$bad" && [ ! -s "$T/gh.log" ]; then ok org-app-manifest; else fail org-app-manifest "$bad"; fi
else fail org-app-manifest "$m :: $out :: $(cat "$T/gh.log" 2>/dev/null)"; fi

done_cases
