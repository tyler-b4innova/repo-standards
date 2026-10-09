#!/usr/bin/env bash
# release.mjs: supporting Workers (release_workers) first, and Sentry releases (JSONC and TOML). Through release.mjs with the stub wrangler.
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
  if (req.headers.authorization === "Bearer stall") return; // a stalled Sentry: the request is never answered
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
# a repository not set up for Sentry (no DSN) prints nothing Sentry-related, even with the token set, and is not an error
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace(/"vars": \{[^}]*\},/,""))'); commit nodsn; S=$(sha); : >"$SLOG"
out=$(cd "$R" && SENTRY_AUTH_TOKEN=tok WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -eq 0 ] && ! printf '%s' "$out" | grep -qE 'Sentry (skipped|release|source)|SENTRY_AUTH_TOKEN|not set up for Sentry' && [ ! -s "$SLOG" ] || why="$why; a repo without the DSN was not skipped (exit $rc): $out"
if [ -z "$why" ]; then ok release-sentry; else fail release-sentry "$why"; fi

# ---- a wrangler.toml Worker (the DSN sentry-setup writes there is found too): release created, source maps uploaded or, when the
# upload fails, a warning and a successful release
why=""
repo sentrytoml "$T/ov-sentry.json"
mkdir -p "$R/node_modules/.bin" "$R/src" "$R/dist"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"; echo '{}' >"$R/dist/app.js.map"
printf 'name = "site"\nmain = "src/index.js"\n[vars]\nSENTRY_DSN = "https://abc@o1.ingest.sentry.io/42"\n[env.staging]\nroutes = []\nworkers_dev = true\n' >"$R/wrangler.toml"
printf 'node_modules/\ndist/\n.wrangler/\n' >>"$R/.gitignore"; commit toml; S=$(sha)
cat >"$R/node_modules/.bin/sentry-cli" <<'SH'
#!/bin/sh
echo "sentry-cli $*" >>"$SENTRY_CLI_LOG"
[ -z "${SENTRY_CLI_FAIL:-}" ]
SH
chmod +x "$R/node_modules/.bin/sentry-cli"; export SENTRY_CLI_LOG=$T/cli.log; : >"$SENTRY_CLI_LOG"; : >"$SLOG"
out=$(cd "$R" && SENTRY_AUTH_TOKEN=tok WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -eq 0 ] && has "Sentry release ${S:0:7} created for acme/site" "$out" && has "Sentry source maps uploaded" "$out" && grep -q "sourcemaps upload --org acme --project site --release $S " "$SENTRY_CLI_LOG" || why="TOML release (exit $rc): $out"
# the maps come from Wrangler's final bundle: the primary's versions upload wrote them to a clean --outdir, which is what is uploaded (never dist/)
OUTDIR=$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(x=>x.args&&x.args[0]==="versions");const a=l[l.length-1].args;console.log(a[a.indexOf("--outdir")+1])' "$RELEASE_LOG")
UPLOADED=$(sed -n 's/.*--release [0-9a-f]* //p' "$SENTRY_CLI_LOG" | head -1)
[ -n "$OUTDIR" ] && [ "$UPLOADED" = "$OUTDIR" ] && has "--upload-source-maps" "$(calls)" && ! grep -q " dist" "$SENTRY_CLI_LOG" || why="$why; the uploaded maps are not from Wrangler's outdir (outdir=$OUTDIR uploaded=$UPLOADED)"
: >"$SENTRY_CLI_LOG"; out=$(cd "$R" && SENTRY_CLI_FAIL=1 SENTRY_AUTH_TOKEN=tok WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -eq 0 ] && has "::warning::Sentry source map upload failed (exit 1); the release exists without them" "$out" && has "versions upload" "$out" || why="$why; a failed source map upload failed the release or was silent (exit $rc): $out"
if [ -z "$why" ]; then ok release-sentry-toml; else fail release-sentry-toml "$why"; fi

