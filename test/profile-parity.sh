#!/usr/bin/env bash
# Real apply entry points: org identity/resource data must not fork review or CI behavior.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for name in fixture-a fixture-b; do
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
  for name in fixture-a fixture-b; do
    dir="$T/$name-$profile"
    git init -q -b main "$dir"
    node bin/repo-standards.mjs apply --target "$dir" --overlay "$T/$name.json" --profile "$profile" --version 1.0.0 >/dev/null || why="$why apply $name $profile"
    git -C "$dir" add -A && git -C "$dir" commit -qm apply
    (cd "$dir" && CI=true scripts/agent/setup.sh --check) >/dev/null 2>&1 || why="$why check $name $profile"
    sed -E "s/$name/identity/g" "$dir/AGENTS.md" > "$T/$name-$profile.block"
  done
  cmp "$T/fixture-a-$profile.block" "$T/fixture-b-$profile.block" || why="$why profile instructions differ"
  for path in scripts/agent/review.mjs scripts/agent/review-record.mjs .github/workflows/std-gate.yml .agents/skills/std-babysit/SKILL.md .agents/skills/std-file-pr/SKILL.md; do
    cmp "$T/fixture-a-$profile/$path" "$T/fixture-b-$profile/$path" || why="$why $path differs"
  done
done
if [ -z "$why" ]; then ok profile-workflow-parity; else fail profile-workflow-parity "$why"; fi
why=""
for profile in internal client; do
  for value in string number object null array; do
    node - "$T/fixture-a.json" "$T/invalid.json" "$profile" "$value" <<'JS'
const fs=require("fs"), [source,target,profile,value]=process.argv.slice(2), o=JSON.parse(fs.readFileSync(source));
o.profiles[profile].block_lines={string:"- policy",number:3,object:{line:"- policy"},null:null,array:["- policy",3]}[value];
fs.writeFileSync(target,JSON.stringify(o));
JS
    dir="$T/fixture-a-$profile"
    out=$(node bin/repo-standards.mjs apply --target "$dir" --overlay "$T/invalid.json" --profile "$profile" --version 1.0.0 2>&1); status=$?
    [ "$status" -ne 0 ] && [[ "$out" == *"profiles.$profile.block_lines must be an array of strings"* ]] || why="$why accepted $profile $value"
    [ -z "$(git -C "$dir" status --porcelain)" ] || why="$why changed target $profile $value"
  done
done
if [ -z "$why" ]; then ok profile-block-lines-type; else fail profile-block-lines-type "$why"; fi
done_cases
