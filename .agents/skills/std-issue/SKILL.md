---
name: std-issue
description: Turn an idea into ONE complete GitHub issue an agent can run - grill for what is missing, copy context in, write the launcher's shape, flag work too big for one PR. Use for "write an issue", "I have an idea", "scope this", "file a task".
---

# Write the issue

Produce one self-contained issue an agent can finish in one PR with nobody to ask. Read the repo first (README, AGENTS.md, the files involved) and check the idea against what the code does today; never ask what the code answers, and say so if the idea does not match it.

1. Grill, one question at a time, only for what is missing, each with your best guess to accept or correct:
   - the outcome, and who sees it;
   - done criteria someone can check by running or looking;
   - which page, screen or module it touches;
   - any visual change (screenshots expected, phone and desktop);
   - constraints and must-nots.
   Stop when you could fill every section without guessing. Never invent a product decision: if the person leaves one to you, record your choice under Context as "Assumed", for them to overrule.
2. Copy in the facts the work needs from email, Teams, Slack, meetings or SharePoint, as quoted text or a table. The agent gets no connector, so a link alone is not context. No secrets or personal data.
3. Write the body with exactly these headings. The launcher rejects the issue if `## Goal` or `## Acceptance criteria` is missing or empty:
   - `## Goal`: one to three plain sentences: the outcome, who sees it, why.
   - `## Acceptance criteria`: a checkbox list; each item verifiable by running something or looking at something.
   - `## Context`: copied facts and assumptions.
   - `## Files`: the files the change will touch, as full repo-relative paths in backticks, each checked to exist (`ls`); a file to be created goes on a line saying "new". The launcher rejects any backticked path-like text that is not a file at HEAD, so backtick nothing else. Cannot read the repo: omit this section rather than guess.
   - `## Evidence`: what to show (before/after screenshots, command output).
   - `## Out of scope`: what must not change.
   Plain words. Say what and why; never a model, subagent, lane, effort or how-to-run instruction.
4. Size check: one PR, one concern, reviewable in one sitting. If it is multi-day, has a slice needing separate approval, or has 3+ independent slices, do not write one giant issue. Propose a parent issue (its Goal and Acceptance criteria are the whole outcome; plus the plan and shared constraints) and sub-issues, every one written in the shape above, and a linked branch `feat/<n>-<slug>` they merge into. Wait for the person to confirm.
5. Show the issue, apply corrections, and only when the person says so file it (`gh issue create --body-file`, or paste into GitHub's Agent task form). Add `agent-ready` to a single issue, or to sub-issues as they become unblocked, never to a parent. Reply with the link.
