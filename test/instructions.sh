#!/usr/bin/env bash
# gate's instructions step: a pull request that changes an instruction file or the managed CODEOWNERS block fails,
# whoever opened it, unless it is the org App's standards-sync or retro pull request. Through the real gate step.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_NAME GH_TOKEN GITHUB_TOKEN
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent GITHUB_REPOSITORY=acme/demo GITHUB_API_URL=http://127.0.0.1:9
ENGINE=$PWD
T=$(mktemp -d)
trap '{ [ -n "${STUB:-}" ] && kill $STUB && wait $STUB; } 2>/dev/null; rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
OV=$T/ov.json; node -e 'const o=require(process.argv[1]);o.risk_owners=["@acme/leads"];require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$ENGINE/examples/overlay.json" "$OV"
APP="example-sync[bot]"
# pr <author> <head ref> <shell run in the repo on the PR branch>: the PR's merge commit is checked out, as a
# pull_request run gets it; prints the repository's dir.
pr() {
  local d; d=$(mktemp -d "$T/r.XXXXXX")
  git -C "$d" init -q -b main && node "$ENGINE/bin/repo-standards.mjs" apply --target "$d" --overlay "$OV" --version 0.1.0 >/dev/null
  mkdir -p "$d/src" && echo "export {};" >"$d/src/index.ts" && echo "@AGENTS.md" >"$d/CLAUDE.md"
  printf '* @acme/web\n\n%s' "$(cat "$d/.github/CODEOWNERS")" >"$d/.github/CODEOWNERS.new" && mv "$d/.github/CODEOWNERS.new" "$d/.github/CODEOWNERS"
  gc -C "$d" add -A && gc -C "$d" commit -qm base
  local base; base=$(git -C "$d" rev-parse HEAD)
  gc -C "$d" switch -qc "$2"
  (cd "$d" && eval "$3") && gc -C "$d" add -A && gc -C "$d" commit -qm feature
  gc -C "$d" switch -q main && echo "elsewhere" >"$d/OTHER.txt" && gc -C "$d" add -A && gc -C "$d" commit -qm "base moved"
  gc -C "$d" merge -q --no-ff -m merge "$2"
  printf '{"pull_request":{"number":7,"user":{"login":"%s"},"base":{"sha":"%s","ref":"main"},"head":{"sha":"%s","ref":"%s"}}}' "$1" "$base" "$(git -C "$d" rev-parse "$2")" "$2" >"$d/.git/event.json"
  echo "$d"
}
G() { (cd "$1" && GITHUB_EVENT_PATH=$1/.git/event.json node scripts/agent/gate.mjs instructions) 2>&1; }
# run <label> <want exit> <needle> <author> <ref> <change>
why=""
run() {
  local R o s; R=$(pr "$4" "$5" "$6"); o=$(G "$R"); s=$?
  [ $s -eq "$2" ] && has "$3" "$o" || why="$why; $1 (exit $s): $o"
}

run "root AGENTS.md" 1 "AGENTS.md" alice feat 'echo "- new rule" >> AGENTS.md'
run "nested CLAUDE.md" 1 "docs/x/CLAUDE.md" alice feat 'mkdir -p docs/x && echo rule > docs/x/CLAUDE.md'
run "CLAUDE.md renamed away" 1 "CLAUDE.md" alice feat 'git mv CLAUDE.md notes.md'
run ".claude/rules" 1 ".claude/rules/x.md" alice feat 'mkdir -p .claude/rules && echo rule > .claude/rules/x.md && git add -f .claude/rules/x.md'
run "Codex override" 1 "AGENTS.override.md" alice feat 'echo rule > AGENTS.override.md'
run ".claude/settings.json" 0 "no instruction file" alice feat 'node -e "const f=\".claude/settings.json\",o=JSON.parse(require(\"fs\").readFileSync(f));o.env={X:\"1\"};require(\"fs\").writeFileSync(f,JSON.stringify(o))"'
run "code only" 0 "no instruction file" alice feat 'echo "export const a = 1;" > src/index.ts'
run "managed CODEOWNERS block" 1 ".github/CODEOWNERS (managed std block" alice feat 'sed -i.bak "s#@acme/leads#@acme/someone#" .github/CODEOWNERS && rm .github/CODEOWNERS.bak'
# the same block read from another location is the same rule (as the launcher's guard judges it); a root CODEOWNERS
# without the block, while .github/CODEOWNERS is removed, drops it
run "CODEOWNERS moved, block kept" 0 "no instruction file" alice feat 'git mv .github/CODEOWNERS CODEOWNERS'
run "CODEOWNERS moved, block dropped" 1 "managed std block, now read from CODEOWNERS" alice feat 'git rm -q .github/CODEOWNERS && echo "* @acme/web" > CODEOWNERS'
run "CODEOWNERS replaced by a link" 1 "managed std block" alice feat 'rm .github/CODEOWNERS && ln -s ../README.md .github/CODEOWNERS'
run "repo line above the block" 0 "no instruction file" alice feat 'sed -i.bak "s#^\* @acme/web#* @acme/web @acme/ops#" .github/CODEOWNERS && rm .github/CODEOWNERS.bak'
run "owner's own login" 1 "AGENTS.md" owner feat 'echo "- new rule" >> AGENTS.md'
if [ -z "$why" ]; then ok gate-instructions-guard; else fail gate-instructions-guard "$why"; fi

