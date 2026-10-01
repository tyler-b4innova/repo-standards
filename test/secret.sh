#!/usr/bin/env bash
# scripts/agent/secret through its real entry point, in a repository the pack was applied to, with a stand-in `op`
# (test/stubs/op-bin/op) that, like the real CLI, needs the service-account token and refuses the desktop app.
# Secret values and the token are random at runtime and never written to any output this file checks.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home FAKE_OP_STATE=$T/op.json FAKE_OP_LOG=$T/op.log CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset OP_SERVICE_ACCOUNT_TOKEN OP_BIOMETRIC_UNLOCK_ENABLED
mkdir -p "$HOME/.config/example-org"
rnd() { node -e "console.log(require('crypto').randomBytes(32).toString('hex').slice(0,$1))"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
TOKEN=ops_$(rnd 40) PASS=$(rnd 24) KEY=$(rnd 20) OTHER=$(rnd 24)
echo "OP_SERVICE_ACCOUNT_TOKEN=$TOKEN" > "$HOME/.config/example-org/op-sa.env"
state() { node -e 'const [t,p,k,o,leak]=process.argv.slice(1);console.log(JSON.stringify({token:t,leak:leak==="leak",vaults:{"Example Vault":{Service:{password:p,"api key":k}},"Other Vault":{Service:{password:o}}}}))' "$TOKEN" "$PASS" "$KEY" "$OTHER" "${1:-}" > "$FAKE_OP_STATE"; }
state; : > "$FAKE_OP_LOG"
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "$1" --version 0.1.0 --target "$2"; }
mkrepo() { local d; d=$(mktemp -d "$T/r.XXXXXX"); git -C "$d" init -q -b main; apply "${1:-$OV}" "$d" >/dev/null && git -C "$d" add -A && git -C "$d" commit -qm init && echo "$d"; }
R=$(mkrepo)
ALL=$T/all.log; : > "$ALL"
V="op://Example Vault/Service/password" K="op://Example Vault/Service/api key" X="op://Other Vault/Service/password"
# sec <args>: runs the script as an agent would, output (both streams) to $OUT and appended to $ALL; status in $?
sec() { OUT=$( (cd "$R" && PATH="$ENGINE/test/stubs/op-bin:$PATH" scripts/agent/secret "$@") </dev/null 2>&1 ); local st=$?; printf '%s\n' "$OUT" >> "$ALL"; return $st; }
calls() { wc -l < "$FAKE_OP_LOG" | tr -d ' '; }

# ---- reads go through the service account, never the desktop app
why=""
sec pipe "$V" -- sh -c 'cat > "$1"' sh "$T/piped" || why="pipe failed: $OUT"
printf %s "$PASS" | cmp -s - "$T/piped" || why="$why; the command did not get exactly the value on stdin"
[ -z "$OUT" ] || why="$why; pipe printed: $OUT"
sec env A="$V" B="$K" -- sh -c 'printf %s "$A:$B" > "$1"; env | grep "^OP_" > "$2" || true' sh "$T/envd" "$T/ops" || why="$why; env failed: $OUT"
[ "$(cat "$T/envd")" = "$PASS:$KEY" ] || why="$why; env did not set both variables"
[ ! -s "$T/ops" ] || why="$why; the command inherited an OP_ variable"
OP_BIOMETRIC_UNLOCK_ENABLED=true OP_SERVICE_ACCOUNT_TOKEN=wrong sec check "$V" || why="$why; check with a stray token or desktop setting in the environment: $OUT"
[ -z "$OUT" ] || why="$why; check printed: $OUT"
sec check "op://Example Vault/Service/nothing"; [ $? -eq 1 ] && ! has "$PASS" "$OUT" || why="$why; a missing field did not fail check cleanly: $OUT"
sec pipe "$V" -- sh -c 'exit 7'; [ $? -eq 7 ] || why="$why; the command's exit status was lost"
# no token file (a cloud session): the variable the org names
mv "$HOME/.config/example-org/op-sa.env" "$T/op-sa.env"
OP_SERVICE_ACCOUNT_TOKEN=$TOKEN sec check "$V" || why="$why; the token variable alone was not used: $OUT"
mv "$T/op-sa.env" "$HOME/.config/example-org/op-sa.env"
if [ -z "$why" ]; then ok secret-reads-through-service-account; else fail secret-reads-through-service-account "$why"; fi

