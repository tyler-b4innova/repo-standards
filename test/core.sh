#!/usr/bin/env bash
# Apply, offline check, forbidden content and pack hygiene cases.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH ANTHROPIC_MODEL CLAUDE_CODE_EFFORT_LEVEL
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "${OVERLAY:-$OV}" --version "${VER:-0.1.0}" --target "$@"; }
mkrepo() { local d; d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; apply "$d" ${1:+--profile "$1"} >/dev/null && commit "$d" init && echo "$d"; }
check() { (cd "$1" && scripts/agent/setup.sh --check) 2>&1; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
# expect_fail <id> <repo> <needle>: check exits 1 with a failure line naming <needle> and carrying a fix
expect_fail() {
  local out st
  out=$(check "$2"); st=$?
  if [ $st -eq 1 ] && has "$3" "$out" && has "| fix: " "$out"; then ok "$1"; else fail "$1" "exit=$st: $out"; fi
}


# ---- CLAUDE.md modes
R=$(mkrepo); echo "Always use tabs." > "$R/CLAUDE.md" && commit "$R"; a=$(check "$R"); sa=$?
echo "@AGENTS.md" > "$R/CLAUDE.md" && commit "$R"; b=$(check "$R"); sb=$?
FO=$T/forbid.json; node -e 'const o=require(process.argv[1]);o.claude_md="forbid";require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$FO"
# the shim may carry Claude-only lines below the import; the import must come first
printf '@AGENTS.md\n\n- Claude only: x\n' > "$R/CLAUDE.md" && commit "$R"; d=$(check "$R"); sd=$?
printf 'Always use tabs.\n@AGENTS.md\n' > "$R/CLAUDE.md" && commit "$R"; e=$(check "$R"); se=$?
echo "@AGENTS.md" > "$R/CLAUDE.md" && commit "$R"
OVERLAY=$FO apply "$R" >/dev/null && commit "$R"; c=$(check "$R"); sc=$?
if [ $sa -eq 1 ] && has CLAUDE.md "$a" && [ $sb -eq 0 ] && [ $sd -eq 0 ] && [ $se -eq 1 ] && has CLAUDE.md "$e" && [ $sc -eq 1 ] && has CLAUDE.md "$c"; then ok claude-md-no-own-content; else fail claude-md-no-own-content "own=$sa shim=$sb shim+lines=$sd lines-first=$se forbid=$sc: $d $e"; fi

# ---- offline check
all=1; for p in internal client; do R=$(mkrepo $p); out=$(check "$R"); [ $? -eq 0 ] && has "standards ok: example v0.1.0 $p" "$out" || { all=0; echo "$out"; }; done
if [ $all = 1 ]; then ok managed-drift-detected; else fail managed-drift-detected; fi

R=$(mkrepo); echo "// edit" >> "$R/scripts/agent/pr.sh"; out=$(check "$R"); st=$?
fix=$(printf '%s\n' "$out" | sed -n 's/^FAIL: managed file changed: scripts\/agent\/pr.sh | fix: \(git checkout [^ ]* -- scripts\/agent\/pr.sh\).*/\1/p')
(cd "$R" && eval "$fix") && out2=$(check "$R"); st2=$?
if [ $st -eq 1 ] && [ -n "$fix" ] && [ $st2 -eq 0 ]; then ok managed-drift-detected; else fail managed-drift-detected "$out"; fi

R=$(mkrepo); gc -C "$R" branch -q feature
# main moves to a newer pack whose std-babysit differs; the feature branch keeps the older lock
echo "- newer rule" >> "$R/.agents/skills/std-babysit/SKILL.md"
node -e 'const fs=require("fs"),c=require("crypto"),f=".agents/skills/std-babysit/SKILL.md",d=process.argv[1];
const h=c.createHash("sha256").update(fs.readFileSync(d+"/"+f)).digest("hex");
fs.writeFileSync(d+"/standards.lock",fs.readFileSync(d+"/standards.lock","utf8").replace(/^# (\S+) v0\.1\.0/,"# $1 v0.2.0").replace(new RegExp("^[0-9a-f]{64}  "+f.replace(/\./g,"\\.")+"$","m"),h+"  "+f))' "$R"
jset "$R/standards.json" 'o.version="0.2.0"'; commit "$R" "pack 0.2.0"; check "$R" >/dev/null || echo "setup: main not clean"
gc -C "$R" checkout -q feature
echo "drift" >> "$R/.agents/skills/std-babysit/SKILL.md"
fix=$(check "$R" | sed -n 's/.*| fix: \(git checkout [^ ]* -- \.agents\/skills\/std-babysit\/SKILL.md\).*/\1/p')
(cd "$R" && eval "$fix") 2>/dev/null; out=$(check "$R"); st=$?
if [ -n "$fix" ] && [ $st -eq 0 ] && has "v0.1.0" "$out" && ! grep -q "newer rule" "$R/.agents/skills/std-babysit/SKILL.md"; then ok managed-drift-detected; else fail managed-drift-detected "fix=$fix $out"; fi

# the lock header must name the pack, version and profile standards.json claims (a profile swap once went unnoticed)
R=$(mkrepo); jset "$R/standards.json" 'o.profile="client"'; a=$(check "$R"); sa=$?
gc -C "$R" checkout -q -- standards.json; sed -i.bak 1d "$R/standards.lock" && rm "$R/standards.lock.bak"; b=$(check "$R"); sb=$?
if [ $sa -eq 1 ] && has "standards.lock says profile internal, standards.json client" "$a" && [ $sb -eq 1 ] && has "standards.lock says pack (no header)" "$b"
then ok managed-drift-detected; else fail managed-drift-detected "$sa $a | $sb $b"; fi

# apply never writes or deletes through a symlink or outside the checkout
why=""
R=$(mkrepo); mkdir "$T/outside"; rm -rf "$R/scripts" && ln -s "$T/outside" "$R/scripts"
out=$(apply "$R" 2>&1) && why="symlinked scripts/ accepted"
has "scripts is a symlink" "$out" || why="$why; message: $out"
[ -z "$(ls -A "$T/outside")" ] || why="$why; wrote through the link: $(ls -A "$T/outside")"
R=$(mkrepo); echo keep >"$T/keep.txt"; echo "$(printf '%064d' 0)  ../keep.txt" >>"$R/standards.lock"
out=$(apply "$R" 2>&1) || why="$why; a foreign lock line made apply fail: $out"
[ -f "$T/keep.txt" ] || why="$why; deleted a file outside the repo"
R=$(mkrepo); echo mine >"$R/victim"; echo "$(printf '%064d' 0)  scripts/agent/../../victim" >>"$R/standards.lock"
out=$(apply "$R" 2>&1) || why="$why; a traversing lock line made apply fail: $out"
[ -f "$R/victim" ] || why="$why; a lock line through a managed prefix deleted a repo file"
# an older pack's lock (`sha256 <hash> <path>` lines and `key value` headers): retired paths go, nothing else does
R=$(mkrepo); mkdir -p "$R/scripts/agent" && echo old >"$R/scripts/agent/old-helper" && echo mine >"$R/example"
printf '# standards.lock\npack example\nversion 0.0.9\nsha256 %064d scripts/agent/old-helper\n' 0 >"$R/standards.lock"
apply "$R" >/dev/null || why="$why; old-format lock refused"
[ ! -e "$R/scripts/agent/old-helper" ] || why="$why; retired path from an old-format lock kept"
[ -f "$R/example" ] || why="$why; a lock header line deleted a repo file"
if [ -z "$why" ]; then ok apply-no-symlink-writes; else fail apply-no-symlink-writes "$why"; fi

# packs that were never locked left recall files; apply removes them by name and nothing else
R=$(mkrepo); mkdir -p "$R/.agents/skills/std-recall" "$R/.agents/skills/my-recall"
for f in .agents/skills/std-recall/SKILL.md scripts/agent/recall scripts/agent/recall.mjs scripts/agent/ledger-recall .agents/skills/my-recall/SKILL.md; do echo old > "$R/$f"; done
commit "$R"; out=$(apply "$R"); why=""
for f in .agents/skills/std-recall scripts/agent/recall scripts/agent/recall.mjs scripts/agent/ledger-recall; do [ ! -e "$R/$f" ] || why="$why; $f kept"; done
[ -f "$R/.agents/skills/my-recall/SKILL.md" ] || why="$why; removed a repo-owned skill"
has "-scripts/agent/ledger-recall" "$out" || why="$why; removal not reported: $out"
commit "$R" >/dev/null; c=$(check "$R") || why="$why; check after removal: $c"
if [ -z "$why" ]; then ok orphan-recall-removed; else fail orphan-recall-removed "$why"; fi

# standards.json allow_paths exempts shipped content (a plugin's .mcp.json) and nothing else; re-apply keeps it
why=""
R=$(mkrepo); mkdir -p "$R/plugins/clerk" && echo '{}' > "$R/plugins/clerk/.mcp.json" && commit "$R"
out=$(check "$R") && why="tracked plugin .mcp.json passed without allow_paths"
jset "$R/standards.json" 'o.allow_paths=["plugins/*/.mcp.json"]'; commit "$R"
out=$(check "$R") || why="$why; allowed path still failed: $out"
apply "$R" >/dev/null; [ "$(node -p 'JSON.stringify(require(process.argv[1]).allow_paths)' "$R/standards.json")" = '["plugins/*/.mcp.json"]' ] || why="$why; re-apply dropped allow_paths"
echo '{}' > "$R/.mcp.json" && commit "$R"; out=$(check "$R") && why="$why; root .mcp.json passed"
has ".mcp.json is committed" "$out" || why="$why; root message: $out"
git -C "$R" rm -q --cached .mcp.json && rm "$R/.mcp.json" && jset "$R/standards.json" 'o.allow_paths="plugins"'; commit "$R"
out=$(check "$R") && why="$why; a non-list allow_paths passed"
has "standards.json allow_paths is" "$out" || why="$why; non-list message: $out"
if [ -z "$why" ]; then ok repo-allow-paths; else fail repo-allow-paths "$why"; fi

# overlay-launcher-validated: the example's launcher settings load; typos, unknown vendors or lanes, bad schedules and
# credential-looking values are refused before anything is written
why=""
R=$(mkrepo) || why="example overlay with launcher refused"
lbad() { node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));(new Function("l",process.argv[3]))(o.launcher);require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/lov.json" "$1"
  local d; d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; OVERLAY="$T/lov.json" apply "$d" 2>&1 && echo "ACCEPTED"; [ -z "$(ls -A "$d" | grep -v '^.git$')" ] || echo "WROTE"; }
for c in 'l.lane=[]|launcher.lane is not a launcher setting' 'l.lanes[0].vendor="gpt"|vendor must be claude or codex' 'l.unassigned=["ghost"]|names ghost, which is not a lane' \
  'l.dispatch[0].every="hourly"|every must look like' 'l.lanes[1].accounts=["gh"+"p_"+"a".repeat(36)]|looks like a credential' 'l.lanes[1].accounts=[" gh"+"p_"+"b".repeat(36)]|looks like a credential' 'l.lanes.push({name:"claude",vendor:"codex"})|duplicate lane claude' \
  'l.revert={newIssueEvents:0}|revert.newIssueEvents must be a positive number' 'l.revert={eventFactor:5,window:30}|launcher.revert.window is not a launcher setting' \
  'l.lanes[0].runner="cloud"|runner must be t3, claude-cloud, codex-cloud' 'l.lanes[0].runner="codex-cloud"|runner codex-cloud needs vendor codex, not claude' 'l.lanes[0].model="m"|model is for a t3 lane' \
  'l.dispatch[0].ref=""|dispatch[0].ref must be a non-empty string' 'l.lanes[0].runner="claude-cloud";l.lanes[0].vendor="gpt"|vendor must be claude or codex' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"gpt",model:"m"};l.review={provider:"codex",model:"m"}|provider must be claudeAgent or codex on a t3 lane' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"codex"};l.review={provider:"claudeAgent",model:"m"}|model must be a non-empty string on a t3 lane' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"codex",model:"m",vendor:"codex"};l.review={provider:"claudeAgent",model:"m"}|vendor must be omitted on a t3 lane' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"codex",model:"m",effort:" "};l.review={provider:"claudeAgent",model:"m"}|effort must be a non-empty string' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"codex",model:"m"}|launcher.review is required when a lane runs on t3' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"codex",model:"m"};l.review={provider:"codex",model:"m"}|review must be a different provider from every t3 lane' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"codex",model:"m"};l.review={provider:"claudeAgent"}|review.model must be a non-empty string' \
  'l.lanes[0]={name:"t",runner:"t3",provider:"codex",model:"m"};l.review={provider:"claudeAgent",model:"m",effort:""}|review.effort must be a non-empty string' \
  'l.review={provider:"codex",model:"m",tier:"x"}|launcher.review.tier is not a launcher setting'; do
  out=$(lbad "${c%%|*}"); has "${c#*|}" "$out" && ! has ACCEPTED "$out" && ! has WROTE "$out" || why="$why; [${c%%|*}] $out"
