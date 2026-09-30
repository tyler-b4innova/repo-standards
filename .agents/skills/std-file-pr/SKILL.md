---
name: std-file-pr
description: Open, file or update a draft pull request over the REST API, or hand off a ready diff when the sandbox cannot reach GitHub. Use for "open a PR", "file the PR", "draft PR", "update PR body".
---

# File a PR

Before opening a PR, get it reviewed by a different vendor's CLI (`codex review --base <base>` for Claude-written work) or a fresh-context reviewer, never by yourself; fix or answer the findings (max 2 rounds).

Title: Conventional Commit in plain language. Body (file outside the repo), per `.github/PULL_REQUEST_TEMPLATE.md`: What, Why with `Closes #N`, Evidence (the `std-evidence` comment, or the command you ran and its result). Last line: the model and harness that did the work.

## With a token (Claude cloud, laptop)

1. Push first (`git push -u origin HEAD`), then `scripts/agent/pr.sh open "<title>" <body-file>` (add `--dry-run` to see the request). It refuses a branch that is not on GitHub or not pushed up to HEAD, uses REST only (GraphQL is blocked in some sandboxes), reuses the open PR for the branch, and prints the URL only after reading the PR back.
2. Report that URL. No URL printed means no PR exists.

## Codex cloud (no remote, no token)

1. Commit locally. Write the title on the first line of `.evidence/pr.md`, then the body; leave it uncommitted for the launcher.
2. End with "diff ready", the branch name and the commit SHA. Never say a PR was opened.

If you close a PR without merging, delete its branch.

Never mark ready, merge or enable auto-merge yourself.
