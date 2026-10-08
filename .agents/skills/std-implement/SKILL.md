---
name: std-implement
description: Implement an issue or requested change end to end - fix a bug, build a feature, change code, config or docs, and carry it to a verified draft PR. Use for "implement #N", "fix issue", "agent-ready", dispatched issues.
---

# Implement

1. Read the issue, its comments and the files it names. Write down the proof of done (a test, a command, a capture). No checkable proof, `human-decision`, or more than one PR of work: ask on the issue and stop.
2. Branch from the default branch, or with no `origin` (Codex cloud) from the checked-out HEAD, noting its SHA as the base: `<type>/<n>-<slug>`, or the branch the harness assigned.
3. Make the smallest change that meets the issue. Delete before adding; no fallback for the old path. File an issue only for an actionable defect or deliberate follow-up work, grouping related work under one issue.
4. Prove it through the real entry point. Add or change an end-to-end test when behaviour changed. Iterate with `node scripts/agent/gate.mjs local`: the full gate, including the same e2e suite through the real entry point and local bindings. No mocks of what the repo owns; only third-party services through existing seams. Run it without secrets; keep local values in the ignored `.dev.vars`. It must pass before a PR is marked ready.
   Write tests that earn their place:
   - One behaviour, one layer: Worker/integration tests prove rules; a browser test covers only what needs a browser.
   - Seed through the API or SQL, never by replaying UI steps.
   - No test that only asserts a mock, a snapshot or a screenshot count.
   - axe lives only in dedicated `@a11y` tests that run in `release-check`, one scan per distinct page or state; functional specs never call it.
   - No CPU throttling, `test.retries`, `waitForTimeout` or wall-clock assertions: wait on an event, or use `page.clock`.
   - Every test can fail for a real reason: break the code (revert the fix, flip the condition), watch it fail, and put that mutation in the PR body.
   - A new slow test (browser, multi-step) says in a comment what it alone proves; if another test proves it, delete one.
5. UI, .docx or .pptx changed (`node scripts/agent/gate.mjs classify`): follow `std-evidence`.
6. `scripts/agent/setup.sh --check`.
7. Conventional Commits, small and logical. Then `std-file-pr` and `std-babysit` until `scripts/agent/pr.sh status <pr>` prints `DONE` or a human is needed.