done
# dispatch when: only "drift"
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.launcher.dispatch[0].when="drift";o.launcher.revert={newIssueEvents:5,eventFactor:2.5};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/drift.json"
d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; out=$(OVERLAY="$T/drift.json" apply "$d" 2>&1) || why="$why; when=drift or revert refused: $out"
out=$(lbad 'l.dispatch[0].when="always"'); has 'when must be "drift"' "$out" && ! has ACCEPTED "$out" || why="$why; [when=always] $out"
# t3 lanes: provider and model, any effort string, a review from another provider; cloud lanes with a matching runner; both kinds together
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.launcher.lanes=[{name:"t3-main",runner:"t3",provider:"claudeAgent",model:"model-x",effort:"any-effort-string",slots:2},{name:"cloud",runner:"codex-cloud",vendor:"codex"},{name:"implied",runner:"claude-cloud"},{name:"legacy",vendor:"claude"}];o.launcher.dispatch[0].ref="main";o.launcher.review={provider:"codex",model:"model-y"};o.launcher.unassigned=["cloud"];require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/t3.json"
d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; out=$(OVERLAY="$T/t3.json" apply "$d" 2>&1) || why="$why; a t3 lane with its review, or cloud lanes, refused: $out"
# retro: who approves its rule changes, and the drafting model (Claude only; the launcher refuses codex as drafter)
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.launcher.retro={approvers:["octocat","hubot"],engineApprovers:["octocat"],provider:"claudeAgent",model:"model-x",effort:"high",repo:"standards"};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/retro.json"
d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; out=$(OVERLAY="$T/retro.json" apply "$d" 2>&1) || why="$why; a well-formed retro refused: $out"
R0='approvers:["octocat"],engineApprovers:["octocat"],provider:"claudeAgent",model:"m"'
for c in "l.retro={$R0,cadence:\"weekly\"}|launcher.retro.cadence is not a launcher setting" "l.retro={$R0};l.retro.approvers=[]|retro.approvers must be a non-empty list of GitHub logins" \
  "l.retro={$R0};l.retro.engineApprovers=[\"not a login\"]|retro.engineApprovers must be a non-empty list of GitHub logins" "l.retro={$R0};l.retro.provider=\"codex\"|retro.provider must be claudeAgent" \
  "l.retro={$R0};l.retro.model=\" \"|retro.model must be a non-empty string" "l.retro={$R0};l.retro.effort=3|retro.effort must be a string" "l.retro={$R0};l.retro.repo=[]|retro.repo must be a string" \
  "l.retro={$R0};l.retro.model=\"sk-\"+\"a\".repeat(40)|looks like a credential" "l.retro=[]|launcher.retro must be an object"; do
  out=$(lbad "${c%%|*}"); has "${c#*|}" "$out" && ! has ACCEPTED "$out" && ! has WROTE "$out" || why="$why; [${c%%|*}] $out"
