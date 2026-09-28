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

**Org contract:** run `sync` (and `expiry`) from a `workflow_dispatch` / `repository_dispatch` workflow in the org's standards repository, triggered by the org's dispatcher or a release. Never rely on `schedule`: it has not fired for either org. Credentials: repo variable `STANDARDS_APP_CLIENT_ID`, secret `STANDARDS_APP_PRIVATE_KEY`; `expiry` reads each credential's issue date from the env var named by `issued_var` (pass `vars.<name>` in the workflow). `org-apply` (from `org/`) reconciles the org's rulesets, `flow` property and App settings. Sync applies only a released overlay with the engine version it pins, and lands it without a PR: it pushes `standards/v<ver>` (which runs that repo's `gate`), fast-forwards the default branch when `gate` passes (the integration branch on staged repos, never main), re-applies once if the branch moved or re-runs once if red, and otherwise opens one PR for a person. Only the App may push `standards/v*`, so a person fixing a red fallback PR branches from it, commits the fix, opens their own PR and closes the sync's (its body gives the commands). The org App needs ruleset bypass on the default branch, `contents`/`workflows`/`actions` write, and the repos need `std-gate.yml` (managed).

**Precedence:** restrictions are additive (engine, then overlay, then repo can only add). Data is repo-owned and replaces: `standards.json` `ui_paths` (explicit `[]` = no UI, with a `--check` warning), `profile`, `dispatch`, `sensitive`, `e2e`, `flow`, `design_signoff`, `allow_paths` (globs exempt from the `.mcp.json` and forbidden-path checks, for shipped content such as a client plugin's `.mcp.json`), `deploy_workflow` (the one repo workflow allowed to build on push; it must not test), and `e2e` as an object: `{ "command", "browsers" (promotion PRs), "preview": false, "budget" (minutes, tighter only) }`. Org overlay: `gate.canary` (one repo per profile; its pack landings run the full gate first), `gate.budget.e2e`, `codex.verdict` (`gate` or `status`), `preview.check_name` / `preview.comment_author`, `e2e.promotion_browsers`.

## Gate

`gate` builds once per pull request head and runs, in one job: the offline check, a checksum-pinned secret scan, install/typecheck/build, the e2e suite (none fails unless `"e2e": false`), `scripts/agent/gate.local.sh`, then evidence (a PR changing UI paths needs a comment by a trusted author with images pinned to a commit in this repo: before and after at 400 and 1280px for web changes, and before-N/after-N page images for documents) and the Codex verdict. **Promotions** (flow `staged`: default branch into another branch) need no evidence comment; a promotion that changes UI paths passes only with an APPROVED review on the current head SHA by a human with write access. Non-UI promotions pass on green.

**Codex verdict.** A non-draft PR passes only when the Codex summary comment shows the current head as Completed and no Codex thread is unresolved; it waits up to 20 minutes after a push or ready-for-review, then fails so the launcher can request a review. Drafts, repos with no Codex reviews, `codex_review: false`, and the sync's fallback PRs are exempt. With the overlay's `codex.verdict: "status"`, gate's step defers to a `codex-verdict` commit status that the org App posts, and org-apply requires it pinned to the App (`org_admin.codex_verdict_status`; turn that on only once the App has `statuses: write`).

**Minutes.** Gate runs on `pull_request` (opened, synchronize, reopened, ready_for_review), `merge_group`, `standards/v*` landings, and a `workflow_dispatch` re-gate after a base change; never on pushes to main or staging, never on comments. Its first step, `plan`, picks a mode: **full** builds and tests; **reuse** (a re-run of a run whose earlier attempt passed every build and test step, so the same SHA and workflow) re-checks only evidence, approval and the Codex verdict, about one billed minute; **cheap** (drafts, and pack-only landings outside the profile's canary) runs the check, the secret scan and a syntax pass. e2e runs Chromium only (promotion PRs may add browsers through `standards.json` `e2e.browsers`), within a 5-minute budget, against the head's Workers Builds preview when the Cloudflare comment has one (`PLAYWRIGHT_BASE_URL`/`BASE_URL`; a red Cloudflare build fails gate). The runner is the org variable `STD_GATE_RUNNER` (default `ubuntu-24.04`). `std-cache-warm.yml` refreshes the npm cache when the default branch's lockfile changes. `--check` fails repository workflows that test beside gate (on pull requests, or on pushes to the default or integration branch), schedules more frequent than daily, jobs without `timeout-minutes`, `playwright install` without a browser, and expired or unlinked `@quarantine` tags.

**Re-checks without a push** (the contract each org's launcher or merge helper calls; comments never start a gate run):

```sh
scripts/agent/verdict-recheck <pr> [--evidence] [--revalidate] [--wait] [--dry-run]
```

It re-runs the head's gate run only when that can change the result: the last attempt failed only on the Codex verdict (which now passes) or on evidence (`--evidence`, after new evidence; `pr.sh evidence` calls it), or passed while the verdict has since failed; `--revalidate` re-checks before a merge (a deleted evidence comment is only caught this way). In status mode it also posts `codex-verdict` (GH_TOKEN must be the org App's token). `std-gate-rerun.yml` handles the two events that need no caller: a person's approval or dismissal re-runs the head's gate run, and a base change dispatches std-gate on the fresh merge ref.

## One-time, per person

- Claude: bypass cannot be set from a repository. Set `permissions.defaultMode: "bypassPermissions"` in `~/.claude/settings.json` (or run `claude --dangerously-skip-permissions` once and accept the dialog). `setup.sh --check` warns while it is off.
- Codex: trust each repository (accept the prompt, or add `[projects."<path>"] trust_level = "trusted"`). Until then Codex ignores the repo's model, bypass and rules; `setup.sh --check` warns with the fix.
- Deny rules bind even under bypass: agents cannot read secret files or run `op`, and cannot force-push. Repo scripts that need a secret (for example `sentry-setup`) read it themselves.

Models: Claude `opus` for the main thread and subagents (`/model` still switches a session); Codex `gpt-6-sol` for both. Claude cloud reads these in single-repository sessions; Codex Cloud tasks ignore the repo's model keys and use the workspace or composer model (there is no per-task model option).

## Gotchas

- The `deploy` module runs `wrangler deploy` only; a Worker with D1 must run `wrangler d1 migrations apply <db> --remote` before it.

- In issues and comments write "the Codex mention", never the literal handle: any comment containing it starts a paid task, even on a closed issue.

## Develop

`test/run.sh` runs every scenario in `SCENARIOS.md` (each prints `ok <id>`) plus the neutrality check over the tree and full history. After changing `template/`, re-apply to this repository: `node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version "$(node -p 'require("./package.json").version')"`.
