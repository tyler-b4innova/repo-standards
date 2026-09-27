# Result lines: `ok <id>` / `FAIL <id>`. A scenario counts as implemented only if a case prints its id.
FAILS=0
ok() { echo "ok $1"; }
fail() { echo "FAIL $1"; [ -z "${2:-}" ] || printf '  %s\n' "$2" | head -20; FAILS=$((FAILS + 1)); }
done_cases() { [ "$FAILS" -eq 0 ]; }
