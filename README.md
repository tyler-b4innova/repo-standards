# repo-standards

An org-neutral engine for repo-scoped agent standards. Each organization keeps a small overlay (`org.json`, data only) in its own standards repository and pins an engine release; the engine renders and applies the pack from it. The optional `launcher` key holds that org's own launcher settings (each org runs its own launcher deployment); the engine validates it on every load and never writes it into repositories:

```json
"launcher": {
  "repos": "*",
  "lanes": [{ "name": "claude", "vendor": "claude", "slots": 2, "accounts": ["<account id>"], "base": "<branch>", "timeoutMin": 60, "github": "<login>" }],
  "unassigned": ["<lane>"],
  "dispatch": [{ "repo": "standards", "workflow": "sync.yml", "every": "1h" }],
  "sections": ["Goal", "Acceptance criteria"], "bodyBudget": 8000, "uiPaths": ["<glob>"],
  "duplicates": { "apps": ["<app slug>"] }
}
```

Every key is optional except a lane's `name` and `vendor` (`claude` or `codex`). Unknown keys, lanes named in `unassigned` that do not exist, schedules other than `<n>m|h|d`, and credential-looking values are refused. Other top-level keys the engine does not read pass through untouched.

## Consumer repositories

Every managed file is committed, so offline cloud sessions and sandboxes have everything: the managed `AGENTS.md` block, `.agents/skills/std-*` (+ `.claude/skills` link), `scripts/agent/` (`setup.sh`, `check.mjs`, `gate.mjs`, `pr.sh`, `evidence.mjs`, `pack.json`), `.github/workflows/std-gate.yml` (the one required check, `gate`), PR/issue templates, `.claude/settings.json`, `.codex/config.toml`, `.codex/rules/std.rules`, and `standards.json` (repo-owned; states the pack version) + `standards.lock` (sha256 per managed path, engine version). Consumers never fetch the engine; only the org's sync job does:

```sh
npx -y github:tyler-b4innova/repo-standards#vX.Y.Z sync --overlay org.json --version <org release>   # GH_TOKEN = org App token
npx -y github:tyler-b4innova/repo-standards#vX.Y.Z apply --target <repo> --overlay org.json --version <org release>
```

**Org contract:** run `sync` (and `expiry`) from a `workflow_dispatch` / `repository_dispatch` workflow in the org's standards repository, triggered by the org's dispatcher or a release. Never rely on `schedule`: it has not fired for either org. Credentials: repo variable `STANDARDS_APP_CLIENT_ID`, secret `STANDARDS_APP_PRIVATE_KEY`; `expiry` reads each credential's issue date from the env var named by `issued_var` (pass `vars.<name>` in the workflow). `org-apply` (from `org/`) reconciles the org's rulesets, `flow` property and App settings. Sync applies only a released overlay with the engine version it pins, and a pack landing runs no gate (the engine's own CI is the release gate): per repository it commits the pack on the default head, requires the repository's offline check (`setup.sh --check`) to pass on that commit, and fast-forwards the default branch (the integration branch on staged repos, never main), re-applying once if the branch moved. A failing check opens one PR for a person; only the App may push `standards/v*`, so the person branches from it, commits the fix, opens their own PR and closes the sync's (its body gives the commands). An engine release marked `"breaking": true` in its `package.json` (it can stop a repository's gate or check from passing: a new required step, a trigger change, a new `--check` failure class) lands only with `--repo` until a person runs sync with `--proven` (recorded in the compliance issue, so later scheduled syncs follow; until then they sync nothing): prove it on the org's sandbox first, and open fix PRs for repositories the new rules would fail. The org App needs ruleset bypass on the default branch, `contents`/`workflows`/`actions` write, and the repos need `std-gate.yml` (managed).

