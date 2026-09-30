---
name: std-babysit
description: Babysit an open PR until it is green - watch checks, fix failures, answer review bot findings and review comments. Use for "babysit", "watch the PR", "fix CI", "why is gate red", "address review comments".
---

# Babysit a PR

Loop until `scripts/agent/pr.sh status <pr>` prints `DONE`:

1. Failing check: read its log once, reproduce with the smallest command, fix, push.
2. `scripts/agent/pr.sh feedback <pr>` lists comments and reviews newer than the last push. For each finding, open the code it points at:
   - correct: fix it, push, reply with the commit SHA;
   - wrong: `scripts/agent/pr.sh reply <pr> <id> "<reason citing the line>"`.
   Then `scripts/agent/pr.sh resolve <pr> <id>` (merging needs every thread resolved). Never resolve without a reply, and never resolve a human's thread.
3. A finding that asks for new scope becomes an issue, linked in your reply.
4. Nothing new and checks pending: wait 60s, then 120s, then 300s. Stay quiet meanwhile.

Stop when `gate` and the bots are green with every finding answered, or when a human decision is needed; say what is left. Do not merge unless the task says you may.
