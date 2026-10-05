#!/usr/bin/env bash
# Workers Builds deploy commands (scripts/agent/release.mjs) and the PR Preview clean-up (std-preview-cleanup.yml):
# through apply and the applied script, with wrangler and the 1Password CLI as recording stand-ins and a GitHub stand-in.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME GH_TOKEN GITHUB_TOKEN WORKERS_CI_BRANCH WORKERS_CI_COMMIT_SHA OP_VAULT OP_SERVICE_ACCOUNT_TOKEN OP_CLI
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap '{ kill $STUB; wait $STUB; } 2>/dev/null; rm -rf "$T"' EXIT
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("o",process.argv[2]))(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$1" "$2"; }
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "${OVERLAY:-$OV}" --version 0.1.0 --target "$1"; }
WF=.github/workflows/std-preview-cleanup.yml

# Stand-ins. npx: one log line per call (its arguments, and for --secrets-file the file's mode and keys, never values);
# `secret list` prints the names in $T/listed (JSON) after a banner; `preview delete` of a name in $T/gone says not found,
# of a name in $T/broken fails. op: `op read op://<vault>/staging/<NAME>` prints "value-of-<NAME>" unless NAME is in $T/opmissing.
mkdir -p "$T/bin"
cat >"$T/bin/npx" <<'EOF'
#!/usr/bin/env bash
line="$*"; f=""; prev=""
for a in "$@"; do [ "$prev" = --secrets-file ] && f=$a; prev=$a; done
if [ -n "$f" ]; then line="$line | file $(node -p "(require(\"fs\").statSync(process.argv[1]).mode & 0o777).toString(8)" "$f") keys $(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).join(","))' "$f")"; echo "$f" >>"$FAKE/files"; fi
echo "$line" >>"$FAKE/npx.log"
case "$line" in *"deploy --env staging"*) echo "deploy --env staging: ${WRANGLER_CI_OVERRIDE_NAME:--} ${WRANGLER_CI_MATCH_TAG:--}" >>"$FAKE/envlog" ;; *"versions upload"*) echo "versions upload: ${WRANGLER_CI_OVERRIDE_NAME:--} ${WRANGLER_CI_MATCH_TAG:--}" >>"$FAKE/envlog" ;; esac
case "$line" in
  *"secret list"*) echo "⛅️ wrangler 4.147.0"; echo "[WARNING] beta"; cat "$FAKE/listed" ;;
  *"preview delete"*) for n in $(cat "$FAKE/gone" 2>/dev/null); do case "$line" in *"--name $n "*) echo "X [ERROR] The Preview \"$n\" was not found." >&2; exit 1 ;; esac; done
    for n in $(cat "$FAKE/broken" 2>/dev/null); do case "$line" in *"--name $n "*) echo "X [ERROR] Authentication error" >&2; exit 1 ;; esac; done ;;