# ---- Sentry work is bounded and comes after the Worker uploads: a stalled Sentry (API or sentry-cli) ends in a warning and exit 0; a failed
# Worker upload creates no Sentry release
why=""
: >"$SLOG"; out=$(cd "$R" && FAIL_UPLOAD=site SENTRY_AUTH_TOKEN=tok WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -ne 0 ] && [ ! -s "$SLOG" ] || why="a failed Worker upload still created a Sentry release (exit $rc)"
# RELEASE_SENTRY_TIMEOUT_S=1 shortens the hang guard: both stalls run at once, each past it, from two copies of the repository
R2=$T/sentrybounded2; cp -R "$R" "$R2"; printf '#!/bin/sh\nexec sleep 300\n' >"$R2/node_modules/.bin/sentry-cli"; start=$SECONDS
(cd "$R" && RELEASE_SENTRY_TIMEOUT_S=1 SENTRY_AUTH_TOKEN=stall WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main >"$T/stall-api.out" 2>&1; echo $? >"$T/stall-api.rc") &
P1=$!
(cd "$R2" && RELEASE_SENTRY_TIMEOUT_S=1 SENTRY_AUTH_TOKEN=tok WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main >"$T/stall-cli.out" 2>&1; echo $? >"$T/stall-cli.rc") &
P2=$!
wait $P1 $P2; took=$((SECONDS - start))
[ "$(cat "$T/stall-api.rc")" = 0 ] && grep -q "::warning::Sentry release skipped: timed out after 1s" "$T/stall-api.out" || why="$why; a stalled Sentry API did not end in a warning and exit 0: $(cat "$T/stall-api.rc") $(cat "$T/stall-api.out")"
[ "$(cat "$T/stall-cli.rc")" = 0 ] && grep -q "::warning::Sentry source map upload timed out after 1s" "$T/stall-cli.out" || why="$why; a stalled sentry-cli did not end in a warning and exit 0: $(cat "$T/stall-cli.rc") $(cat "$T/stall-cli.out")"
[ $took -lt 25 ] || why="$why; the stalls ended after ${took}s, not at the 1s limit"
if [ -z "$why" ]; then ok release-sentry-bounded; else fail release-sentry-bounded "$why"; fi

# ---- a failure part-way through leaves a mixed state: the report says which Workers were updated or uploaded, which were not, and
# that a re-run does it all again (nothing is restored)
why=""
repo mixed
mkdir -p "$R/node_modules/.bin" "$R/workers/runtime" "$R/workers/jobs" "$R/src"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"
printf '{ "name": "app", "main": "src/index.js", %s }\n' "$STAGING" >"$R/wrangler.jsonc"
for w in runtime jobs; do printf '{ "name": "%s", "main": "../../src/index.js", %s }\n' "$w" "$STAGING" >"$R/workers/$w/wrangler.jsonc"; done
node -e 'const fs=require("fs"),o=JSON.parse(fs.readFileSync(process.argv[1]));o.release_workers=["workers/runtime/wrangler.jsonc","workers/jobs/wrangler.jsonc"];fs.writeFileSync(process.argv[1],JSON.stringify(o,null,2))' "$R/standards.json"
printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"; commit fixture; S=$(sha)
out=$(cd "$R" && FAIL_DEPLOY=jobs-staging WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -ne 0 ] && has "release incomplete: Workers are in a mixed state" "$out" && has "staging updated: runtime-staging" "$out" && has "staging not updated: jobs-staging, app-staging" "$out" \
  && has "production uploaded: none" "$out" && has "re-running the build deploys and uploads all of them again" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" && has "nothing was restored or rolled back" "$out" || why="staging failure report (exit $rc): $out"
out=$(cd "$R" && FAIL_UPLOAD=jobs WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -ne 0 ] && has "staging updated: runtime-staging, jobs-staging, app-staging" "$out" && has "production uploaded: runtime (version ver-runtime)" "$out" && has "production not uploaded: jobs, app" "$out" || why="$why; production failure report (exit $rc): $out"
out=$(cd "$R" && WORKERS_CI_COMMIT_SHA=$S node scripts/agent/release.mjs main 2>&1); rc=$?
[ $rc -eq 0 ] && ! has "mixed state" "$out" || why="$why; a complete release printed a mixed-state report (exit $rc)"
if [ -z "$why" ]; then ok release-partial-failure; else fail release-partial-failure "$why"; fi
done_cases
