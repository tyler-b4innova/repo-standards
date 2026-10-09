#!/usr/bin/env bash
# release.mjs for a Worker with its own config in a subdirectory (the Workers Builds root directory), supporting Workers first, and
# Sentry releases. Through release.mjs with the stub wrangler.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap '{ [ -n "${SENTRY_PID:-}" ] && kill $SENTRY_PID; } 2>/dev/null; rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME OP_CLI OP_VAULT OP_SERVICE_ACCOUNT_TOKEN SENTRY_AUTH_TOKEN
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"; chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
OV=${OV:-$ENGINE/examples/overlay.json}
# repo <name> [overlay]: a git repo with the pack applied
repo() { R=$T/$1; git init -q -b main "$R"; node bin/repo-standards.mjs apply --target "$R" --overlay "${2:-$ENGINE/examples/overlay.json}" --version 0.8.3 >/dev/null; export RELEASE_LOG=$T/$1.log; : >"$RELEASE_LOG"; }
commit() { gc -C "$R" add -A && gc -C "$R" commit -qm "${1:-change}"; }
sha() { git -C "$R" rev-parse HEAD; }
calls() { node -e 'const fs=require("fs");const l=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(x=>x.args);console.log(l.map(x=>x.args.join(" ")).join("\n"))' "$RELEASE_LOG"; }
STAGING='"env": { "staging": { "routes": [], "workers_dev": true } }'

# ---- per-Worker configs: the trigger's root directory is workers/api; no root Wrangler config
why=""
repo mono
mkdir -p "$R/workers/api/node_modules/.bin" "$R/workers/api/src"; touch "$R/workers/api/node_modules/.bin/wrangler"
printf '{ "name": "api", "main": "src/index.js", %s }\n' "$STAGING" >"$R/workers/api/wrangler.jsonc"; echo "export default {};" >"$R/workers/api/src/index.js"
printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"; commit fixture; S=$(sha)
out=$(cd "$R/workers/api" && WORKERS_CI_COMMIT_SHA=$S node ../../scripts/agent/release.mjs main 2>&1); rc=$?
c=$(calls)
[ $rc -eq 0 ] && has "deploy --env staging" "$c" && has "--name api-staging" "$c" && has "versions upload --tag $S" "$c" || why="main from workers/api (exit $rc): $out"
out=$(cd "$R/workers/api" && WORKERS_CI_BRANCH=feat/x node ../../scripts/agent/release.mjs preview 2>&1); rc=$?
[ $rc -eq 0 ] && has "preview --name feat-x" "$(calls)" || why="$why; preview from workers/api (exit $rc): $out"
# from the repository root there is still no Worker to release
out=$(cd "$R" && node scripts/agent/release.mjs main 2>&1); [ $? -ne 0 ] && has "no wrangler config" "$out" || why="$why; root run did not refuse: $out"
if [ -z "$why" ]; then ok release-subdir-worker; else fail release-subdir-worker "$why"; fi

