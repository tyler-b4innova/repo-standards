# Org layer

One ruleset set, one `flow` property and one App definition for every organization. An org admin runs `org/apply.mjs` with their own `gh` login; the overlay's `org_admin` key holds the org's values.

| Ruleset | Targets | Rules |
|---|---|---|
| default branch and main | every repo: default branch, `main` | PR (0 approvals), `gate`, no deletion, no force-push |
| direct repos squash-merge | `flow=direct`: default branch, `main` | squash only |
| staged main takes promotions | `flow=staged`: `main` | merge commit only; `gate` plus `extra_checks.staged_main` |
| staged staging | `flow=staged`: `staging` | PR (squash only), `gate`, no deletion, no force-push |
| push hygiene | every repo | no private env files, keys or tfvars, plus `extra_restricted_paths`; files up to `max_file_size_mb` |

A staged repo's default branch is `staging`; work squash-merges there and is promoted to `main` with a merge commit. A repo whose work lands on `main` is `direct`. `gate` is not strict (merge-commit promotions leave `staging` behind `main`). Bypass is the org App only, mode `always`, for pack sync; org admins do not bypass. `apply.mjs` owns every organization-level ruleset: an unlisted one is deleted, and one with the same target and conditions is renamed in place.

```sh
node org/apply.mjs --overlay org.json --dry-run    # diff against the live org; only GETs
node org/apply.mjs --overlay org.json              # property, repo flows, create/update, deletes last
node org/apply.mjs create-app --overlay org.json   # writes the one-click manifest page and prints how to open it
node org/apply.mjs create-app --overlay org.json --code <code> [--key-file <path>]
```

`create-app --code` stores the private key as the standards repo secret (the overlay's `app_key_secret` under `sync`) through `gh secret set` stdin and never prints it; `--key-file` also writes it with mode 600 for the launcher host.

Overlay:

```json
"org_admin": {
  "app": { "id": 0, "slug": "<app slug>", "name": "<new App name>", "issued_var": "APP_KEY_ISSUED" },
  "staged": ["<repo>"],
  "review_thread_resolution": false,
  "extra_checks": { "staged_main": [] },
  "extra_restricted_paths": [],
  "max_file_size_mb": 50
}
```

`review_thread_resolution` stays `false` until the open-PR review backlog is cleared. App permissions are listed with their callers in `app-manifest.json`; the App has no webhook because the launcher polls.
