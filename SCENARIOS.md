# Standards engine conformance scenarios

The org-neutral standards engine implements these 72 scenarios. Each organization's overlay supplies data, never behaviour.

## Rules

- IDs are stable. An ID is never renamed or reused. A retired scenario keeps its ID and is marked retired.
- A pack conforms to a scenario when its self-test runs a case for it that can fail, and prints the ID on the result line (`ok <id>` or `FAIL <id>`). Behaviour without such a case does not count.
- Two pinned engine versions differ by the set of IDs their self-tests print.
- Pass evidence is observable behaviour: exit status, printed lines, GitHub state, or requests sent. It never depends on a file name inside the engine.
- Where two mechanisms were in use, the scenario takes the more repo-scoped one. The engine default is the fallback when the repository says nothing.

## Scope

| Scope | Meaning |
|---|---|
| `shared` | Same behaviour and same values for every organization. |
| `shared+data` | Same behaviour; the organization's overlay supplies the values (hosts, patterns, modes, fleet, credentials). An empty value makes the scenario pass trivially. |
| `overlay-module` | Ships in the engine but is off unless the organization's overlay enables it. |

## Entry points referred to

These are behaviours of the engine: **apply** (install the pack into a repository), **check** (offline self-check, run at session start and in gate), **setup** (sandbox install, then check), **gate** (the one required check), the **PR helper** (open, status, evidence, feedback, reply), **capture** (web evidence), and **sync** (the fleet updater run from each organization's standards repository). The engine chooses their paths.


## Apply

- **`apply-idempotent`** (shared)
  - Given a repository the pack was just applied to.
  - When apply runs again with the same versions.
  - Then nothing changes.
  - Pass evidence: Apply reports no changes and the working tree is clean.
- **`repo-text-preserved`** (shared)
  - Given an AGENTS.md with repo-owned text outside the managed block.
  - When apply runs with another profile or version.
  - Then every line outside the block is unchanged.
  - Pass evidence: A diff of AGENTS.md outside the markers is empty.
- **`dropped-path-removed`** (shared)
  - Given a lock listing a managed path the new pack no longer ships.
  - When apply runs.
  - Then that path is deleted.
  - Pass evidence: The file is gone and the new lock has no line for it.
- **`apply-keeps-repo-skills`** (shared)
  - Given a repo-owned skill under the Claude skills path, as a real directory or a link.
  - When apply runs.
  - Then the skill stays loadable, or apply stops and names it without deleting anything.
  - Pass evidence: The skill's SKILL.md is readable through the skills link after apply, or apply exits non-zero naming it and the tree is unchanged.
- **`apply-merges-settings`** (shared)
  - Given agent settings holding repo-owned keys.
  - When apply runs twice.
  - Then the session hook and the engine's permission rules appear exactly once and repo keys are unchanged.
  - Pass evidence: The settings diff shows only engine entries added; the second apply adds nothing.
- **`apply-keeps-repo-fields`** (shared)
  - Given a standards.json with repo-owned fields (dispatch, sensitive, e2e, ui_paths).
  - When apply installs a new version.
  - Then only pack, version and profile change.
  - Pass evidence: The repo-owned fields are byte-identical after apply.
- **`apply-ignores-local-agent-state`** (shared)
  - Given local agent state under `.claude/`.
  - When apply runs.
  - Then only the settings file and the skills link under `.claude/` are trackable.
  - Pass evidence: Git reports any other `.claude/` path as ignored and those two as not ignored.
- **`claude-md-no-own-content`** (shared+data)
  - Given a CLAUDE.md holding its own instructions, under either overlay `claude_md` mode.
  - When the check runs.
  - Then it fails; in mode `forbid` any CLAUDE.md fails, and in mode `import-only` a CLAUDE.md that is exactly `@AGENTS.md` passes.
  - Pass evidence: Exit 1 naming CLAUDE.md for own content in both modes; for `@AGENTS.md`, exit 1 in `forbid` and exit 0 in `import-only`.

## Offline check

- **`check-passes-fresh-apply`** (shared)
  - Given an empty git repository.
  - When each profile is applied and committed, then the check runs.
  - Then it passes.
  - Pass evidence: Exit 0 and one ok line naming pack, version and profile.
- **`check-offline-fast`** (shared)
  - Given a freshly applied repository and no network.
  - When the check runs.
  - Then it completes.
  - Pass evidence: Exit 0 in under 2 seconds with networking disabled.
- **`check-failure-names-fix`** (shared)
  - Given any failing condition.
  - When the check runs.
  - Then each failure is one line with a fix.
  - Pass evidence: Every failure line carries a fix command or action; exit 1.
- **`managed-drift-detected`** (shared)
  - Given an edited managed file.
  - When the check runs.
  - Then it fails naming the path and printing a restore command.
  - Pass evidence: Exit 1 with the path and a restore command in the failure line.
- **`drift-fix-restores-lock`** (shared)
  - Given an edited managed file on a branch where the default branch has since moved to a newer pack.
  - When the printed restore command runs offline.
  - Then the file returns to the content recorded in this branch's lock.
  - Pass evidence: The file hash matches the lock and the check passes, with no network.
- **`managed-missing-detected`** (shared)
  - Given a deleted managed file.
  - When the check runs.
  - Then it fails naming the path.
  - Pass evidence: Exit 1 with the path in the failure line.
- **`managed-block-drift-detected`** (shared)
  - Given an edited line inside the managed AGENTS.md block.
  - When the check runs.
  - Then it fails.
  - Pass evidence: Exit 1 naming the managed block.
- **`agents-block-single`** (shared)
  - Given an AGENTS.md with two managed blocks.
  - When the check or apply runs.
  - Then the check fails and apply refuses.
  - Pass evidence: Check exit 1 naming the marker counts; apply exits non-zero and writes nothing.
- **`agents-md-max-4096`** (shared)
  - Given an AGENTS.md over 4096 bytes.
  - When the check runs.
  - Then it fails naming the size and the limit.
  - Pass evidence: Exit 1 with both numbers.
- **`skills-symlink-enforced`** (shared)
  - Given the Claude skills path is not a link to the shared skills directory.
  - When the check runs.
  - Then it fails.
  - Pass evidence: Exit 1 with the relink command.
- **`session-hook-enforced`** (shared)
  - Given agent settings without the session-start check hook.
  - When the check runs.
  - Then it fails.
  - Pass evidence: Exit 1 naming the settings file.
- **`standards-json-validated`** (shared)
  - Given a standards.json with an unknown pack, profile or dispatch value, or a wrong type.
  - When the check runs.
  - Then it fails naming the allowed values.
  - Pass evidence: Exit 1 with the allowed values in the fix.
- **`version-lock-agree`** (shared)
  - Given standards.json and the lock name different versions.
  - When the check runs.
  - Then it fails.
  - Pass evidence: Exit 1 naming both versions.

## Forbidden content

- **`root-context-md-forbidden`** (shared)
  - Given a CONTEXT.md at the repository root.
  - When the check runs.
  - Then it fails.
  - Pass evidence: Exit 1 naming CONTEXT.md.
- **`mcp-json-forbidden`** (shared)
  - Given a committed `.mcp.json`.
  - When the check runs.
  - Then it fails.
  - Pass evidence: Exit 1 with an untrack-and-ignore fix.
- **`no-decision-records-in-tree`** (shared+data)
  - Given a tracked markdown file under a directory named adr, adrs, decisions or decision-records at any depth, a file named ADR-*.md anywhere, or a path matching the overlay's extra decision-record globs.
  - When the check runs.
  - Then it fails; the fix is to delete it, because decisions are not recorded anywhere and must be evident in the work itself.
  - Pass evidence: Exit 1 naming the file; the same content at a path matching none of those passes.
- **`no-evidence-on-main`** (shared)
  - Given `.evidence/` tracked on the default branch or on a pull request head.
  - When the check or the gate runs.
  - Then it fails.
  - Pass evidence: Check exit 1 on the default branch; gate red on the pull request.
- **`overlay-forbidden-paths`** (shared+data)
  - Given the overlay forbids a path glob for this profile, and the repository tracks a match.
  - When the check runs.
  - Then it fails naming the path.
  - Pass evidence: Exit 1 naming the path and the overlay rule.
- **`client-leak-scan`** (shared+data)
  - Given a client-profile repository tracking a file that matches an overlay forbidden pattern.
  - When the check runs.
  - Then it fails naming file and line.
  - Pass evidence: Exit 1 with file:line; the same file in an internal repository passes.
- **`shared-preview-host-rejected`** (shared+data)
  - Given a tracked deploy config naming an overlay shared preview host.
  - When the check runs.
  - Then it fails; with an empty list nothing is checked.
  - Pass evidence: Exit 1 naming the file and host.

## Sandbox setup

- **`setup-never-blocks-sandbox`** (shared)
  - Given an install step that fails (no sudo, unknown package).
  - When setup runs without flags.
  - Then it prints what failed, runs the check and still exits 0.
  - Pass evidence: Exit 0 with the install failure and check result printed.
- **`setup-offline-skips-installs`** (shared)
  - Given no network.
  - When setup runs.
  - Then installs are skipped and the check runs.
  - Pass evidence: An offline notice and no package-manager calls.
- **`setup-installs-repo-deps`** (shared)
  - Given a lockfile for pnpm, yarn or npm and a Playwright dependency.
  - When setup runs.
  - Then dependencies install without changing the lockfile and Chromium is available.
  - Pass evidence: Dependencies present, lockfile unchanged, a headless Chromium launch succeeds.
- **`setup-installs-capture-tools`** (shared)
  - Given tracked .docx or .pptx files, or UI paths.
  - When setup runs.
  - Then a document renderer and a browser are available when installable.
  - Pass evidence: Document-to-PDF conversion and a headless browser launch succeed.

## Gate

- **`gate-is-one-required-job`** (shared)
  - Given any pull request.
  - When workflows run.
  - Then one check named gate carries every engine step.
  - Pass evidence: The head SHA has exactly one check run named gate.
- **`gate-runs-check`** (shared)
  - Given managed drift on the pull request head.
  - When gate runs.
  - Then it fails at the check step.
  - Pass evidence: Gate red with the check's failure line in the log.
- **`gate-runs-on-merge-group`** (shared)
  - Given a merge queue on the base branch.
  - When a pull request enters the queue.
  - Then gate reports on the merge-group commit.
  - Pass evidence: A gate check run exists for the merge-group SHA.
- **`gate-supply-chain-pinned`** (shared)
  - Given the gate workflow.
  - When it runs, and separately the scanner archive's checksum is altered.
  - Then every action is referenced by full SHA, checkout does not keep credentials, and a checksum mismatch fails the step.
  - Pass evidence: Workflow references are 40-hex SHAs; checkout keeps no credentials; the altered-checksum run fails.
- **`secret-scan-in-gate`** (shared)
  - Given a pull request range that adds a credential-shaped string.
  - When gate runs.
  - Then it fails at the secret-scan step and redacts the value.
  - Pass evidence: Gate red; the log names the finding without the secret.
- **`gate-fails-without-e2e`** (shared)
  - Given a repository with no end-to-end suite and no opt-out.
  - When gate runs.
  - Then it fails.
  - Pass evidence: Gate red with an add-an-e2e-suite fix.
- **`e2e-opt-out-honoured`** (shared)
  - Given a repository that declares e2e false (docs or static only).
  - When gate runs, then apply runs.
  - Then gate passes with a warning and apply keeps the declaration.
  - Pass evidence: Gate green with a warning annotation; the field survives apply.
- **`gate-runs-repo-scripts`** (shared)
  - Given a repository defining typecheck and build scripts.
  - When gate runs.
  - Then both run; a missing script is skipped with a notice; a failing one fails gate.
  - Pass evidence: Log shows each script run or skipped; a failing script turns gate red.
- **`repo-gate-hook-runs`** (shared)
  - Given an executable repo-owned gate hook.
  - When gate runs.
  - Then the hook runs after the check and its failure fails gate; no hook prints a notice.
  - Pass evidence: Gate red when the hook exits non-zero; a notice line when absent.

## Evidence

- **`ui-paths-repo-override`** (shared)
  - Given standards.json lists ui_paths.
  - When one pull request changes a file matching only a repo glob, another a file matching only an engine default.
  - Then the first needs evidence and the second does not.
  - Pass evidence: Gate red for the first without evidence; the evidence step passes for the second.
- **`ui-paths-empty-warns`** (shared)
  - Given a standards.json with `ui_paths: []` and tracked files matching the engine's default UI globs.
  - When the check runs, then gate runs on a pull request changing one of those files.
  - Then the check passes with a warning naming the matching files, and gate requires no evidence.
  - Pass evidence: Check exit 0 with a warning line listing the files; the evidence step passes without a comment.
- **`ui-paths-default-fallback`** (shared)
  - Given a standards.json without ui_paths.
  - When a pull request changes markup, styles, components, .docx or .pptx.
  - Then evidence is required under the engine defaults.
  - Pass evidence: Gate red without an accepted evidence comment.
- **`ui-paths-evidence-required`** (shared)
  - Given a pull request changing a UI path.
  - When gate runs with no accepted evidence comment.
  - Then it fails.
  - Pass evidence: Gate red naming the changed UI paths.
- **`non-ui-change-no-evidence`** (shared)
  - Given a pull request changing no UI path.
  - When gate runs.
  - Then the evidence step passes without a comment.
  - Pass evidence: A no-UI-paths line and a green step.
- **`evidence-comment-author-or-app`** (shared)
  - Given an evidence comment by someone other than the PR author or an app.
  - When gate runs.
  - Then the comment is not accepted.
  - Pass evidence: Gate red naming the comment and its author.
- **`evidence-images-pinned-resolving`** (shared)
  - Given an evidence comment whose image is on a branch name, in another repository, or missing at its SHA.
  - When gate runs.
  - Then the comment is not accepted.
  - Pass evidence: Gate red listing each unresolved image URL.
- **`evidence-post-pinned-idempotent`** (shared)
  - Given captures for a pull request.
  - When evidence is posted twice.
  - Then image URLs are pinned to a full commit SHA and the second post updates the same comment.
  - Pass evidence: One comment exists; its URLs contain the 40-hex SHA.
- **`evidence-post-cleans-tip`** (shared)
  - Given captures on a pull request branch.
  - When evidence is posted.
  - Then the branch tip carries no `.evidence/` and the posted images still resolve.
  - Pass evidence: The tip tree has no `.evidence/`; each image URL returns 200.
- **`evidence-capture-web`** (shared)
  - Given a running app URL.
  - When web capture runs.
  - Then full-page PNGs at 400 and 1280 px are written, plus video when asked.
  - Pass evidence: Printed file paths; image widths 400 and 1280.

## Pull requests

- **`pr-open-verified`** (shared)
  - Given a branch.
  - When the PR helper opens a PR, first dry-run, then for an unpushed branch, then twice for a pushed one.
  - Then dry-run sends nothing, an unpushed branch is refused, one draft is created and reused, and a URL prints only after reading the PR back.
  - Pass evidence: Request log: no request on dry-run; exactly one create; a read-back before the URL prints.
- **`pr-open-requires-closes`** (shared)
  - Given a PR body without Closes, Fixes or Resolves #N.
  - When the PR helper opens a PR.
  - Then it refuses before any request.
  - Pass evidence: Non-zero exit and no create request.
- **`pr-status-done`** (shared)
  - Given a pull request.
  - When the status helper runs.
  - Then it prints DONE only when the PR is open or merged, closes an issue, and gate is green on the head SHA.
  - Pass evidence: DONE and exit 0 in that state; NOT DONE with the reasons and exit 1 otherwise.
- **`pr-feedback-and-reply`** (shared)
  - Given comments and reviews older and newer than the last push.
  - When the feedback and reply helpers run.
  - Then only newer items are listed with ids, and a reply lands on the review thread or as a PR comment.
  - Pass evidence: Listed ids equal the newer items; the reply exists on GitHub.

## Pack hygiene

- **`agents-block-max-1800`** (shared+data)
  - Given the engine block plus each profile's overlay lines.
  - When the pack self-test renders each profile.
  - Then every rendered block is at most 1800 bytes.
  - Pass evidence: Self-test fails naming the profile and size above the limit.
- **`pack-size-budgets`** (shared)
  - Given the pack's skills.
  - When the self-test runs.
  - Then each SKILL.md is at most 1536 bytes with name and description frontmatter, and the pack is at most 40 KB.
  - Pass evidence: Self-test fails naming the file and size above a limit.
- **`skills-model-invocable`** (shared)
  - Given the pack's skills.
  - When the self-test runs.
  - Then no skill disables model invocation.
  - Pass evidence: Self-test fails naming any skill that does.
- **`scripts-lint-and-help`** (shared)
  - Given every pack script.
  - When the self-test runs.
  - Then each passes a syntax check and answers --help with usage.
  - Pass evidence: Self-test fails naming the script.
- **`pack-dogfooded`** (shared)
  - Given the pack repository.
  - When the self-test runs.
  - Then the repository carries the current pack and fails when stale.
  - Pass evidence: Self-test fails with a re-apply command when the lock differs.

## Sync and fleet

- **`sync-applies-release`** (shared+data)
  - Given an overlay release that pins an engine version.
  - When sync runs.
  - Then repositories get exactly that overlay release and engine version; an unreleased branch head never ships.
  - Pass evidence: The lock in each sync PR names both versions from the release.
- **`sync-discovers-fleet`** (shared+data)
  - Given org repositories, some declaring this pack in standards.json, plus overlay includes and excludes.
  - When sync runs.
  - Then PRs open only for declaring repositories and overlay includes, minus excludes and archived repositories.
  - Pass evidence: The set of repositories with sync PRs equals that set.
- **`sync-org-isolated`** (shared)
  - Given a repository owned by another org or declaring another org's pack.
  - When sync runs.
  - Then it is skipped.
  - Pass evidence: No branch, PR or comment is written to it.
- **`sync-automerge-requires-gate`** (shared)
  - Given a base branch where gate is not a required check.
  - When sync opens a PR.
  - Then auto-merge is not armed and the reason is reported.
  - Pass evidence: PR has no auto-merge; compliance row says why.
- **`sync-respects-closed-pr`** (shared)
  - Given a sync PR a person closed for the current content.
  - When sync runs again.
  - Then it does not reopen or re-push it.
  - Pass evidence: No new commit or PR for that content.
- **`sync-supersedes-old-versions`** (shared)
  - Given an open sync PR for an older version.
  - When sync opens the newer one.
  - Then the older PR is closed with a superseded comment.
  - Pass evidence: Older PR closed with the comment; its branch deleted.
- **`sync-never-force-pushes`** (shared)
  - Given an existing sync branch.
  - When sync refreshes it.
  - Then the branch only moves forward.
  - Pass evidence: The old head is an ancestor of the new head.
- **`sync-idle-without-credentials`** (shared)
  - Given no sync app credentials configured.
  - When sync runs.
  - Then it exits green with a notice and writes nothing.
  - Pass evidence: A notice line and no API writes.
- **`sync-compliance-issue`** (shared+data)
  - Given a sync run.
  - When it finishes.
  - Then one pinned issue in the standards repository has a row per repository with profile, pinned version and state.
  - Pass evidence: The issue body has one row per synced repository.
- **`credential-expiry-sentinel`** (shared+data)
  - Given an overlay credential whose issue date is older than its limit.
  - When the daily run happens, then the date is updated.
  - Then one issue labelled human-decision opens, then closes itself.
  - Pass evidence: Exactly one such issue while stale; closed with a clear comment after.

## Overlay modules

- **`error-tracker-setup`** (overlay-module)
  - Given an overlay with an error tracker configured and a deployable repository.
  - When the setup command runs twice, the first time as a dry run.
  - Then the dry run writes nothing; the real run creates the project, routes its issues to the filer and writes the public DSN; the second run changes nothing.
  - Pass evidence: Dry-run prints intended steps only; after the run the project exists and the config holds the DSN; the rerun reports all steps already done.
- **`deploy-release-tagging`** (overlay-module)
  - Given an overlay with the deploy module on.
  - When a deploy runs with and without tracker build settings.
  - Then the release is the commit SHA; source maps upload only when all tracker settings are present.
  - Pass evidence: The deployed release variable equals the SHA; the upload is skipped with a notice otherwise.
