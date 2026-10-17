#!/usr/bin/env bash
# The one setup line every cloud environment calls: `scripts/agent/setup.sh`.
#   (no args)  install tools and repo dependencies (a failed install never fails it), then run the check: its status
#   --check    offline standards self-check (session start and `gate`); outside a GitHub runner and a local gate run, fresh-base warnings and (after a clean pass) the clean-up of merged work
set -uo pipefail
start=$PWD
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1

case "${1:-}" in
  --check)
    node scripts/agent/check.mjs; st=$?
    # Not on a GitHub runner (GITHUB_ACTIONS) or in a local gate run (STD_GATE, set by gate.mjs local, whose --check is one of
    # its steps): both act on a checkout nobody is working in. CI is no signal here: agent sandboxes export it too.
    if [ -z "${GITHUB_ACTIONS:-}" ] && [ -z "${STD_GATE:-}" ]; then
      # fresh.mjs only warns (a stale default branch, work in the primary checkout) and never fails the session.
      node scripts/agent/fresh.mjs || true
      # Only after a clean check; cleanup.mjs is best-effort and never fails the session.
      [ $st -ne 0 ] || node scripts/agent/cleanup.mjs "$start" || true
    fi
    exit $st ;;
  -h | --help) sed -n '2,4p' "$0"; exit 0 ;;
  "") ;;
  *) sed -n '2,4p' "$0" >&2; exit 2 ;;
esac

note() { echo "setup: $*"; }
try() { "$@" || note "failed (continuing): $*"; }
online() { curl -sSfI --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; }
sudo=""
[ "$(id -u)" = 0 ] || sudo="sudo -n" # never wait for a password
# Whether this process can install system packages here: root, or sudo that can run. Under no_new_privs (agent sandboxes)
# sudo cannot run at all, so the kernel's flag decides and sudo is not called. Asked only when something is missing. Otherwise sudo
# is asked whether the apt-get this script runs is permitted without a password (sudo -l), not whether an unrelated command is.
can_sudo() {
  [ "$(id -u)" = 0 ] && return 0
  grep -qE '^NoNewPrivs:[[:space:]]*1' /proc/self/status 2>/dev/null && return 1
  $sudo -l "$(command -v apt-get)" >/dev/null 2>&1
}
host="" # what is missing and this host must provide, because sudo cannot install it here

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
      if can_sudo; then
        try $sudo apt-get update -qq
        try $sudo apt-get install -y -qq "${want[@]}"
      else host="$host; system packages ${want[*]}"; fi
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
      pw=""
      if [ -x node_modules/.bin/playwright ]; then pw=node_modules/.bin/playwright
      elif [ -n "$x" ]; then pw="$x playwright"; fi # pnpm exec / yarn (Plug'n'Play has no node_modules)
      if [ -z "$pw" ]; then note "playwright is in package.json but not installed (did the install above fail?); no browser installed"
      else
        # The browser only. Its system packages are installed only when a library is missing and this host can install them.
        # A failed browser install ends this step: the library check would otherwise report the browser as missing.
        if ! $pw install chromium; then note "playwright install chromium failed; no browser libraries were checked"
        elif ! lib=$(node scripts/agent/gate.mjs browser-deps 2>/dev/null); then
          if can_sudo; then try node scripts/agent/gate.mjs browser-deps --install
          else host="$host; browser libraries $(sed -n 's/^browser-deps: missing //p' <<<"$lib")"; fi
        fi
      fi
    fi
  fi
fi
if [ -n "$host" ]; then note "sudo cannot run here, so nothing was installed; the host must provide: ${host#; }"; fi
exec node scripts/agent/check.mjs
