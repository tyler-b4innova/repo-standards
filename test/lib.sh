# Result lines: `ok <id>` / `FAIL <id>`. A scenario counts as implemented only if a case prints its id.
FAILS=0
ok() { echo "ok $1"; }
fail() { echo "FAIL $1"; [ -z "${2:-}" ] || printf '  %s\n' "$2" | head -20; FAILS=$((FAILS + 1)); }
done_cases() { [ "$FAILS" -eq 0 ]; }
# CI runners have no git identity; commits made by scripts under test need one.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