done
if [ -z "$why" ]; then ok overlay-launcher-validated; else fail overlay-launcher-validated "$why"; fi

# review-settings-removed: the conversation is not a required status any more; an overlay still naming it is refused
# with the reason, before anything is written
why=""
for k in 'o.review={status:true}' 'Object.assign(o.org_admin ??= {}, {review_status:true})' 'o.codex={verdict:"status"}'; do
  node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));(new Function("o",process.argv[3]))(o);require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/legacy.json" "$k"
  d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; out=$(OVERLAY="$T/legacy.json" apply "$d" 2>&1) && why="$why; [$k] accepted"
  has "is gone: gate checks code only" "$out" && [ -z "$(ls -A "$d" | grep -v '^.git$')" ] || why="$why; [$k] $out"
done
if [ -z "$why" ]; then ok review-settings-removed; else fail review-settings-removed "$why"; fi

# CI rules in --check: one gate per head, job timeouts, schedules at most daily, quarantine with an issue and an expiry
wf() { mkdir -p "$1/.github/workflows" && printf '%s\n' "$3" > "$1/.github/workflows/$2"; }
cr() { commit "$1" >/dev/null; check "$1"; }
why=""
R=$(mkrepo); wf "$R" validate.yml 'on:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - run: npm ci && npm test'; out=$(cr "$R") && why="$why; a PR test workflow passed"; has "validate.yml runs checks on pull_request" "$out" || why="$why; [$out]"
R=$(mkrepo); wf "$R" gates.yml 'on:
  pull_request:
    paths: ["plugins/**"]
  push:
    branches: [main]
jobs:
  gates:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Check shared files
        run: node scripts/sync-shared.mjs --check'; out=$(cr "$R") && why="$why; a check workflow on PR and push passed"
R=$(mkrepo); wf "$R" poll.yml 'on:
  schedule:
    - cron: "*/10 * * * *"
jobs:
  poll:
    runs-on: ubuntu-24.04
    timeout-minutes: 2
    steps:
      - run: curl -s https://example.test'; out=$(cr "$R") && why="$why; a 10-minute schedule passed"; has "scheduled more often than daily" "$out" || why="$why; [$out]"
DEPLOY='on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - run: npm ci && npm run build && npx wrangler deploy'
R=$(mkrepo); wf "$R" deploy.yml "$DEPLOY"; out=$(cr "$R") && why="$why; an undeclared build-on-push passed"
jset "$R/standards.json" 'o.deploy_workflow="deploy.yml"'; out=$(cr "$R") || why="$why; the declared deploy workflow failed: $out"
wf "$R" nightly.yml 'on:
  schedule:
    - cron: "17 4 * * 1"
  workflow_dispatch:
jobs:
  report:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - run: echo weekly'; out=$(cr "$R") || why="$why; a weekly schedule failed: $out"
# a push trigger limited to other branches is read where it stands, even when `on:` is not the first line
R=$(mkrepo); wf "$R" release.yml 'name: release checks
on:
  push:
    branches: ["release/**"]
jobs:
  test:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - run: npm ci && npm test'; out=$(cr "$R") || why="$why; a push-to-release test workflow was rejected: $out"
if [ -z "$why" ]; then ok no-duplicate-gate-workflows; else fail no-duplicate-gate-workflows "$why"; fi
# A named duplicate check can stay only while its reviewed bytes and rationale match. Other workflow rules still apply.
why=""
R=$(mkrepo); wf "$R" validate.yml 'on:
  pull_request:
