# repo-standards

An org-neutral engine for repo-scoped agent standards. Each organization keeps a small overlay (`org.json`, data only) in its own standards repository and pins an engine release; the engine renders and applies the pack from it. The optional `launcher` key holds that org's own launcher settings (each org runs its own launcher deployment); the engine validates it on every load and never writes it into repositories:

```json
"launcher": {
  "repos": "*",
  "lanes": [{ "name": "claude", "vendor": "claude", "slots": 2, "accounts": ["<account id>"], "base": "<branch>", "timeoutMin": 60, "github": "<login>" }],
  "unassigned": ["<lane>"],
  "dispatch": [{ "repo": "standards", "workflow": "sync.yml", "every": "1d", "when": "drift" }],
  "sections": ["Goal", "Acceptance criteria"], "bodyBudget": 8000, "uiPaths": ["<glob>"],
  "duplicates": { "apps": ["<app slug>"] },
  "revert": { "newIssueEvents": 5, "eventFactor": 5 }
}
```

Every key is optional except a lane's `name` and `vendor` (`claude` or `codex`). `revert` holds the launcher's thresholds for reverting a production deploy (positive numbers; the launcher owns the defaults). A dispatch entry's `when: "drift"` fires it only when some repository's `standards.lock` is missing or behind the entry repository's latest release. Unknown keys, lanes named in `unassigned` that do not exist, schedules other than `<n>m|h|d`, and credential-looking values are refused. Other top-level keys the engine does not read pass through untouched.

## Consumer repositories

Every managed file is committed, so offline cloud sessions and sandboxes have everything: the managed `AGENTS.md` block, `.agents/skills/std-*` (+ `.claude/skills` link), `scripts/agent/` (`setup.sh`, `check.mjs`, `pins.mjs`, `gate.mjs`, `review.mjs`, `pr.sh`, `evidence.mjs`, `pack.json`), `.github/workflows/std-gate.yml` (the one required check, `gate`), PR/issue templates, `.claude/settings.json`, `.codex/config.toml`, `.codex/rules/std.rules`, the managed CODEOWNERS block (with `ui_owners`), and `standards.json` (repo-owned; states the pack version) + `standards.lock` (sha256 per managed path, engine version). Consumers never fetch the engine; only the org's sync job does:

```sh
npx -y github:tyler-b4innova/repo-standards#vX.Y.Z sync --overlay org.json --version <org release>   # GH_TOKEN = org App token
npx -y github:tyler-b4innova/repo-standards#vX.Y.Z apply --target <repo> --overlay org.json --version <org release>
```

**Org contract:** run `sync` (and `expiry`) from a `workflow_dispatch` / `repository_dispatch` workflow in the org's standards repository, triggered by the org's dispatcher or a release. Never rely on `schedule`: it has not fired for either org. Credentials: repo variable `STANDARDS_APP_CLIENT_ID`, secret `STANDARDS_APP_PRIVATE_KEY`; `expiry` reads each credential's issue date from the env var named by `issued_var` (pass `vars.<name>` in the workflow). `org-apply` (from `org/`) reconciles the org's rulesets, `flow` property and App settings. Sync applies only a released overlay with the engine version it pins, and a pack landing runs no gate (the engine's own CI is the release gate): per repository it commits the pack on the default head, requires the repository's offline check (`setup.sh --check`) to pass on that commit, and fast-forwards the default branch (the integration branch on staged repos, never main), re-applying once if the branch moved. A failing check opens one PR for a person; only the App may push `standards/v*`, so the person branches from it, commits the fix, opens their own PR and closes the sync's (its body gives the commands). An engine release marked `"breaking": true` in its `package.json` (it can stop a repository's gate or check from passing: a new required step, a trigger change, a new `--check` failure class) lands only with `--repo` until a person runs sync with `--proven` (recorded in the compliance issue, so later scheduled syncs follow; until then they sync nothing): prove it on the org's sandbox first, and open fix PRs for repositories the new rules would fail. The org App needs ruleset bypass on the default branch, `contents`/`workflows`/`actions` write, and the repos need `std-gate.yml` (managed).

