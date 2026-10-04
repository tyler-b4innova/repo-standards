#!/usr/bin/env bash
# Client-profile site checks: offline in `setup.sh --check`, the built-output scan in `gate.mjs run build`, and the
# preview noindex check in `gate.mjs e2e`. Each passes on a site that follows the rule and fails one that breaks it;
# the internal profile is never checked.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GH_TOKEN GITHUB_TOKEN
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
mkrepo() { local d; d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; node "$ENGINE/bin/repo-standards.mjs" apply --overlay "$OV" --version 0.1.0 --target "$d" --profile "${1:-client}" >/dev/null && commit "$d" init && echo "$d"; }
check() { (cd "$1" && scripts/agent/setup.sh --check) 2>&1; }
put() { mkdir -p "$(dirname "$1/$2")" && printf '%s\n' "$3" >"$1/$2"; }
# verdict <id> <repo that follows the rule> <repo that breaks it> <needle in the failure>: and an internal repo with the
# same breakage passes
verdict() {
  local a b st
  a=$(check "$2"); st=$?
  b=$(check "$3")
  if [ $st -eq 0 ] && has "$4" "$b" && has "| fix: " "$b" && check "$5" >/dev/null; then ok "$1"; else fail "$1" "good=$st: $a | bad: $b"; fi
}
SCRIPT='<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>'

# ---- Turnstile: the script is the versioned /turnstile/v0/api.js (an unversioned URL 404s)
G=$(mkrepo); put "$G" src/components/Contact.astro "$SCRIPT"; put "$G" src/pages/api/contact.ts 'fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify")'; commit "$G"
B=$(mkrepo); put "$B" src/components/Contact.astro '<script src="https://challenges.cloudflare.com/turnstile/api.js" async></script>'; commit "$B"
I=$(mkrepo internal); put "$I" src/components/Contact.astro '<script src="https://challenges.cloudflare.com/turnstile/api.js" async></script>'; commit "$I"
verdict client-turnstile-versioned "$G" "$B" "src/components/Contact.astro loads Turnstile from" "$I"

done_cases
