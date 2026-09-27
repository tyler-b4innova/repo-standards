# repo-standards

<!-- std:begin example -->
## Example standards

- Done = verified on GitHub: the PR exists, `gate` is green, evidence is posted. A text-only end of turn is a report. Never claim a PR, check or deploy you did not verify on GitHub.
- Stop and name the stop point: `human-decision` label, uncheckable criteria, missing secret or permission, destructive step, a rule here that fights the task. In a sandbox with no remote (Codex cloud): commit and stop at "diff ready"; the dispatcher pushes and opens the PR.
- Silo: everything is in this repo: no global config, plugins, MCP or personal memory; nothing crosses orgs.
- One concern per PR; new scope from review becomes an issue.
- Visual change (UI, .docx, .pptx): before/after captures (400 and 1280px) you inspected, in chat and on the PR (`std-evidence`).
- Tests: end-to-end through the real entry point; unit tests only for pure logic with a failure history. Never mock what you own; every test must be able to fail. Run the smallest proof; `gate` runs the rest.
- Answer every bot finding: fix it or reply why.
- Never commit plans, notes, scratch, decision records, secrets, `.mcp.json`, `.env`, `.dev.vars`, `*.pem` or `.evidence/` on main.
- Managed paths change only upstream (`scripts/agent/setup.sh --check` names drift). Cloud setup calls `scripts/agent/setup.sh`; a step naming a missing path silently breaks every cloud task.
- AGENTS.md ≤4 KB. Add a line only for a failure that happened.
- Deploys run from the org's CI builds, never from a personal token.
<!-- std:end -->

## Repo rules

- This repository is org-neutral and public: no organization names, internal hosts, account, App or vault ids, in files or commit messages. `node tools/neutrality.mjs --history` must pass; build rejected samples at runtime.
- The engine ships behaviour; org values come only from an overlay. Examples use `example-org` and `example.com`.
- Every behaviour has a scenario id in `SCENARIOS.md`; its case prints `ok <id>` from `test/run.sh`. Keep a scenario only for a failure that happened or a stated rule, run through a real entry point.
- The engine dogfoods itself with `examples/overlay.json`: after changing `template/`, re-run `node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version <package version>`.

## Code Review Rules

- `.codex/config.toml` targets Codex CLI ≥0.155; don't flag its model or [agents] keys against older CLIs.
