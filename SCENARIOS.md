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
- **`no-evidence-on-main`**: tracked `.evidence/` fails `--check` and `gate`; the PR helper leaves no `.evidence/` on the branch tip after posting.

- **`codex-verdict-required`**: a non-draft PR passes `gate` only when the Codex summary shows the current head as Completed (after the head's push and any base edit) and every Codex thread is resolved; pending or stale fails (after 20 min: "no Codex verdict … the launcher will request one"); drafts, repos without Codex reviews, and the sync's fallback PRs are exempt.
- **`codex-verdict-status`**: with the overlay's `codex.verdict: "status"`, `verdict-recheck` posts the `codex-verdict` commit status on the head (a token that cannot post fails loudly), and gate's codex step defers to that status.
- **`gate-rerun-never-cancelled`**: `std-gate-rerun` has no concurrency group, so a burst of events leaves no cancelled check runs (GitHub reported clean PRs UNSTABLE); an approval re-runs a finished gate run once, a lost race counts as done, and a base change dispatches std-gate (a fork's pull request is asked for a push instead).

### CI minutes (each reproduces a measured cost from the Sep 27 Actions audit)

- **`rerun-reuses-build`**: a re-run of a gate run reuses the head's passed build (install, typecheck, build, e2e, repo checks), also through an earlier reuse attempt, and still checks evidence and the Codex verdict; a cheap or failed-standards attempt does not qualify. `verdict-recheck` re-runs only when that can change the result. Incident: every Codex event rebuilt the site (759 billed minutes of review re-runs in one org in a day; 241 minutes in 138 runs on one repo in the other).
- **`rerun-ignores-noise-senders`**: comments start no gate run at all (every reply on a Codex thread was a full gate), and reviews re-gate only when a person approves or dismisses. Incident: 104 minutes of re-runs came from preview-bot comments.
- **`rerun-never-polls`**: an approval during a gate run that has not read approvals yet exits at once; only an approval that lands after the run read them waits for it (bounded by the gate's timeout). Incident: the 35-minute wait loop on every event.
- **`gate-no-push-regate`**: pushes to main or staging start no gate run (the tree was gated as a PR); `standards/v*` landings do. Incident: 442 billed minutes of post-merge gates.
- **`gate-ignores-body-edits`**: a title or body edit starts no gate run; a base change re-gates the PR's fresh merge ref by dispatch.
- **`skip-never-greens-gate`**: the gate job has no job-level `if` (a skipped job reports success and could mask a red gate on the same head); a dispatch re-gate evaluates the PR, never "not a pull request"; evidence and the Codex verdict run after a failed build step.
- **`pack-landing-cheap-except-canary`**: a pack-only landing runs the cheap gate (check, secret scan, syntax) except on the profile's canary, which runs the full gate; sync lands the canaries first and stops the fleet when one is red (a dry run plans the whole fleet). Incident: each fleet roll re-ran every repo's full gate twice (about 60 billed minutes).
- **`draft-cheap-ready-full`**: drafts run the cheap gate; `ready_for_review` runs the full one.
- **`e2e-chromium-default`**: gate installs and runs Chromium only; more browsers run on promotion PRs when `standards.json` `e2e.browsers` (or the overlay) opts in, and only for projects the Playwright config defines; a config whose projects are named otherwise is refused (without `--project` Playwright runs them all). Incident: three-browser suites ran on every PR.
- **`e2e-uses-preview-url`**: with a Workers Builds check run on the head, e2e runs against the preview URL from the Cloudflare comment for that commit; a red Cloudflare build fails gate; with none, e2e runs locally.
- **`e2e-budget-enforced`**: an e2e suite over its budget (5 minutes; `e2e.budget` may only tighten it) fails gate.
- **`quarantine-expires`**: `@quarantine` needs an issue link and an expiry at most 14 days out; an expired one fails `--check`.
- **`no-duplicate-gate-workflows`**: a repository workflow that runs checks on pull requests, or re-tests pushes to the default or integration branch, or a schedule more frequent than daily, fails `--check`; the declared deploy workflow may build on push. Incidents: a duplicate `validate.yml` ran 142 times; a sub-hourly alert poll billed 166 minutes.
- **`jobs-have-timeouts`**: a workflow job without `timeout-minutes` fails `--check` (the default is 360 minutes).

## Promotions (flow `staged`)

- **`promote-no-ui-auto`**: a promotion without UI changes passes `gate` with no approval, so auto-merge completes.
- **`promote-ui-needs-human-approval`**: a promotion with UI changes fails until a human with write access approves; a bot's or a read-only user's approval does not count.
- **`promote-approval-then-merges`**: the approval re-runs `gate` (the workflow listens for review events) and turns it green on the same head.
- **`promote-stale-approval-rejected`**: an approval on an older head, or one later dismissed, does not count.

## Repository contents

- **`agents-md-max-4096`**: an AGENTS.md over 4096 bytes fails `--check`.
- **`agents-block-max-1800`**: an overlay whose rendered managed block exceeds 1800 bytes is refused.
- **`managed-drift-detected`**: a fresh apply passes `--check`; an edited managed file fails it, and the printed fix restores the branch's locked content offline even after the default branch moved to a newer pack.
- **`no-decision-records-in-tree`**: tracked decision records (`adr/`, `adrs/`, `decisions/`, `decision-records/`, `ADR-*.md`, overlay globs) fail `--check`.
- **`shared-preview-host-rejected`**: a deploy config claiming an overlay shared preview host fails `--check`, naming the per-Worker pattern.
- **`claude-md-no-own-content`**: a CLAUDE.md with its own instructions fails; `@AGENTS.md` alone passes in `import-only` mode and fails in `forbid` mode.
- **`model-defaults-repo-scoped`**: apply writes the Claude and Codex model defaults only where the repository sets none; a repository's own model survives `--check` and re-apply (Tyler's rule: a repo override beats the engine default), and a user-level override only warns.
- **`apply-no-symlink-writes`**: apply writes and deletes only its own paths inside the repository: it refuses, changing nothing, when a path's parent is a symlink or lies outside the tree; a lock line naming anything outside the pack's managed paths, or traversing out of one with `..`, is never deleted; old lock formats are read so retired pack paths are removed (apply once wrote through a symlinked parent).
- **`repo-allow-paths`**: `standards.json` `allow_paths` (a list of globs) exempts matching tracked files from the `.mcp.json` and forbidden-path checks only (a client plugin ships its own `.mcp.json`); other paths still fail, a non-list fails, and re-apply keeps the key.
- **`overlay-launcher-validated`**: an overlay's optional `launcher` settings (this org's lanes, dispatch schedule, issue sections) load when well-formed; unknown keys, vendors or lanes, malformed schedules and credential-looking values are refused before anything is written.
- **`session-hook-single`**: apply keeps the repository's own SessionStart hooks and leaves exactly one `setup.sh --check` hook under matcher `startup|resume`; `--check` fails when the hook sits under another matcher (apply once dropped a repo's hooks with the old group).
- **`agent-deny-secrets-and-force-push`**: apply writes the deny set (secret reads, `op`, force-push) replacing any repo list, the Codex bypass keys above the first table, and Codex rules that forbid `op` and force-push but allow `--force-with-lease`; a repository that ignores `.codex/` in any form still commits the engine's Codex files.