jobs:
  validate:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - run: npm test'
out=$(cr "$R") && why="$why; an unexcepted PR check passed"
has "validate.yml runs checks on pull_request" "$out" || why="$why; no-exception message: $out"
pin_exception() { node -e 'const fs=require("fs"),c=require("crypto"),s=process.argv[1],w=process.argv[2],o=JSON.parse(fs.readFileSync(s));o.duplicate_check_exceptions=[{path:".github/workflows/validate.yml",sha256:c.createHash("sha256").update(fs.readFileSync(w)).digest("hex"),reason:"Preview artifacts consumed by protected publish"}];fs.writeFileSync(s,JSON.stringify(o,null,2)+"\n")' "$R/standards.json" "$R/.github/workflows/validate.yml"; }
pin_exception; out=$(cr "$R") || why="$why; valid pinned exception failed: $out"
apply "$R" >/dev/null; [ "$(node -p 'require(process.argv[1]).duplicate_check_exceptions?.length' "$R/standards.json")" = 1 ] || why="$why; apply dropped exception"
jset "$R/standards.json" 'o.duplicate_check_exceptions=[{path:".github/workflows/validate.yml",sha256:"bad",reason:" "}]'; out=$(cr "$R") && why="$why; malformed exception passed"
has "duplicate_check_exceptions has an invalid entry" "$out" || why="$why; malformed message: $out"
pin_exception; echo '# changed' >> "$R/.github/workflows/validate.yml"; out=$(cr "$R") && why="$why; hash mismatch passed"
has "duplicate_check_exceptions SHA256 mismatch" "$out" || why="$why; mismatch message: $out"
wf "$R" validate.yml 'on:
  pull_request:
  schedule:
    - cron: "*/10 * * * *"
jobs:
  validate:
    runs-on: ubuntu-24.04
    steps:
      - run: npx playwright install && npm test'
pin_exception; out=$(cr "$R") && why="$why; pinned exception bypassed other workflow rules"
has "scheduled more often than daily" "$out" && has "has no timeout-minutes" "$out" && has "playwright install without naming a browser" "$out" || why="$why; guardrail message: $out"
if [ -z "$why" ]; then ok duplicate-check-exception-pinned; else fail duplicate-check-exception-pinned "$why"; fi
why=""
R=$(mkrepo); wf "$R" manual.yml 'on: workflow_dispatch
jobs:
  once:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi
  shared:
    uses: ./.github/workflows/other.yml'; out=$(cr "$R") && why="$why; a job without timeout passed"
has "manual.yml job once has no timeout-minutes" "$out" && ! has "job shared" "$out" || why="$why; [$out]"
sed -i.bak 's/    runs-on: ubuntu-24.04/    runs-on: ubuntu-24.04\n    timeout-minutes: 5/' "$R/.github/workflows/manual.yml" && rm "$R/.github/workflows/manual.yml.bak"
node -e 'const f=process.argv[1],y=require("fs").readFileSync(f,"utf8");require("fs").writeFileSync(f,y.replace("    runs-on: ubuntu-24.04\n","    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n"))' "$R/.github/workflows/manual.yml"
out=$(cr "$R") || why="$why; with a timeout it still failed: $out"
if [ -z "$why" ]; then ok jobs-have-timeouts; else fail jobs-have-timeouts "$why"; fi
why=""
d() { N=$1 node -e 'console.log(new Date(Date.now()+Number(process.env.N)*864e5).toISOString().slice(0,10))'; }
R=$(mkrepo); mkdir -p "$R/tests/e2e"
q() { printf 'test("checkout %s", () => {}); // %s\n' "$1" "$2" > "$R/tests/e2e/q.test.mjs"; cr "$R"; }
out=$(q a "@quarantine(#12, until $(d 7))") || why="$why; a linked 7-day quarantine failed: $out"
out=$(q b "@quarantine(#12, until $(d -1))") && why="$why; an expired quarantine passed"; has "quarantine expired" "$out" || why="$why; [$out]"
out=$(q c "@quarantine(until $(d 3))") && why="$why; an unlinked quarantine passed"
out=$(q e "@quarantine(https://github.com/acme/app/issues/9, until $(d 30))") && why="$why; a 30-day quarantine passed"; has "more than 14 days out" "$out" || why="$why; [$out]"
if [ -z "$why" ]; then ok quarantine-expires; else fail quarantine-expires "$why"; fi

# the SessionStart hook: once, under startup|resume, next to the repo's own hooks
why=""
R=$(mkrepo)
jset "$R/.claude/settings.json" 'o.hooks.SessionStart=[{matcher:"startup",hooks:[{type:"command",command:"echo warm"},o.hooks.SessionStart[0].hooks[0]]}]'
commit "$R"; out=$(check "$R") && why="hook under startup only passed"
has "SessionStart setup.sh --check hook for startup and resume" "$out" || why="$why; check: $out"
apply "$R" >/dev/null && again=$(apply "$R")
hooks=$(node -e 'const S=require(process.argv[1]).hooks.SessionStart;console.log(S.map(m=>m.matcher+":"+m.hooks.map(h=>h.command.includes("setup.sh")?"check":h.command).join("+")).join(","))' "$R/.claude/settings.json")
[ "$hooks" = "startup:echo warm,startup|resume:check" ] || why="$why; hooks after apply: $hooks"
has "already current" "$again" || why="$why; re-apply not idempotent: $again"
commit "$R"; out=$(check "$R") || why="$why; check after apply: $out"
if [ -z "$why" ]; then ok session-hook-single; else fail session-hook-single "$why"; fi

R=$(mkrepo); node -e 'console.log("- " + "x".repeat(3000))' >> "$R/AGENTS.md"
expect_fail agents-md-max-4096 "$R" "(limit 4096)"
# nothing invites bloat: a new AGENTS.md is the title and the block only, and the over-limit fix asks for less, not more
R=$(mkrepo); want=$(printf '# %s\n\n' "$(basename "$R")"; node bin/repo-standards.mjs block --overlay "$OV" --profile internal)
node -e 'console.log("- " + "x".repeat(3000))' >> "$R/AGENTS.md"; out=$(check "$R")
if [ "$(git -C "$R" show HEAD:AGENTS.md)" = "$want" ] && has "repeated failure modes only" "$out" && ! has "footguns" "$out"; then ok agents-md-invites-nothing
else fail agents-md-invites-nothing "$(git -C "$R" show HEAD:AGENTS.md | tail -4) | $out"; fi

