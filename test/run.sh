#!/usr/bin/env bash
# Runs every case file; each prints `ok <id>` / `FAIL <id>` / `skip <id> (why)`.
# Then checks coverage: every scenario id in SCENARIOS.md printed, and no unknown id (engine-* are engine-only).
set -uo pipefail
cd "$(dirname "$0")/.."
unset GATE_SELECT GATE_AFFECTED GATE_AFFECTED_E2E # inherited when this suite is the gate e2e command; cases set their own
status=0 log=$(mktemp)
trap 'rm -f "$log"' EXIT
for f in test/[a-z]*.sh $( [ -f org/test.sh ] && echo org/test.sh ); do
  case "$f" in test/lib.sh | test/run.sh) continue ;; esac
  bash "$f" | tee -a "$log"
  [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
done
want=$(grep -oE '^- \*\*`[a-z0-9-]+`\*\*' SCENARIOS.md | sed -E 's/^- \*\*`([^`]+)`\*\*/\1/' | sort -u)
got=$(sed -nE 's/^(ok|FAIL|skip) ([a-z0-9-]+).*/\2/p' "$log" | sort -u)
missing=$(comm -23 <(echo "$want") <(echo "$got"))
unknown=$(comm -13 <(echo "$want") <(echo "$got") | grep -vE '^engine-(neutral|org)-' || true)
if [ -z "$missing" ] && [ -z "$unknown" ]; then echo "ok engine-scenarios-covered ($(echo "$want" | wc -l | tr -d ' ') scenarios)"
else echo "FAIL engine-scenarios-covered"; echo "  missing: $(echo $missing)"; echo "  unknown: $(echo $unknown)"; status=1; fi
echo "summary: $(grep -c '^ok ' "$log") ok, $(grep -c '^FAIL ' "$log") FAIL, $(grep -c '^skip ' "$log") skip"
exit $status
