---
name: std-babysit
description: Babysit an open PR until it is green - watch checks, fix failures, answer review bot findings and review comments. Use for "babysit", "watch the PR", "fix CI", "why is gate red", "address review comments".
---

# Babysit a PR

Loop until `scripts/agent/pr.sh status <pr>` prints `DONE`.

Fix rounds happen in draft. Before the first fix push to a ready PR, run `scripts/agent/pr.sh review-round <pr> "<why>"`: it converts the PR back to draft and records why, so no CI job runs on a fix push. Iterate with `node scripts/agent/gate.mjs local`. When it passes on the pushed head, run `scripts/agent/pr.sh ready <pr>` once: the full gate then runs once on the final head. Never push fixes to a ready PR.


1. Failing check: read its log once, reproduce with the smallest command, fix, push (in draft).
2. `scripts/agent/pr.sh feedback <pr>` lists comments and reviews newer than the last push. For each finding, open the code it points at:
   - correct: fix it, push (in draft), reply with the commit SHA;
   - wrong: `scripts/agent/pr.sh reply <pr> <id> "<reason citing the line>"`.
   Then `scripts/agent/pr.sh resolve <pr> <id>` (merging needs every thread resolved). Never resolve without a reply, and never resolve a human's thread.
3. A finding that asks for new scope: reply why it is out of scope; file an issue only for an actionable defect or deliberate work (grouped with related work under one issue) and link it.
4. Nothing new and checks pending: wait 60s, then 120s, then 300s. Stay quiet meanwhile.

Stop when `gate` and the bots are green with every finding answered, or when a human decision is needed; say what is left. Do not merge unless the task says you may.
