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
html { scroll-behavior: smooth; overflow-x: clip; }'; commit "$G" # clip makes no scroll container
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
b=$(check "$B"); has "src/styles/global.css: html sets overflow-x to a scroll container" "$b" && ok client-overflow-clip || fail client-overflow-clip "html overflow-x: $b"

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
# Astro's directory form of the middleware counts; a Worker entry the build generates (dist/_worker.js) is checked in the
# tracked source that wraps it, so a clean checkout never fails for want of a build
G=$(mkrepo); sentry_site "$G" middleware; put "$G" src/middleware/index.ts 'export const onRequest = sequence(capture);'; put "$G" src/middleware/capture.ts 'export const capture = async (_c, next) => { try { return await next(); } catch (e) { Sentry.captureException(e); throw e; } };'; commit "$G"
check "$G" >/dev/null || why="$why; middleware directory: $(check "$G")"
G=$(mkrepo); sentry_site "$G"; put "$G" wrangler.jsonc '{ "name": "site", "main": "./dist/_worker.js/index.js" }'; gc -C "$G" rm -q sentry.server.config.ts; put "$G" src/worker.ts 'export default Sentry.withSentry(() => ({}), app);'; commit "$G"
check "$G" >/dev/null || why="$why; generated main: $(check "$G")"
B=$(mkrepo); sentry_site "$B"; put "$B" wrangler.jsonc '{ "name": "site", "main": "./dist/_worker.js/index.js" }'; gc -C "$B" rm -q sentry.server.config.ts; commit "$B"
has "Sentry layer missing: wrapper" "$(check "$B")" || why="$why; generated main without a wrapper passed"
if [ -z "$why" ]; then ok client-sentry-four-layers; else fail client-sentry-four-layers "$why"; fi

# ---- mail: every send goes through one seam, which reroutes any non-production host (previews, workers.dev, localhost)
SEAM='import { env } from "cloudflare:workers";
const PRODUCTION_HOSTS = ["example.com", "www.example.com"];
export async function sendFormEmail(request, mail) {
  const live = PRODUCTION_HOSTS.includes(new URL(request.url).hostname);
  await env.SEND_EMAIL.send({ ...mail, to: live ? mail.to : ["test@example.com"] });
}'
mail_site() { put "$1" wrangler.jsonc '{ "name": "site", "send_email": [{ "name": "SEND_EMAIL" }] }'; put "$1" src/env.d.ts 'interface Env { SEND_EMAIL: SendEmail }'; }
G=$(mkrepo); mail_site "$G"; put "$G" src/lib/email.ts "$SEAM"; put "$G" src/pages/api/contact.ts 'import { sendFormEmail } from "../../lib/email"; export const POST = ({ request }) => sendFormEmail(request, {});'
put "$G" tests/contact.test.mjs 'const env = { SEND_EMAIL: { send: async () => {} } };'; commit "$G" # a test's stand-in binding is not a sender
B=$(mkrepo); mail_site "$B"; put "$B" src/lib/email.ts "$SEAM"; put "$B" src/pages/api/order.ts 'import { env } from "cloudflare:workers"; export const POST = () => env.SEND_EMAIL.send({ to: ["client@example.com"] });'; commit "$B"
I=$(mkrepo internal); mail_site "$I"; put "$I" src/pages/api/contact.ts 'export const POST = () => env.SEND_EMAIL.send({});'; commit "$I"
verdict client-mail-seam "$G" "$B" "src/pages/api/order.ts sends mail outside the email seam" "$I"
# a same-origin check reads the host too, but routes nothing: the seam must compare the hostname with the production hosts
B=$(mkrepo); mail_site "$B"; put "$B" src/pages/api/contact.ts 'import { EmailMessage } from "cloudflare:email";
export const POST = ({ request }) => { if (new URL(request.headers.get("origin")).host !== new URL(request.url).host) return new Response(null, { status: 403 });
  return env.SEND_EMAIL.send(new EmailMessage("a", "client@example.com", "")); };'; commit "$B"
