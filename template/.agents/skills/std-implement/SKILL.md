---
name: std-implement
description: Implement an issue or requested change end to end - fix a bug, build a feature, change code, config or docs, and carry it to a verified draft PR. Use for "implement #N", "fix issue", "agent-ready", dispatched issues.
---

# Implement

1. Read the issue, its comments and the files it names. Write down the proof that will show it is done (a test, a command, a capture). No checkable proof: ask on the issue and stop. Stop too on `human-decision` or more than one PR's worth of work.
2. `scripts/agent/recall "<words>"` for prior decisions and gotchas.
3. Branch from the default branch: `<type>/<n>-<slug>`, or the branch the harness assigned.
4. Make the smallest change that meets the issue. Delete before adding; no fallback for the old path. Anything else you notice becomes a new issue.
5. Prove it through the real entry point. Add or change an end-to-end test when behaviour changed. Run the tests you touched; `gate` runs the rest.
6. UI, .docx or .pptx changed (`node scripts/agent/gate.mjs classify`): follow `std-evidence`.
7. `std-autoreview`, then `scripts/agent/setup.sh --check`.
8. Conventional Commits, small and logical. Then `std-file-pr` and `std-babysit` until `scripts/agent/pr.sh status <pr>` prints `DONE` or a human is needed.