esac
[ ! -f "$FAKE/failon" ] || case "$line" in *"$(cat "$FAKE/failon")"*) exit 7 ;; esac
exit 0
EOF
cat >"$T/bin/op" <<'EOF'
#!/usr/bin/env bash
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || exit 9
ref=${@: -1}; name=${ref##*/}
grep -qx "$name" "$FAKE/opmissing" 2>/dev/null && { echo "[ERROR] no field" >&2; exit 1; }
printf 'value-of-%s' "$name"
EOF
chmod +x "$T/bin/npx" "$T/bin/op"
export FAKE=$T PATH="$T/bin:$PATH"
reset() { rm -f "$T/npx.log" "$T/files" "$T/gone" "$T/broken" "$T/failon" "$T/opmissing"; printf '%s' "${1:-[]}" >"$T/listed"; }
rel() { (cd "$1" && shift && node scripts/agent/release.mjs "$@" 2>&1); echo "exit=$?"; }
log() { cat "$T/npx.log" 2>/dev/null; }

site() { # a Worker repository with the pack, an env.staging (unless "legacy") and the repository's wrangler installed
  local d=$T/$1; git init -q -b main "$d"; apply "$d" >/dev/null
  # a legacy (0.6.x) config: apply's migration is kept off so the release script meets it as it was
  if [ "${2:-}" = legacy ]; then printf '{\n  // site\n  "name": "site",\n  "main": "src/index.ts",\n}\n' >"$d/wrangler.jsonc"
    node -e 'const f=process.argv[1]+"/standards.json",fs=require("fs"),o=JSON.parse(fs.readFileSync(f,"utf8"));o.staging=false;fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$d"
  else printf '{\n  // site\n  "name": "site",\n  "main": "src/index.ts",\n  "env": { "staging": { "vars": { "ENVIRONMENT": "staging" } } },\n}\n' >"$d/wrangler.jsonc"; fi
  apply "$d" >/dev/null # the clean-up workflow ships once the repository has a Worker
  mkdir -p "$d/node_modules/.bin" && : >"$d/node_modules/.bin/wrangler" && printf 'node_modules/\n' >>"$d/.gitignore"
  commit "$d" init; echo "$d"
}

# ---- main: staging is the env.staging Worker, then the production version is uploaded; legacy configs keep the old Preview
why=""
R=$(site main); reset
o=$(WORKERS_CI_COMMIT_SHA=abc1234 rel "$R" main)
want="wrangler deploy --env staging
wrangler versions upload --tag abc1234 --message main abc1234 --var SENTRY_RELEASE:abc1234"
[ "$(log)" = "$want" ] && has "exit=0" "$o" || why="main: $o // $(log)"
reset; o=$(rel "$R" main); [ "$(log | tail -1)" = "wrangler versions upload" ] || why="$why; no sha: $(log)"
L=$(site legacy legacy); reset; o=$(WORKERS_CI_COMMIT_SHA=abc1234 rel "$L" main)
has "exit=0" "$o" && has "::warning::wrangler.jsonc has no env.staging" "$o" && [ "$(log | head -1)" = "wrangler preview --name staging" ] && has "versions upload" "$(log)" || why="$why; legacy: $o // $(log)"
reset; echo "deploy --env staging" >"$T/failon"; o=$(rel "$R" main); has "exit=7" "$o" && ! has "versions upload" "$(log)" || why="$why; failed deploy went on: $o // $(log)"
rm -f "$T/failon"
# staging's own D1 takes this commit's migrations before the staging deploy (never production's)
D=$(site db); printf '{ "name": "site", "main": "src/index.ts", "env": { "staging": { "d1_databases": [{ "binding": "DB", "database_name": "db-staging", "database_id": "d1-staging" }] } } }\n' >"$D/wrangler.jsonc"; mkdir -p "$D/migrations"; : >"$D/migrations/0001.sql"
reset; o=$(rel "$D" main); [ "$(log | head -2)" = "wrangler d1 migrations apply DB --env staging --remote
wrangler deploy --env staging" ] || why="$why; staging migrations: $o // $(log)"
# the Builds override that targets the production Worker never reaches a staging command
reset; rm -f "$T/envlog"; o=$(WRANGLER_CI_OVERRIDE_NAME=site WRANGLER_CI_MATCH_TAG=t rel "$R" main); has "exit=0" "$o" && [ "$(cat "$T/envlog")" = "deploy --env staging: - -
versions upload: site t" ] || why="$why; ci override: $(cat "$T/envlog" 2>/dev/null)"
if [ -z "$why" ]; then ok release-staging-env; else fail release-staging-env "$why"; fi

# ---- secrets: re-supplied from 1Password on every staging and Preview deploy, never on the production upload, never printed
why=""
S=$(site secrets); jset "$S/standards.json" 'o.secrets={required:["MAIL_KEY","TURNSTILE_SECRET"],store:"1password"}'; commit "$S"
reset '[{"name":"MAIL_KEY","type":"secret_text"},{"name":"TURNSTILE_SECRET","type":"secret_text"}]'
o=$(OP_CLI=$T/bin/op OP_VAULT=client-a OP_SERVICE_ACCOUNT_TOKEN=t WORKERS_CI_COMMIT_SHA=abc1234 rel "$S" main)
has "exit=0" "$o" && has "wrangler deploy --env staging --secrets-file " "$(log)" && has "| file 600 keys MAIL_KEY,TURNSTILE_SECRET" "$(log)" \
  && has "wrangler secret list --env staging --format json" "$(log)" && has "wrangler secret list --format json" "$(log)" \
  && ! log | grep "versions upload" | grep -q secrets-file || why="main: $o // $(log)"
o2=$(OP_CLI=$T/bin/op OP_VAULT=client-a OP_SERVICE_ACCOUNT_TOKEN=t WORKERS_CI_BRANCH=Feat/Login rel "$S" preview)
has "exit=0" "$o2" && has "wrangler preview --name feat-login --secrets-file " "$(log)" && has "wrangler preview secret list --name feat-login --json" "$(log)" || why="$why; preview: $o2 // $(log)"
for f in $(cat "$T/files"); do [ ! -e "$f" ] && [ ! -e "$(dirname "$f")" ] || why="$why; secrets file left at $f"; done
has "value-of-" "$o$o2" && why="$why; a value was printed"
# no vault or token: a warning, the deploy keeps the Worker's secrets, and the post-deploy check still fails a missing one
reset; o=$(OP_CLI=$T/bin/op OP_SERVICE_ACCOUNT_TOKEN=t rel "$S" main); has "exit=1" "$o" && has "::warning::secrets" "$o" && has "no OP_VAULT variable" "$o" && has "missing required secret" "$o" && ! has "secrets-file" "$(log)" || why="$why; no vault: $o"
reset; echo TURNSTILE_SECRET >"$T/opmissing"; o=$(OP_CLI=$T/bin/op OP_VAULT=client-a OP_SERVICE_ACCOUNT_TOKEN=t rel "$S" main)
has "exit=1" "$o" && has "no readable TURNSTILE_SECRET" "$o" && [ -z "$(log)" ] || why="$why; missing item: $o"
# a client-owned account: Secrets Store bindings, nothing re-supplied, no 1Password needed
C=$(site store); jset "$C/standards.json" 'o.secrets={required:["MAIL_KEY"],store:"secrets_store"}'; commit "$C"
reset; o=$(rel "$C" main); has "exit=0" "$o" && ! has "secrets-file" "$(log)" && ! has "secret list" "$(log)" && has "Secrets Store" "$o" || why="$why; secrets_store: $o // $(log)"
# no secrets declared: no file, no check
reset; o=$(rel "$R" preview); ! has "secrets-file" "$(log)" && ! has "secret list" "$(log)" || why="$why; none declared: $(log)"
if [ -z "$why" ]; then ok release-secrets-resupplied; else fail release-secrets-resupplied "$why"; fi

# ---- post-deploy: a deployed Worker without a required secret fails the build, naming it (never a value)
why=""
reset '[{"name":"MAIL_KEY","type":"secret_text"}]'
o=$(OP_CLI=$T/bin/op OP_VAULT=client-a OP_SERVICE_ACCOUNT_TOKEN=t WORKERS_CI_COMMIT_SHA=abc1234 rel "$S" main)
has "exit=1" "$o" && has "the staging Worker is missing required secret(s): TURNSTILE_SECRET" "$o" && ! has "versions upload" "$(log)" || why="staging: $o // $(log)"
reset '[{"name":"MAIL_KEY","type":"secret_text"}]'
o=$(OP_CLI=$T/bin/op OP_VAULT=client-a OP_SERVICE_ACCOUNT_TOKEN=t WORKERS_CI_BRANCH=fix rel "$S" preview)
has "exit=1" "$o" && has "Preview fix is missing required secret(s): TURNSTILE_SECRET" "$o" || why="$why; preview: $o"
reset 'not json'; o=$(OP_CLI=$T/bin/op OP_VAULT=client-a OP_SERVICE_ACCOUNT_TOKEN=t WORKERS_CI_BRANCH=fix rel "$S" preview)
has "exit=1" "$o" && has "could not read the secret list" "$o" || why="$why; unreadable list passed: $o"
if [ -z "$why" ]; then ok release-secret-check; else fail release-secret-check "$why"; fi

# ---- the Preview name equals the live trigger's shell pipeline, byte for byte
why=""
shslug() { printf %s "$1" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-" | cut -c1-30 | sed "s/^-*//;s/-*$//"; }
for b in "main" "Feat/Login-Redesign" "fix/#42 broken_form!!" "--weird--" "dependabot/npm_and_yarn/astro-6.1.0" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbb" "feature/abcdefghijklmnopqrstuvwxyz0123" "UPPER__case..dots" "café/ünïcode" "x" "a-b-c-d-e-f-g-h-i-j-k-l-m-n-o-"; do
  got=$(node "$R/scripts/agent/release.mjs" slug "$b"); want=$(shslug "$b")
  [ "$got" = "$want" ] || why="$why; [$b] script=$got shell=$want"
done
if [ -z "$why" ]; then ok preview-slug-parity; else fail preview-slug-parity "$why"; fi

# ---- clean-up: ships with a Worker only, inert without the overlay's refs, deletes closed pull requests' Previews
why=""
N=$T/noworker; git init -q -b main "$N"; apply "$N" >/dev/null; [ ! -e "$N/$WF" ] || why="shipped without a wrangler config"
[ -f "$R/$WF" ] && grep -q "  $WF$" "$R/standards.lock" || why="$why; not shipped (or not locked) with a wrangler config"
crons=$(grep -cE '^\s*- cron:' "$R/$WF"); cron=$(sed -nE 's/.*cron: "([^"]+)".*/\1/p' "$R/$WF")
[ "$crons" = 1 ] && [ "$(echo "$cron" | awk '{print $3, $4, $5}')" != "* * *" ] && echo "$cron" | awk '{exit !($5 ~ /^[0-6]$/)}' || why="$why; cron not weekly: $cron"
trig=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("\non:"),y.indexOf("\npermissions:")))' "$R/$WF")
has "types: [closed]" "$trig" && has "workflow_dispatch" "$trig" || why="$why; triggers: $trig"
grep -q 'load-secrets-action@70062d7a876d3eb6334754fa26efd2fbd90c32f2' "$R/$WF" && grep -q 'OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}' "$R/$WF" || why="$why; token not from the pinned 1Password action"
grep -q 'CLOUDFLARE_API_TOKEN: ${{ secrets' "$R/$WF" && why="$why; a Cloudflare token stored in GitHub"
grep -q 'HEAD_REF: ${{ github.event.pull_request.head.ref }}' "$R/$WF" && ! grep -q 'run:.*github.event.pull_request.head.ref' "$R/$WF" || why="$why; head ref interpolated into a script"
# the settings step reads the overlay's refs from pack.json: empty without preview.cleanup (inert), the refs with it
cfg() { (cd "$1" && node -e "$(sed -n "s/^ *run: node -e '\(.*\)' >>.*/\1/p" "$1/$WF" | head -1)"); }
has "token_ref=" "$(cfg "$R")" && [ "$(cfg "$R" | head -1)" = "token_ref=" ] || why="$why; settings without cleanup: $(cfg "$R")"
grep -q "::notice::PR Previews were not cleaned up" "$R/$WF" || why="$why; no inert notice"
O=$T/ov.json; node -e 'const o=require(process.argv[1]);o.preview={cleanup:{token_ref:"op://ci/previews/token",account_ref:"op://ci/previews/account"}};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$O"
grep -q 'ref: ${{ github.event.repository.default_branch }}' "$R/.github/workflows/std-preview-cleanup.yml" || why="$why; cleanup does not check out the default branch"
OVERLAY=$O apply "$R" >/dev/null; [ "$(cfg "$R" | tr '\n' ' ')" = "token_ref=op://ci/previews/token account_ref=op://ci/previews/account " ] || why="$why; settings with cleanup: $(cfg "$R")"
node -e 'const o=require(process.argv[1]);o.preview={cleanup:{token_ref:"ghp_x"}};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$O"
out=$(OVERLAY=$O apply "$T/x" 2>&1) && why="$why; a bad cleanup ref was accepted"
apply "$R" >/dev/null; rm -rf "$R/node_modules" # the clean-up job installs nothing: the current wrangler major
# one closed pull request: its branch's Preview goes; one already gone is fine; staging, and a Preview an open pull
# request still uses (the same slug), are never deleted
echo '{"open":[{"head":{"ref":"still/open","repo":{"full_name":"acme/demo"}}}],"closed":[]}' >"$T/state.json"
node test/stubs/previews-github.mjs "$T/port" "$T/state.json" & STUB=$!
for i in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
export GITHUB_API_URL="http://127.0.0.1:$(cat "$T/port")" GITHUB_REPOSITORY=acme/demo GITHUB_TOKEN=t
reset; o=$(rel "$R" cleanup --pr-branch "Still-Open"); has "exit=0" "$o" && has "keep still-open" "$o" && [ -z "$(log)" ] || why="$why; open PR's preview deleted: $o // $(log)"
reset; o=$(rel "$R" cleanup --pr-branch "Feat/Login"); has "exit=0" "$o" && [ "$(log)" = "-y wrangler@4 preview delete --name feat-login --skip-confirmation" ] || why="$why; pr: $o // $(log)"
reset; echo feat-login >"$T/gone"; o=$(rel "$R" cleanup --pr-branch "Feat/Login"); has "exit=0" "$o" && has "already gone" "$o" || why="$why; gone: $o"
reset; echo feat-login >"$T/broken"; o=$(rel "$R" cleanup --pr-branch "Feat/Login"); has "exit=1" "$o" && has "could not delete Preview feat-login" "$o" || why="$why; error passed: $o"
reset; o=$(rel "$R" cleanup --pr-branch staging); has "exit=0" "$o" && [ -z "$(log)" ] || why="$why; staging deleted: $(log)"
# the sweep: pull requests closed in the last 30 days, except branches an open pull request uses, forks, and staging
now=$(node -e 'console.log(new Date().toISOString())'); old=$(node -e 'console.log(new Date(Date.now()-40*864e5).toISOString())')
cat >"$T/state.json" <<EOF
{"open":[{"head":{"ref":"reopened-work","repo":{"full_name":"acme/demo"}}}],
 "closed":[{"head":{"ref":"done/one","repo":{"full_name":"acme/demo"}},"closed_at":"$now","updated_at":"$now"},
  {"head":{"ref":"reopened-work","repo":{"full_name":"acme/demo"}},"closed_at":"$now","updated_at":"$now"},
  {"head":{"ref":"staging","repo":{"full_name":"acme/demo"}},"closed_at":"$now","updated_at":"$now"},
  {"head":{"ref":"done/two","repo":{"full_name":"someone/fork"}},"closed_at":"$now","updated_at":"$now"},
  {"head":{"ref":"ancient","repo":{"full_name":"acme/demo"}},"closed_at":"$old","updated_at":"$old"}]}
EOF
reset; o=$(rel "$R" cleanup --sweep)
has "exit=0" "$o" && [ "$(log)" = "-y wrangler@4 preview delete --name done-one --skip-confirmation" ] && has "keep reopened-work" "$o" || why="$why; sweep: $o // $(log)"
if [ -z "$why" ]; then ok preview-cleanup; else fail preview-cleanup "$why"; fi
done_cases
