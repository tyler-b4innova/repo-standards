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
OVERLAY=$FO apply "$R" >/dev/null && commit "$R"; c=$(check "$R"); sc=$?
if [ $sa -eq 1 ] && has CLAUDE.md "$a" && [ $sb -eq 0 ] && [ $sc -eq 1 ] && has CLAUDE.md "$c"; then ok claude-md-no-own-content; else fail claude-md-no-own-content "$sa $sb $sc"; fi

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

R=$(mkrepo); node -e 'console.log("- " + "x".repeat(3000))' >> "$R/AGENTS.md"
expect_fail agents-md-max-4096 "$R" "(limit 4096)"

all=1
for f in docs/adr/0001-use-x.md decisions/2026-db.md api/decision-records/a.md notes/ADR-7.md; do
  R=$(mkrepo); mkdir -p "$R/$(dirname "$f")" && echo "We chose X." > "$R/$f" && git -C "$R" add "$f"
  out=$(check "$R"); [ $? -eq 1 ] && has "decision record tracked: $f" "$out" || { all=0; echo "$f: $out"; }
done
R=$(mkrepo); mkdir -p "$R/docs/guide" && echo "We chose X." > "$R/docs/guide/setup.md" && git -C "$R" add docs; check "$R" >/dev/null || all=0
if [ $all = 1 ]; then ok no-decision-records-in-tree; else fail no-decision-records-in-tree; fi

R=$(mkrepo); mkdir -p "$R/.evidence" && echo png > "$R/.evidence/a.png" && git -C "$R" add -f .evidence
expect_fail no-evidence-on-main "$R" ".evidence/ is tracked"

R=$(mkrepo); echo '{"routes":[{"pattern":"preview.example.com","custom_domain":true}]}' > "$R/wrangler.jsonc" && git -C "$R" add wrangler.jsonc; a=$(check "$R"); sa=$?
sed -i.bak 's/preview\.example\.com/preview-site.example.com/' "$R/wrangler.jsonc" && rm "$R/wrangler.jsonc.bak"; check "$R" >/dev/null; sb=$?
if [ $sa -eq 1 ] && has "wrangler.jsonc uses the shared preview host preview.example.com" "$a" && [ $sb -eq 0 ]; then ok shared-preview-host-rejected; else fail shared-preview-host-rejected "$a"; fi

R=$(mkrepo); jset "$R/standards.json" 'o.ui_paths=[]'; mkdir -p "$R/src/components" && echo "<b/>" > "$R/src/components/Nav.svelte" && commit "$R"
out=$(check "$R"); st=$?
cls=$( (cd "$R" && echo "<i/>" >> src/components/Nav.svelte && node scripts/agent/gate.mjs classify HEAD) 2>&1)
if [ $st -eq 0 ] && has "WARN: ui_paths is []" "$out" && has "src/components/Nav.svelte" "$out" && has "no UI paths changed" "$cls"; then ok ui-paths-empty-warns; else fail ui-paths-empty-warns "$out | $cls"; fi

# ---- agent config (Tyler: repo-scoped model defaults; never read secrets, never force-push)
R=$(mkrepo); a=$(node -e 'const s=require(process.argv[1]);console.log(s.model,s.env.CLAUDE_CODE_SUBAGENT_MODEL)' "$R/.claude/settings.json"); c=$(cat "$R/.codex/config.toml")
jset "$R/.claude/settings.json" 'o.model="sonnet"'; b=$(check "$R"); sb=$?; gc -C "$R" checkout -q -- .claude/settings.json
w=$(ANTHROPIC_MODEL=haiku check "$R"); sw=$?
if [ "$a" = "opus opus" ] && has 'model = "gpt-6-sol"' "$c" && has 'default_subagent_model = "gpt-6-sol"' "$c" && [ $sb -eq 1 ] && has "model or deny keys changed" "$b" && [ $sw -eq 0 ] && has "WARN: shell sets ANTHROPIC_MODEL" "$w"
then ok model-defaults-repo-scoped; else fail model-defaults-repo-scoped "$a | $sb $b | $sw"; fi

R=$(mktemp -d "$T/r.XXXXXX"); git -C "$R" init -q -b main; mkdir -p "$R/.claude" "$R/.codex"
echo '{"permissions":{"deny":["Read(./secrets.txt)"]}}' > "$R/.claude/settings.json"; printf '[agents]\nmax_threads = 2\n' > "$R/.codex/config.toml"
apply "$R" >/dev/null
deny=$(node -e 'const d=require(process.argv[1]).permissions.deny;console.log(d.includes("Bash(op *)")&&d.includes("Bash(git push --force *)")&&d.includes("Read(**/.env)")&&!d.includes("Read(./secrets.txt)"))' "$R/.claude/settings.json")
top=$(node -e 'const t=require("fs").readFileSync(process.argv[1],"utf8").split(/^(?=\[)/m)[0];console.log(/approval_policy = "never"/.test(t)&&/sandbox_mode = "danger-full-access"/.test(t))' "$R/.codex/config.toml")
rules=skipped
if command -v codex >/dev/null; then
  pol() { codex execpolicy check --rules "$R/.codex/rules/std.rules" -- "$@" 2>/dev/null | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).decision||"allow")'; }
  rules="$(pol op read x) $(pol git push --force origin x) $(pol git push -f origin x) $(pol git push --force-with-lease origin x) $(pol git push origin x)"
fi
if [ "$deny" = true ] && [ "$top" = true ] && [ -f "$R/.codex/rules/std.rules" ] && { [ "$rules" = skipped ] || [ "$rules" = "forbidden forbidden forbidden allow allow" ]; }
then ok agent-deny-secrets-and-force-push; else fail agent-deny-secrets-and-force-push "deny=$deny top=$top rules=$rules"; fi
[ "$rules" != skipped ] || echo "  (codex CLI absent: std.rules decisions not evaluated)"

# ---- pack hygiene
out=$(python3 -c 'import sys,yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' template/.github/workflows/*.yml 2>&1)
if [ $? -eq 0 ]; then ok engine-workflows-parse; else fail engine-workflows-parse "$out"; fi

BIG=$T/big.json; node -e 'const o=require(process.argv[1]);o.profiles.client.block_lines=["- "+"x".repeat(400)];require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$BIG"
out=$(node bin/repo-standards.mjs block --overlay "$BIG" --profile client 2>&1); st=$?
sizes=$(for p in internal client; do node bin/repo-standards.mjs block --overlay "$OV" --profile $p | wc -c; done | sort -n | tail -1 | tr -d ' ')
if [ $st -ne 0 ] && has "rendered client block is" "$out" && [ "$sizes" -le 1800 ]; then ok agents-block-max-1800; else fail agents-block-max-1800 "st=$st max=$sizes $out"; fi

done_cases
