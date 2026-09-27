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

# ---- apply
R=$(mkrepo)
out=$(apply "$R"); st=$?
if [ $st -eq 0 ] && has "already current" "$out" && [ -z "$(git -C "$R" status --porcelain)" ]; then ok apply-idempotent; else fail apply-idempotent "$out $(git -C "$R" status --porcelain)"; fi

R=$(mkrepo)
printf '\n## Repo rules\n\n- Use pnpm, never npm.\n' >> "$R/AGENTS.md" && commit "$R"
outside() { sed '/^<!-- std:begin /,/^<!-- std:end -->$/d' "$1/AGENTS.md"; }
before=$(outside "$R"); VER=0.2.0 apply "$R" --profile client >/dev/null; jset "$R/standards.json" 'o.profile="client"'; VER=0.2.0 apply "$R" >/dev/null
if [ "$before" = "$(outside "$R")" ] && grep -q 'client language' "$R/AGENTS.md"; then ok repo-text-preserved; else fail repo-text-preserved "$(diff <(echo "$before") <(outside "$R"))"; fi

R=$(mkrepo)
mkdir -p "$R/scripts/agent" && echo old > "$R/scripts/agent/retired.sh" && echo "0000  scripts/agent/retired.sh" >> "$R/standards.lock" && commit "$R"
apply "$R" >/dev/null
if [ ! -e "$R/scripts/agent/retired.sh" ] && ! grep -q retired "$R/standards.lock"; then ok dropped-path-removed; else fail dropped-path-removed; fi

R=$(mktemp -d "$T/r.XXXXXX"); git -C "$R" init -q -b main
mkdir -p "$R/.claude/skills/deploy-notes" && echo "---" > "$R/.claude/skills/deploy-notes/SKILL.md"
apply "$R" >/dev/null
R2=$(mktemp -d "$T/r.XXXXXX"); git -C "$R2" init -q -b main
mkdir -p "$R2/.claude/skills/std-babysit" "$R2/.agents/skills/std-babysit" && echo mine > "$R2/.claude/skills/std-babysit/SKILL.md" && echo theirs > "$R2/.agents/skills/std-babysit/SKILL.md"
out=$(apply "$R2" 2>&1); st=$?
if [ -f "$R/.claude/skills/deploy-notes/SKILL.md" ] && [ -L "$R/.claude/skills" ] && [ $st -ne 0 ] && has "std-babysit" "$out" \
  && [ "$(cat "$R2/.claude/skills/std-babysit/SKILL.md")" = mine ] && [ ! -e "$R2/AGENTS.md" ]; then ok apply-keeps-repo-skills; else fail apply-keeps-repo-skills "st=$st $out"; fi

