# repo-standards

An org-neutral engine for repo-scoped agent standards. Each organization keeps a small overlay (`org.json`: data only) in its own standards repository; the engine renders and applies the pack from it.

## What a consumer repository carries

Every managed file is committed in the repository, so cloud sessions and sandboxes with no network still have everything: the managed `AGENTS.md` block, `.agents/skills/std-*` (+ `.claude/skills` link), `scripts/agent/` (`setup.sh`, `check.mjs`, `gate.mjs`, `pr.sh`, `evidence.mjs`, `pack.json`), `.github/workflows/std-gate.yml` (the one required check, `gate`), PR and issue templates, `.claude/settings.json` (session hook, model defaults, allow rules) and `.codex/config.toml` (model defaults), plus `standards.json` (repo-owned) and `standards.lock` (sha256 of each managed path).

Consumer repositories never depend on this engine at run time. Only the organization's sync job fetches it, pinned to a release:

```sh
npx -y github:tyler-b4innova/repo-standards#v0.2.0 apply --target <repo> --overlay org.json --version <org release>
npx -y github:tyler-b4innova/repo-standards#v0.2.0 sync --overlay org.json --version <org release>   # GH_TOKEN = App token
npx -y github:tyler-b4innova/repo-standards#v0.2.0 expiry --overlay org.json
```

## Behaviour

`SCENARIOS.md` is the contract: every behaviour has a stable id, and `test/run.sh` prints `ok <id>` / `FAIL <id>` for each one and fails if any id is missing. Overlay keys and rules are described there and in `examples/overlay.json`.

Model defaults (effort stays at provider defaults):
- Claude: project `.claude/settings.json` sets `model: opus` and `CLAUDE_CODE_SUBAGENT_MODEL=opus`; project settings outrank user settings, and `/model` still switches a session. Claude cloud sessions on one repository read this file; multi-repository sessions do not.
- Codex: `.codex/config.toml` sets `model` and `[agents] default_subagent_model`. Codex reads it only in trusted projects; `setup.sh --check` warns with the fix when a checkout is not trusted. Codex Cloud tasks have no per-task model; they use the workspace default.

Budgets: rendered block ≤1800 bytes, each skill ≤1536 bytes, core pack ≤40 KB (overlay modules `error_tracker` and `deploy` add their own files).

## Develop

```sh
test/run.sh                                  # every scenario, plus neutrality of tree and history
node tools/neutrality.mjs --history          # this repository names no organization, host or account
node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version "$(node -p 'require("./package.json").version')"
```
