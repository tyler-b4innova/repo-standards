# Engine scenarios

Each scenario reproduces a failure that actually happened or a rule the owners stated, and runs through a real entry point: `apply` on a fixture repository, then `scripts/agent/setup.sh --check`, a `gate` step, the PR helper, or `sync` against a GitHub stand-in. `test/run.sh` prints `ok <id>` or `FAIL <id>` for each and fails if any id below is missing. Ids are stable; a retired id stays listed as retired.

## Gate and evidence

- **`gate-fails-without-e2e`**: a repository with no end-to-end suite fails `gate` (the suite was once skipped silently while `gate` went green). The workflow has exactly one job, `gate`, carrying every step.
- **`e2e-opt-out-honoured`**: `"e2e": false` in `standards.json` passes with a warning, and re-applying the pack keeps it.
- **`ui-paths-evidence-required`**: a pull request changing a UI path (markup, styles, components, .docx, .pptx) fails without an accepted evidence comment and passes with one.
- **`evidence-comment-author-or-app`**: an evidence comment by anyone but the PR author, an app or an overlay-trusted login is rejected (a forged comment once passed).
- **`evidence-images-pinned-resolving`**: every evidence image must be in this repository at a 40-hex commit and exist there; the PR helper posts images that way and re-posting updates one comment.
- **`ui-paths-repo-override`**: `standards.json` `ui_paths` replaces the default globs, and `{ "ignore": [...] }` keeps them while exempting paths (release notes generated upstream once tripped the evidence gate).
- **`ui-paths-empty-warns`**: an explicit `ui_paths: []` turns the evidence gate off, and `--check` warns naming tracked files the defaults would cover.
- **`no-evidence-on-main`**: tracked `.evidence/` fails `--check` and `gate`; the PR helper leaves no `.evidence/` on the branch tip after posting.

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
- **`model-defaults-repo-scoped`**: apply writes the Claude and Codex model defaults into the repository; changing them fails `--check`, and a user-level override only warns.
- **`agent-deny-secrets-and-force-push`**: apply writes the deny set (secret reads, `op`, force-push) replacing any repo list, the Codex bypass keys above the first table, and Codex rules that forbid `op` and force-push but allow `--force-with-lease`.

## Pull requests and sync

- **`pr-open-verified`**: the PR helper sends nothing on a dry run, refuses a branch that is not on GitHub, reuses the open PR, and prints a URL only after reading the PR back.
- **`pr-status-done`**: `DONE` only when the PR is open or merged, closes an issue, and `gate` is green on the head SHA.
- **`sync-lands-direct-when-green`**: sync pushes `standards/v<ver>`, which starts that repository's own `gate`; green fast-forwards the default branch (staging on staged repositories, never main) and deletes the branch; `gate` on that branch accepts only pack-managed paths. The default branch moving first costs one re-apply, then it lands. No PR is opened (a pack PR once merged red).
- **`sync-opens-pr-when-red`**: when `gate` stays red after one re-run, sync opens exactly one PR for a person, naming the run, without auto-merge, and leaves the default branch alone; a PR a person closed for the same content is not reopened.
- **`sync-applies-release`**: sync applies the released overlay with the engine version it pins and refuses a mismatch (an old sync script once ran from a release tag).

## Modules

- **`error-tracker-rerun-safe`**: the error-tracker setup (dry run, create, route, write the DSN) is a no-op on rerun, and a rerun after a closed mapping PR re-creates the mapping branch from the current default and opens a new PR (reruns once broke on a leftover branch).

## Engine

- **`workflows-parse`**: every workflow the engine ships parses as YAML (an unquoted colon once disabled a workflow silently).

- **`engine-neutral`**: no organization name, internal host, account, App or vault identifier appears in the tree or anywhere in history.
