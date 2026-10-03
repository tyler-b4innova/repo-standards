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
  "org_admin": { "app": { "id": 4242, "slug": "acme-bot", "name": "acme-bot" }, "gate_integration_id": 42,
                 "staged": ["site"], "extra_restricted_paths": ["vault/**"] } }
JSON
# Today's org: one hand-made main ruleset (admin bypass, rebase allowed), one stray ruleset, no flow property.
cat >"$T/state.json" <<'JSON'
{ "org": "acme",
  "repos": [{"name":"app","allow_merge_commit":false},{"name":"site","allow_merge_commit":false,"delete_branch_on_merge":false},{"name":"gone","archived":true}],
  "property": null, "values": {},
  "rulesets": [
    { "name": "hand-made main", "target": "branch", "enforcement": "active",
      "bypass_actors": [{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}],
      "conditions": { "ref_name": {"include": ["refs/heads/main", "~DEFAULT_BRANCH"], "exclude": []}, "repository_name": {"include": ["~ALL"], "exclude": []} },
      "rules": [ {"type": "deletion"}, {"type": "non_fast_forward"},
                 {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "require_extra_approval_for_unattributed_changes": true, "allowed_merge_methods": ["merge","squash","rebase"]}},
                 {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "do_not_enforce_on_create": true, "required_status_checks": [{"context": "gate", "integration_id": 42}]}} ] },
    { "name": "stray", "target": "branch", "enforcement": "active", "bypass_actors": [],
      "conditions": { "ref_name": {"include": ["refs/heads/release"], "exclude": []}, "repository_name": {"include": ["~ALL"], "exclude": []} },
      "rules": [ {"type": "deletion"} ] } ] }
JSON

