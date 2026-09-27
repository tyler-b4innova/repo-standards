---
name: std-errors
description: Fix a production error filed from the error tracker - issues labelled sentry, stack traces, regressions, "fixes <SHORT-ID>". Use when an issue came from the error tracker.
---

# Production errors

Deployed Workers report errors through the Sentry SDK (`withSentry`, with `SENTRY_DSN` and `SENTRY_RELEASE`); the org's filer turns each Sentry issue into a GitHub issue labelled `sentry`. OTLP export never creates Sentry issues, so removing the SDK silently stops them: keep it.

1. The title is `[<SHORT-ID>] <error>: <message>`. The body has the release (commit SHA), culprit, counts and a source-mapped stack, newest call first.
2. Start at the top in-app frame and the release: `git show <sha>:<file>` is the code that failed.
3. Reproduce through the real entry point, then add an end-to-end test that fails without the fix.
4. Put `fixes <SHORT-ID>` in the PR body; Sentry resolves the issue when that commit ships.
5. A regressed issue reopens with a new count: the first fix did not hold.
6. Never edit the filer's marked sections in the issue body.

New deployable repo: `scripts/agent/sentry-setup` creates the project, routes its issues here and fills in the DSN.