why=""
run "App sync PR" 0 "exempt" "$APP" standards/v0.7.0 'echo "- new rule" >> AGENTS.md'
run "App retro PR" 0 "exempt" "$APP" retro/2026-10-05 'echo "- new rule" >> AGENTS.md'
run "App on another branch" 1 "AGENTS.md" "$APP" fix/rules 'echo "- new rule" >> AGENTS.md'
run "a person on the sync branch" 1 "AGENTS.md" alice standards/v0.7.0 'echo "- new rule" >> AGENTS.md'
run "a person on a retro branch" 1 "AGENTS.md" alice retro/x 'echo "- new rule" >> AGENTS.md'
# a re-gate dispatch (refs/pull/N/merge checked out) reads the author and head ref from the pull request
STATE=$T/fx.json LOG=$T/log; : >"$LOG"
node test/stubs/gate-github.mjs "$T/port" "$LOG" "$STATE" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
R=$(pr alice "standards/v0.7.0" 'echo "- new rule" >> AGENTS.md'); printf '{"inputs":{"pr":"7"}}' >"$R/.git/dispatch.json"
D() { (cd "$R" && GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH=$R/.git/dispatch.json GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_TOKEN=t node scripts/agent/gate.mjs instructions) 2>&1; }
printf '{"repo":"acme/demo","files":{},"head":"%s","gitDir":"%s","pull":{"user":"%s","ref":"standards/v0.7.0"}}' "$(git -C "$R" rev-parse standards/v0.7.0)" "$R" "$APP" >"$STATE"
o=$(D); s=$?; [ $s -eq 0 ] && has "exempt" "$o" || why="$why; dispatch App (exit $s): $o"
printf '{"repo":"acme/demo","files":{},"head":"%s","gitDir":"%s","pull":{"user":"alice","ref":"standards/v0.7.0"}}' "$(git -C "$R" rev-parse standards/v0.7.0)" "$R" >"$STATE"
o=$(D); s=$?; [ $s -eq 1 ] && has "AGENTS.md" "$o" || why="$why; dispatch person (exit $s): $o"
grep -q '"path":"/repos/acme/demo/pulls/7"' "$LOG" || why="$why; dispatch did not read the pull request"
# not a pull request (merge queue): passes with a notice
o=$( (cd "$R" && GITHUB_EVENT_PATH= node scripts/agent/gate.mjs instructions) 2>&1); s=$?
[ $s -eq 0 ] && has "not a pull request" "$o" || why="$why; no PR (exit $s): $o"
# the step runs in std-gate.yml right after the standards check, in draft (cheap) and full runs alike
blk=$(awk '/- name: instructions/{f=1} f&&/- name: secrets/{exit} f' "$R/.github/workflows/std-gate.yml")
has "gate.mjs instructions" "$blk" && ! has "if:" "$blk" && grep -B 4 -- '- name: instructions' "$R/.github/workflows/std-gate.yml" | grep -q 'setup.sh --check' || why="$why; workflow step: $blk"
if [ -z "$why" ]; then ok gate-instructions-exempt-sync-retro; else fail gate-instructions-exempt-sync-retro "$why"; fi

