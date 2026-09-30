---
name: std-autoreview
description: The one independent review before a PR - a checklist, then a read-only review by another vendor or a fresh-context reviewer. Use for "review my diff", "autoreview", "second opinion", "check before PR".
---

# Review before filing

1. Read `git diff origin/HEAD...HEAD` (no `origin`, as in Codex cloud: `git diff <base-sha>...HEAD` from the commit you branched from) in full before asking for review. Check:
   - one concern; no unrelated edits or reformatting;
   - no plans, notes, scratch, secrets or `.mcp.json` (outside `standards.json` `allow_paths`); managed paths untouched (`scripts/agent/gate.local.sh` is repo-owned);
   - the proof you named covers the change and you ran it;
   - error paths, empty inputs, concurrency.
2. Independent review, never by the session that wrote the code: in Claude run `codex review --base <base>`; in Codex run `claude -p --permission-mode plan "<prompt>"`. Else a fresh-context read-only subagent given only the diff and the issue. Prompt: the acceptance criteria, the diff, and "Find correctness bugs, missed call sites, security problems and tests that cannot fail. Cite file:line. No style nits. Do not edit files."
3. Verify each finding in the source. Fix real ones; note rejected ones and why in the PR body.
4. Re-run only when a later change invalidates the review (new behaviour, or fixes beyond its findings); at most 2 rounds. Then `scripts/agent/setup.sh --check`.

This is the only review before the PR. After it opens, the only other check is the verdict on the PR: the GitHub Codex review, or an `<!-- independent-review sha=… verdict=… -->` comment when that is unavailable.
