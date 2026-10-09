#!/usr/bin/env bash
# release.mjs for a Worker with its own config in a subdirectory (the Workers Builds root directory), Durable Object migrations
# (annotated on the uploaded version; promote does the right thing for both kinds) and Sentry releases. Through release.mjs
# with the stub wrangler.
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

# ---- Durable Object lifecycle: Cloudflare cannot upload a version that changes it, so a commit that does (legacy `migrations`,
# declarative `exports`, JSON or TOML) gets staging's normal deploy and NO production version; one that does not uploads as usual
why=""
mkdo() { # mkdo <name>: a repo with a Worker "site" (JSON) and a supporting Worker "extra" (TOML), nothing lifecycle yet
  repo "$1"; mkdir -p "$R/node_modules/.bin" "$R/src" "$R/workers/extra"; touch "$R/node_modules/.bin/wrangler"; echo "export default {};" >"$R/src/index.js"
  printf '{ "name": "site", "main": "src/index.js", %s }\n' "$STAGING" >"$R/wrangler.jsonc"
  printf 'name = "extra"\nmain = "../../src/index.js"\n[env.staging]\nroutes = []\nworkers_dev = true\n' >"$R/workers/extra/wrangler.toml"
  node -e 'const fs=require("fs"),o=JSON.parse(fs.readFileSync(process.argv[1]));o.release_workers=["workers/extra/wrangler.toml"];fs.writeFileSync(process.argv[1],JSON.stringify(o,null,2))' "$R/standards.json"
  printf 'node_modules/\n.wrangler/\n' >>"$R/.gitignore"; commit base
}
mainrun() { : >"$RELEASE_LOG"; MAINOUT=$(cd "$R" && WORKERS_CI_COMMIT_SHA=$(sha) node scripts/agent/release.mjs main 2>&1); MAINRC=$?; }
uploads() { calls | grep -c "^versions upload"; }
mkdo do
mainrun; [ $MAINRC -eq 0 ] && [ "$(uploads)" = 2 ] || why="a commit with no lifecycle change uploaded $(uploads) versions (exit $MAINRC): $MAINOUT"
# legacy migrations array on the primary
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace(/"name": "site",/,"\"name\": \"site\",\n  \"migrations\": [{ \"tag\": \"v1\", \"new_classes\": [\"Counter\"] }],"))'); commit migration; S1=$(sha)
mainrun; c=$(calls)
[ $MAINRC -eq 0 ] && [ "$(uploads)" = 1 ] && has "--name extra --tag" "$c" && ! has "versions upload --tag" "$c" && has "deploy --env staging" "$c" \
  && has "NO production version is uploaded for $S1" "$MAINOUT" && has "release.mjs promote $S1" "$MAINOUT" && has "wrangler deploy of this exact commit" "$MAINOUT" || why="$why; migration commit (exit $MAINRC, uploads=$(uploads)): $MAINOUT"
# the next commit adds nothing: uploads again
echo "// change" >>"$R/src/index.js"; commit plain; mainrun
[ $MAINRC -eq 0 ] && [ "$(uploads)" = 2 ] || why="$why; the commit after a migration did not upload ($(uploads))"
# declarative exports on the primary (Durable Object entry)
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace(/"name": "site",/,"\"name\": \"site\",\n  \"exports\": { \"Room\": { \"type\": \"durable-object\", \"storage\": \"sqlite\" } },"))'); commit exports; mainrun
[ $MAINRC -eq 0 ] && [ "$(uploads)" = 1 ] && has "export Room sqlite created" "$MAINOUT" || why="$why; a DO entry in exports was not detected (exit $MAINRC, uploads=$(uploads)): $MAINOUT"
# a TOML supporting Worker's migration
printf '\n[[migrations]]\ntag = "v1"\nnew_classes = ["Jobs"]\n' >>"$R/workers/extra/wrangler.toml"; commit toml; mainrun; c=$(calls)
[ $MAINRC -eq 0 ] && ! has "--name extra --tag" "$c" && has "migration v1" "$MAINOUT" || why="$why; a TOML migration was not detected (exit $MAINRC): $MAINOUT"
# unreadable history for a Worker that has lifecycle entries is an error, never "none": a shallow clone that cannot fetch more
SH=$T/shallow; git clone -q --depth 1 "file://$R" "$SH" 2>/dev/null; mkdir -p "$SH/node_modules/.bin"; touch "$SH/node_modules/.bin/wrangler"; git -C "$SH" remote remove origin
: >"$RELEASE_LOG"; MAINOUT=$(cd "$SH" && WORKERS_CI_COMMIT_SHA=$(git -C "$SH" rev-parse HEAD) node scripts/agent/release.mjs main 2>&1); MAINRC=$?
[ $MAINRC -ne 0 ] && has "cannot tell whether" "$MAINOUT" && [ "$(uploads)" = 0 ] || why="$why; shallow history was guessed (exit $MAINRC, uploads=$(uploads)): $MAINOUT"
if [ -z "$why" ]; then ok release-do-migration; else fail release-do-migration "$why"; fi

