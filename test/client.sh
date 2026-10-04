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

# ---- mail: every send goes through one seam, which reroutes any non-production host (previews, workers.dev, localhost)
SEAM='import { env } from "cloudflare:workers";
const PRODUCTION_HOSTS = ["example.com", "www.example.com"];
export async function sendFormEmail(request, mail) {
  const live = PRODUCTION_HOSTS.includes(new URL(request.url).hostname);
  await env.SEND_EMAIL.send({ ...mail, to: live ? mail.to : ["test@example.com"] });
}'
mail_site() { put "$1" wrangler.jsonc '{ "name": "site", "send_email": [{ "name": "SEND_EMAIL" }] }'; put "$1" src/env.d.ts 'interface Env { SEND_EMAIL: SendEmail }'; }
G=$(mkrepo); mail_site "$G"; put "$G" src/lib/email.ts "$SEAM"; put "$G" src/pages/api/contact.ts 'import { sendFormEmail } from "../../lib/email"; export const POST = ({ request }) => sendFormEmail(request, {});'; commit "$G"
B=$(mkrepo); mail_site "$B"; put "$B" src/lib/email.ts "$SEAM"; put "$B" src/pages/api/order.ts 'import { env } from "cloudflare:workers"; export const POST = () => env.SEND_EMAIL.send({ to: ["client@example.com"] });'; commit "$B"
I=$(mkrepo internal); mail_site "$I"; put "$I" src/pages/api/contact.ts 'export const POST = () => env.SEND_EMAIL.send({});'; commit "$I"
verdict client-mail-seam "$G" "$B" "src/pages/api/order.ts sends mail outside the email seam" "$I"
B=$(mkrepo); mail_site "$B"; put "$B" src/pages/api/contact.ts 'import { EmailMessage } from "cloudflare:email"; export const POST = () => env.SEND_EMAIL.send(new EmailMessage("a", "client@example.com", ""));'; commit "$B"
b=$(check "$B"); has "src/pages/api/contact.ts sends mail but never checks the request host" "$b" && ok client-mail-seam || fail client-mail-seam "no reroute: $b"

# ---- built output: after the build, dist/ HTML has no HTML comments, no comments in inline scripts, and no
# source-platform names (gate.mjs run build)
built() { # built <profile> <html>: a site whose build writes dist/index.html; prints gate's build output, then the exit
  local d; d=$(mkrepo "$1"); printf '%s' "$2" >"$d/page.html"
  put "$d" package.json '{"name":"site","private":true,"scripts":{"build":"mkdir -p dist/blog && cp page.html dist/index.html && cp page.html dist/blog/index.html"}}'
  commit "$d"; (cd "$d" && node scripts/agent/gate.mjs run build 2>&1); echo "exit=$?"
}
CLEAN='<!doctype html><html><head><meta name="generator" content="Astro"><script>window.x = "https://example.com/a";</script></head><body><p>Hand-built.</p></body></html>'
why=""
o=$(built client "$CLEAN"); has "exit=0" "$o" && has "built output: dist/ is clean" "$o" || why="clean: $o"
o=$(built client '<html><body><!-- old layout --><p>x</p></body></html>'); has "exit=1" "$o" && has "dist/index.html: HTML comment" "$o" || why="$why; comment: $o"
o=$(built client '<html><body><script>
  // tracks the old menu
  go();
</script></body></html>'); has "exit=1" "$o" && has "dist/index.html: comment in an inline script" "$o" || why="$why; inline: $o"
o=$(built client '<html><body><p>Site by Squarespace</p></body></html>'); has "exit=1" "$o" && has "dist/index.html: source-platform name Squarespace" "$o" || why="$why; platform: $o"
o=$(built internal '<html><body><!-- note --></body></html>'); has "exit=0" "$o" && ! has "built output" "$o" || why="$why; internal scanned: $o"
if [ -z "$why" ]; then ok client-built-output-clean; else fail client-built-output-clean "$why"; fi

done_cases