# ---- no verb prints a value
why=""; n=$(calls)
for v in read get item inject "$V"; do sec "$v" "$V"; [ $? -eq 2 ] && ! has "$PASS" "$OUT" || why="$why; '$v' was not refused: $OUT"; done
sec; [ $? -eq 0 ] && has "pipe" "$OUT" || why="$why; no verb did not print usage"
sec pipe "$V"; [ $? -eq 2 ] || why="$why; pipe without -- accepted"
sec pipe "$V" --; [ $? -eq 2 ] || why="$why; pipe without a command accepted"
sec env A="$V"; [ $? -eq 2 ] || why="$why; env without -- accepted"
sec env 'a-b'="$V" -- true; [ $? -eq 2 ] || why="$why; a bad variable name accepted"
sec env OP_SERVICE_ACCOUNT_TOKEN="$V" -- true; [ $? -eq 2 ] || why="$why; env set the token variable"
[ "$(calls)" = "$n" ] || why="$why; refused input still reached op"
# a command that prints what it was given shows the mask, whole or split across writes, on either stream
sec pipe "$V" -- cat; [ "$OUT" = "***" ] || why="$why; cat printed: $OUT"
sec env A="$V" -- sh -c 'printf %s "$A"; echo "$A" >&2'; has "$PASS" "$OUT" && why="$why; echo printed the value"; [ "$(printf %s "$OUT" | grep -c '\*\*\*')" -ge 1 ] || why="$why; echo output not masked: $OUT"
sec env A="$V" -- sh -c 'printf %s "${A%????}"; sleep 0.2; printf %s "${A#"${A%????}"}"'; [ "$OUT" = "***" ] || why="$why; a split write printed: $OUT"
sec list; [ "$OUT" = "Service" ] || why="$why; list printed: $OUT"
sec fields Service --vault "Example Vault"; [ "$OUT" = "password
api key" ] || why="$why; fields printed: $OUT"
if [ -z "$why" ]; then ok secret-never-prints-values; else fail secret-never-prints-values "$why"; fi

# ---- only the org's vaults
why=""; n=$(calls)
refused() { sec "$@"; [ $? -eq 2 ] && ! has "$OTHER" "$OUT" && has "not allowed" "$OUT" || why="$why; '$*' was not refused as another vault: $OUT"; }
refused check "$X"; refused pipe "$X" -- cat; refused env A="$X" -- cat; refused list --vault "Other Vault"; refused fields Service --vault "Other Vault"
for tricky in "op://Example Vault/../Other Vault/Service/password" "op://Example Vault/./Service/password"; do
  sec check "$tricky"; [ $? -eq 2 ] || why="$why; '$tricky' was accepted"
done
[ "$(calls)" = "$n" ] || why="$why; a refused vault still reached op"
sec list --vault "Example Vault" >/dev/null || why="$why; the allowed vault was refused"
if [ -z "$why" ]; then ok secret-vault-allowlist; else fail secret-vault-allowlist "$why"; fi

# ---- the token is never echoed, and a missing one is explained
why=""; n=$(calls)
mv "$HOME/.config/example-org/op-sa.env" "$T/op-sa.env"
sec check "$V"; [ $? -eq 1 ] && has "~/.config/example-org/op-sa.env" "$OUT" && has "OP_SERVICE_ACCOUNT_TOKEN" "$OUT" || why="$why; a missing token file was not explained: $OUT"
echo "SOMETHING_ELSE=x" > "$HOME/.config/example-org/op-sa.env"
sec check "$V"; [ $? -eq 1 ] && has "no OP_SERVICE_ACCOUNT_TOKEN" "$OUT" || why="$why; a token file without the token was not explained: $OUT"
[ "$(calls)" = "$n" ] || why="$why; op ran without a token"
mv "$T/op-sa.env" "$HOME/.config/example-org/op-sa.env"
state leak   # this op puts the token in its error text
sec check "op://Example Vault/Service/nothing"; [ $? -eq 1 ] && has "***" "$OUT" || why="$why; op's error was not scrubbed: $OUT"
sec list --vault "Example Vault" >/dev/null; sec fields Nothing --vault "Example Vault"
state
node -e 'const o=require(process.argv[1]);o.accounts.secrets={kind:"none"};require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/none.json"
NO=$(mkrepo "$T/none.json")
OUT=$( (cd "$NO" && PATH="$ENGINE/test/stubs/op-bin:$PATH" scripts/agent/secret check "$V") 2>&1 ); st=$?; printf '%s\n' "$OUT" >> "$ALL"
[ $st -eq 1 ] && has "configures no secrets vault" "$OUT" || why="$why; a pack without a vault: $st $OUT"
! grep -qF "$TOKEN" "$ALL" || why="$why; the token appeared in output"
! grep -qF "$PASS" "$ALL" && ! grep -qF "$KEY" "$ALL" || why="$why; a secret value appeared in output"
if [ -z "$why" ]; then ok secret-token-never-echoed; else fail secret-token-never-echoed "$why"; fi

# ---- permissions and overlay
why=""
node -e 'const s=require(process.argv[1]+"/.claude/settings.json").permissions;
  const ok=s.allow.includes("Bash(scripts/agent/secret:*)")&&["Bash(op *)","Read(~/.config/**)"].every((d)=>s.deny.includes(d));process.exit(ok?0:1)' "$R" || why="settings: allow the script, keep bare op and ~/.config denied"
grep -q 'pattern=\["op"\],' "$R/.codex/rules/std.rules" && grep -q 'decision="forbidden"' "$R/.codex/rules/std.rules" || why="$why; the Codex rule no longer forbids op"
[ -x "$R/scripts/agent/secret" ] || why="$why; the script is not executable"
out=$(cd "$R" && scripts/agent/setup.sh --check 2>&1) || why="$why; the offline check fails with the script: $out"
bad() { # <jq-ish edit> <needle>: an overlay edit that must be refused naming <needle>
  node -e 'const o=require(process.argv[1]);(new Function("s",process.argv[3]))(o.accounts.secrets);require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$OV" "$T/bad.json" "$1"
  local d; d=$(mktemp -d "$T/b.XXXXXX"); git -C "$d" init -q -b main
  local o; o=$(apply "$T/bad.json" "$d" 2>&1); [ $? -ne 0 ] && has "$2" "$o" || why="$why; '$1' was accepted: $o"
}
bad 's.token_file="relative/op-sa.env"' "accounts.secrets.token_file"
bad 's.vaults="Example Vault"' "accounts.secrets.vaults"
bad 's.token_env="not a name"' "accounts.secrets.token_env"
bad 's.vault_id="ops_ey"+"Jabc"' "looks like a credential"
if [ -z "$why" ]; then ok agent-secret-permissions; else fail agent-secret-permissions "$why"; fi
done_cases