# ---- promote: preflight everything, then supporting Workers first and the primary last; a migrating Worker is deployed from a fresh
# checkout of the approved commit, never the caller's working tree
why=""
mkdo pr
cat >"$R/probe.mjs" <<'JS'
import { appendFileSync, existsSync, readFileSync } from "node:fs";
appendFileSync(process.env.RELEASE_LOG, JSON.stringify({ probe: { cwd: process.cwd(), extra: existsSync("EXTRA.txt"), src: readFileSync("src/index.js", "utf8").trim() } }) + "\n");
JS
node -e 'const fs=require("fs"),o=JSON.parse(fs.readFileSync(process.argv[1]));o.build="node probe.mjs";fs.writeFileSync(process.argv[1],JSON.stringify(o,null,2))' "$R/standards.json"
commit probe
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace(/"name": "site",/,"\"name\": \"site\",\n  \"migrations\": [{ \"tag\": \"v1\", \"new_classes\": [\"Counter\"] }],"))'); echo "// approved" >>"$R/src/index.js"; commit migration; SM=$(sha)
echo "// ordinary" >>"$R/src/index.js"; commit ordinary; SO=$(sha)
VERS="[{\"id\":\"vid-o\",\"annotations\":{\"workers/tag\":\"$SO\"}}]"
promote() { : >"$RELEASE_LOG"; PROUT=$(cd "$R" && RELEASE_VERSIONS=$VERS node scripts/agent/release.mjs promote "$@" 2>&1); PRRC=$?; }
remote_changes() { calls | grep -cE "^(deploy|versions deploy)"; }
# an ordinary commit: version deploys, supporting Worker first, primary last
promote "$SO"; c=$(calls)
[ $PRRC -eq 0 ] && [ "$(printf '%s\n' "$c" | grep '^versions deploy' | sed 's/ vid.*//')" = "$(printf 'versions deploy --name extra\nversions deploy --name site')" ] || why="ordinary promote (exit $PRRC): $PROUT $c"
# the migrating commit, with a dirty and an extra file in the caller's checkout (and the caller on another commit): the approved SHA is deployed
echo "// UNAPPROVED local edit" >>"$R/src/index.js"; echo x >"$R/EXTRA.txt"
VERS="[{\"id\":\"vid-m\",\"annotations\":{\"workers/tag\":\"$SM\"}}]"
promote "$SM"; c=$(calls)
node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(x=>x.probe);process.exit(l.length>=1&&l.every(x=>!x.probe.extra&&x.probe.src.endsWith("// approved")&&!x.probe.src.includes("UNAPPROVED")&&!x.probe.cwd.includes("/pr/")||(!x.probe.cwd.startsWith(process.argv[2])))?0:1)' "$RELEASE_LOG" "$R"; probed=$?
[ $PRRC -eq 0 ] && [ $probed -eq 0 ] && has "deploy --name site --tag $SM --message promote $SM" "$c" && has "versions deploy --name extra" "$c" && ! has "versions deploy --name site" "$c" || why="$why; migrating promote used the caller's tree or failed (exit $PRRC, probed=$probed): $PROUT $c"
git -C "$R" worktree prune; [ "$(git -C "$R" worktree list --porcelain | grep -c "^worktree ")" = 1 ] || why="$why; the promote checkout was left registered"
git -C "$R" checkout -q -- src/index.js; rm -f "$R/EXTRA.txt"
# preflight: a Worker without an uploaded version stops everything before any remote change
VERS='[]'; promote "$SM"
[ $PRRC -ne 0 ] && has "no uploaded version is tagged" "$PROUT" && [ "$(remote_changes)" = 0 ] || why="$why; a preflight failure still deployed ($(remote_changes)): $PROUT"
# preflight: the supporting Worker migrates, the primary is ordinary, and the primary's version is missing: nothing is deployed
VERS='[]'; promote "$SO"
[ $PRRC -ne 0 ] && [ "$(remote_changes)" = 0 ] || why="$why; nothing may be deployed after a failed preflight"
# an unreadable sha, a short sha, a commit whose config cannot be read
promote "$(printf '7%.0s' $(seq 40))"; [ $PRRC -ne 0 ] && has "not readable" "$PROUT" && [ -z "$(calls)" ] || why="$why; an unreadable sha was not refused: $PROUT"
promote abc; [ $PRRC -ne 0 ] && has "40-character" "$PROUT" || why="$why; a short sha was accepted"
EMPTY=$(git -C "$R" commit-tree "$(git -C "$R" hash-object -t tree /dev/null)" -m empty)
promote "$EMPTY"; [ $PRRC -ne 0 ] && has "no Wrangler config" "$PROUT" && [ "$(remote_changes)" = 0 ] || why="$why; a commit with no config was not refused: $PROUT"
if [ -z "$why" ]; then ok release-promote; else fail release-promote "$why"; fi