all=1
for f in docs/adr/0001-use-x.md decisions/2026-db.md api/decision-records/a.md notes/ADR-7.md; do
  R=$(mkrepo); mkdir -p "$R/$(dirname "$f")" && echo "We chose X." > "$R/$f" && git -C "$R" add "$f"
  out=$(check "$R"); [ $? -eq 1 ] && has "decision record tracked: $f" "$out" || { all=0; echo "$f: $out"; }
done
R=$(mkrepo); mkdir -p "$R/docs/guide" && echo "We chose X." > "$R/docs/guide/setup.md" && git -C "$R" add docs; check "$R" >/dev/null || all=0
if [ $all = 1 ]; then ok no-decision-records-in-tree; else fail no-decision-records-in-tree; fi

# instruction files at any depth: CONTEXT.md fails anywhere; a nested AGENTS.md or CLAUDE.md only with a declared reason
why=""
for f in CONTEXT.md docs/CONTEXT.md apps/web/CONTEXT.md; do
  R=$(mkrepo); mkdir -p "$R/$(dirname "$f")" && echo "Glossary." > "$R/$f" && git -C "$R" add "$f"
  out=$(check "$R"); [ $? -eq 1 ] && has "CONTEXT.md is forbidden: $f" "$out" || why="$why; $f: $out"
done
R=$(mkrepo); mkdir -p "$R/apps/web" "$R/.claude" "$R/workers/api"
echo "- web rule" > "$R/apps/web/AGENTS.md"; echo "@AGENTS.md" > "$R/apps/web/CLAUDE.md"; echo "Rules." > "$R/.claude/CLAUDE.md"; git -C "$R" add -f .claude/CLAUDE.md; commit "$R"
out=$(check "$R"); st=$?
for f in apps/web/AGENTS.md apps/web/CLAUDE.md .claude/CLAUDE.md; do has "undeclared nested instruction file: $f" "$out" || why="$why; $f not named"; done
[ $st -eq 1 ] || why="$why; undeclared passed"
git -C "$R" rm -q .claude/CLAUDE.md
jset "$R/standards.json" 'o.nested_instructions=[{path:"apps/web/AGENTS.md",reason:"the web app deploys separately"},{path:"apps/web/CLAUDE.md",reason:"imports it for Claude"}]'; commit "$R"
out=$(check "$R") || why="$why; declared failed: $out"
apply "$R" >/dev/null; [ "$(node -p 'require(process.argv[1]).nested_instructions.length' "$R/standards.json")" = 2 ] || why="$why; re-apply dropped nested_instructions"
gc -C "$R" checkout -q -- standards.json
jset "$R/standards.json" 'o.nested_instructions.push({path:"workers/api/AGENTS.md",reason:"gone"},{path:"apps/web/README.md",reason:"not one"},{path:"apps/web/AGENTS.md",reason:" "})'; commit "$R"
out=$(check "$R"); st=$?
[ $st -eq 1 ] && has "nested_instructions names workers/api/AGENTS.md, which is not tracked" "$out" && has "apps/web/README.md is not an AGENTS.md or CLAUDE.md" "$out" && has "nested_instructions has an invalid entry" "$out" || why="$why; bad declarations: $out"
if [ -z "$why" ]; then ok instruction-files-any-depth; else fail instruction-files-any-depth "$why"; fi

# a CLAUDE.md above the repository (up to $HOME) makes Claude skip AGENTS.md: a warning, never a failure
H=$T/home; R=$H/work/site; mkdir -p "$R" "$H/.claude" && git -C "$R" init -q -b main && apply "$R" >/dev/null && commit "$R" init
echo "Rules." > "$H/work/CLAUDE.md"; echo "Mine." > "$H/CLAUDE.local.md"; echo "User rules." > "$H/.claude/CLAUDE.md"; echo "Above home." > "$T/CLAUDE.md"
out=$(HOME=$H check "$R"); st=$?; why=""
[ $st -eq 0 ] || why="exit $st"
has "WARN: ~/work/CLAUDE.md" "$out" && has "WARN: ~/CLAUDE.local.md" "$out" || why="$why; ancestors not named"
[ "$(printf '%s\n' "$out" | grep -c 'skip AGENTS.md')" = 2 ] || why="$why; named the user-level file or looked above HOME"
# a root shim that imports AGENTS.md still loads it, so the ancestors are harmless then
printf '@AGENTS.md\n\n- Claude only: x\n' > "$R/CLAUDE.md" && commit "$R"; out3=$(HOME=$H check "$R") || why="$why; shim check failed: $out3"
has "skip AGENTS.md" "$out3" && why="$why; warned though the root CLAUDE.md imports AGENTS.md"
gc -C "$R" rm -q CLAUDE.md && commit "$R"
rm "$H/work/CLAUDE.md" "$H/CLAUDE.local.md"; out2=$(HOME=$H check "$R"); has "skip AGENTS.md" "$out2" && why="$why; warned with none"
rm "$T/CLAUDE.md"
if [ -z "$why" ]; then ok ancestor-claude-md-warns; else fail ancestor-claude-md-warns "$why: $out"; fi

R=$(mkrepo); mkdir -p "$R/.evidence" && echo png > "$R/.evidence/a.png" && git -C "$R" add -f .evidence
expect_fail no-evidence-on-main "$R" ".evidence/ is tracked"

R=$(mkrepo); echo '{"routes":[{"pattern":"preview.example.com","custom_domain":true}]}' > "$R/wrangler.jsonc" && git -C "$R" add wrangler.jsonc; a=$(check "$R"); sa=$?
sed -i.bak 's/preview\.example\.com/preview-site.example.com/' "$R/wrangler.jsonc" && rm "$R/wrangler.jsonc.bak"; check "$R" >/dev/null; sb=$?
sed -i.bak 's/preview-site\.example\.com/cos.preview.example.com/' "$R/wrangler.jsonc" && rm "$R/wrangler.jsonc.bak"; check "$R" >/dev/null; sb=$((sb + $?))
if [ $sa -eq 1 ] && has "wrangler.jsonc uses the shared preview host preview.example.com" "$a" && [ $sb -eq 0 ]; then ok shared-preview-host-rejected; else fail shared-preview-host-rejected "$a"; fi