## Pull requests and sync

- **`pr-open-verified`**: the PR helper sends nothing on a dry run, refuses a branch that is not on GitHub, reuses the open PR, and prints a URL only after reading the PR back.
- **`pr-status-done`**: `DONE` only when the PR is open or merged, closes an issue, and `gate` is green on the head SHA.
- **`sync-lands-direct-when-green`**: sync pushes `standards/v<ver>`, which starts that repository's own `gate`; green fast-forwards the default branch (staging on staged repositories, never main) and deletes the branch; `gate` on that branch accepts only pack-managed paths, and its secret scan covers only what the default branch lacks. The default branch moving first costs one re-apply, then it lands. No PR is opened (a pack PR once merged red).
- **`sync-opens-pr-when-red`**: when `gate` stays red after one re-run, sync opens exactly one PR for a person, naming the run, without auto-merge, and leaves the default branch alone; a PR a person closed for the same content is not reopened. Its body tells a person how to fix it from a fresh branch (only the App may push `standards/v*`).
- **`sync-applies-release`**: sync applies the released overlay with the engine version it pins and refuses a mismatch (an old sync script once ran from a release tag).

## Modules

- **`error-tracker-rerun-safe`**: the error-tracker setup (dry run, create, route, write the DSN) is a no-op on rerun, and a rerun after a closed mapping PR never deletes that branch (it may hold later work): it opens a new PR from the next free retry branch (`chore/sentry-project-retry/<repo>/<n>`) off the current default (reruns once broke on a leftover branch).

## Org settings (`org/`)

- **`org-rulesets-render`**: the org ruleset set renders from the overlay: PR rule and required `gate` on default branches, promotions on staged `main`, the sync App's bypass (on push rulesets only when the overlay sets `push_app_bypass`); a live ruleset's extra approval for unattributed changes is kept unless the overlay sets it.
- **`org-apply-idempotent`**: `org-apply --dry-run` shows the diff against live settings, and a second apply changes nothing.

## Engine

- **`workflows-parse`**: every workflow the engine ships parses as YAML (an unquoted colon once disabled a workflow silently).

- **`engine-neutral`**: no organization name, internal host, account, App or vault identifier appears in the tree or anywhere in history.
