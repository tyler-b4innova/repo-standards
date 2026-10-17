---
name: std-file-pr
description: Open, file or update a draft pull request over the REST API, or hand off a ready diff when the sandbox cannot reach GitHub. Use for "open a PR", "file the PR", "draft PR", "update PR body".
---

# File a PR

Iterate with `node scripts/agent/gate.mjs local` and include its head SHA and step results in Evidence. It uses the real entry point with local bindings, without secrets or mocks of what the repo owns. The local gate must pass before a PR is marked ready; this skill opens drafts only.

Title: Conventional Commit in plain language. Body (file outside the repo), per `.github/PULL_REQUEST_TEMPLATE.md`: What, Why with `Closes #N`, Evidence (the `std-evidence` comment, or the command you ran and its result). Last line: the model and harness that did the work if the profile requests attribution; client profiles omit model names, costs and agent narration.

## With a token (Claude cloud, laptop)

1. Push first (`git push -u origin HEAD`), then `scripts/agent/pr.sh open "<title>" <body-file>` (add `--dry-run` to see the request). It refuses a branch that is not on GitHub or not pushed up to HEAD, uses REST only (GraphQL is blocked in some sandboxes), reuses the open PR for the branch, and prints the URL only after reading the PR back.
2. Report that URL. No URL printed means no PR exists.

## Codex cloud (no remote, no token)

1. Commit locally. Write the title on the first line of `.evidence/pr.md`, then the body; leave it uncommitted for the launcher.
2. End with "diff ready", the branch name and the commit SHA. Never say a PR was opened.

Open PRs as drafts and keep them drafts while iterating: drafts start no billed gate job. Iterate with `node scripts/agent/gate.mjs local`. With Launcher reviewers enabled, full review, batched fixes and independent follow-up verification finish in draft; the Launcher marks the locally verified candidate ready and the one job `gate` runs. For a manually managed or GitHub-only PR, mark ready after local proof to start its configured review and gate. A later changed candidate requires fresh review coverage and gate success. See `std-babysit` for findings.

If you close a PR without merging, delete its branch.

A draft is not ready. Once ready, arm auto-merge only when the base branch rules require both `gate` and `review`: `scripts/agent/pr.sh arm <pr>` checks that and refuses otherwise. Never merge directly or through a bypass. Link the PR to this task and watch it until it merges; you own it until then, so do not settle the task while it is open.