R=$(mkrepo); jset "$R/standards.json" 'o.ui_paths=[]'; mkdir -p "$R/src/components" && echo "<b/>" > "$R/src/components/Nav.svelte" && commit "$R"
out=$(check "$R"); st=$?
cls=$( (cd "$R" && echo "<i/>" >> src/components/Nav.svelte && node scripts/agent/gate.mjs classify HEAD) 2>&1)
if [ $st -eq 0 ] && has "WARN: ui_paths is []" "$out" && has "src/components/Nav.svelte" "$out" && has "no UI paths changed" "$cls"; then ok ui-paths-empty-warns; else fail ui-paths-empty-warns "$out | $cls"; fi

# codeowners-from-ui-paths: with ui_owners set, the managed CODEOWNERS block gives the repo's UI paths (standards.json,
# else the engine defaults) to them and leaves ignored paths unowned; it goes after the repo's own lines, which stay;
# --check guards it; no UI paths (or no ui_owners) means no block, and a glob CODEOWNERS cannot hold stops apply
why=""
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.ui_owners=["@acme/design","@octocat"];require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/owners.json"
R=$(OVERLAY="$T/owners.json" mkrepo); co=$(cat "$R/.github/CODEOWNERS" 2>&1)
grep -qx '\*\*/\*.tsx @acme/design @octocat' <<<"$co" && grep -qx '/src/components/\*\* @acme/design @octocat' <<<"$co" && grep -qx '/tests/\*\*' <<<"$co" || why="$why; default block: $co"
out=$(check "$R") || why="$why; check on a fresh block: $out"
sed -i.bak 's#^/public/\*\* .*#/public/** @someone-else#' "$R/.github/CODEOWNERS" && rm "$R/.github/CODEOWNERS.bak" && commit "$R"
out=$(check "$R") && why="$why; an edited block passed check"; has "the managed .github/CODEOWNERS block was edited" "$out" || why="$why; [$out]"
git -C "$R" checkout -q HEAD~1 -- .github/CODEOWNERS; printf '/src/components/** @someone-else\n' >> "$R/.github/CODEOWNERS"; commit "$R"
out=$(check "$R") && why="$why; a line after the block passed check"; has "has lines after the managed block" "$out" || why="$why; [$out]"
printf '* @repo-owner\n' > "$R/.github/CODEOWNERS"; jset "$R/standards.json" 'o.ui_paths={include:["content/**"],ignore:["content/drafts/**"]}'
OVERLAY="$T/owners.json" apply "$R" >/dev/null; commit "$R"; co=$(cat "$R/.github/CODEOWNERS")
[ "$(head -1 <<<"$co")" = "* @repo-owner" ] && grep -qx '/content/\*\* @acme/design @octocat' <<<"$co" && grep -qx '/content/drafts/\*\*' <<<"$co" && [ "$(tail -1 <<<"$co")" = "# std:end" ] && ! grep -q tsx <<<"$co" || why="$why; repo override: $co"
out=$(check "$R") || why="$why; check after override: $out"
jset "$R/standards.json" 'o.ui_paths=[]'; OVERLAY="$T/owners.json" apply "$R" >/dev/null; [ "$(cat "$R/.github/CODEOWNERS")" = "* @repo-owner" ] || why="$why; no-UI left: $(cat "$R/.github/CODEOWNERS")"
R=$(OVERLAY="$T/owners.json" mkrepo); jset "$R/standards.json" 'o.ui_paths=[]'; OVERLAY="$T/owners.json" apply "$R" >/dev/null; [ ! -e "$R/.github/CODEOWNERS" ] || why="$why; block-only file kept"
R=$(mkrepo); [ ! -e "$R/.github/CODEOWNERS" ] || why="$why; a block without ui_owners"
R=$(OVERLAY="$T/owners.json" mkrepo); jset "$R/standards.json" 'o.ui_paths=["content/[ab]/**"]'; before=$(git -C "$R" status --porcelain)
out=$(OVERLAY="$T/owners.json" apply "$R" 2>&1) && why="$why; an unwritable glob applied"
has "cannot be written to CODEOWNERS" "$out" && [ "$(git -C "$R" status --porcelain)" = "$before" ] || why="$why; [$out]"
if [ -z "$why" ]; then ok codeowners-from-ui-paths; else fail codeowners-from-ui-paths "$why"; fi

# codeowners-risk-paths: the overlay's risk_owners own the risky paths (standards.json risk_paths, else the defaults)
# through the same block, after the UI lines, so a risky path under an ignored UI path (workflows) is still owned;
# risk_paths [] drops them; risk owners alone still write a block
why=""
node -e 'const f=process.argv[1],o=JSON.parse(require("fs").readFileSync(f,"utf8"));o.ui_owners=["@acme/design"];o.risk_owners=["@acme/leads"];require("fs").writeFileSync(process.argv[2],JSON.stringify(o));delete o.ui_owners;require("fs").writeFileSync(process.argv[3],JSON.stringify(o))' "$OV" "$T/risk.json" "$T/riskonly.json"
R=$(OVERLAY="$T/risk.json" mkrepo); co=$(cat "$R/.github/CODEOWNERS")
ig=$(grep -nx '/.github/\*\*' <<<"$co" | cut -d: -f1); wfl=$(grep -nx '/.github/workflows/\*\* @acme/leads' <<<"$co" | cut -d: -f1)
{ [ -n "$ig" ] && [ -n "$wfl" ] && [ "$wfl" -gt "$ig" ] && grep -qx '\*\*/migrations/\*\* @acme/leads' <<<"$co" && grep -qx '\*\*/wrangler.jsonc @acme/leads' <<<"$co" && grep -qx '/CODEOWNERS @acme/leads' <<<"$co" && grep -qx '/AGENTS.md @acme/leads' <<<"$co" && grep -qx '/scripts/agent/\*\* @acme/leads' <<<"$co" && grep -qx '/.agents/skills/std-\*/\*\* @acme/leads' <<<"$co" && grep -qx '/standards.json @acme/leads' <<<"$co" && grep -qx '\*\*/\*.tsx @acme/design' <<<"$co"; } || why="$why; both: $co"
out=$(check "$R") || why="$why; check: $out"
jset "$R/standards.json" 'o.risk_paths=["db/**"]'; OVERLAY="$T/risk.json" apply "$R" >/dev/null; co=$(cat "$R/.github/CODEOWNERS")
{ grep -qx '/db/\*\* @acme/leads' <<<"$co" && ! grep -q migrations <<<"$co"; } || why="$why; override: $co"
jset "$R/standards.json" 'o.risk_paths=[]'; OVERLAY="$T/risk.json" apply "$R" >/dev/null; ! grep -q '@acme/leads' "$R/.github/CODEOWNERS" || why="$why; [] kept risk lines"
R=$(OVERLAY="$T/riskonly.json" mkrepo); co=$(cat "$R/.github/CODEOWNERS" 2>&1)
{ grep -qx '/.github/workflows/\*\* @acme/leads' <<<"$co" && ! grep -q 'tsx' <<<"$co"; } || why="$why; risk only: $co"
jset "$R/standards.json" 'o.risk_paths="db/**"'; commit "$R"; out=$(check "$R") && why="$why; a string risk_paths passed"; has "risk_paths must be a glob list" "$out" || why="$why; [$out]"
if [ -z "$why" ]; then ok codeowners-risk-paths; else fail codeowners-risk-paths "$why"; fi

