---
name: std-implement
description: Implement an issue or requested change end to end - fix a bug, build a feature, change code, config or docs, and carry it to a verified draft PR. Use for "implement #N", "fix issue", "agent-ready", dispatched issues.
---

# Implement

1. Read the issue, its comments and the files it names. Write down the proof of done (a test, a command, a capture). No checkable proof, `human-decision`, or more than one PR of work: ask on the issue and stop.
2. Branch from the default branch, or with no `origin` (Codex cloud) from the checked-out HEAD, noting its SHA as the base: `<type>/<n>-<slug>`, or the branch the harness assigned.
3. Make the smallest change that meets the issue. Delete before adding; no fallback for the old path. Secrets: `scripts/agent/secret --help`, never bare `op`, never print a value. File an issue only for an actionable defect or deliberate follow-up work, grouping related work under one issue.
4. Prove it through the real entry point. Add or change an end-to-end test when behaviour changed. Run the tests you touched; `gate` runs the rest.
5. UI, .docx or .pptx changed (`node scripts/agent/gate.mjs classify`): follow `std-evidence`.
6. `scripts/agent/setup.sh --check`.
7. Conventional Commits, small and logical. Then `std-file-pr` and `std-babysit` until `scripts/agent/pr.sh status <pr>` prints `DONE` or a human is needed.
