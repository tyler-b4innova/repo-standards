# Org layer

One ruleset set and one App definition for every organization. An org admin runs `org/apply.mjs` with their own `gh` login; the overlay's `org_admin` key holds the org's values.

| Ruleset | Targets | Rules |
|---|---|---|
| default branch and main | every repo: default branch, `main` | PR (0 approvals, threads resolved), `gate` plus `extra_checks.default`, no deletion, no force-push |
| squash-merge with code-owner review | every repo: default branch, `main` | squash only; code-owner review; `gate` (strict when `strict_status_checks`) |
| release branches (portal App only) | every repo: `release/**` | creating, moving and deleting are restricted; the only bypass is the portal App (`org_admin.release_app.id`), and with none set nobody can create one |
| standards version branches (standards App only) | every repo: `standards/v*` | creating and moving are restricted (deleting is not: a missing branch already makes gate refuse, and GitHub's auto-delete after a merge must not be blocked); the only bypass is the org standards App (`org_admin.app.id`) |
| push hygiene | every repo | no private env files, keys or tfvars, plus `extra_restricted_paths`, except `push_ignored_paths`; files up to `max_file_size_mb` |

`release/<40-hex sha>` is how a production release starts: the portal's GitHub App creates it at an approved commit that is already on `main`, the repository's Workers Builds preview trigger builds it, `release.mjs preview` promotes the commit (see the README's Releases section), and the portal deletes the branch afterwards. `standards/v<version>` is the sync App's pack branch; gate's instructions step trusts its tip, which is why only the org App may write it. Neither ruleset has an org-admin bypass: a ref-protection ruleset carries exactly one bypass actor, because a bypass for admins would let a local agent session on an admin's `gh` login push to either branch.

Every repository squash-merges and deletes merged branches, and its squash commit takes the PR title and description, so the commit on `main` carries the PR's What, Why and linked issue.

One branch: work squash-merges to `main`, and a release is a person deploying the version that merge uploaded (Workers Builds), so there is no staging branch or promotion. The staged flow's `flow` property is retired: org-apply deletes it after the rulesets, and refuses `org_admin.staged` and `extra_checks.staged_main` / `staging`. `gate` is not strict by default; `strict_status_checks` turns it on. Bypass: the org App `always` (it fast-forwards gated pack commits), org admins `pull_request` only, because local agent sessions run on an admin's `gh` login and `always` would let them push or force-push to protected branches; an admin can still merge a PR past a failing requirement as break-glass. Push rulesets refuse `pull_request` mode, so push hygiene has no bypass at all: the App's bypass exists so pack landings can commit onto default branches, and a pack never adds a secret or a large file. `apply.mjs` owns every organization-level ruleset: an unlisted one is deleted, and one with the same target and conditions is renamed in place. On every active repository org-apply also keeps squash merging on and `delete_branch_on_merge` on, so a merged PR's branch is deleted.

```sh
node org/apply.mjs --overlay org.json --dry-run    # diff against the live org; only GETs
node org/apply.mjs --overlay org.json              # repo settings, create/update, deletes last
node org/apply.mjs create-app --overlay org.json   # prints the one-click App registration link
```

`create-app` prints GitHub's URL-parameter registration link, prefilled from `app-manifest.json` (webhook off). After creating the App, the owner generates a private key, stores it as the standards repo secret, installs the App on all repositories, and sets `org_admin.app.id` and `.slug`. GitHub has no API to change an existing App's permissions; an owner edits them in the App's settings and accepts the change on the installation.

Overlay:

```json
"org_admin": {
  "app": { "id": 0, "slug": "<app slug>", "name": "<App name>" },
  "release_app": { "id": 0, "slug": "<portal App slug>" },
  "gate_integration_id": 0,
  "strict_status_checks": false,
  "extra_checks": { "default": [] },
  "extra_restricted_paths": [],
  "push_ignored_paths": [],
  "push_ruleset": "managed",
  "max_file_size_mb": 50
}
```

`release_app` is optional: the portal's GitHub App, the only actor that may create `release/**` branches (a positive `id` is required when it is set; the example's `0` is refused). Leave it out and nobody can create them.

`strict_status_checks` defaults to `false`; `gate` is required either way, and when on, it makes `gate` strict on the squash-merge ruleset. Every pull-request ruleset requires resolved review threads, and `gate` is the only required check (plus `extra_checks`). Code-owner review is required on the default branch and `main`, which with the pack's managed CODEOWNERS block (overlay `ui_owners`) is the approval for UI changes. App permissions are listed with their callers in `app-manifest.json`; the App has no webhook because the launcher polls.

Push paths are additive: `extra_restricted_paths` adds patterns, and `push_ignored_paths` exempts matches (GitHub honours `ignored_file_paths` on a push ruleset, so `.env.*` plus `**/.env.*` with `.env.example` and `**/.env.example` ignored blocks `.env.test` and allows `.env.example`, verified live). `push_ruleset: "external"` leaves every org push ruleset alone: org-apply neither writes nor deletes one. The App never bypasses the push ruleset (the removed `push_app_bypass` is refused). `require_extra_approval_for_unattributed_changes` sets that pull-request rule option on every branch ruleset; leave it out to keep each live ruleset's value. Extra checks are objects `{ "context": "<check>", "integration_id": <app id> }`; omit `integration_id` to accept the check from any source.

`app.id` must be the real App id (the example's `0` is refused before anything is written). `gate_integration_id` pins `gate` to the check-run App that runs it (the Actions App on your host), so a status from another App cannot satisfy it; leave it out to accept `gate` from any source. Before touching rulesets, apply turns on squash merging for every active repo where the repo setting has it off, since a ruleset can only narrow the methods a repository allows.