# production-urls-validated: standards.json production_urls (the launcher's post-deploy smoke test) must be absolute https URLs
R=$(mkrepo); jset "$R/standards.json" 'o.production_urls=["https://example.com/"]'; commit "$R"; a=$(check "$R"); sa=$?
jset "$R/standards.json" 'o.production_urls=["http://example.com/","/relative"]'; commit "$R"; b=$(check "$R"); sb=$?
if [ $sa -eq 0 ] && [ $sb -eq 1 ] && has "standards.json production_urls is" "$b"; then ok production-urls-validated; else fail production-urls-validated "$sa $a | $sb $b"; fi

# setup-returns-check-status: cloud setup (`setup.sh`, no arguments) keeps failed installs non-fatal but returns the
# check's status, so a broken pack is not reported as a ready environment (offline here: curl fails, installs skip)
R=$(mkrepo); mkdir -p "$T/offline"; printf '#!/bin/sh\nexit 7\n' > "$T/offline/curl"; chmod +x "$T/offline/curl"
a=$(cd "$R" && PATH="$T/offline:$PATH" CI=1 scripts/agent/setup.sh 2>&1); sa=$?
echo "// edit" >> "$R/scripts/agent/pr.sh"; commit "$R"
b=$(cd "$R" && PATH="$T/offline:$PATH" CI=1 scripts/agent/setup.sh 2>&1); sb=$?
if [ $sa -eq 0 ] && has "offline: skipping installs" "$a" && [ $sb -eq 1 ] && has "managed file changed: scripts/agent/pr.sh" "$b"; then ok setup-returns-check-status; else fail setup-returns-check-status "$sa $a | $sb $b"; fi

# agents-review-guidelines: the managed block tells the reviewer to leave pack-managed paths to the engine repo
blk=$(node bin/repo-standards.mjs block --overlay "$OV" --profile internal)
if grep -qx "## Review guidelines" <<<"$blk" && grep -q 'Skip pack-managed paths (`scripts/agent/`, `.claude/`, `.codex/`, `std-\*`)' <<<"$blk" && [ "$(tail -1 <<<"$blk")" = "<!-- std:end -->" ]
then ok agents-review-guidelines; else fail agents-review-guidelines "$blk"; fi

# ---- agent config: the pack pins no model; never read secrets, never force-push
# models-unpinned: repositories never pin a model or effort. A fresh repo gets none; re-applying removes every pin
# (any value, both files, profiles and a table left empty) and keeps other keys; --check fails on any pin left.
R=$(mkrepo); fresh=$(node -e 'const s=require(process.argv[1]);console.log(s.model??"-",s.env?.CLAUDE_CODE_SUBAGENT_MODEL??"-")' "$R/.claude/settings.json"); c=$(cat "$R/.codex/config.toml")
jset "$R/.claude/settings.json" 'o.model="sonnet";o.effortLevel="high";o.env={ANTHROPIC_MODEL:"x",CLAUDE_CODE_SUBAGENT_MODEL:"opus",CLAUDE_CODE_EFFORT_LEVEL:"max",KEEP_ME:"1"}'
printf 'model = "gpt-repo"\nmodel_reasoning_effort = "high"\n%s\n\n[agents]\ndefault_subagent_model = "gpt-6-sol"\nmax_threads = 2\n\n[profiles.fast]\nmodel = "gpt-mini"\n\n[profiles."deep"]\nmodel_reasoning_effort = "xhigh"\napproval_policy = "never"\n\n[profiles."a.b"]\nmodel = "q"\n\n[notes]\ntext = """\nmodel = "prose, not a key"\n"""\n' "$c" > "$R/.codex/config.toml"
commit "$R"; pinned=$(check "$R"); sp=$?
apply "$R" >/dev/null; commit "$R"; uc=$(cat "$R/.codex/config.toml")
up=$(node -e 'const s=require(process.argv[1]);console.log(JSON.stringify([s.model,s.effortLevel,s.env]))' "$R/.claude/settings.json")
w=$(ANTHROPIC_MODEL=haiku check "$R"); sw=$?
if [ "$fresh" = "- -" ] && ! grep -qE 'model|\[agents\]' <<<"$c" && [ $sp -eq 1 ] \
  && has ".claude/settings.json model, .claude/settings.json effortLevel, .claude/settings.json env.ANTHROPIC_MODEL, .claude/settings.json env.CLAUDE_CODE_SUBAGENT_MODEL, .claude/settings.json env.CLAUDE_CODE_EFFORT_LEVEL, .codex/config.toml model, .codex/config.toml model_reasoning_effort, .codex/config.toml agents.default_subagent_model, .codex/config.toml profiles.fast.model, .codex/config.toml profiles.deep.model_reasoning_effort, .codex/config.toml profiles.a.b.model)" "$pinned" \
  && [ "$up" = '[null,null,{"KEEP_ME":"1"}]' ] && [ "$(grep -cE 'model|profiles\.fast' <<<"$uc")" = 1 ] && grep -qx 'max_threads = 2' <<<"$uc" && grep -qx '\[profiles."deep"\]' <<<"$uc" && ! grep -q 'profiles."a.b"' <<<"$uc" && grep -qx 'model = "prose, not a key"' <<<"$uc" \
  && [ $sw -eq 0 ] && ! grep -qi model <<<"$w"
then ok models-unpinned; else fail models-unpinned "fresh=$fresh | pinned=$sp $pinned | upgraded=$up | $uc | check=$sw $w"; fi
# a pin inside an inline table: apply leaves the line (it holds other keys) and --check still fails naming it
R=$(mkrepo); printf '%s\n[profiles]\nquick = { model = "z", approval_policy = "never" }\n' "$(cat "$R/.codex/config.toml")" > "$R/.codex/config.toml"
apply "$R" >/dev/null; commit "$R"; out=$(check "$R"); st=$?
if [ $st -eq 1 ] && has ".codex/config.toml profiles.quick (inline table)" "$out" && grep -q 'quick = { model = "z"' "$R/.codex/config.toml"; then ok models-unpinned; else fail models-unpinned "inline: $st $out"; fi