**Precedence:** restrictions are additive (engine, then overlay, then repo can only add). Data is repo-owned and replaces: `standards.json` `ui_paths` (explicit `[]` = no UI, with a `--check` warning), `profile`, `dispatch`, `sensitive`, `e2e`, `flow`, `design_signoff`, `allow_paths` (globs exempt from the `.mcp.json` and forbidden-path checks, for shipped content such as a client plugin's `.mcp.json`), `deploy_workflow` (the one repo workflow allowed to build on push; it must not test), and `e2e` as an object: `{ "command", "browsers" (promotion PRs), "preview": false, "budget" (minutes, tighter only) }`. Org overlay: `review.status`, `gate.budget.e2e`, `preview.check_name` / `preview.comment_author`, `e2e.promotion_browsers`.

## Gate and review

Two required results per pull request head: `gate` (Actions) checks the code; `review` (a commit status the org App posts) checks the conversation. Nothing but code changes starts Actions.

**`gate`** runs on a pull request's commits (opened, synchronize, reopened, ready_for_review), the merge queue, and a `workflow_dispatch` the org launcher sends after a base change (gate then tests the fresh `refs/pull/<n>/merge`); never on comments, reviews, edits or pushes. In one job: the offline check, a checksum-pinned secret scan of the PR's own commits, install/typecheck/build, the e2e suite (none fails unless `"e2e": false`) and `scripts/agent/gate.local.sh`. Its `plan` step runs drafts cheap (check, secret scan, syntax) until ready_for_review. e2e runs Chromium only (promotion PRs may add browsers through `standards.json` `e2e.browsers`), within a 5-minute budget, against the head's Workers Builds preview when the Cloudflare comment has one (`PLAYWRIGHT_BASE_URL`/`BASE_URL`; a red Cloudflare build fails gate). The runner is the org variable `STD_GATE_RUNNER` (default `ubuntu-24.04`); `std-cache-warm.yml` refreshes the npm cache when the default branch's lockfile changes. `--check` fails repository workflows that test beside gate (on pull requests, or on pushes to the default or integration branch), schedules more frequent than daily, jobs without `timeout-minutes`, `playwright install` without a browser, and expired or unlinked `@quarantine` tags.

**`review`** is `scripts/agent/review.mjs` (also exported as `repo-standards/review` for the org launcher): `reviewStatus` is one read-only rule, and `postReviews` posts it: every open PR on a head is judged twice and read once more, and only when those agree is the worst verdict posted; otherwise, or when a PR cannot be judged, `pending` goes on every head involved (callers run one pass at a time):
- **Codex verdict:** the Codex summary shows the current head as Completed (after the head's push and any base change) and no Codex thread is unresolved; pending for 20 minutes, then failure ("request a review"). Repos with no Codex reviews, `codex_review: false`, and the sync's fallback PRs pass.
- **Evidence:** a PR changing UI paths needs a comment by a trusted author with images pinned to a commit in its history: before and after at 400 and 1280px for web changes, before-N/after-N page images for documents, and no UI change after them.
- **Promotions** (flow `staged`: default branch into another branch) need no evidence comment; one that changes UI paths needs an APPROVED review on the current head by a person with write access.

The org launcher posts `review` for every open non-draft PR each tick (context `review`, the org App's token; it re-reads the head before posting); an org without a launcher runs `scripts/agent/verdict-recheck <pr>... | --all` from its merge helper. Enable it per org in one overlay release, in this order: the App has `statuses: write`; the overlay sets both `review.status: true` and `org_admin.review_status: true`; run org-apply first, so the ruleset requires `review` pinned to the App (merges wait for it meanwhile); then sync lands the pack (gate's review step stops evaluating) and the poster starts posting. The reverse order leaves a window where neither gate nor the ruleset checks the conversation. Until then gate's review step evaluates the same rule on each push. A human merge without a poster has only gate's last evaluation: an evidence comment deleted afterwards is not re-checked. A repository using a merge queue would need `review` on merge-group commits too; neither org uses one today.

## One-time, per person

- Claude: bypass cannot be set from a repository. Set `permissions.defaultMode: "bypassPermissions"` in `~/.claude/settings.json` (or run `claude --dangerously-skip-permissions` once and accept the dialog). `setup.sh --check` warns while it is off.
- Codex: trust each repository (accept the prompt, or add `[projects."<path>"] trust_level = "trusted"`). Until then Codex ignores the repo's model, bypass and rules; `setup.sh --check` warns with the fix.
- Deny rules bind even under bypass: agents cannot read secret files or run `op`, and cannot force-push. Repo scripts that need a secret (for example `sentry-setup`) read it themselves.

Models: Claude `opus` for the main thread and subagents (`/model` still switches a session); Codex `gpt-6-sol` for both. Claude cloud reads these in single-repository sessions; Codex Cloud tasks ignore the repo's model keys and use the workspace or composer model (there is no per-task model option).

## Gotchas

- The `deploy` module runs `wrangler deploy` only; a Worker with D1 must run `wrangler d1 migrations apply <db> --remote` before it.

- In issues and comments write "the Codex mention", never the literal handle: any comment containing it starts a paid task, even on a closed issue.

## Develop

`test/run.sh` runs every scenario in `SCENARIOS.md` (each prints `ok <id>`) plus the neutrality check over the tree and full history. Each release sets `package.json` `"breaking"`: `true` only when it can stop a consumer's gate or check from passing, otherwise `false`. After changing `template/`, re-apply to this repository: `node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version "$(node -p 'require("./package.json").version')"`.
