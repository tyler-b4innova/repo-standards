#!/usr/bin/env bash
# The one setup line every cloud environment calls: `scripts/agent/setup.sh`.
#   (no args)  install tools and repo dependencies (a failed install never fails it), then run the check: its status
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
[ "$(id -u)" = 0 ] || sudo="sudo -n" # never wait for a password

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
    elif command -v brew >/dev/null; then # macOS: brew names; LibreOffice is a cask
      for p in "${want[@]}"; do
        case $p in poppler-utils) try brew install poppler ;; libreoffice-writer) ;; libreoffice-impress) try brew install --cask libreoffice ;; *) try brew install "$p" ;; esac
      done
    else
      note "no apt-get or brew; install manually if needed: ${want[*]}"
    fi
  fi
  if [ -f package.json ]; then
    x=""
    if [ -f pnpm-lock.yaml ]; then try corepack enable; try pnpm install --frozen-lockfile; x="pnpm exec"
    elif [ -f yarn.lock ]; then try corepack enable; x=yarn; if [ -f .yarnrc.yml ]; then try yarn install --immutable; else try yarn install --frozen-lockfile; fi
    elif [ -f package-lock.json ]; then try npm ci
    else try npm install --no-package-lock; fi
    # The repo's own playwright, so the browser matches the lockfile (never the registry's latest). Not npx: npm 6's
    # npx reads `--no <pkg>` as an option value, and a missing local package would fetch the latest.
    if grep -qE '"(@playwright/test|playwright)"' package.json; then
      if [ -x node_modules/.bin/playwright ]; then try node_modules/.bin/playwright install --with-deps chromium
      elif [ -n "$x" ]; then try $x playwright install --with-deps chromium # pnpm exec / yarn (Plug'n'Play has no node_modules)
      else note "playwright is in package.json but not installed (did the install above fail?); no browser installed"; fi
    fi
  fi
fi
exec node scripts/agent/check.mjs