# org-rulesets-render: placeholders filled from the overlay (strict checks off unless set); bypass is the org App (always) and org admins
# (pull_request only, branch rulesets; GitHub refuses that mode on push rulesets, which carry no bypass, not even the App's); every PR ruleset requires resolved
# review threads, and code-owner review only on main (direct repos' default branch and main, staged repos' main);
# `gate` is the only required check unless the overlay adds some; the removed review settings are refused;
# extra paths and checks spread into their lists; `gate` is pinned to the overlay's
# gate_integration_id or accepted from any source; a missing or 0 App id is refused.
out=$(node --input-type=module -e '
  import { render } from "./org/apply.mjs";
  import { readFileSync } from "node:fs";
  const o = JSON.parse(readFileSync(process.argv[1], "utf8"));
  const a = render(o);
  o.org_admin.strict_status_checks = true; o.org_admin.extra_checks = { default: [{ context: "lint" }], staged_main: [{ context: "promote-main" }], staging: [{ context: "preview" }] }; o.org_admin.push_ignored_paths = [".env.example"]; o.org_admin.max_file_size_mb = 20; o.org_admin.require_extra_approval_for_unattributed_changes = true;
  const b = render(o);
  const rs = (x, n) => x.rulesets.find((r) => r.name.includes(n)).rules;
  const refuse = (oa) => { try { render({ org_admin: oa }); return false; } catch { return true; } };
  const refused = refuse({}) && refuse({ app: { id: 0, slug: "x" } }) && refuse({ app: { id: 1, slug: "x" }, gate_integration_id: "15" })
    && refuse({ app: { id: 1, slug: "x" }, push_app_bypass: true }) && refuse({ app: { id: 1, slug: "x" }, push_app_bypass: false }) && refuse({ app: { id: 1, slug: "x" }, codex_verdict_status: true }) && refuse({ app: { id: 1, slug: "x" }, review_status: true }) && refuse({ app: { id: 1, slug: "x" }, review_status: false }) && refuse({ app: { id: 1, slug: "x" }, review_thread_resolution: true }) && refuse({ app: { id: 1, slug: "x" }, require_extra_approval_for_unattributed_changes: 1 });
  const unpinned = render({ org_admin: { app: { id: 1, slug: "x" } } }).rulesets.find((r) => r.name.includes("default branch")).rules.required_status_checks.required_status_checks;
  console.log(JSON.stringify({
    bypass: [...new Set(a.rulesets.map((r) => `${r.target}:${JSON.stringify(r.bypass_actors)}`))].sort(),
    threads: a.rulesets.filter((r) => r.rules.pull_request).map((r) => r.rules.pull_request.required_review_thread_resolution),
    codeOwners: a.rulesets.filter((r) => r.rules.pull_request?.require_code_owner_review).map((r) => r.name),
    direct: rs(a, "direct").pull_request.allowed_merge_methods, staged: rs(a, "staged main").pull_request.allowed_merge_methods,
    vault: rs(a, "push").file_path_restriction.restricted_file_paths.includes("vault/**"),
    size: [rs(a, "push").max_file_size.max_file_size, rs(b, "push").max_file_size.max_file_size],
    strict: [a, b].map((x) => x.rulesets.filter((r) => r.rules.required_status_checks?.strict_required_status_checks_policy).map((r) => r.name)),
    checks: ["default branch", "staged main", "org: staging"].map((n) => rs(b, n).required_status_checks.required_status_checks.map((c) => c.context).join("+")),
    ignored: [rs(a, "push").file_path_restriction.ignored_file_paths ?? null, rs(b, "push").file_path_restriction.ignored_file_paths],
    pinned: rs(a, "default branch").required_status_checks.required_status_checks, unpinned,
    pushBypass: b.rulesets.find((r) => r.target === "push").bypass_actors,
    unattributed: [a, b].map((x) => [...new Set(x.rulesets.flatMap((r) => r.rules.pull_request ? [r.rules.pull_request.require_extra_approval_for_unattributed_changes] : []))]),
    placeholders: JSON.stringify(a).includes("\"$"), refused }));' "$T/org.json" 2>&1)
want='{"bypass":["branch:[{\"actor_id\":4242,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"},{\"actor_id\":null,\"actor_type\":\"OrganizationAdmin\",\"bypass_mode\":\"pull_request\"}]","push:[]"],"threads":[true,true,true,true],"codeOwners":["org: direct repos squash-merge","org: staged main takes promotions (merge commit)"],"direct":["squash"],"staged":["merge"],"vault":true,"size":[50,20],"strict":[[],["org: direct repos squash-merge","org: staging (PR + gate, squash)"]],"checks":["gate+lint","gate+promote-main","gate+preview"],"ignored":[null,[".env.example"]],"pinned":[{"context":"gate","integration_id":42}],"unpinned":[{"context":"gate"}],"pushBypass":[],"unattributed":[[false],[true]],"placeholders":false,"refused":true}'
[ "$out" = "$want" ] && ok org-rulesets-render || fail org-rulesets-render "$out"

# promotion-not-strict: with strict_status_checks on, a staged repo's promotion into main whose main is ahead only by
# earlier promotion merge commits (staging never gets them and cannot take a direct push) stays mergeable: no
# ruleset that covers staged main is strict. Strict still holds where ordinary PRs land (staging, a direct repo's main).
P=$T/promo; git init -q -b main "$P"; g() { git -C "$P" -c user.name=t -c user.email=t@t "$@"; }
g commit -q --allow-empty -m base; g checkout -q -b staging; g commit -q --allow-empty -m work1
g checkout -q main; g merge -q --no-ff -m "promote 1" staging; g checkout -q staging; g commit -q --allow-empty -m work2
behind=$(git -C "$P" merge-base --is-ancestor main staging && echo no || echo yes)
out=$(node --input-type=module -e '
  import { render } from "./org/apply.mjs";
  import { readFileSync } from "node:fs";
  const o = JSON.parse(readFileSync(process.argv[1], "utf8")); o.org_admin.strict_status_checks = true;
  const { rulesets } = render(o);
  // the rulesets GitHub applies to <ref> in a repo with this default branch and flow (conditions as rendered)
  const applies = (r, def, flow, ref) => {
    if (r.target !== "branch") return false;
    const c = r.conditions, refs = c.ref_name.include.map((x) => (x === "~DEFAULT_BRANCH" ? `refs/heads/${def}` : x === "~ALL" ? ref : x));
    const prop = c.repository_property?.include?.find((p) => p.name === "flow");
    return refs.includes(ref) && (!prop || prop.property_values.includes(flow));
  };
  const strict = (def, flow, ref) => rulesets.some((r) => applies(r, def, flow, ref) && r.rules.required_status_checks?.strict_required_status_checks_policy);
  console.log([strict("staging", "staged", "refs/heads/main"), strict("main", "staged", "refs/heads/main"), strict("staging", "staged", "refs/heads/staging"), strict("main", "direct", "refs/heads/main")].join(" "));' "$T/org.json" 2>&1)
# mergeable = not (strict and behind)
if [ "$behind" = yes ] && [ "$out" = "false false true true" ]; then ok promotion-not-strict; else fail promotion-not-strict "behind=$behind strict(staged main, staged main with default main, staging, direct main)=$out"; fi

# gate-required-either-strict: `gate` is a required check on every ruleset that covers a default branch or main, direct
# repos' and staged repos' shapes alike, with strict on or off; strict only changes the flag, and only where ordinary PRs land
# (staging, direct repos). Incident: strict off dropped the direct repos' required_status_checks rule, so org-apply would
# have removed `gate` from every direct repo's default branch.
out=$(node --input-type=module -e '
  import { render } from "./org/apply.mjs";
  import { readFileSync } from "node:fs";
  const o = JSON.parse(readFileSync(process.argv[1], "utf8"));
  const shape = (strict) => {
    o.org_admin.strict_status_checks = strict;
    return render(o).rulesets.filter((r) => r.rules.pull_request).map((r) => {
      const c = r.rules.required_status_checks;
      return `${r.name}=${c ? c.required_status_checks.map((x) => x.context).join("+") + ":" + c.strict_required_status_checks_policy : "MISSING"}`;
    });
  };
  console.log(JSON.stringify([false, true].map(shape)));' "$T/org.json" 2>&1)
want='[["org: default branch and main (PR + gate)=gate:false","org: direct repos squash-merge=gate:false","org: staged main takes promotions (merge commit)=gate:false","org: staging (PR + gate, squash)=gate:false"],["org: default branch and main (PR + gate)=gate:false","org: direct repos squash-merge=gate:true","org: staged main takes promotions (merge commit)=gate:false","org: staging (PR + gate, squash)=gate:true"]]'
[ "$out" = "$want" ] && ok gate-required-either-strict || fail gate-required-either-strict "$out"

# engine-org-dry-run-diff: a dry run names each change (field diffs for a matched ruleset, its old name, creates,
# the stray delete, the property, a staged repo's missing merge-commit setting and a repo keeping merged branches, the repo flows) and sends only GETs.
start "$T/state.json"
out=$(run --dry-run)
# the live ruleset's extra approval for unattributed changes is kept unless the overlay sets it
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8")); o.org_admin.require_extra_approval_for_unattributed_changes=false; require("fs").writeFileSync(f+".ua",JSON.stringify(o))' "$T/org.json"
ua=$(node org/apply.mjs --overlay "$T/org.json.ua" --dry-run 2>&1)
if ! grep -q unattributed <<<"$out" && grep -q 'rules.pull_request.require_extra_approval_for_unattributed_changes: true -> false' <<<"$ua" && [ "$(writes)" = 0 ] && grep -q 'update (was "hand-made main")' <<<"$out" && grep -q 'rules.pull_request.allowed_merge_methods: \["merge","rebase","squash"\] -> \["merge","squash"\]' <<<"$out" \
  && grep -q 'bypass_actors: .*OrganizationAdmin.* -> \[{"actor_id":4242' <<<"$out" && grep -q '"stray" #[0-9]*: delete' <<<"$out" \
  && grep -q 'repo site: enable delete_branch_on_merge, allow_merge_commit' <<<"$out" && ! grep -q 'repo app:' <<<"$out" && grep -q 'property flow: create' <<<"$out" && grep -q 'flow=staged: site' <<<"$out" && grep -q 'flow=direct: app$' <<<"$out" && ! grep -q gone <<<"$out"; then
  ok engine-org-dry-run-diff
else fail engine-org-dry-run-diff "$out :: $ua"; fi

# engine-org-apply-order: apply writes the property, then enables required merge methods, then repo flows, then creates and updates, and deletes last,
# so no branch loses its required check mid-apply.
out=$(run)
order=$(grep -v '"method":"GET"' "$T/log" | node -e 'for (const l of require("fs").readFileSync(0,"utf8").trim().split("\n")) { const {method:m,path:p}=JSON.parse(l); console.log(p.startsWith("/repos/")?"repo":p.includes("schema")?"property":p.endsWith("values")?"values":m==="DELETE"?"delete":"ruleset"); }' | uniq | tr '\n' ' ')
[ "$order" = "property repo values ruleset delete " ] && ok engine-org-apply-order || fail engine-org-apply-order "$order :: $out"

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

# engine-org-dry-run-diff (launcher): org-apply refuses an overlay whose launcher settings are invalid, before any request
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8")); o.launcher={lanes:[{name:"x",vendor:"gpt"}]}; require("fs").writeFileSync(f+".bad",JSON.stringify(o))' "$T/org.json"
: >"$T/log"; lb=$(node org/apply.mjs --overlay "$T/org.json.bad" --dry-run 2>&1); lx=$?
if [ $lx -ne 0 ] && grep -q "vendor must be claude or codex" <<<"$lb" && [ ! -s "$T/log" ]; then ok engine-org-dry-run-diff; else fail engine-org-dry-run-diff "launcher: $lx $lb"; fi

# engine-org-app-link: create-app prints GitHub's URL-parameter registration link for the org, prefilled with
# the overlay's App name, webhook off, and exactly the manifest's permissions.
link=$(run create-app | grep -o 'https://github.com/organizations/[^ ]*')
got=$(node -e 'const u=new URL(process.argv[1]); const q=Object.fromEntries(u.searchParams); const perms=Object.keys(q).filter(k=>!["name","url","description","public","webhook_active"].includes(k)).sort().map(k=>k+"="+q[k]).join(","); console.log(u.pathname, q.name, q.public, q.webhook_active, perms)' "$link" 2>&1)
[ "$got" = "/organizations/acme/settings/apps/new acme-bot false false actions=write,checks=read,contents=write,issues=write,metadata=read,pull_requests=write,statuses=read,workflows=write" ] && ok engine-org-app-link || fail engine-org-app-link "$got"

done_cases