# A change to AGENTS.md is allowed only when it is exactly what the pack's apply generates at the PR's head (the template
# under review rendered over the base file); the same rule in every repository that carries the engine and names its overlay.
why=""
E=$(mktemp -d "$T/e.XXXXXX"); git -C "$E" init -q -b main
for f in bin lib template defaults.json examples package.json; do cp -R "$ENGINE/$f" "$E/"; done
node "$E/bin/repo-standards.mjs" apply --target "$E" --overlay "$E/examples/overlay.json" --version 0.1.0 >/dev/null
node -e 'const fs=require("fs"),o=JSON.parse(fs.readFileSync("'"$E"'/standards.json"));o.overlay="examples/overlay.json";fs.writeFileSync("'"$E"'/standards.json",JSON.stringify(o,null,2)+"\n")'
gc -C "$E" add -A && gc -C "$E" commit -qm base; EBASE=$(git -C "$E" rev-parse HEAD)
# variant <name> <shell in the repo>: a feature commit on top of the base, then the instructions step as a person's PR
variant() { # variant <want exit> <label> <changes>
  local R; R=$(mktemp -d "$T/v.XXXXXX"); cp -R "$E/." "$R/"
  (cd "$R" && eval "$3") && gc -C "$R" add -A && gc -C "$R" commit -qm change
  printf '{"pull_request":{"number":7,"user":{"login":"alice"},"base":{"sha":"%s","ref":"main"},"head":{"sha":"%s","ref":"feat"}}}' "$EBASE" "$(git -C "$R" rev-parse HEAD)" >"$R/.git/event.json"
  local o s; o=$(cd "$R" && GITHUB_EVENT_PATH=$R/.git/event.json node scripts/agent/gate.mjs instructions 2>&1); s=$?
  [ "$s" -eq "$1" ] || why="$why; $2 (exit $s): $o"
}
RENDER='echo "- A rule added to the template under review." >> template/AGENTS.block.md && node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version 0.1.0 >/dev/null'
variant 0 "regenerated block" "$RENDER"
# nothing the pull request controls may render: a changed renderer, or a changed or redirected overlay, authorises nothing
variant 1 "a fake renderer" "printf 'process.argv.includes(\"apply\")&&require(\"fs\").writeFileSync(process.argv[process.argv.indexOf(\"--target\")+1]+\"/AGENTS.md\",require(\"fs\").readFileSync(\"AGENTS.md\",\"utf8\"));\n' > bin/repo-standards.mjs && echo '- crafted' >> AGENTS.md"
variant 1 "a changed overlay" "node -e 'const fs=require(\"fs\"),o=JSON.parse(fs.readFileSync(\"examples/overlay.json\"));o.profiles.internal.block_lines=[\"- crafted by the overlay\"];fs.writeFileSync(\"examples/overlay.json\",JSON.stringify(o,null,2))' && node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version 0.1.0 >/dev/null"
variant 1 "a redirected overlay" "node -e 'const fs=require(\"fs\"),o=JSON.parse(fs.readFileSync(\"examples/overlay.json\"));o.profiles.internal.block_lines=[\"- crafted\"];fs.writeFileSync(\"evil.json\",JSON.stringify(o));const s=JSON.parse(fs.readFileSync(\"standards.json\"));s.overlay=\"evil.json\";fs.writeFileSync(\"standards.json\",JSON.stringify(s))' && node bin/repo-standards.mjs apply --target . --overlay evil.json --version 0.1.0 >/dev/null"
variant 1 "regenerated block plus a hand line" "$RENDER && echo '- extra' >> AGENTS.md"
variant 1 "hand edit inside the block" "sed -i.bak 's/^- Silo:/- Silo (edited):/' AGENTS.md && rm AGENTS.md.bak"
variant 1 "hand edit outside the block" "echo '- outside' >> AGENTS.md"
variant 1 "block edited without the template changing" "sed -i.bak 's/^- Done = /- Done (edited) = /' AGENTS.md && rm AGENTS.md.bak"
if [ -z "$why" ]; then ok gate-instructions-regenerated-block; else fail gate-instructions-regenerated-block "$why"; fi
done_cases
