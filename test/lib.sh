# Result lines: `ok <id>` / `FAIL <id>`. A scenario counts as implemented only if a case prints its id.
# The suite may itself run as a gate e2e command, which passes the selection (GATE_SELECT, GATE_AFFECTED*) down; each case sets what it needs.
unset GATE_SELECT GATE_AFFECTED GATE_AFFECTED_E2E
FAILS=0
ok() { echo "ok $1"; }
fail() { echo "FAIL $1"; [ -z "${2:-}" ] || printf '  %s\n' "$2" | head -20; FAILS=$((FAILS + 1)); }
done_cases() { [ "$FAILS" -eq 0 ]; }
# CI runners have no git identity; commits made by scripts under test need one.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# Hermetic: a CI runner exports the commit and run it is on; no case may depend on them. A case that needs one sets it itself.
unset GITHUB_SHA WORKERS_CI_COMMIT_SHA RELEASE_SHA RELEASE_CHECK RELEASE_JOB_STATUS GITHUB_RUN_ID