R=$(mktemp -d "$T/r.XXXXXX"); git -C "$R" init -q -b main; mkdir -p "$R/.claude" "$R/.codex"
echo '{"permissions":{"deny":["Read(./secrets.txt)"]}}' > "$R/.claude/settings.json"; printf '[agents]\nmax_threads = 2\n' > "$R/.codex/config.toml"
apply "$R" >/dev/null
deny=$(node -e 'const d=require(process.argv[1]).permissions.deny;console.log(d.includes("Bash(op *)")&&d.includes("Bash(git push --force *)")&&d.includes("Read(**/.env)")&&!d.includes("Read(./secrets.txt)"))' "$R/.claude/settings.json")
top=$(node -e 'const t=require("fs").readFileSync(process.argv[1],"utf8").split(/^(?=\[)/m)[0];console.log(/approval_policy = "never"/.test(t)&&/sandbox_mode = "danger-full-access"/.test(t))' "$R/.codex/config.toml")
rules=skipped
if codex --version >/dev/null 2>&1; then
  pol() { codex execpolicy check --rules "$R/.codex/rules/std.rules" -- "$@" 2>/dev/null | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).decision||"allow")'; }
  rules="$(pol op read x) $(pol git push --force origin x) $(pol git push -f origin x) $(pol git push --force-with-lease origin x) $(pol git push origin x)"
fi
# a repo that ignores .codex/ (any form) still commits the engine's Codex files
R2=$(mktemp -d "$T/r.XXXXXX"); git -C "$R2" init -q -b main; echo '**/.codex/' > "$R2/.gitignore"; apply "$R2" >/dev/null && commit "$R2" init
tracked=$(git -C "$R2" ls-files .codex | tr '\n' ' ')
if [ "$deny" = true ] && [ "$top" = true ] && [ -f "$R/.codex/rules/std.rules" ] && { [ "$rules" = skipped ] || [ "$rules" = "forbidden forbidden forbidden allow allow" ]; } && [ "$tracked" = ".codex/config.toml .codex/rules/std.rules " ]
then ok agent-deny-secrets-and-force-push; else fail agent-deny-secrets-and-force-push "deny=$deny top=$top rules=$rules tracked=$tracked"; fi
# a commented-out bypass key does not count
R=$(mkrepo); sed -i.bak 's/^approval_policy = .*/# approval_policy = "never"\
approval_policy = "on-request"/' "$R/.codex/config.toml" && rm "$R/.codex/config.toml.bak"
expect_fail agent-deny-secrets-and-force-push "$R" ".codex/config.toml engine keys changed"
[ "$rules" != skipped ] || echo "  (codex CLI absent: std.rules decisions not evaluated)"

# std-issue: one launcher-ready issue per idea, in the sections the launcher requires
R=$(mkrepo); f=$R/.claude/skills/std-issue/SKILL.md; why=""
[ -f "$f" ] && grep -q "  .agents/skills/std-issue/SKILL.md$" "$R/standards.lock" || why="not shipped and locked"
grep -qx "name: std-issue" "$f" 2>/dev/null && grep -q '`## Goal`' "$f" && grep -q '`## Acceptance criteria`' "$f" && grep -q "never a model, subagent, lane, effort" "$f" || why="$why; content"
if [ -z "$why" ]; then ok std-issue-shipped; else fail std-issue-shipped "$why"; fi

# one-branch releases: the staged flow (a staging branch promoted to main) is gone; `direct` or no flow passes
why=""
R=$(mkrepo); check "$R" >/dev/null || why="no flow failed"
jset "$R/standards.json" 'o.flow="direct"'; commit "$R"; check "$R" >/dev/null || why="$why; direct failed"
jset "$R/standards.json" 'o.flow="staged"'; commit "$R"; out=$(check "$R"); st=$?
[ $st -eq 1 ] && has 'standards.json flow "staged" is retired' "$out" && has "merge staging into main" "$out" || why="$why; staged: $out"
if [ -z "$why" ]; then ok flow-staged-retired; else fail flow-staged-retired "$why"; fi

# ---- pack hygiene
out=$(python3 -c 'import sys,yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' template/.github/workflows/*.yml 2>&1)
if [ $? -eq 0 ]; then ok workflows-parse; else fail workflows-parse "$out"; fi

BIG=$T/big.json; node -e 'const o=require(process.argv[1]);o.profiles.client.block_lines=["- "+"x".repeat(400)];require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$BIG"
out=$(node bin/repo-standards.mjs block --overlay "$BIG" --profile client 2>&1); st=$?
sizes=$(for p in internal client; do node bin/repo-standards.mjs block --overlay "$OV" --profile $p | wc -c; done | sort -n | tail -1 | tr -d ' ')
if [ $st -ne 0 ] && has "rendered client block is" "$out" && [ "$sizes" -le 1800 ]; then ok agents-block-max-1800; else fail agents-block-max-1800 "st=$st max=$sizes $out"; fi

# ---- gate job timeout: 30 minutes unless the overlay's gate.timeout_minutes (an integer from 5 to 120) says otherwise
why=""
d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; apply "$d" >/dev/null; has "    timeout-minutes: 30" "$(cat "$d/.github/workflows/std-gate.yml")" || why="$why; default is not 30"
GT=$T/gate-timeout.json; node -e 'const o=require(process.argv[1]);o.gate={...o.gate,timeout_minutes:45};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$GT"
d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; OVERLAY=$GT apply "$d" >/dev/null; has "    timeout-minutes: 45" "$(cat "$d/.github/workflows/std-gate.yml")" || why="$why; overlay value not rendered"
commit "$d" init; out=$(check "$d") || why="$why; check failed on a custom timeout: $out"
for v in 4 121 30.5 '"30"'; do
  node -e 'const o=require(process.argv[1]);o.gate={timeout_minutes:JSON.parse(process.argv[3])};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/bad-gt.json" "$v"
  d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; out=$(OVERLAY=$T/bad-gt.json apply "$d" 2>&1) && why="$why; $v accepted"; has "gate.timeout_minutes must be an integer from 5 to 120" "$out" || why="$why; $v: $out"
done
if [ -z "$why" ]; then ok gate-timeout-overlay; else fail gate-timeout-overlay "$why"; fi

done_cases
