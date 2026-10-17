# repo-standards

<!-- std:begin example -->
## Example standards

- Done = verified on GitHub: `gate` green, review threads resolved, evidence posted. A text-only end of turn is a report. Never claim a PR, check or deploy you did not verify.
- Stop and name the stop point: `human-decision` label, uncheckable criteria, missing secret or permission, destructive step, a rule here that fights the task.
- Silo: no global config, plugins, MCP or personal memory; nothing crosses orgs.
- Start each task in a new worktree from freshly fetched `origin/<default>`, unless you are building on an existing branch.
- One concern per PR. Issues only for actionable defects or deliberate work, related work grouped in one.
- Work can be discussed anywhere, between sessions included. Once its scope is settled, it's written as issues with `std-issue` before any agent builds it with `std-implement`.
- Visuals (screenshots, video) are for the people reviewing the PR, in GitHub or the portal, like Cursor's visual PRs; never a test, never compared. Show what the issue asked to see: a video when it moves, before/after for a static change (`std-evidence`).
- Tests: end-to-end through the real entry point; unit tests only for pure logic with a failure history. Never mock what you own; every test must be able to fail. Run the smallest proof; `gate` runs the rest.
- Use `std-file-pr` and `std-babysit` for the pull request workflow.
- Never commit plans, notes, scratch, decision records, secrets, `.mcp.json`, `.env`, `.dev.vars`, `*.pem` or `.evidence/` on main.
- Managed paths change only upstream (`setup.sh --check` names drift; `scripts/agent/gate.local.sh` is yours). Cloud setup calls `scripts/agent/setup.sh`; a missing path there breaks cloud tasks.
- Gates never need root: a gate runs on the machine it is given, which provisions its system packages (the host for an agent, the workflow's own step on a runner). Never key an install or a clean-up on `CI`; `node scripts/agent/gate.mjs browser-deps` names any browser library the host lacks, and `--install` installs them only when one is missing.
- Shared machines: stop only the processes and containers you started, by PID, process group or container ID. Never `pkill -f`, `killall` or `docker kill` by name or image: other sessions run on the same host.
- Add a line only for a failure that happened.
- No per-repo exceptions, and no new rules, gates or numbers to fix a symptom: use the one org-wide pattern or remove something. Never present an inference as the founder's decision; his decisions are his own words in the issue, commit or PR they concern.
- Cloudflare deploys: Workers Builds in the account that owns the Worker runs `scripts/agent/release.mjs`. Nothing is deployed by hand, and no Cloudflare tokens in GitHub.
- Deploys run from the org's CI builds, never from a personal token.

## Code Review Rules
- Report every finding you can see in this head in one review, not only the first.
- In a re-review, raise only what the new commits changed or what the last fix missed, and say which. A fail-open, security or data-loss finding that an earlier round missed is still raised at any severity, marked missed earlier.
<!-- std:end -->

## Repo rules

- This repository is org-neutral and public: no organization names, internal hosts, account, App or vault ids, in files or commit messages. `node tools/neutrality.mjs --history` must pass; build rejected samples at runtime.
- The engine ships behaviour; org values come only from an overlay. Examples use `example-org` and `example.com`.
- Every behaviour has a scenario id in `SCENARIOS.md`; its case prints `ok <id>` from `test/run.sh`. Keep a scenario only for a failure that happened or a stated rule, run through a real entry point.
- The engine dogfoods itself with `examples/overlay.json`: after changing `template/`, re-run `node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version <package version>`.

## Code Review Rules

- `.codex/config.toml` targets Codex CLI ≥0.155; don't flag its model or [agents] keys against older CLIs.