R=$(mktemp -d "$T/r.XXXXXX"); git -C "$R" init -q -b main; mkdir -p "$R/.claude"
echo '{"theme":"dark","permissions":{"allow":["Bash(make test)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}' > "$R/.claude/settings.json"
apply "$R" >/dev/null; first=$(cat "$R/.claude/settings.json"); apply "$R" >/dev/null
out=$(node -e 'const s=require(process.argv[1]),n=(a,x)=>a.filter(y=>JSON.stringify(y).includes(x)).length;
console.log([s.theme,s.permissions.allow.includes("Bash(make test)"),n(s.hooks.SessionStart,"echo hi"),n(s.hooks.SessionStart,"setup.sh --check"),s.permissions.allow.length===new Set(s.permissions.allow).size].join(" "))' "$R/.claude/settings.json")
if [ "$out" = "dark true 1 1 true" ] && [ "$first" = "$(cat "$R/.claude/settings.json")" ]; then ok apply-merges-settings; else fail apply-merges-settings "$out"; fi

R=$(mkrepo)
jset "$R/standards.json" 'o.dispatch="auto";o.sensitive=true;o.e2e=false;o.ui_paths={ignore:["release-notes/**"]};o.network=["api.example.com"]'
keep() { node -e 'const {pack,version,profile,...r}=require(process.argv[1]);console.log(JSON.stringify(r))' "$R/standards.json"; }
before=$(keep); VER=0.3.0 apply "$R" >/dev/null
if [ "$before" = "$(keep)" ] && grep -q '"version": "0.3.0"' "$R/standards.json"; then ok apply-keeps-repo-fields; else fail apply-keeps-repo-fields "$before vs $(keep)"; fi

R=$(mkrepo); mkdir -p "$R/.claude/agents" && touch "$R/.claude/settings.local.json" "$R/.claude/agents/x.md"
ign=$(git -C "$R" check-ignore .claude/settings.local.json .claude/agents/x.md | wc -l | tr -d ' ')
if [ "$ign" = 2 ] && ! git -C "$R" check-ignore -q .claude/settings.json && ! git -C "$R" check-ignore -q .claude/skills; then ok apply-ignores-local-agent-state; else fail apply-ignores-local-agent-state "ignored=$ign"; fi

# ---- CLAUDE.md modes
R=$(mkrepo); echo "Always use tabs." > "$R/CLAUDE.md" && commit "$R"; a=$(check "$R"); sa=$?
echo "@AGENTS.md" > "$R/CLAUDE.md" && commit "$R"; b=$(check "$R"); sb=$?
FO=$T/forbid.json; node -e 'const o=require(process.argv[1]);o.claude_md="forbid";require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$FO"
OVERLAY=$FO apply "$R" >/dev/null && commit "$R"; c=$(check "$R"); sc=$?
if [ $sa -eq 1 ] && has CLAUDE.md "$a" && [ $sb -eq 0 ] && [ $sc -eq 1 ] && has CLAUDE.md "$c"; then ok claude-md-no-own-content; else fail claude-md-no-own-content "$sa $sb $sc"; fi

# ---- offline check
all=1; for p in internal client; do R=$(mkrepo $p); out=$(check "$R"); [ $? -eq 0 ] && has "standards ok: example v0.1.0 $p" "$out" || { all=0; echo "$out"; }; done
if [ $all = 1 ]; then ok check-passes-fresh-apply; else fail check-passes-fresh-apply; fi

R=$(mkrepo); s=$(node -e 'console.log(Date.now())'); out=$(check "$R"); st=$?; e=$(node -e 'console.log(Date.now())')
if [ $st -eq 0 ] && [ $((e - s)) -lt 2000 ] && ! grep -qE 'fetch\(|https?\.request|net\.connect' "$R/scripts/agent/check.mjs"; then ok check-offline-fast; else fail check-offline-fast "$((e - s))ms"; fi

R=$(mkrepo); echo x >> "$R/scripts/agent/gate.mjs"; echo "{}" > "$R/.mcp.json"; git -C "$R" add .mcp.json; rm "$R/.claude/skills"
out=$(check "$R"); st=$?; lines=$(printf '%s\n' "$out" | grep -c '^FAIL: '); fixed=$(printf '%s\n' "$out" | grep '^FAIL: ' | grep -c ' | fix: ')
if [ $st -eq 1 ] && [ "$lines" -ge 3 ] && [ "$lines" = "$fixed" ]; then ok check-failure-names-fix; else fail check-failure-names-fix "$out"; fi

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
if [ -n "$fix" ] && [ $st -eq 0 ] && has "v0.1.0" "$out" && ! grep -q "newer rule" "$R/.agents/skills/std-babysit/SKILL.md"; then ok drift-fix-restores-lock; else fail drift-fix-restores-lock "fix=$fix $out"; fi

R=$(mkrepo); rm "$R/scripts/agent/evidence.mjs"; out=$(check "$R")
if [ $? -eq 1 ] && has "managed file missing: scripts/agent/evidence.mjs" "$out"; then ok managed-missing-detected; else fail managed-missing-detected "$out"; fi

R=$(mkrepo); sed -i.bak 's/^- One concern per PR.*/- Scope creep is fine./' "$R/AGENTS.md" && rm "$R/AGENTS.md.bak"
expect_fail managed-block-drift-detected "$R" "managed AGENTS.md block"

R=$(mkrepo); sed -n '/^<!-- std:begin /,/^<!-- std:end -->$/p' "$R/AGENTS.md" >> "$R/AGENTS.md"; commit "$R"
out=$(check "$R"); st=$?; before=$(git -C "$R" status --porcelain); aout=$(apply "$R" 2>&1); ast=$?
if [ $st -eq 1 ] && has "2 std:begin" "$out" && [ $ast -ne 0 ] && [ "$before" = "$(git -C "$R" status --porcelain)" ]; then ok agents-block-single; else fail agents-block-single "$st $ast $aout"; fi

R=$(mkrepo); node -e 'console.log("- " + "x".repeat(3000))' >> "$R/AGENTS.md"
expect_fail agents-md-max-4096 "$R" "(limit 4096)"

R=$(mkrepo); rm "$R/.claude/skills" && mkdir "$R/.claude/skills"
expect_fail skills-symlink-enforced "$R" "ln -s ../.agents/skills .claude/skills"

R=$(mkrepo); jset "$R/.claude/settings.json" 'o.hooks.SessionStart=[]'
expect_fail session-hook-enforced "$R" ".claude/settings.json lacks the SessionStart"

R=$(mkrepo); jset "$R/standards.json" 'o.profile="partner"'; a=$(check "$R"); sa=$?
jset "$R/standards.json" 'o.profile="internal";o.dispatch="sometimes"'; b=$(check "$R"); sb=$?
jset "$R/standards.json" 'o.dispatch="auto";o.sensitive="no"'; c=$(check "$R"); sc=$?
if [ $sa$sb$sc = 111 ] && has "internal|client" "$a" && has "auto|manual|off" "$b" && has "true|false" "$c"; then ok standards-json-validated; else fail standards-json-validated "$a / $b / $c"; fi

R=$(mkrepo); jset "$R/standards.json" 'o.version="0.9.0"'
expect_fail version-lock-agree "$R" "0.9.0 differs from standards.lock 0.1.0"

# ---- forbidden content
R=$(mkrepo); echo "# Context" > "$R/CONTEXT.md"; git -C "$R" add CONTEXT.md
expect_fail root-context-md-forbidden "$R" "CONTEXT.md at the root"

R=$(mkrepo); echo '{"mcpServers":{}}' > "$R/.mcp.json"; git -C "$R" add .mcp.json
expect_fail mcp-json-forbidden "$R" "git rm --cached .mcp.json"

all=1
for f in docs/adr/0001-use-x.md decisions/2026-db.md api/decision-records/a.md notes/ADR-7.md; do
  R=$(mkrepo); mkdir -p "$R/$(dirname "$f")" && echo "We chose X." > "$R/$f" && git -C "$R" add "$f"
  out=$(check "$R"); [ $? -eq 1 ] && has "decision record tracked: $f" "$out" || { all=0; echo "$f: $out"; }
done
R=$(mkrepo); mkdir -p "$R/docs/guide" && echo "We chose X." > "$R/docs/guide/setup.md" && git -C "$R" add docs; check "$R" >/dev/null || all=0
if [ $all = 1 ]; then ok no-decision-records-in-tree; else fail no-decision-records-in-tree; fi

all=1
for f in .env .env.production .dev.vars certs/app.pem; do
  R=$(mkrepo); mkdir -p "$R/$(dirname "$f")" && echo "K=v" > "$R/$f" && git -C "$R" add -f "$f"
  out=$(check "$R"); [ $? -eq 1 ] && has "secret-bearing file tracked: $f" "$out" || all=0
done
R=$(mkrepo); echo "K=" > "$R/.env.example" && git -C "$R" add .env.example; check "$R" >/dev/null || all=0
if [ $all = 1 ]; then ok engine-no-secret-files; else fail engine-no-secret-files; fi

R=$(mkrepo); mkdir -p "$R/.evidence" && echo png > "$R/.evidence/a.png" && git -C "$R" add -f .evidence
expect_fail no-evidence-on-main "$R" ".evidence/ is tracked"

PO=$T/paths.json; node -e 'const o=require(process.argv[1]);o.forbid_paths=["**/CONTEXT.md"];o.profiles.client.forbid_paths=["docs/internal/**"];require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$PO"
R=$(mktemp -d "$T/r.XXXXXX"); git -C "$R" init -q -b main; OVERLAY=$PO apply "$R" --profile client >/dev/null; commit "$R"
mkdir -p "$R/docs/internal" "$R/api" && echo x > "$R/docs/internal/plan.txt" && echo x > "$R/api/CONTEXT.md" && git -C "$R" add docs api
out=$(check "$R")
if [ $? -eq 1 ] && has "docs/internal/plan.txt matches" "$out" && has "api/CONTEXT.md matches" "$out"; then ok overlay-forbidden-paths; else fail overlay-forbidden-paths "$out"; fi

R=$(mkrepo client); echo "see https://internal.example.com/runbook" > "$R/ops.txt" && git -C "$R" add ops.txt; a=$(check "$R"); sa=$?
R=$(mkrepo internal); echo "see https://internal.example.com/runbook" > "$R/ops.txt" && git -C "$R" add ops.txt; check "$R" >/dev/null; sb=$?
if [ $sa -eq 1 ] && has "ops.txt:1" "$a" && [ $sb -eq 0 ]; then ok client-leak-scan; else fail client-leak-scan "$sa $sb $a"; fi

R=$(mkrepo); echo '{"routes":[{"pattern":"preview.example.com","custom_domain":true}]}' > "$R/wrangler.jsonc" && git -C "$R" add wrangler.jsonc; a=$(check "$R"); sa=$?
sed -i.bak 's/preview\.example\.com/preview-site.example.com/' "$R/wrangler.jsonc" && rm "$R/wrangler.jsonc.bak"; check "$R" >/dev/null; sb=$?
if [ $sa -eq 1 ] && has "wrangler.jsonc uses the shared preview host preview.example.com" "$a" && [ $sb -eq 0 ]; then ok shared-preview-host-rejected; else fail shared-preview-host-rejected "$a"; fi

R=$(mkrepo); jset "$R/standards.json" 'o.ui_paths=[]'; mkdir -p "$R/src/components" && echo "<b/>" > "$R/src/components/Nav.svelte" && commit "$R"
out=$(check "$R"); st=$?
cls=$( (cd "$R" && echo "<i/>" >> src/components/Nav.svelte && node scripts/agent/gate.mjs classify HEAD) 2>&1)
if [ $st -eq 0 ] && has "WARN: ui_paths is []" "$out" && has "src/components/Nav.svelte" "$out" && has "no UI paths changed" "$cls"; then ok ui-paths-empty-warns; else fail ui-paths-empty-warns "$out | $cls"; fi

# ---- pack hygiene
BIG=$T/big.json; node -e 'const o=require(process.argv[1]);o.profiles.client.block_lines=["- "+"x".repeat(400)];require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$BIG"
out=$(node bin/repo-standards.mjs block --overlay "$BIG" --profile client 2>&1); st=$?
sizes=$(for p in internal client; do node bin/repo-standards.mjs block --overlay "$OV" --profile $p | wc -c; done | sort -n | tail -1 | tr -d ' ')
if [ $st -ne 0 ] && has "rendered client block is" "$out" && [ "$sizes" -le 1800 ]; then ok agents-block-max-1800; else fail agents-block-max-1800 "st=$st max=$sizes $out"; fi

out=$(node --input-type=module -e '
import { renderFiles, loadOverlay } from "./lib/engine.mjs";
const o = loadOverlay(process.argv[1]), bad = [];
for (const p of ["internal", "client"]) {
  const files = renderFiles(o, p, "0.1.0").filter(([f]) => !f.startsWith("scripts/agent/sentry-setup") && !f.startsWith("scripts/agent/deploy.sh"));
  const total = files.reduce((a, [, c]) => a + Buffer.byteLength(c), 0);
  if (total > 40960) bad.push(`${p} pack is ${total} bytes (limit 40960)`);
  for (const [f, c] of files.filter(([f]) => f.endsWith("SKILL.md"))) {
    if (Buffer.byteLength(c) > 1536) bad.push(`${f} is ${Buffer.byteLength(c)} bytes (limit 1536)`);
    if (!/^---\nname: [\w-]+\ndescription: .+\n/.test(c)) bad.push(`${f} lacks name/description frontmatter`);
  }
}
console.log(bad.join("\n"));' "$OV")
if [ -z "$out" ]; then ok pack-size-budgets; else fail pack-size-budgets "$out"; fi

out=$(grep -l '^disable-model-invocation: *true' template/.agents/skills/*/SKILL.md 2>/dev/null)
if [ -z "$out" ]; then ok skills-model-invocable; else fail skills-model-invocable "$out"; fi

bad=""
for f in template/scripts/agent/* modules/*/scripts/agent/*; do
  case "$(head -1 "$f")" in *bash*) bash -n "$f" || bad="$bad $f(syntax)" ;; *node*) node --check "$f" 2>/dev/null || node --input-type=module --check < "$f" 2>/dev/null || bad="$bad $f(syntax)" ;; *) continue ;; esac
  case "$f" in *pack.json) continue ;; esac
  H=${H:-$(mkrepo)}; h=$( (cd "$H" && GH_REPO=acme/demo "$ENGINE/$f" --help) 2>&1); st=$?
  [ $st -eq 0 ] && [ "$(printf '%s\n' "$h" | grep -c .)" -ge 1 ] && printf '%s\n' "$h" | grep -qiE 'usage|--|\[' || bad="$bad $f(--help exit=$st)"
done
if [ -z "$bad" ]; then ok scripts-lint-and-help; else fail scripts-lint-and-help "$bad"; fi

C=$T/dogfood; mkdir -p "$C" && git ls-files -z | xargs -0 -I{} sh -c 'mkdir -p "$1/$(dirname "{}")" && cp -P "{}" "$1/{}"' _ "$C"
v=$(node -p 'require("./package.json").version')
out=$(node bin/repo-standards.mjs apply --target "$C" --overlay "$OV" --version "$v" 2>&1)
if has "already current" "$out"; then ok pack-dogfooded; else fail pack-dogfooded "stale; re-apply: node bin/repo-standards.mjs apply --target . --overlay examples/overlay.json --version $v
$out"; fi

done_cases
