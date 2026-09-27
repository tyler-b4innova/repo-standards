#!/usr/bin/env bash
# Runs every case file; each prints `ok <id>` / `FAIL <id>`. Exit 1 if any case failed.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
for f in test/[a-z]*.sh; do
  case "$f" in test/lib.sh | test/run.sh) continue ;; esac
  bash "$f" || status=1
done
exit $status
