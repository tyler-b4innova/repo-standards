---
name: std-babysit
description: Babysit an open PR until it is green - watch checks, fix failures, answer review bot findings and review comments. Use for "babysit", "watch the PR", "fix CI", "why is gate red", "address review comments".
---

# Babysit a PR

Loop until `scripts/agent/pr.sh status <pr>` prints `DONE`.

The GitHub Codex review is the one review of a PR. Fixes are not re-reviewed.

1. Failing check: read its log once, reproduce with the smallest command, fix. Collect every fix and push once.
2. Once the Codex review lands, `scripts/agent/pr.sh feedback <pr>` lists its comments with ids. For each finding, open the code it points at and ask: "Can I name a concrete input or sequence this repo runs, or will run once merged, where this code gives a wrong result?"
   - Yes, within the PR: fix it.
   - Yes, outside the PR: file an issue and link it in the reply.
   - No: a one-line reply.
   Reply with `scripts/agent/pr.sh reply <pr> <id> "<text>"` (the commit SHA for a fix), then `scripts/agent/pr.sh resolve <pr> <id>` (merging needs every thread resolved). P1/P2 labels are Codex's guess, not the rule. Never resolve a human's thread.
3. Push all fixes in one push on the ready PR. Do not convert it to draft or mark it ready again. A fix that changes what the PR is about becomes a new PR.
4. Nothing new and checks pending: wait 60s, then 120s, then 300s. Stay quiet meanwhile.

Stop when `gate` and the bots are green with every finding answered, or when a human decision is needed; say what is left. Do not merge unless the task says you may.
