#!/usr/bin/env bash
# Full local gate through a consumer fixture's real Wrangler Worker and local KV. No owned mocks.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME ROLLBACK_BASE ROLLBACK_DRAFT GH_TOKEN GITHUB_TOKEN CF_API_TOKEN CLOUDFLARE_API_TOKEN
export NPM_CONFIG_CACHE=$(npm config get cache)
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD T=$(mktemp -d)
export LOCAL_FIXTURE_PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
PID=""
trap '[ -z "$PID" ] || kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo; mkdir "$R"
git -C "$R" init -q -b main
cp test/fixtures/local-worker/* "$R/"
printf 'node_modules/\n.wrangler/\n.dev.vars\n.gate-order\n.env*\n.credential-build.mjs\n' > "$R/.gitignore"
printf 'LOCAL_VALUE=dummy\n' > "$R/.dev.vars"
# CI repeatedly exceeded the suite budget on registry revalidation in this fixture.
# Keep real installs; reuse cached third-party packages and avoid repeating npm's remote audit.
printf 'prefer-offline=true\naudit=false\n' > "$R/.npmrc"
# Build neutral rejected samples at runtime; no org/account ids in the source fixture.
node - "$R" <<'JS'
const fs=require('fs'),d=process.argv[2];
fs.writeFileSync(d+'/standards.json',JSON.stringify({staging:false}));
fs.writeFileSync(d+'/wrangler.json',JSON.stringify({name:'local-gate-fixture',main:'worker.mjs',compatibility_date:'2026-01-01',build:{command:'node credential-probe.mjs'},kv_namespaces:[{binding:'DATA',id:'0'.repeat(32)}],env:{selected:{kv_namespaces:[{binding:'DATA',id:'0'.repeat(32)}]}}}));
JS
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.11 >/dev/null
printf '#!/usr/bin/env bash\nnode record.mjs repo || exit 1\n[ -z "${FAIL_REPO:-}" ]\n' > "$R/scripts/agent/gate.local.sh"
git -C "$R" add -A && git -C "$R" commit -qm fixture
base_sha=$(git -C "$R" rev-parse HEAD)
printf 'feature change\n' > "$R/feature.txt"
git -C "$R" add feature.txt && git -C "$R" commit -qm feature
mkdir -p "$T/home/.wrangler/config" "$T/home/Library/Preferences/.wrangler/config"
printf 'oauth_token = "dummy"\n' > "$T/home/.wrangler/config/default.toml"
cp "$T/home/.wrangler/config/default.toml" "$T/home/Library/Preferences/.wrangler/config/default.toml"
# Download only a third-party tool once; every gate still verifies the engine's pinned checksum.
platform=$(node -p 'process.platform+"_"+process.arch')
export GATE_GITLEAKS_ARCHIVE=$T/gitleaks.tgz
curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_${platform}.tar.gz" -o "$GATE_GITLEAKS_ARCHIVE" || exit 1
run() { local name=$1; shift; rm -f "$R/.gate-order"; (cd "$R" && env HOME="$T/home" USERPROFILE="$T/home" GATE_LOCAL_WAIT_S=${GATE_LOCAL_WAIT_S:-20} node scripts/agent/gate.mjs local "$@") > "$T/$name.log" 2>&1; }
jset() { node -e 'const fs=require("fs"),f=process.argv[1],o=JSON.parse(fs.readFileSync(f));new Function("o",process.argv[2])(o);fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n")' "$R/standards.json" "$1"; }
has() { grep -qF -e "$1" "$T/$2.log"; } # -e: a needle may start with a dash
closed() { node - "${1:-8787}" <<'JS'
const s=require('net').createConnection({host:'127.0.0.1',port:Number(process.argv[2])});
s.once('connect',()=>{s.destroy();process.exit(1)});
s.once('error',()=>process.exit(0));s.setTimeout(500,()=>{s.destroy();process.exit(1)});
JS
}
# Feature-only checkouts cannot silently reduce instruction/secret checks to HEAD..HEAD.
git -C "$R" branch -m feature
run no-base; nb=$?
if [ "$nb" -ne 0 ] && has 'cannot resolve a comparison base' no-base && ! has 'instructions PASS' no-base; then ok gate-local-base-required
else fail gate-local-base-required "no-base=$nb"; cat "$T/no-base.log"; fi
(cd "$R" && node scripts/agent/gate.mjs local --base missing-ref) > "$T/bad-base.log" 2>&1; bb=$?
if [ "$bb" -ne 0 ] && has 'cannot resolve a comparison base from missing-ref' bad-base; then ok gate-local-base-required
else fail gate-local-base-required "missing explicit base=$bb"; fi
run head-base --base HEAD; hb=$?
if [ "$hb" -ne 0 ] && has 'nothing to compare: HEAD has no commits beyond HEAD; run from a feature branch or pass --base' head-base && ! has 'local: setup' head-base; then ok gate-local-base-required
else fail gate-local-base-required "HEAD base=$hb"; fi
# Both an equal automatic ref and one containing HEAD must fail before any child.
head_sha=$(git -C "$R" rev-parse HEAD)
future_sha=$(printf 'later base\n' | git -C "$R" commit-tree 'HEAD^{tree}' -p HEAD)
for ref_sha in "$head_sha" "$future_sha"; do
  git -C "$R" update-ref refs/remotes/origin/main "$ref_sha"
  run empty-base; eb=$?
  if [ "$eb" -ne 0 ] && has 'nothing to compare: HEAD has no commits beyond origin/main; run from a feature branch or pass --base' empty-base && ! has 'local: setup' empty-base; then ok gate-local-base-required
  else fail gate-local-base-required "automatic base=$eb"; fi
done
# The default run has a distinct base commit plus a feature commit.
git -C "$R" update-ref refs/remotes/origin/main "$base_sha"
run default; d=$?
# The clear per-step start/result output proves ordering through the orchestration entry point.
order=$(sed -n 's/^local: \(.*\) starting$/\1/p' "$T/default.log" | paste -sd, -)
summary=$(tail -1 "$T/default.log")
sha=$(git -C "$R" rev-parse HEAD)
gp=$(git -C "$R" rev-parse --git-path std-local-gate); case "$gp" in /*) ;; *) gp="$R/$gp" ;; esac
[ "$d" -ne 0 ] || [ "$(cat "$gp" 2>/dev/null)" = "$sha" ] || { fail gate-local-runs-ci-steps "a passing local gate left no pass record for $sha"; }
if [ "$d" -eq 0 ] && [ "$order" = 'setup --check,instructions,secrets,syntax,install,typecheck,build,gate.local.sh,e2e' ] && has "local gate $sha:" default && has 'worker=PASS; e2e=PASS' default && has 'standards ok:' default && has 'secrets: gitleaks git' default && has 'syntax: scripts and workflows parse' default; then ok gate-local-runs-ci-steps
else fail gate-local-runs-ci-steps "exit=$d order=$order summary=$summary"; cat "$T/default.log"; fi
if [ "$d" -eq 0 ] && has 'wrangler dev --ip 127.0.0.1 --port 8787 --local --config' default && has 'worker stopped' default && closed; then ok gate-local-starts-and-stops-worker
else fail gate-local-starts-and-stops-worker "default=$d or Worker leaked"; fi
# Confirm the fallback is necessary against real Wrangler 4.148, including Worker
# dotenv bindings without .dev.vars masking them. The gate must stop both entry points.
mv "$R/.dev.vars" "$T/dev.vars"
for file in .env .env.local .env.selected; do
  printf 'CLOUDFLARE_API_TOKEN=dummy-dotenv\n' > "$R/$file"
  node - "$R" "$LOCAL_FIXTURE_PORT" "$file" > "$T/dotenv-control.log" 2>&1 <<'JS'
const assert = require('node:assert/strict'), {spawn} = require('node:child_process');
const [cwd, port, file] = process.argv.slice(2);
assert.equal(require(cwd+'/node_modules/wrangler/package.json').version, '4.148.0');
const args = ['dev', '--local', '--ip', '127.0.0.1', '--port', port, '--config', 'wrangler.json'];
if (file === '.env.selected') args.push('--env', 'selected');
const child = spawn(cwd+'/node_modules/.bin/wrangler', args, {cwd, detached:true, stdio:'inherit', env:{...process.env, PROBE_UNSAFE:'1', WRANGLER_SEND_METRICS:'false', CLOUDFLARE_API_TOKEN:'', CLOUDFLARE_API_KEY:'', CLOUDFLARE_EMAIL:'', CLOUDFLARE_ACCOUNT_ID:''}});
(async () => {
  try {
    let report;
    const deadline = Date.now()+20000;
    while (Date.now()<deadline && child.exitCode === null) {
      try { report = await (await fetch(`http://127.0.0.1:${port}/credentials`, {signal:AbortSignal.timeout(500)})).json(); break; } catch {}
      await new Promise(r=>setTimeout(r,100));
    }
    assert.equal(report?.build.credentials[0], 'dummy-dotenv', `${file} overrides empty token in build.command`);
    assert.equal(report?.worker[0], 'dummy-dotenv', `${file} supplies token to dev Worker`);
    console.log(`${file}: real Wrangler build.command and dev Worker both read token despite empty process env`);
  } finally {
    try { process.kill(-child.pid, 'SIGTERM'); } catch {}
    await new Promise(r=>setTimeout(r,300));
    try { process.kill(-child.pid, 'SIGKILL'); } catch {}
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
JS
  control=$?
  rm -f "$R/.credential-build.mjs"
  if [ "$file" = .env.selected ]; then jset 'o.local={command:"wrangler dev --env selected --port 8787",url:"http://127.0.0.1:8787",ready:"/"}'; fi
  run dotenv; denied=$?
  if [ "$control" -eq 0 ] && [ "$denied" -ne 0 ] && has "credential-bearing ./$file refused" dotenv && ! has 'local: setup' dotenv && [ ! -f "$R/.credential-build.mjs" ] && closed "$LOCAL_FIXTURE_PORT"; then ok gate-local-no-secrets
  else fail gate-local-no-secrets "$file control=$control denied=$denied; build.command/Worker must be unreachable"; cat "$T/dotenv-control.log" "$T/dotenv.log"; fi
  rm "$R/$file"
done
jset 'delete o.local'
mv "$T/dev.vars" "$R/.dev.vars"
FAIL_E2E=1 run failing; f=$?
if [ "$d" -eq 0 ] && has 'HTTP entry point + local KV' default && [ "$f" -ne 0 ] && has 'deliberately failing e2e' failing && has 'e2e=FAIL' failing && closed; then ok gate-local-e2e-against-local-url
else fail gate-local-e2e-against-local-url "default=$d failing=$f or Worker leaked"; fi
# Custom local command, readiness path and port. Inherited preview context must not escape local.
jset 'o.local={command:"wrangler dev --ip 127.0.0.1 --port "+process.env.LOCAL_FIXTURE_PORT,url:"http://127.0.0.1:"+process.env.LOCAL_FIXTURE_PORT,ready:"/health"}'
mkdir -p "$T/oauth/config/default"
printf 'oauth_token = "dummy"\n' > "$T/oauth/config/default.toml"
# A selected config with remote bindings must fail before Worker startup, even with --local.
node - "$R" <<'JS'
const fs=require('fs'),d=process.argv[2],cfg=JSON.parse(fs.readFileSync(d+'/wrangler.json'));
cfg.kv_namespaces[0].remote=true;
fs.writeFileSync(d+'/remote.jsonc','// selected config\n'+JSON.stringify(cfg));
JS
jset 'o.local.command="wrangler dev --config remote.jsonc --port "+process.env.LOCAL_FIXTURE_PORT'
run remote-binding; rb=$?
if [ "$rb" -ne 0 ] && has 'remote: true binding refused' remote-binding && ! has 'local: worker starting:' remote-binding && closed "$LOCAL_FIXTURE_PORT"; then ok gate-local-remote-refused
else fail gate-local-remote-refused "remote-binding=$rb"; cat "$T/remote-binding.log"; fi
rm "$R/remote.jsonc"
bad=0
for command in 'wrangler dev --remote' 'wrangler dev -r' 'wrangler dev --local=false' 'wrangler dev --local false' 'wrangler dev --x-remote-bindings' 'wrangler deploy' 'npm run dev' 'npx wrangler dev' 'wrangler dev; echo unsafe'; do
  LOCAL_BAD_COMMAND="$command" jset 'o.local.command=process.env.LOCAL_BAD_COMMAND'
  run remote-command; rc=$?
  [ "$rc" -ne 0 ] && ! has 'local: worker starting:' remote-command || bad=$((bad + 1))
done
if [ "$bad" -eq 0 ]; then ok gate-local-remote-refused; else fail gate-local-remote-refused "$bad unsafe commands accepted"; fi
jset 'o.local={command:"wrangler dev --ip 127.0.0.1 --port "+process.env.LOCAL_FIXTURE_PORT,url:"http://127.0.0.1:"+process.env.LOCAL_FIXTURE_PORT,ready:"/health"}'
FAIL_REPO=1 run repo; rc=$?
[ ! -e "$gp" ] || fail gate-local-runs-ci-steps "a failing local gate left a stale pass record"
if [ "$rc" -ne 0 ] && has 'gate.local.sh=FAIL; worker=not run; e2e=not run' repo && closed "$LOCAL_FIXTURE_PORT"; then ok gate-local-runs-ci-steps; else fail gate-local-runs-ci-steps 'failed repo check ran tail'; fi
# A real Worker that redirects readiness must time out without following a remote URL.
jset 'o.local={command:"wrangler dev --ip 127.0.0.1 --port "+process.env.LOCAL_FIXTURE_PORT,url:"http://127.0.0.1:"+process.env.LOCAL_FIXTURE_PORT,ready:"/redirect"}'
GATE_LOCAL_WAIT_S=4 run timeout; to=$?
if [ "$to" -ne 0 ] && has 'worker=FAIL; e2e=not run' timeout && closed "$LOCAL_FIXTURE_PORT"; then ok gate-local-starts-and-stops-worker
else fail gate-local-starts-and-stops-worker "readiness timeout=$to or Worker leaked"; fi
# Interrupt a live real Worker during e2e; TCP occupancy must refuse even a hanging readiness path.
jset 'o.local={command:"wrangler dev --ip 127.0.0.1 --port "+process.env.LOCAL_FIXTURE_PORT,url:"http://127.0.0.1:"+process.env.LOCAL_FIXTURE_PORT,ready:"/health"}'
rm -f "$R/.gate-order"
# Reuse the custom Worker run for credential isolation, explicit-base and SIGHUP proofs.
# CI exceeded its five-minute budget when these each launched another full gate.
jset 'o.local.command += " --env selected"'
git -C "$R" update-ref -d refs/remotes/origin/main
(cd "$R" && exec env HOME="$T/home" USERPROFILE="$T/home" LINGER=1 GATE_LOCAL_WAIT_S=20 GATE_PREVIEW_URL=https://preview.example.com BASE_URL=https://example.com GITHUB_EVENT_PATH=/nonexistent CLOUDFLARE_API_TOKEN=dummy CLOUDFLARE_ACCOUNT_ID=dummy WRANGLER_HOME="$T/oauth" XDG_CONFIG_HOME="$T/oauth" node scripts/agent/gate.mjs local --base "$base_sha") > "$T/interrupted.log" 2>&1 & PID=$!
ready=0
for i in $(seq 1 400); do
  if has 'same e2e suite: HTTP entry point + local KV' interrupted; then ready=1; break; fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.1
done
git -C "$R" update-ref refs/remotes/origin/main "$base_sha"
if [ "$ready" -eq 1 ] && has "local KV at http://127.0.0.1:$LOCAL_FIXTURE_PORT" interrupted; then ok gate-local-no-secrets
else fail gate-local-no-secrets "custom Worker did not reach its credential and HTTP assertions"; cat "$T/interrupted.log"; fi
if [ "$ready" -eq 1 ]; then jset 'o.local.ready="/hang"'; run occupied; busy=$?; else busy=0; fi
kill -HUP "$PID" 2>/dev/null || true
wait "$PID"; interrupted=$?; PID=""
if [ "$ready" -eq 1 ] && [ "$busy" -ne 0 ] && has 'address already in use' occupied && [ "$interrupted" -eq 129 ] && has 'worker stopped' interrupted && closed "$LOCAL_FIXTURE_PORT"; then ok gate-local-hup-cleanup
else fail gate-local-hup-cleanup "ready=$ready occupied=$busy interrupt=$interrupted or Worker leaked"; cat "$T/interrupted.log"; fi
# local:false skips the server, never the suite. Apply keeps the repo-owned opt-out.
jset 'o.local=false'
node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.11 >/dev/null
echo stray >"$R/untracked-source.txt"; git -C "$R" config status.showUntrackedFiles no
NO_WORKER=1 run optout; o=$?
[ ! -e "$gp" ] || fail gate-local-runs-ci-steps "a pass with a non-ignored untracked file left a pass record"
rm -f "$R/untracked-source.txt"; git -C "$R" config --unset status.showUntrackedFiles
if [ "$o" -eq 0 ] && has 'worker=SKIP (local: false); e2e=PASS' optout && has 'same e2e suite: no Worker requested' optout; then ok gate-local-opt-out
else fail gate-local-opt-out "optout=$o"; cat "$T/optout.log"; fi
# The offline check validates shape and origin, including escaped readiness URLs.
bad=0
for config in 'null' 'true' '[]' '{command:"true",url:"https://example.com",ready:"/"}' '{command:"true",url:"http://127.0.0.1",ready:"//example.com"}' '{command:"true",url:"http://127.0.0.1",ready:"/\\example.com"}' '{command:"true",url:"http://127.0.0.1",ready:"/",extra:1}' '{command:"",url:"http://127.0.0.1",ready:"/"}'; do
  jset "o.local=$config"
  (cd "$R" && CI=true scripts/agent/setup.sh --check) > "$T/invalid.log" 2>&1; status=$?
  [ "$status" -ne 0 ] && has 'standards.json local must be' invalid || bad=$((bad + 1))
done
jset 'o.local=false'
if [ "$bad" -eq 0 ]; then ok gate-local-opt-out; else fail gate-local-opt-out "$bad malformed configs accepted"; fi
# The local instruction guard covers uncommitted edits, without a GitHub call.
printf '\nchanged instruction\n' >> "$R/AGENTS.md"
NO_WORKER=1 run instructions; ic=$?
if [ "$ic" -ne 0 ] && has 'instructions=FAIL; secrets=not run' instructions; then ok gate-local-runs-ci-steps
else fail gate-local-runs-ci-steps "instruction edit=$ic"; cat "$T/instructions.log"; fi
# A repository with no Worker (no root Wrangler config, no release_workers) needs no local setting: the worker step skips
# and the pass record pr.sh ready reads (the head sha in the git dir's std-local-gate) is written
N=$T/nowork; mkdir "$N"; git -C "$N" init -q -b main
printf 'node_modules/\n.gate-order\n' >"$N/.gitignore"; printf '{"e2e":false}\n' >"$N/standards.json"
node bin/repo-standards.mjs apply --target "$N" --overlay examples/overlay.json --version 0.7.11 >/dev/null
printf '#!/usr/bin/env bash\nexit 0\n' >"$N/scripts/agent/gate.local.sh"
git -C "$N" add -A && git -C "$N" commit -qm base; git -C "$N" checkout -q -b feature; printf 'docs\n' >"$N/note.txt"; git -C "$N" add note.txt && git -C "$N" commit -qm feature
(cd "$N" && env HOME="$T/home" USERPROFILE="$T/home" node scripts/agent/gate.mjs local --base main) >"$T/nowork.log" 2>&1; nw=$?
rec=$(git -C "$N" rev-parse --git-path std-local-gate); [ "${rec#/}" = "$rec" ] && rec=$N/$rec
if [ "$nw" -eq 0 ] && grep -qF 'worker=SKIP (no Worker)' "$T/nowork.log" && [ "$(cat "$rec" 2>/dev/null)" = "$(git -C "$N" rev-parse HEAD)" ]; then ok gate-local-no-worker
else fail gate-local-no-worker "exit=$nw"; tail -5 "$T/nowork.log"; fi
# gate-local-skip-not-pass: a step that ran nothing is SKIP with its own reason, in the progress line and the summary, and
# the run still passes and writes the record; a step that ran stays PASS (the real-suite run above)
skipsum=$(tail -1 "$T/nowork.log")
sk_ok=1
for want in 'install=SKIP (no package.json)' 'typecheck=SKIP (no typecheck script in package.json)' 'build=SKIP (no build script in package.json)' 'e2e=SKIP (standards.json sets "e2e": false)' 'setup --check=PASS; instructions=PASS; secrets=PASS; syntax=PASS' 'gate.local.sh=PASS'; do
  case "$skipsum" in *"$want"*) ;; *) sk_ok=0; echo "summary lacks: $want" ;; esac
done
for step in install typecheck build e2e; do grep -qE "^local: $step PASS" "$T/nowork.log" && { sk_ok=0; echo "progress says $step PASS"; }; done
grep -qF 'local: e2e SKIP (standards.json sets "e2e": false)' "$T/nowork.log" || { sk_ok=0; echo "no e2e SKIP progress line"; }
# a package.json with no scripts: install ran (PASS), typecheck and build did not
printf '{"name":"empty","private":true}\n' >"$N/package.json"; git -C "$N" add package.json && git -C "$N" commit -qm package
(cd "$N" && env HOME="$T/home" USERPROFILE="$T/home" node scripts/agent/gate.mjs local --base main) >"$T/noscripts.log" 2>&1; nsx=$?
nssum=$(tail -1 "$T/noscripts.log")
for want in 'install=PASS' 'typecheck=SKIP (no typecheck script in package.json)' 'build=SKIP (no build script in package.json)'; do
  case "$nssum" in *"$want"*) ;; *) sk_ok=0; echo "package.json summary lacks: $want" ;; esac
done
# the real-suite run: every step that ran says PASS and nothing but nothing-to-run says SKIP
realsum=$(tail -1 "$T/default.log")
case "$realsum" in *'install=PASS; typecheck=PASS; build=PASS; gate.local.sh=PASS; worker=PASS; e2e=PASS'*) ;; *) sk_ok=0; echo "real-suite summary: $realsum" ;; esac
if [ "$nw" -eq 0 ] && [ "$nsx" -eq 0 ] && [ "$sk_ok" -eq 1 ] && [ "$(cat "$rec" 2>/dev/null)" = "$(git -C "$N" rev-parse HEAD)" ]; then ok gate-local-skip-not-pass
else fail gate-local-skip-not-pass "no-package.json run=$nw summary: $skipsum | package.json without scripts run=$nsx summary: $nssum"; fi
# gate-local-trusts-checkout: hide the host's trusted HOME from children and disable a runner's system-wide trust.
# The first run has no explicit global config, so the gate must supply trust itself; the second proves a caller's
# named global config still reaches the stages. Both preserve command-scope config (for example a credential helper).
# A build reaches the real rollback clone; a linked worktree needs its private git dir trusted as well.
printf '{"name":"empty","private":true,"scripts":{"build":"node -e 0"}}\n' >"$N/package.json"
OWN=$T/ownerhome; mkdir "$OWN"; printf '[safe]\n\tdirectory = *\n[gatetest]\n\tglobal = kept\n' >"$OWN/.gitconfig"
cat >"$N/scripts/agent/gate.local.sh" <<'SH'
#!/usr/bin/env bash
[ "$(git config --get gatetest.marker)" = kept ] || { echo "caller git config entry lost"; exit 1; }
if [ "${EXPECT_GLOBAL_CONFIG:-}" = 1 ]; then
  [ "$(git config --get gatetest.global)" = kept ] || { echo "caller global git config lost"; exit 1; }
fi
git rev-parse --git-dir >/dev/null
SH
git -C "$N" add -A && git -C "$N" commit -qm "gate.local.sh reads the caller git config"
scrubbed=$(env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_COUNT -u XDG_CONFIG_HOME HOME="$T/scrubbed" GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git -C "$N" rev-parse --git-dir 2>&1)
trust() { local name=$1 repo=$2; shift 2; (cd "$repo" && env -u GIT_CONFIG_GLOBAL -u XDG_CONFIG_HOME HOME="$OWN" USERPROFILE="$OWN" GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gatetest.marker GIT_CONFIG_VALUE_0=kept "$@" node scripts/agent/gate.mjs local --base main) >"$T/$name.log" 2>&1; }
trust trust "$N"; tc=$?
trust trust-global "$N" GIT_CONFIG_GLOBAL="$OWN/.gitconfig" EXPECT_GLOBAL_CONFIG=1; tg=$?
L=$T/linked; git -C "$N" worktree add --detach -q "$L" HEAD
trust trust-linked "$L"; tl=$?
tsum=$(tail -1 "$T/trust.log"); gsum=$(tail -1 "$T/trust-global.log"); lsum=$(tail -1 "$T/trust-linked.log")
case "$scrubbed" in *'dubious ownership'*) knob=1 ;; *) knob=0 ;; esac
if [ "$knob" -eq 1 ] && [ "$tc" -eq 0 ] && [ "$tg" -eq 0 ] && [ "$tl" -eq 0 ] && has 'setup --check=PASS' trust && has 'build=PASS' trust && has 'gate.local.sh=PASS' trust-global && has 'build=PASS; gate.local.sh=PASS' trust-linked && ! has 'dubious ownership' trust && ! has 'dubious ownership' trust-linked; then ok gate-local-trusts-checkout
else fail gate-local-trusts-checkout "scrubbed-home git (knob works: $knob): $scrubbed | exit=$tc summary: $tsum | caller global exit=$tg summary: $gsum | linked worktree exit=$tl summary: $lsum"; grep -m3 -i 'dubious\|caller.*git' "$T/trust.log" "$T/trust-global.log" "$T/trust-linked.log"; fi
printf '\nLocal gate evidence (real Worker):\n'; tail -1 "$T/default.log"; tail -1 "$T/failing.log"; tail -1 "$T/optout.log"
printf 'Local gate evidence (steps that ran nothing):\n'; echo "$skipsum"; echo "$nssum"
# gitleaks-download-retry: a 504, then a body cut short, then the pinned archive: each failed attempt is logged and retried,
# and the real secrets entry point completes the scan with no temp directory left
if node -e 'process.exit(["linux", "darwin"].includes(process.platform) && ["x64", "arm64"].includes(process.arch) ? 0 : 1)'; then
  rt=$T/retry-tmp; mkdir -p "$rt"
  node -e 'const fs = require("fs"), http = require("http"), body = fs.readFileSync(process.argv[1]); let n = 0;
    http.createServer((q, r) => { n++;
      if (n === 1) { r.writeHead(504); r.end(); return; }
      r.writeHead(200, { "Content-Length": body.length });
      if (n === 2) { r.write(body.subarray(0, body.length >> 1)); setTimeout(() => r.destroy(), 50); return; }
      r.end(body);
    }).listen(0, "127.0.0.1", function () { fs.writeFileSync(process.argv[2], String(this.address().port)); });' "$GATE_GITLEAKS_ARCHIVE" "$T/retry.port" & retry_srv=$!
  for i in $(seq 100); do [ -s "$T/retry.port" ] && break; sleep 0.1; done
  (cd "$R" && exec env -u GITHUB_EVENT_PATH -u GITHUB_EVENT_NAME -u GATE_GITLEAKS_ARCHIVE -u GATE_GITLEAKS_CACHE GATE_GITLEAKS_BASE="http://127.0.0.1:$(cat "$T/retry.port")" GATE_GITLEAKS_BACKOFF_MS=0 TMPDIR="$rt" node scripts/agent/gate.mjs secrets) > "$T/retry.log" 2>&1; rx=$?
  kill "$retry_srv" 2>/dev/null; wait "$retry_srv" 2>/dev/null
  if [ "$rx" -eq 0 ] && has "download 1 of 3" retry && has "-> 504" retry && has "download 2 of 3" retry && has "-> 200, body:" retry && has "download 3 of 3" retry && has "-> 200, verified" retry && has "no leaks found" retry && [ -z "$(ls -A "$rt")" ]; then ok gitleaks-download-retry
  else fail gitleaks-download-retry "exit=$rx dir=[$(ls -A "$rt")]: $(cat "$T/retry.log")"; fi
else echo "skip gitleaks-download-retry (no pinned gitleaks build for this platform)"; fi
# gitleaks-temp-dir-removed: the secret scan's temp directory is gone after a success, after a checksum failure and after
# a SIGTERM during the download (a signal ends Node without its exit event, so the handler must route it through exit)
if node -e 'process.exit(["linux", "darwin"].includes(process.platform) && ["x64", "arm64"].includes(process.arch) ? 0 : 1)'; then
  tt=$T/secrets-tmp; mkdir -p "$tt"; left() { ls -A "$tt" | wc -l | tr -d ' '; }
  (cd "$R" && exec env -u GITHUB_EVENT_PATH -u GITHUB_EVENT_NAME GATE_GITLEAKS_ARCHIVE="$GATE_GITLEAKS_ARCHIVE" TMPDIR="$tt" node scripts/agent/gate.mjs secrets) > "$T/tmp-ok.log" 2>&1; x1=$?; l1=$(left)
  printf 'not an archive\n' > "$T/junk.tgz"
  (cd "$R" && exec env -u GITHUB_EVENT_PATH -u GITHUB_EVENT_NAME GATE_GITLEAKS_ARCHIVE="$T/junk.tgz" TMPDIR="$tt" node scripts/agent/gate.mjs secrets) > "$T/tmp-bad.log" 2>&1; x2=$?; l2=$(left)
  node -e 'require("http").createServer(() => {}).listen(0, "127.0.0.1", function () { require("fs").writeFileSync(process.argv[1], String(this.address().port)) })' "$T/hang.port" & hang=$!
  for i in $(seq 100); do [ -s "$T/hang.port" ] && break; sleep 0.1; done
  (cd "$R" && exec env -u GITHUB_EVENT_PATH -u GITHUB_EVENT_NAME -u GATE_GITLEAKS_ARCHIVE GATE_GITLEAKS_BASE="http://127.0.0.1:$(cat "$T/hang.port")" TMPDIR="$tt" node scripts/agent/gate.mjs secrets) > "$T/tmp-signal.log" 2>&1 & run_pid=$!
  for i in $(seq 100); do ls "$tt"/gitleaks-* >/dev/null 2>&1 && break; sleep 0.1; done; started=$(left)
  kill -TERM "$run_pid" 2>/dev/null; wait "$run_pid"; x3=$?; l3=$(left)
  kill "$hang" 2>/dev/null; wait "$hang" 2>/dev/null
  if [ "$x1" -eq 0 ] && has 'no leaks found' tmp-ok && [ "$l1" -eq 0 ] && [ "$x2" -eq 1 ] && has 'checksum mismatch' tmp-bad && [ "$l2" -eq 0 ] && [ "$started" -eq 1 ] && [ "$x3" -eq 143 ] && [ "$l3" -eq 0 ]; then ok gitleaks-temp-dir-removed
  else fail gitleaks-temp-dir-removed "success=$x1 left=$l1 mismatch=$x2 left=$l2 started=$started signal=$x3 left=$l3"; fi
else echo "skip gitleaks-temp-dir-removed (no pinned gitleaks build for this platform)"; fi
# gitleaks-cache-hit: the verified archive in GATE_GITLEAKS_CACHE (the workflow restores it) is used with no download; the
# base is a port nothing listens on, so a download would fail. The pinned checksum still applies (the real archive passes).
gc=$T/gl-cache; mkdir -p "$gc" && cp "$GATE_GITLEAKS_ARCHIVE" "$gc/gitleaks_8.30.1_${platform}.tar.gz"
dead=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
(cd "$R" && env -u GATE_GITLEAKS_ARCHIVE -u GITHUB_EVENT_PATH -u GITHUB_EVENT_NAME GATE_GITLEAKS_CACHE="$gc" GATE_GITLEAKS_BASE="http://127.0.0.1:$dead" node scripts/agent/gate.mjs secrets) > "$T/gl-cache.log" 2>&1; gx=$?
if [ "$gx" -eq 0 ] && has 'from the cache' gl-cache && has 'no leaks found' gl-cache && ! has 'download 1 of' gl-cache; then ok gitleaks-cache-hit
else fail gitleaks-cache-hit "exit=$gx: $(tail -5 "$T/gl-cache.log")"; fi
done_cases
