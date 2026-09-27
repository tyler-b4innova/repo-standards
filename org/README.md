# Org layer

One ruleset set, one `flow` property and one App definition for every organization. An org admin runs `org/apply.mjs` with their own `gh` login; the overlay's `org_admin` key holds the org's values.

| Ruleset | Targets | Rules |
|---|---|---|
| default branch and main | every repo: default branch, `main` | PR (0 approvals), `gate` plus `extra_checks.default`, no deletion, no force-push |
| direct repos squash-merge | `flow=direct`: default branch, `main` | squash only |
| staged main takes promotions | `flow=staged`: `main` | merge commit only; `gate` plus `extra_checks.staged_main` |
| staging | every repo with a `staging` branch (a staged repo's work lane, or a preview branch) | PR (squash only), `gate` plus `extra_checks.staging`, no deletion, no force-push |
| push hygiene | every repo | no private env files, keys or tfvars, plus `extra_restricted_paths`, except `push_ignored_paths`; files up to `max_file_size_mb` |

A staged repo's default branch is `staging`; work squash-merges there and is promoted to `main` with a merge commit. A repo whose work lands on `main` is `direct`. `gate` is not strict by default (merge-commit promotions leave `staging` behind `main`); `strict_status_checks` turns it on. Bypass: the org App `always` (it fast-forwards gated pack commits), org admins `pull_request` only, because local agent sessions run on an admin's `gh` login and `always` would let them push or force-push to protected branches; an admin can still merge a PR past a failing requirement as break-glass. Push rulesets refuse `pull_request` mode, so push hygiene has the App alone. `apply.mjs` owns every organization-level ruleset: an unlisted one is deleted, and one with the same target and conditions is renamed in place.

```sh
node org/apply.mjs --overlay org.json --dry-run    # diff against the live org; only GETs
node org/apply.mjs --overlay org.json              # property, repo flows, create/update, deletes last
node org/apply.mjs create-app --overlay org.json   # prints the one-click App registration link
```

`create-app` prints GitHub's URL-parameter registration link, prefilled from `app-manifest.json` (webhook off). After creating the App, the owner generates a private key, stores it as the standards repo secret, installs the App on all repositories, and sets `org_admin.app.id` and `.slug`. GitHub has no API to change an existing App's permissions; an owner edits them in the App's settings and accepts the change on the installation.

Overlay:

```json
"org_admin": {
  "app": { "id": 0, "slug": "<app slug>", "name": "<App name>" },
  "gate_integration_id": 0,
  "staged": ["<repo>"],
  "review_thread_resolution": false,
  "strict_status_checks": false,
  "extra_checks": { "default": [], "staged_main": [], "staging": [] },
  "extra_restricted_paths": [],
  "push_ignored_paths": [],
  "push_ruleset": "managed",
  "push_app_bypass": false,
  "max_file_size_mb": 50
}
```

`review_thread_resolution` and `strict_status_checks` default to `false`; each org sets them in its overlay. App permissions are listed with their callers in `app-manifest.json`; the App has no webhook because the launcher polls.

Push paths are additive: `extra_restricted_paths` adds patterns, and `push_ignored_paths` exempts matches (GitHub honours `ignored_file_paths` on a push ruleset, so `.env.*` plus `**/.env.*` with `.env.example` and `**/.env.example` ignored blocks `.env.test` and allows `.env.example`, verified live). `push_ruleset: "external"` leaves every org push ruleset alone: org-apply neither writes nor deletes one. `push_app_bypass: true` lets the App bypass the push ruleset too (off by default: an org without it keeps none). `require_extra_approval_for_unattributed_changes` sets that pull-request rule option on every branch ruleset; leave it out to keep each live ruleset's value. Extra checks are objects `{ "context": "<check>", "integration_id": <app id> }`; omit `integration_id` to accept the check from any source.

`app.id` must be the real App id (the example's `0` is refused before anything is written). `gate_integration_id` pins `gate` to the check-run App that runs it (the Actions App on your host), so a status from another App cannot satisfy it; leave it out to accept `gate` from any source. Before touching rulesets, apply turns on squash merging for every active repo and merge commits for staged repos where the repo setting has them off, since a ruleset can only narrow the methods a repository allows.
