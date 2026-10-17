---
name: std-babysit
description: Babysit an open PR until it is green - watch checks, fix failures, answer review bot findings and review comments. Use for "babysit", "watch the PR", "fix CI", "why is gate red", "address review comments".
---

# Babysit a PR

Loop until `scripts/agent/pr.sh status <pr>` prints `DONE`.

Review the complete change, then independently verify batched fixes against the earlier findings and the fix diff. Report every finding you can see in that head in one review, not only the first. Reviewer selection and operational limits belong to the org's Launcher configuration.

1. Failing check: read its log once, reproduce with the smallest command, fix. Collect every fix and push once.
2. Once a review lands, `scripts/agent/pr.sh feedback <pr>` lists GitHub review comments with ids. Include the Launcher's review record when it owns the review. For each finding, open the code it points at and ask: "Can I name a concrete input or sequence this repo runs, or will run once merged, where this code gives a wrong result?"
   - Yes, within the PR: fix it.
   - Yes, outside the PR: file an issue and link it in the reply.
   - No: a one-line reply.
   Reply with the fix and its real-entry-point proof, or the concrete reason for rejecting the finding. An independent reviewer verifies each disposition before `scripts/agent/pr.sh resolve <pr> <id>`. A changed file or the author's assertion alone proves nothing. Priority labels are the reviewer's assessment, not the rule. Never resolve a person's thread; `pr.sh resolve` refuses one.
3. Batch fixes in one push. Follow-up review receives the earlier findings, responses, fix diff and acceptance criteria; it checks the changed behavior and callers and raises only what the new commits changed or what the last fix missed, and says which. A fail-open, security or data-loss blocker that an earlier round missed is still raised, marked missed earlier. Keep Launcher-owned iteration in draft until review and local proof complete. A fix that changes what the PR is about becomes a new PR. The final candidate needs completed review coverage, a green gate, required approvals, current evidence and resolved threads.
4. Nothing new and checks pending: wait 60s, then 120s, then 300s. Stay quiet meanwhile.

Stop when `gate` and the bots are green with every finding answered, or when a human decision is needed; say what is left. A draft is not ready. Arm auto-merge when the PR is marked ready, as `std-file-pr` says. Arm auto-merge only when the base branch rules require both `gate` and `review`; `scripts/agent/pr.sh arm <pr>` checks that and refuses otherwise. If arm refuses, stop and report it. Never merge directly or through a bypass, and never change a merge setting or a rule. You own the PR until it merges.
