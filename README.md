# repo-standards

An org-neutral engine for repo-scoped agent standards. Each organization keeps a small overlay (`org.json`, data only) in its own standards repository and pins an engine release; the engine renders and applies the pack from it.

## Consumer repositories

Every managed file is committed, so offline cloud sessions and sandboxes have everything: the managed `AGENTS.md` block, `.agents/skills/std-*` (+ `.claude/skills` link), `scripts/agent/` (`setup.sh`, `check.mjs`, `gate.mjs`, `pr.sh`, `evidence.mjs`, `pack.json`), `.github/workflows/std-gate.yml` (the one required check, `gate`), PR/issue templates, `.claude/settings.json`, `.codex/config.toml`, `.codex/rules/std.rules`, and `standards.json` (repo-owned; states the pack version) + `standards.lock` (sha256 per managed path, engine version). Consumers never fetch the engine; only the org's sync job does:

```sh
npx -y github:tyler-b4innova/repo-standards#vX.Y.Z sync --overlay org.json --version <org release>   # GH_TOKEN = org App token
npx -y github:tyler-b4innova/repo-standards#vX.Y.Z apply --target <repo> --overlay org.json --version <org release>
```

**Org contract:** run `sync` (and `expiry`) from a `workflow_dispatch` / `repository_dispatch` workflow in the org's standards repository, triggered by the org's dispatcher or a release. Never rely on `schedule`: it has not fired for either org. Credentials: repo variable `STANDARDS_APP_CLIENT_ID`, secret `STANDARDS_APP_PRIVATE_KEY`. Sync applies only a released overlay with the engine version it pins, and lands it without a PR: it pushes `standards/v<ver>` (which runs that repo's `gate`), fast-forwards the default branch when `gate` passes (the integration branch on staged repos, never main), re-applies once if the branch moved or re-runs once if red, and otherwise opens one PR for a person. The org App needs ruleset bypass on the default branch, `contents`/`workflows`/`actions` write, and the repos need `std-gate.yml` (managed).

**Precedence:** restrictions are additive (engine, then overlay, then repo can only add). Data is repo-owned and replaces: `standards.json` `ui_paths` (explicit `[]` = no UI, with a `--check` warning), `profile`, `dispatch`, `sensitive`, `e2e`, `flow`, `design_signoff`.

## Gate

`gate` runs the offline check, evidence (a PR changing UI paths needs a comment by a trusted author with images pinned to a commit in this repo), a checksum-pinned secret scan, install/typecheck/build, the e2e suite (none fails unless `"e2e": false`), and `scripts/agent/gate.local.sh`. **Promotions** (flow `staged`: default branch into another branch) need no evidence comment; a promotion that changes UI paths passes only with an APPROVED review on the current head SHA by a human with write access (the review event re-runs `gate`, so auto-merge completes). Non-UI promotions pass on green.

## One-time, per person

- Claude: bypass cannot be set from a repository. Set `permissions.defaultMode: "bypassPermissions"` in `~/.claude/settings.json` (or run `claude --dangerously-skip-permissions` once and accept the dialog). `setup.sh --check` warns while it is off.
- Codex: trust each repository (accept the prompt, or add `[projects."<path>"] trust_level = "trusted"`). Until then Codex ignores the repo's model, bypass and rules; `setup.sh --check` warns with the fix.
- Deny rules bind even under bypass: agents cannot read secret files or run `op`, and cannot force-push. Repo scripts that need a secret (for example `sentry-setup`) read it themselves.

Models: Claude `opus` for the main thread and subagents (`/model` still switches a session); Codex `gpt-6-sol` for both. Claude cloud reads these in single-repository sessions; Codex Cloud tasks ignore the repo's model keys and use the workspace or composer model (there is no per-task model option).

## Gotchas

- In issues and comments write "the Codex mention", never the literal handle: any comment containing it starts a paid task, even on a closed issue.

## Develop

`test/run.sh` runs every scenario in `SCENARIOS.md` (each prints `ok <id>`) plus the neutrality check over the tree and full history. After changing `template/`, re-apply to this repository: `node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version "$(node -p 'require("./package.json").version')"`.