# ---- supporting Workers (release_workers) go first, in listed order, then the primary: for the staging deploy and the production upload
why=""
repo order
mkdir -p "$R/node_modules/.bin" "$R/workers/runtime" "$R/workers/jobs" "$R/src"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"
printf '{ "name": "app", "main": "src/index.js", %s }\n' "$STAGING" >"$R/wrangler.jsonc"
for w in runtime jobs; do printf '{ "name": "%s", "main": "../../src/index.js", %s }\n' "$w" "$STAGING" >"$R/workers/$w/wrangler.jsonc"; done
node -e 'const fs=require("fs"),o=JSON.parse(fs.readFileSync(process.argv[1]));o.release_workers=["workers/runtime/wrangler.jsonc","workers/jobs/wrangler.jsonc"];fs.writeFileSync(process.argv[1],JSON.stringify(o,null,2))' "$R/standards.json"
printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"; commit fixture; S=$(sha)
out=$(cd "$R" && WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(x=>x.args);const d=l.filter(x=>x.args[0]==="deploy").map(x=>x.name),u=l.filter(x=>x.args[0]==="versions").map(x=>x.name);process.exit(JSON.stringify(d)===JSON.stringify(["runtime-staging","jobs-staging","app-staging"])&&JSON.stringify(u)===JSON.stringify(["runtime","jobs","app"])?0:1)' "$RELEASE_LOG"; ord=$?
[ $rc -eq 0 ] && [ $ord -eq 0 ] || why="order (exit $rc, ordered=$ord): $out $(calls)"
if [ -z "$why" ]; then ok release-supporting-workers-first; else fail release-supporting-workers-first "$why"; fi

# ---- Sentry: skipped with one notice without SENTRY_AUTH_TOKEN; a release for the commit with it and the DSN sentry-setup commits
why=""
cat >"$T/sentry.mjs" <<'JS'
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";
const [portFile, log] = process.argv.slice(2);
createServer((req, res) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => {
  appendFileSync(log, JSON.stringify({ method: req.method, path: req.url, auth: req.headers.authorization, body: b }) + "\n");
  if (req.url === "/api/0/projects/acme/42/") { res.writeHead(200, { "Content-Type": "application/json" }); return res.end(JSON.stringify({ slug: "site" })); }
  res.writeHead(201, { "Content-Type": "application/json" }); res.end("{}"); }); })
  .listen(0, "127.0.0.1", function () { writeFileSync(portFile, String(this.address().port)); });
JS
SLOG=$T/sentry-http.log; : >"$SLOG"; node "$T/sentry.mjs" "$T/sentry.port" "$SLOG" & SENTRY_PID=$!
for i in $(seq 50); do [ -s "$T/sentry.port" ] && break; sleep 0.1; done
node -e 'const o=require(process.argv[1]);Object.assign(o,{org:"acme",modules:{error_tracker:true,deploy:true}});o.accounts.error_tracker={kind:"sentry",org:"acme",api_base:"http://127.0.0.1:"+process.argv[3],filer_repo:"acme/filer",alert_workflow:"issues bridge",credential_item:"Tracker token"};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$ENGINE/examples/overlay.json" "$T/ov-sentry.json" "$(cat "$T/sentry.port")"
repo sentry "$T/ov-sentry.json"
cp -R test/fixtures/release-plain/. "$R/"; mkdir -p "$R/node_modules/.bin" "$R/src"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"; printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace(/"name": "site",/,"\"name\": \"site\",\n  \"vars\": { \"SENTRY_DSN\": \"https://abc@o1.ingest.sentry.io/42\" },"))'); commit fixture; S=$(sha); : >"$SLOG"
: >"$SLOG"
out=$(cd "$R" && WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c 'Sentry skipped')" = 1 ] && has "no SENTRY_AUTH_TOKEN build secret" "$out" && [ ! -s "$SLOG" ] || why="no token (exit $rc): $out"
: >"$SLOG"; out=$(cd "$R" && SENTRY_AUTH_TOKEN=tok WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse),r=l.find((x)=>x.method==="POST"&&x.path==="/api/0/organizations/acme/releases/");process.exit(r&&r.auth==="Bearer tok"&&JSON.parse(r.body).version===process.argv[2]&&JSON.parse(r.body).projects[0]==="site"?0:1)' "$SLOG" "$S"; posted=$?
[ $rc -eq 0 ] && has "Sentry release ${S:0:7} created for acme/site" "$out" && [ $posted -eq 0 ] || why="$why; release not created (exit $rc, posted=$posted): $out"
has "no sentry-cli" "$out" || why="$why; source maps not mentioned: $out"
# a repository not set up for Sentry (no DSN) is skipped with a notice, not an error
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace(/"vars": \{[^}]*\},/,""))'); commit nodsn; S=$(sha); : >"$SLOG"
out=$(cd "$R" && SENTRY_AUTH_TOKEN=tok WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -eq 0 ] && has "not set up for Sentry" "$out" && [ ! -s "$SLOG" ] || why="$why; a repo without the DSN was not skipped (exit $rc): $out"
if [ -z "$why" ]; then ok release-sentry; else fail release-sentry "$why"; fi
done_cases
