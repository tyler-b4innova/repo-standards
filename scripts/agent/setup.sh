#!/usr/bin/env bash
# The one setup line every cloud environment calls: `scripts/agent/setup.sh`.
#   (no args)  install tools and repo dependencies (never fails the sandbox), then run the check
#   --check    offline standards self-check only (session start and `gate`)
set -uo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1

case "${1:-}" in
  --check) exec node scripts/agent/check.mjs ;;
  -h | --help) sed -n '2,4p' "$0"; exit 0 ;;
  "") ;;
  *) sed -n '2,4p' "$0" >&2; exit 2 ;;
esac

note() { echo "setup: $*"; }
try() { "$@" || note "failed (continuing): $*"; }
online() { curl -sSfI --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; }
sudo=""
[ "$(id -u)" = 0 ] || sudo=sudo

if ! online; then
  note "offline: skipping installs"
else
  want=()
  command -v gh >/dev/null || want+=(gh)
  command -v ffmpeg >/dev/null || want+=(ffmpeg)
  command -v pdftoppm >/dev/null || want+=(poppler-utils)
  if git ls-files | grep -qiE '\.(docx|pptx)$' && ! command -v soffice >/dev/null; then want+=(libreoffice-impress libreoffice-writer); fi
  if [ ${#want[@]} -gt 0 ]; then
    if command -v apt-get >/dev/null; then
      try $sudo apt-get update -qq
      try $sudo apt-get install -y -qq "${want[@]}"
    else
      note "no apt-get; install manually if needed: ${want[*]}"
    fi
  fi
  if [ -f package.json ]; then
    if [ -f pnpm-lock.yaml ]; then try corepack enable; try pnpm install --frozen-lockfile
    elif [ -f yarn.lock ]; then try corepack enable; if [ -f .yarnrc.yml ]; then try yarn install --immutable; else try yarn install --frozen-lockfile; fi
    elif [ -f package-lock.json ]; then try npm ci
    else try npm install --no-package-lock; fi
    if grep -qE '"(@playwright/test|playwright)"' package.json; then try npx playwright install --with-deps chromium; fi
  fi
fi
node scripts/agent/check.mjs
exit 0
