#!/usr/bin/env bash
# Engine-only cases: the neutrality check rejects what must never enter this repository.
# Rejected samples are built at runtime so no organization value is ever committed.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
scan() { node tools/neutrality.mjs --stdin >/dev/null 2>&1; }
rnd() { node -e "const c=require('crypto');console.log(c.randomBytes(64).toString('hex').slice(0,$1))"; }
org=$(node -e 'console.log(String.fromCharCode(98,52))')
case_rejects() { local id=$1 sample=$2; if printf '%s\n' "$sample" | scan; then fail "$id" "accepted: $sample"; else ok "$id"; fi; }
case_rejects engine-neutral-org-word "maintained by the $org team"
case_rejects engine-neutral-org-name "$(echo "$org" | tr a-z A-Z)-Innovations/standards"
case_rejects engine-neutral-host "see https://internal.$(echo corp).io/runbook"
case_rejects engine-neutral-account-id "account: $(rnd 32)"
case_rejects engine-neutral-app-client-id "client-id: Iv23$(rnd 16)"
case_rejects engine-neutral-app-id "$(echo app)_id: 1234567"
case_rejects engine-neutral-vault-id "vault $(node -e "console.log(require('crypto').randomBytes(26).toString('hex').replace(/[^a-z]/g,'').padEnd(25,'q').slice(0,25)+'7')")"
accept="gitleaks sha256 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
docs: https://code.claude.com/docs/en/settings and https://learn.chatgpt.com/docs/config-file/config-basic
preview: preview.example.com; download https://github.com/gitleaks/gitleaks/releases
trigger 1477542a-ed67-4c5a-9f0f-943faadd42b7 timeout 1200000"
if printf '%s\n' "$accept" | scan; then ok engine-neutral-allows-pins-and-docs; else fail engine-neutral-allows-pins-and-docs "$(printf '%s\n' "$accept" | node tools/neutrality.mjs --stdin 2>&1)"; fi
if node tools/neutrality.mjs >/dev/null 2>&1; then ok engine-neutral-tree; else fail engine-neutral-tree "$(node tools/neutrality.mjs 2>&1)"; fi
# GitHub's documented webhook example hosts pass; an organization's host still fails, even next to them
github_hosts='"avatar_url": "https://avatars1.githubusercontent.com/in/29310?v=4", "html_url": "https://octocoders.io/Codertocat"'
if printf '%s\n' "$github_hosts" | scan; then ok engine-neutral-github-example-hosts; else fail engine-neutral-github-example-hosts "$(printf '%s\n' "$github_hosts" | node tools/neutrality.mjs --stdin 2>&1)"; fi
if printf '%s\n' "$github_hosts https://internal.$(echo corp).io/x https://evil-githubusercontent.$(echo com)/a" | scan; then fail engine-neutral-github-hosts-narrow "accepted an org host beside GitHub's"; else ok engine-neutral-github-hosts-narrow; fi
# --history scans what HEAD reaches: a commit on another branch is checked in that branch's own pull request
ENGINE=$PWD; H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
git init -q -b main "$H"; git -C "$H" commit -q --allow-empty -m base; git -C "$H" checkout -q -b other; echo "see https://internal.$(echo corp).io/runbook" >"$H/n.txt"; git -C "$H" add n.txt; git -C "$H" commit -q -m other; git -C "$H" checkout -q main
if (cd "$H" && node "$ENGINE/tools/neutrality.mjs" --history >/dev/null 2>&1); then ok engine-neutral-history-head-only; else fail engine-neutral-history-head-only "another branch's commit failed HEAD's history scan"; fi
git -C "$H" merge -q --no-ff other -m merge
if (cd "$H" && node "$ENGINE/tools/neutrality.mjs" --history >/dev/null 2>&1); then fail engine-neutral-history-reaches-head "a reachable org host passed"; else ok engine-neutral-history-reaches-head; fi
if node tools/neutrality.mjs --history >/dev/null 2>&1; then ok engine-neutral-history; else fail engine-neutral-history "$(node tools/neutrality.mjs --history 2>&1 | head -20)"; fi
if [ "$FAILS" -eq 0 ]; then ok engine-neutral; else fail engine-neutral "$FAILS neutrality case(s) failed"; fi
done_cases