b=$(check "$B"); has "src/pages/api/contact.ts sends mail but never compares the request hostname with the production hosts" "$b" && ok client-mail-seam || fail client-mail-seam "no reroute: $b"
# the seam may take the binding as an argument: routes that pass it on send nothing themselves, and a comment is no send
G=$(mkrepo); mail_site "$G"; put "$G" src/lib/email.ts 'import { EmailMessage } from "cloudflare:email";
const PRODUCTION_HOSTS = new Set(["example.com", "www.example.com"]);
export async function sendFormEmail(mailer, request, to, raw) {
  const live = PRODUCTION_HOSTS.has(new URL(request.url).hostname);
  await mailer.send(new EmailMessage("form@example.com", live ? to : "test@example.com", raw));
}'
for r in contact order; do put "$G" src/pages/api/$r.ts 'import { env } from "cloudflare:workers"; import { sendFormEmail } from "../../lib/email";
// never env.SEND_EMAIL.send(...) here: the seam reroutes
export const POST = ({ request }) => sendFormEmail(env.SEND_EMAIL, request, "client@example.com", "");'; done; commit "$G"
g=$(check "$G") && ok client-mail-seam || fail client-mail-seam "dependency-injected seam: $g"
# logging the hostname beside a host constant routes nothing: the guard is a comparison or membership test
B=$(mkrepo); mail_site "$B"; put "$B" src/pages/api/contact.ts 'const HOST = "example.com";
export const POST = ({ request }) => { console.log(HOST, new URL(request.url).hostname); return env.SEND_EMAIL.send({ to: ["client@example.com"] }); };'; commit "$B"
b=$(check "$B"); has "src/pages/api/contact.ts sends mail but never compares the request hostname with the production hosts" "$b" && ok client-mail-seam || fail client-mail-seam "logged host passed: $b"
# a wrangler.toml [[send_email]] binding counts too, without any cloudflare:email import
B=$(mkrepo); put "$B" wrangler.toml 'name = "site"
[[send_email]]
name = "MAILER"'; put "$B" src/pages/api/contact.ts 'export const POST = ({ locals }) => locals.runtime.env.MAILER.send({ to: ["client@example.com"] });'; commit "$B"
b=$(check "$B"); has "src/pages/api/contact.ts sends mail but never compares the request hostname with the production hosts" "$b" && ok client-mail-seam || fail client-mail-seam "toml binding missed: $b"

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
# a trailing comment counts; // and /* inside strings, template literals and regular expressions do not, nor does division
o=$(built client '<html><body><script>go(); // the old menu
</script></body></html>'); has "exit=1" "$o" && has "dist/index.html: comment in an inline script" "$o" || why="$why; trailing: $o"
o=$(built client '<html><body><script>
const a = "https://example.com/x", b = '"'"'/* not a comment */'"'"', c = `// ${a} /*`, d = /\/\*|\/\/[a-z]/g, e = 4 / 2 / 1;
const f = [1, 2].map((x) => x / 2), g = a.replace(/\/\//g, "/");
</script></body></html>'); has "exit=0" "$o" && has "built output: dist/ is clean" "$o" || why="$why; strings and regexes: $o"
o=$(built client '<html><body><p>Site by Squarespace</p></body></html>'); has "exit=1" "$o" && has "dist/index.html: source-platform name Squarespace" "$o" || why="$why; platform: $o"
o=$(built internal '<html><body><!-- note --></body></html>'); has "exit=0" "$o" && ! has "built output" "$o" || why="$why; internal scanned: $o"
if [ -z "$why" ]; then ok client-built-output-clean; else fail client-built-output-clean "$why"; fi

# ---- previews carry noindex: gate.mjs e2e reads the preview's home page before the suite runs against it
cat >"$T/serve.mjs" <<'JS'
import { createServer } from "node:http";
const [port, mode] = process.argv.slice(2);
createServer((req, res) => {
  const headers = { "content-type": "text/html", ...(mode === "header" && { "x-robots-tag": "noindex" }) };
  res.writeHead(200, headers);
  res.end(`<html><head>${mode === "meta" ? '<meta name="robots" content="noindex, nofollow">' : ""}</head><body>home</body></html>`);
}).listen(Number(port), "127.0.0.1");
JS
e2e() { # e2e <profile> <server mode>: gate's e2e step against a stand-in preview; prints its output, then the exit
  local d port=$((20000 + RANDOM % 20000)) pid; d=$(mkrepo "$1")
  put "$d" tests/e2e/home.test.mjs 'import test from "node:test"; test("home", () => {});'; commit "$d"
  node "$T/serve.mjs" "$port" "$2" & pid=$!; sleep 0.4
  (cd "$d" && GATE_PREVIEW_URL="http://127.0.0.1:$port" node scripts/agent/gate.mjs e2e 2>&1); echo "exit=$?"; kill $pid; wait $pid 2>/dev/null
}
why=""
o=$(e2e client meta); has "exit=0" "$o" && has "preview noindex: ok" "$o" || why="meta: $o"
o=$(e2e client header); has "exit=0" "$o" && has "preview noindex: ok" "$o" || why="$why; header: $o"
o=$(e2e client none); has "exit=1" "$o" && has "the preview at http://127.0.0.1:" "$o" && has "carries no noindex" "$o" || why="$why; none: $o"
o=$(e2e internal none); has "exit=0" "$o" && ! has "noindex" "$o" || why="$why; internal checked: $o"
if [ -z "$why" ]; then ok client-preview-noindex; else fail client-preview-noindex "$why"; fi

done_cases