**Precedence:** restrictions are additive (engine, then overlay, then repo can only add). Data is repo-owned and replaces: `standards.json` `ui_paths` (explicit `[]` = no UI, with a `--check` warning), `profile`, `dispatch`, `sensitive`, `e2e`, `flow`, `design_signoff`, `allow_paths` (globs exempt from the `.mcp.json` and forbidden-path checks, for shipped content such as a client plugin's `.mcp.json`), `deploy_workflow` (the one repo workflow allowed to build on push; it must not test), `risk_paths`, `production_urls` (absolute https URLs the org launcher smoke-tests after a production deploy), and `e2e` as an object: `{ "command", "browsers" (promotion PRs), "preview": false, "budget" (minutes, tighter only) }`. `duplicate_check_exceptions` can preserve a named artifact-validation or promotion guard workflow as `[{"path":".github/workflows/validate.yml","sha256":"<64 lowercase hex>","reason":"why this must run separately"}]`; `--check` rejects a missing, malformed, or changed pin and still enforces timeouts, schedule frequency, browser installs, and managed gate integrity. Org overlay: `ui_owners`, `risk_owners`, `gate.budget.e2e`, `preview.check_name` / `preview.comment_author`, `e2e.promotion_browsers`.

## Gate and review

`gate` (Actions) is the one required check: it checks the code. The org rulesets also require every review thread resolved, and a code owner's approval on `main` for UI paths. Nothing but code changes starts Actions.

**`gate`** runs on a pull request's commits (opened, synchronize, reopened, ready_for_review), the merge queue, and a `workflow_dispatch` the org launcher sends after a base change (gate then tests the fresh `refs/pull/<n>/merge`); never on comments, reviews, edits or pushes. In one job: the offline check, a checksum-pinned secret scan of the PR's own commits, install/typecheck/build, the e2e suite (none fails unless `"e2e": false`) and `scripts/agent/gate.local.sh`. Its `plan` step runs drafts cheap (check, secret scan, syntax) until ready_for_review. e2e runs Chromium only (promotion PRs may add browsers through `standards.json` `e2e.browsers`), within a 5-minute budget, against the head's Workers Builds preview when the Cloudflare comment has one (`PLAYWRIGHT_BASE_URL`/`BASE_URL`). Where the repository has Workers Builds (the check is on its base branch tip), the preview must pass: gate waits for the head's build (up to 8 minutes) and fails on a missing, unfinished or failed one; a build Cloudflare skipped passes; `e2e.preview: false` opts out. The runner is the org variable `STD_GATE_RUNNER` (default `ubuntu-24.04`); `std-cache-warm.yml` refreshes the npm cache when the default branch's lockfile changes. `--check` fails repository workflows that test beside gate (on pull requests, or on pushes to the default or integration branch), schedules more frequent than daily, jobs without `timeout-minutes`, `playwright install` without a browser, and expired or unlinked `@quarantine` tags.

**UI and risk approval:** with the overlay's `ui_owners` set (e.g. `["@octocat"]`), apply writes a managed block at the end of `.github/CODEOWNERS` (or the root or `docs/` one, if that is where the repo keeps it) giving the repository's UI paths (`standards.json` `ui_paths`, else the engine defaults) to those owners; ignored paths get owner-less lines, which also clear the repo's own owners for those paths (the last match wins). The repo's own lines stay above it; `--check` fails a line after it. The org rulesets require code-owner review on `main` only (direct repos' default branch and `main`, staged repos' `main`), so a UI change needs a person's approval where it reaches production. With `risk_owners` set, the same block then gives the risky paths (`standards.json` `risk_paths`, else the defaults in `defaults.json`: workflows, auth, payments, secrets and env handling, migrations, `wrangler.*` and `infra/`, CODEOWNERS itself) to those owners; they come last, so they win. The UI part is left out when `ui_paths` is `[]`, `design_signoff` is `false`, or there are no `ui_owners`; the risk part when `risk_paths` is `[]` or there are no `risk_owners`. GitHub treats the requirement as met when the PR's author is the only code owner. `--check` guards the block; a `ui_paths` edit reaches it on the next pack landing (a release), not before.

**The review rule** is `scripts/agent/review.mjs`, exported as `repo-standards/review` for a launcher or merge helper to ask before merging: `reviewStatus({ api, owner, repo, pr })` is read-only and returns `null` (draft, closed, not engine-managed) or `{ state, description, sha, base, base_sha, target_url, details }`. Its settings come from the current base branch (a promotion: the default branch's head):
- **Codex verdict:** the Codex summary shows the current head as Completed (after the head's push and any base change) and no Codex thread is unresolved; pending for 20 minutes, then failure ("request a review"). Repos with no Codex reviews and `codex_review: false` pass.
- **Evidence:** a PR changing UI paths needs a comment by a trusted author with images pinned to a commit in its history: before and after at 400 and 1280px for web changes, before-N/after-N page images for documents, and no UI change after them.
- **Promotions** (flow `staged`: default branch into another branch) need no evidence comment; one that changes UI paths needs an APPROVED review on the current head by a person with write access.

The managed AGENTS.md block carries a `## Review guidelines` line telling Codex review to skip pack-managed paths: findings on those belong in this repository.

## Setup

The SessionStart hook runs `scripts/agent/setup.sh --check` (the offline check). Cloud setup (`setup.sh` with no arguments) installs tools and dependencies best-effort and exits with the check's status.

## One-time, per person

- Claude: bypass cannot be set from a repository. Set `permissions.defaultMode: "bypassPermissions"` in `~/.claude/settings.json` (or run `claude --dangerously-skip-permissions` once and accept the dialog). `setup.sh --check` warns while it is off.
- Codex: trust each repository (accept the prompt, or add `[projects."<path>"] trust_level = "trusted"`). Until then Codex ignores the repo's bypass and rules; `setup.sh --check` warns with the fix.
- Deny rules bind even under bypass: agents cannot read secret files or run `op`, and cannot force-push. Repo scripts that need a secret (for example `sentry-setup`) read it themselves.

Models: repositories never pin a model or effort; each person's app (or the org launcher) decides. Apply removes any pin from the root `.claude/settings.json` and `.codex/config.toml` (`scripts/agent/pins.mjs` lists the keys), and `--check` fails on one.

## Gotchas

- The `deploy` module runs `wrangler deploy` only; a Worker with D1 must run `wrangler d1 migrations apply <db> --remote` before it.

- In issues and comments write "the Codex mention", never the literal handle: any comment containing it starts a paid task, even on a closed issue.

## Develop

`test/run.sh` runs every scenario in `SCENARIOS.md` (each prints `ok <id>`) plus the neutrality check over the tree and full history. Each release sets `package.json` `"breaking"`: `true` only when it can stop a consumer's gate or check from passing, otherwise `false`. After changing `template/`, re-apply to this repository: `node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version "$(node -p 'require("./package.json").version')"`.
