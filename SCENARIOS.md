# Engine scenarios

Each scenario reproduces a failure that actually happened or a rule the owners stated, and runs through a real entry point: `apply` on a fixture repository, then `scripts/agent/setup.sh --check`, a `gate` step, the PR helper, or `sync` against a GitHub stand-in. `test/run.sh` prints `ok <id>` or `FAIL <id>` for each and fails if any id below is missing. Ids are stable; a retired id stays listed as retired.

## Gate and evidence

- **`gate-fails-without-e2e`**: a repository with no end-to-end suite fails `gate` (the suite was once skipped silently while `gate` went green). The workflow has exactly one job, `gate`, carrying every step.
- **`setup-installs-repo-playwright`**: `setup.sh` installs the Chromium browser with the repository's own Playwright (`node_modules/.bin/playwright`), never through npx, and says so when the package is declared but not installed (npm 6's npx read `--no playwright` as an option value and installed nothing).
- **`e2e-opt-out-honoured`**: `"e2e": false` in `standards.json` passes with a warning, and re-applying the pack keeps it.
- **`ui-paths-evidence-required`**: a pull request changing a UI path (markup, styles, components, .docx, .pptx) fails without an accepted evidence comment and passes with one.
- **`evidence-comment-author-or-app`**: an evidence comment by anyone but the PR author, an app or an overlay-trusted login is rejected (a forged comment once passed).
- **`evidence-images-pinned-resolving`**: every evidence image must be in this repository at a 40-hex commit and exist there, as four distinct image files (before and after at 400 and 1280px); the PR helper posts images that way and re-posting updates one comment.
- **`evidence-document-pages`**: a PR whose UI paths are all documents (.docx, .pptx and similar) accepts before and after page images (`before-N`, `after-N`) with at least one page in both; a PR that also changes web UI needs the 400 and 1280px set and the pages.
- **`ui-paths-repo-override`**: `standards.json` `ui_paths` replaces the default globs, and `{ "ignore": [...] }` keeps them while exempting paths (release notes generated upstream once tripped the evidence gate).
- **`ui-paths-empty-warns`**: an explicit `ui_paths: []` turns the evidence gate off, and `--check` warns naming tracked files the defaults would cover.
- **`no-evidence-on-main`**: tracked `.evidence/` fails `--check` (gate's standards step); the PR helper leaves no `.evidence/` on the branch tip after posting.

### Review (the pull request's conversation: `scripts/agent/review.mjs`, exported as `repo-standards/review`)

- **`codex-verdict-required`**: the review rule passes a non-draft PR only when the Codex summary shows the current head as Completed (after the head's push and any base edit) and every Codex thread is resolved; before that it is pending for 20 minutes, then fails ("no Codex verdict … request a review"); drafts are not evaluated; repos without Codex reviews pass; the sync's fallback PRs get no exemption (anyone with write access can push to their branch). The evidence cases above and the promotion cases below go through the same rule.
- **`review-rule-reads-base`**: the rule reads its settings from the current base branch commit (a pull request cannot bring its own; GitHub can retain an older `base.sha`, so the branch is resolved); a promotion (this repository's default branch into another) is judged by the default branch's head, and a fork's same-named branch is not a promotion.
- **`gate-code-only`**: only code changes start gate (a pull request's commits, the merge queue, the launcher's dispatch after a base change); comments, reviews, edits and pushes start nothing, no re-run wrapper ships, and gate has no step that reads the conversation (no `review` subcommand; the rulesets require resolved threads instead). Incident: every Codex event and thread reply rebuilt the site (759 billed minutes of review re-runs in one org in a day; 241 minutes in 138 runs on one repo in the other; 104 minutes from preview-bot comments).

### CI minutes (each reproduces a measured cost from the Sep 27 Actions audit)

- **`gate-no-push-regate`**: pushes start no gate run, neither to main or staging (the tree was gated as a PR) nor pack landings. Incident: 442 billed minutes of post-merge gates.
- **`gate-ignores-body-edits`**: a title or body edit starts no gate run; after a base change the launcher dispatches gate on the PR's fresh merge ref.
- **`skip-never-greens-gate`**: the gate job has no job-level `if` (a skipped job reports success and could mask a red gate on the same head); a dispatch re-gate plans the pull request it names (full gate), never "not a pull request".
- **`draft-cheap-ready-full`**: drafts run the cheap gate (the check, the secret scan and a syntax pass that fails a broken script and skips workflows where PyYAML is missing); `ready_for_review` runs the full one.
- **`e2e-chromium-default`**: gate installs and runs Chromium only; more browsers run on promotion PRs when `standards.json` `e2e.browsers` (or the overlay) opts in, and only for projects the Playwright config defines; a config whose projects are named otherwise is refused (without `--project` Playwright runs them all); a package script running `playwright test` gets the same selection. Incident: three-browser suites ran on every PR.
- **`e2e-uses-preview-url`**: with a Workers Builds check run on the head, e2e runs against the preview URL from the Cloudflare comment for that commit; a red Cloudflare build fails gate; with none, e2e runs locally. The job has `checks: read`, which reading check runs needs.
- **`e2e-budget-enforced`**: an e2e suite over its budget (5 minutes; `e2e.budget` may only tighten it) fails gate, and a zero or negative `e2e.budget` is refused rather than disabling the limit.
- **`quarantine-expires`**: `@quarantine` needs an issue link and an expiry at most 14 days out; an expired one fails `--check`.
- **`no-duplicate-gate-workflows`**: a repository workflow that runs checks on pull requests, or re-tests pushes to the default or integration branch, or a schedule more frequent than daily, fails `--check`; the declared deploy workflow may build on push. Incidents: a duplicate `validate.yml` ran 142 times; a sub-hourly alert poll billed 166 minutes.
- **`duplicate-check-exception-pinned`**: a repo can keep a named artifact-validation or promotion guard workflow beside gate only by listing its exact path, SHA256, and nonempty rationale in `standards.json` `duplicate_check_exceptions`; an absent, malformed, stale or changed pin fails `--check`. The exception affects only the duplicate-check rule: job timeouts, schedule frequency, and browser install checks still fail when violated.
- **`jobs-have-timeouts`**: a workflow job without `timeout-minutes` fails `--check` (the default is 360 minutes).
- **`secrets-scan-changes-only`**: the secret scan covers the pull request's own commits, including on a dispatch re-gate of the merge ref, so an old leak already on the base does not fail it.

## Promotions (flow `staged`)

- **`promote-no-ui-auto`**: a promotion without UI changes passes the review rule with no approval, so auto-merge completes.
- **`promote-ui-needs-human-approval`**: a promotion with UI changes fails until a human with write access approves; a bot's or a read-only user's approval does not count.
- **`promote-approval-then-merges`**: the approval turns the review verdict green on the same head with no push (the rule is asked again before merging; no workflow listens for reviews).
- **`promote-stale-approval-rejected`**: an approval on an older head, or one later dismissed, does not count.

## Repository contents

- **`agents-md-max-4096`**: an AGENTS.md over 4096 bytes fails `--check`.
- **`agents-block-max-1800`**: an overlay whose rendered managed block exceeds 1800 bytes is refused.
- **`agents-review-guidelines`**: the managed AGENTS.md block ends with a `## Review guidelines` section telling Codex review to skip pack-managed paths (`scripts/agent/`, `.claude/`, `.codex/`, `std-*`); findings there belong in the engine repository.
- **`codeowners-from-ui-paths`**: with the overlay's `ui_owners`, apply writes a managed block at the end of CODEOWNERS giving the repository's UI paths (`standards.json` `ui_paths`, else the defaults; braces expanded) to those owners and leaving ignored paths unowned; the repository's own lines stay above it; `--check` fails an edited block; `ui_paths: []` or no `ui_owners` means no block (a file holding only the block is removed); a glob CODEOWNERS cannot express stops apply before anything is written.
- **`managed-drift-detected`**: a fresh apply passes `--check`; an edited managed file fails it, and the printed fix restores the branch's locked content offline even after the default branch moved to a newer pack.
- **`no-decision-records-in-tree`**: tracked decision records (`adr/`, `adrs/`, `decisions/`, `decision-records/`, `ADR-*.md`, overlay globs) fail `--check`.
- **`shared-preview-host-rejected`**: a deploy config claiming an overlay shared preview host fails `--check`, naming the per-Worker pattern.
- **`claude-md-no-own-content`**: a CLAUDE.md with its own instructions fails; `@AGENTS.md` alone passes in `import-only` mode and fails in `forbid` mode.
- **`models-unpinned`**: repositories never pin a model or effort (Tyler: model choice belongs to each person's app or the launcher). A fresh repository gets no such keys; re-applying removes every pin whatever its value (Claude `model`, `effortLevel`, env `ANTHROPIC_MODEL` / `CLAUDE_CODE_SUBAGENT_MODEL` / `CLAUDE_CODE_EFFORT_LEVEL`; Codex `model`, `model_reasoning_effort`, `[agents] default_subagent_model`, `[profiles.*]` model and effort) and keeps other keys; `--check` fails naming any pin left in the root `.claude/settings.json` or `.codex/config.toml`.
- **`apply-no-symlink-writes`**: apply writes and deletes only its own paths inside the repository: it refuses, changing nothing, when a path's parent is a symlink or lies outside the tree; a lock line naming anything outside the pack's managed paths, or traversing out of one with `..`, is never deleted; old lock formats are read so retired pack paths are removed (apply once wrote through a symlinked parent).
- **`repo-allow-paths`**: `standards.json` `allow_paths` (a list of globs) exempts matching tracked files from the `.mcp.json` and forbidden-path checks only (a client plugin ships its own `.mcp.json`); other paths still fail, a non-list fails, and re-apply keeps the key.
- **`overlay-launcher-validated`**: an overlay's optional `launcher` settings (this org's lanes, dispatch schedule and its `when: "drift"` condition, issue sections) load when well-formed (including `revert` thresholds); unknown keys, vendors or lanes, malformed schedules, a `when` other than `drift`, non-positive or unknown `revert` values and credential-looking values are refused before anything is written.
- **`review-settings-removed`**: an overlay still naming `review`, `org_admin.review_status` or `codex.verdict` is refused with the reason before anything is written (gate checks code only; the rulesets require resolved threads).
- **`session-hook-single`**: apply keeps the repository's own SessionStart hooks and leaves exactly one `setup.sh --check` hook under matcher `startup|resume`; `--check` fails when the hook sits under another matcher (apply once dropped a repo's hooks with the old group).
- **`agent-deny-secrets-and-force-push`**: apply writes the deny set (secret reads, `op`, force-push) replacing any repo list, the Codex bypass keys above the first table, and Codex rules that forbid `op` and force-push but allow `--force-with-lease`; a repository that ignores `.codex/` in any form still commits the engine's Codex files.

## Pull requests and sync

- **`pr-open-verified`**: the PR helper sends nothing on a dry run, refuses a branch that is not on GitHub, reuses the open PR, and prints a URL only after reading the PR back.
- **`pr-status-done`**: `DONE` only when the PR is open or merged, closes an issue, `gate` is green on the head SHA, and every review thread is resolved (the org rulesets require it); an unreadable thread list is not DONE.
- **`sync-lands-without-gate`**: a pack landing runs no gate (the engine's own CI is the release gate): sync commits on the default head, checks the tree offline, and fast-forwards the default branch (staging on staged repositories, never main) with no branch, PR or workflow run. The default branch moving first costs one re-apply, then it lands. Incident: each fleet roll ran every repository's gate twice (about 60 billed minutes).
- **`breaking-release-proves-first`**: an engine release marked `breaking` (it can stop a repository's gate or check from passing) syncs nothing on a fleet run (a warning, not a failure) until a person runs `--proven`; it lands on one repository with `--repo`, and landing there is not proof. The proof is recorded in the compliance issue, so the scheduled syncs that follow roll it without the flag.
- **`sync-opens-pr-when-red`**: when the applied tree fails the repository's offline check, sync opens exactly one PR for a person, naming the failures, without auto-merge, and leaves the default branch alone; a PR a person closed for the same content is not reopened. Its body tells a person how to fix it from a fresh branch (only the App may push `standards/v*`).
- **`sync-applies-release`**: sync applies the released overlay with the engine version it pins and refuses a mismatch (an old sync script once ran from a release tag).

## Modules

- **`error-tracker-rerun-safe`**: the error-tracker setup (dry run, create, route, write the DSN) is a no-op on rerun, and a rerun after a closed mapping PR never deletes that branch (it may hold later work): it opens a new PR from the next free retry branch (`chore/sentry-project-retry/<repo>/<n>`) off the current default (reruns once broke on a leftover branch).

## Org settings (`org/`)

- **`org-rulesets-render`**: the org ruleset set renders from the overlay: PR rule and required `gate` (the only required check unless the overlay adds some) on default branches, promotions on staged `main`, resolved review threads on every PR ruleset, code-owner review on `main` only (direct repos' default branch and `main`, staged `main`), the sync App's bypass (on push rulesets only when the overlay sets `push_app_bypass`); a live ruleset's extra approval for unattributed changes is kept unless the overlay sets it; the removed `review_status`, `review_thread_resolution` and `codex_verdict_status` settings are refused.
- **`promotion-not-strict`**: with `strict_status_checks` on, no ruleset covering a staged repository's `main` is strict, so a promotion whose `main` is ahead only by earlier promotion merge commits (staging never gets them and takes no direct push) stays mergeable; strict still holds on staging and on a direct repository's `main`. Incident: a promotion stuck BEHIND forever in the other org.
- **`org-apply-idempotent`**: `org-apply --dry-run` shows the diff against live settings, and a second apply changes nothing.

## Engine

- **`workflows-parse`**: every workflow the engine ships parses as YAML (an unquoted colon once disabled a workflow silently).

- **`engine-neutral`**: no organization name, internal host, account, App or vault identifier appears in the tree or anywhere in history.