# ---- the fresh checkout installs with the frozen lockfile (a stub npm records it)
why=""
mkdo lock
export NPMLOG=$T/npm.log; : >"$NPMLOG"
printf '#!/bin/sh\necho "npm $*" >>"$NPMLOG"\nmkdir -p node_modules\n' >"$T/bin/npm"; chmod +x "$T/bin/npm"
printf '{ "name": "x", "private": true, "dependencies": { "left-pad": "1.3.0" } }\n' >"$R/package.json"; printf '{ "name": "x", "lockfileVersion": 3, "packages": {} }\n' >"$R/package-lock.json"; commit lock
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace(/"name": "site",/,"\"name\": \"site\",\n  \"migrations\": [{ \"tag\": \"v1\", \"new_classes\": [\"Counter\"] }],"))'); commit migration; SM=$(sha)
VERS="[{\"id\":\"v\",\"annotations\":{\"workers/tag\":\"$SM\"}}]"
promote "$SM"; c=$(calls); lg=$(cat "$NPMLOG")
[ $PRRC -eq 0 ] && has "npm ci" "$lg" || why="no frozen install (exit $PRRC): $PROUT $lg"
rm -f "$R/package-lock.json"; commit nolock; SN=$(sha)
(cd "$R" && node -e 'const fs=require("fs"),t=fs.readFileSync("wrangler.jsonc","utf8");fs.writeFileSync("wrangler.jsonc",t.replace("{ \"tag\": \"v1\", \"new_classes\": [\"Counter\"] }","{ \"tag\": \"v1\", \"new_classes\": [\"Counter\"] }, { \"tag\": \"v2\", \"new_classes\": [\"Room\"] }"))'); commit v2; SN=$(sha)
VERS="[{\"id\":\"v\",\"annotations\":{\"workers/tag\":\"$SN\"}}]"; promote "$SN"
[ $PRRC -ne 0 ] && has "no lockfile" "$PROUT" && [ "$(remote_changes)" = 0 ] || why="$why; an install without a lockfile was allowed (exit $PRRC): $PROUT"
if [ -z "$why" ]; then ok release-promote-isolated; else fail release-promote-isolated "$why"; fi

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
