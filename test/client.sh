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

# ---- overflow: a block animated on a view()/scroll() timeline is never clipped with overflow: hidden (it freezes the
# timeline), and html never sets overflow-x
G=$(mkrepo); put "$G" src/styles/global.css '.card { overflow: hidden; }
.reveal { animation: rise linear both; animation-timeline: view(); overflow: clip; }
html { scroll-behavior: smooth; }'; commit "$G"
B=$(mkrepo); put "$B" src/components/Hero.astro '<section class="hero"></section>
<style>
  .hero {
    animation: rise linear both;
    animation-timeline: view();
    overflow: hidden;
  }
</style>'; commit "$B"
I=$(mkrepo internal); put "$I" src/styles/global.css 'html { overflow-x: hidden; }'; commit "$I"
verdict client-overflow-clip "$G" "$B" "src/components/Hero.astro: .hero is animated on a scroll timeline but sets overflow: hidden" "$I"
B=$(mkrepo); put "$B" src/styles/global.css 'html, body { margin: 0 }
html { overflow-x: hidden; }'; commit "$B"
b=$(check "$B"); has "src/styles/global.css: html sets overflow-x" "$b" && ok client-overflow-clip || fail client-overflow-clip "html overflow-x: $b"

# ---- Sentry: a client site whose Worker runs code (wrangler main) with the Cloudflare SDK has all four layers: the
# Worker wrapper, the middleware, the browser init and its same-origin tunnel route
sentry_site() { # sentry_site <repo> [layer to leave out]
  put "$1" package.json '{"name":"site","private":true,"dependencies":{"@sentry/cloudflare":"^10.0.0","@sentry/browser":"^10.0.0"}}'
  put "$1" wrangler.jsonc '{ "name": "site", "main": "./sentry.server.config.ts" }'
  [ "${2:-}" = wrapper ] || put "$1" sentry.server.config.ts 'export default Sentry.withSentry(() => ({}), handler);'
  [ "${2:-}" = middleware ] || put "$1" src/middleware.ts 'export const onRequest = async (_c, next) => { try { return await next(); } catch (e) { Sentry.captureException(e); throw e; } };'
  [ "${2:-}" = browser ] || put "$1" src/scripts/monitor.ts "import * as Sentry from '@sentry/browser';
Sentry.init({ dsn: 'https://key@o1.ingest.example.com/1', tunnel: '/api/t/' });"
  [ "${2:-}" = tunnel ] || put "$1" src/pages/api/t.ts 'export const POST = async () => new Response(null);'
  commit "$1"
}
G=$(mkrepo); sentry_site "$G"
I=$(mkrepo internal); put "$I" package.json '{"name":"x","dependencies":{"@sentry/cloudflare":"^10.0.0"}}'; put "$I" wrangler.jsonc '{ "main": "src/index.ts" }'; commit "$I"
S=$(mkrepo); put "$S" wrangler.jsonc '{ "name": "static", "assets": { "directory": "./dist" } }'; commit "$S" # no Worker code: nothing to report from
why=""
check "$G" >/dev/null || why="complete site failed: $(check "$G")"
check "$S" >/dev/null || why="$why; static site failed"
check "$I" >/dev/null || why="$why; internal checked"
for layer in wrapper middleware browser tunnel; do
  B=$(mkrepo); sentry_site "$B" $layer; b=$(check "$B")
  has "Sentry layer missing: $layer" "$b" || why="$why; no $layer: $b"
done
if [ -z "$why" ]; then ok client-sentry-four-layers; else fail client-sentry-four-layers "$why"; fi

done_cases
