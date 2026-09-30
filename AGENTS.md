# repo-standards

<!-- std:begin example -->
## Example standards

- Done = verified on GitHub: `gate` green, review threads resolved, evidence posted. A text-only end of turn is a report. Never claim a PR, check or deploy you did not verify.
- Stop and name the stop point: `human-decision` label, uncheckable criteria, missing secret or permission, destructive step, a rule here that fights the task.
- Silo: no global config, plugins, MCP or personal memory; nothing crosses orgs.
- One concern per PR. Issues only for actionable defects or deliberate work, related work grouped in one.
- Visual change (UI, .docx, .pptx): before/after captures you inspected (web 400/1280px, document pages), in chat and on the PR (`std-evidence`).
- Tests: end-to-end through the real entry point; unit tests only for pure logic with a failure history. Never mock what you own; every test must be able to fail. Run the smallest proof; `gate` runs the rest.
- Answer every bot finding (fix it or reply why), then resolve the thread.
- Never commit plans, notes, scratch, decision records, secrets, `.mcp.json`, `.env`, `.dev.vars`, `*.pem` or `.evidence/` on main.
- Managed paths change only upstream (`setup.sh --check` names drift; `scripts/agent/gate.local.sh` is yours). Cloud setup calls `scripts/agent/setup.sh`; a missing path there breaks cloud tasks.
- AGENTS.md ≤4 KB. Add a line only for a failure that happened.
- Deploys run from the org's CI builds, never from a personal token.
## Review guidelines

- Skip pack-managed paths (`scripts/agent/`, `.claude/`, `.codex/`, `std-*`); they change in repo-standards.
<!-- std:end -->

## Repo rules

- This repository is org-neutral and public: no organization names, internal hosts, account, App or vault ids, in files or commit messages. `node tools/neutrality.mjs --history` must pass; build rejected samples at runtime.
- The engine ships behaviour; org values come only from an overlay. Examples use `example-org` and `example.com`.
- Every behaviour has a scenario id in `SCENARIOS.md`; its case prints `ok <id>` from `test/run.sh`. Keep a scenario only for a failure that happened or a stated rule, run through a real entry point.
- The engine dogfoods itself with `examples/overlay.json`: after changing `template/`, re-run `node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version <package version>`.

## Code Review Rules

- `.codex/config.toml` targets Codex CLI ≥0.155; don't flag its model or [agents] keys against older CLIs.
