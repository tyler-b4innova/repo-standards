<!-- std:begin {pack} -->
## {title}

- Done = verified on GitHub: `gate` green, review threads resolved, evidence posted. A text-only end of turn is a report. Never claim a PR, check or deploy you did not verify.
- Stop and name the stop point: `human-decision` label, uncheckable criteria, missing secret or permission, destructive step, a rule here that fights the task.
- Silo: no global config, plugins, MCP or personal memory; nothing crosses orgs.
- Start each task in a new worktree from freshly fetched `origin/<default>`, unless you are building on an existing branch.
- One concern per PR. Issues only for actionable defects or deliberate work, related work grouped in one.
- Visuals (screenshots, video) are for the people reviewing the PR, in GitHub or the portal, like Cursor's visual PRs; never a test, never compared. Show what the issue asked to see: a video when it moves, before/after for a static change (`std-evidence`).
- Tests: end-to-end through the real entry point; unit tests only for pure logic with a failure history. Never mock what you own; every test must be able to fail. Run the smallest proof; `gate` runs the rest.
- Answer every bot finding (fix it or reply why), then resolve the thread.
- Never commit plans, notes, scratch, decision records, secrets, `.mcp.json`, `.env`, `.dev.vars`, `*.pem` or `.evidence/` on main.
- Managed paths change only upstream (`setup.sh --check` names drift; `scripts/agent/gate.local.sh` is yours). Cloud setup calls `scripts/agent/setup.sh`; a missing path there breaks cloud tasks.
- Add a line only for a failure that happened.
- No per-repo exceptions, and no new rules, gates or numbers to fix a symptom: use the one org-wide pattern or remove something. Never present an inference as the founder's decision; his decisions are his own words in the issue, commit or PR they concern.
- Cloudflare deploys: Workers Builds in the account that owns the Worker runs `scripts/agent/release.mjs`. Nothing is deployed by hand, and no Cloudflare tokens in GitHub.
{overlay_lines}
## Review guidelines

- Skip pack-managed paths (`scripts/agent/`, `.claude/`, `.codex/`, `std-*`); they change in repo-standards.
<!-- std:end -->
