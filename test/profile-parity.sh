#!/usr/bin/env bash
# Real apply entry points: org identity/resource data must not fork review or CI behavior.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for name in first second; do
  node - "$T/$name.json" "$name" <<'JS'
const fs = require("fs"), [file, name] = process.argv.slice(2);
const o = JSON.parse(fs.readFileSync("examples/overlay.json"));
o.pack = name; o.title = `${name} standards`; o.org = `${name}-org`; o.standards_repo = `${o.org}/standards`;
o.profiles.internal.block_lines = []; o.profiles.client.block_lines = [];
o.shared_preview_hosts = [`${name}.example.com`];
fs.writeFileSync(file, JSON.stringify(o));
JS
done
why=""
for profile in internal client; do
  for name in first second; do
    dir="$T/$name-$profile"
    git init -q -b main "$dir"
    node bin/repo-standards.mjs apply --target "$dir" --overlay "$T/$name.json" --profile "$profile" --version 1.0.0 >/dev/null || why="$why apply $name $profile"
    git -C "$dir" add -A && git -C "$dir" commit -qm apply
    (cd "$dir" && CI=true scripts/agent/setup.sh --check) >/dev/null 2>&1 || why="$why check $name $profile"
    sed -E "s/$name/identity/g" "$dir/AGENTS.md" > "$T/$name-$profile.block"
  done
  cmp "$T/first-$profile.block" "$T/second-$profile.block" || why="$why profile instructions differ"
  for path in scripts/agent/review.mjs scripts/agent/review-record.mjs .github/workflows/std-gate.yml .agents/skills/std-babysit/SKILL.md .agents/skills/std-file-pr/SKILL.md; do
    cmp "$T/first-$profile/$path" "$T/second-$profile/$path" || why="$why $path differs"
  done
done
if [ -z "$why" ]; then ok profile-workflow-parity; else fail profile-workflow-parity "$why"; fi
done_cases
