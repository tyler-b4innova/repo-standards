#!/usr/bin/env bash
# The opt-in cloud-env workflow: shipped only where the overlay names the tool and the repository has a cloud-env.json.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
ENGINE=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gc() { git -c user.name=t -c user.email=t@t "$@"; }
commit() { gc -C "$1" add -A && gc -C "$1" commit -qm "${2:-change}"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
WF=.github/workflows/std-cloud-env.yml
# ov <file> <js over o>: the example overlay, changed
ov() { node -e 'const o=require(process.argv[1]);(new Function("o",process.argv[3]))(o);require("fs").writeFileSync(process.argv[2],JSON.stringify(o))' "$ENGINE/examples/overlay.json" "$1" "$2"; }
apply() { node "$ENGINE/bin/repo-standards.mjs" apply --overlay "$1" --version 0.1.0 --target "$2"; }
# step_run <workflow> <step name>: the step's run script
step_run() { node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n"),i=L.findIndex(l=>l.trim()==="- name: "+process.argv[2]);if(i<0)process.exit(1);for(let j=i+1;j<L.length&&!/^\s*- /.test(L[j]);j++){const m=L[j].match(/^(\s*)run: (.*)$/);if(!m)continue;if(m[2]!=="|"){console.log(m[2]);process.exit(0)}const b=[];for(let k=j+1;k<L.length&&(L[k].trim()===""||L[k].search(/\S/)>m[1].length);k++)b.push(L[k].trim());console.log(b.join("\n").trim());process.exit(0)}process.exit(1)' "$1" "$2"; }
# step_if <workflow> <step name>: the step's if condition
step_if() { node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n"),i=L.findIndex(l=>l.trim()==="- name: "+process.argv[2]);for(let j=i+1;i>=0&&j<L.length&&!/^\s*- /.test(L[j]);j++){const m=L[j].match(/^\s*if: (.*)$/);if(m){console.log(m[1]);process.exit(0)}}process.exit(1)' "$1" "$2"; }

ON=$T/on.json OFF=$T/off.json REF=$T/ref.json
ov "$ON" 'o["cloud_env"]={package:"github:example-org/cloud-tool#v1.2.3",token_ref:null}'
ov "$REF" 'o["cloud_env"]={package:"github:example-org/cloud-tool#v1.2.3",token_ref:"op://ci/cloudflare-edit/credential"}'
ov "$OFF" ''
why=""

# shipped only with both the overlay's tool and the repository's cloud-env.json; removing the file retires it
R=$T/a; mkdir "$R" && git -C "$R" init -q -b main && echo '{}' >"$R/cloud-env.json"
apply "$OFF" "$R" >/dev/null; [ ! -e "$R/$WF" ] || why="$why; shipped without the overlay's cloud_env"
apply "$ON" "$R" >/dev/null; [ -f "$R/$WF" ] && grep -q "  $WF$" "$R/standards.lock" || why="$why; not shipped and locked with both"
commit "$R"; out=$(cd "$R" && scripts/agent/setup.sh --check 2>&1) || why="$why; check failed: $out"
git -C "$R" rm -q cloud-env.json; out=$(apply "$ON" "$R"); [ ! -e "$R/$WF" ] && has "-$WF" "$out" && ! grep -q "$WF" "$R/standards.lock" || why="$why; kept after cloud-env.json went: $out"
R2=$T/b; mkdir "$R2" && git -C "$R2" init -q -b main && apply "$ON" "$R2" >/dev/null; [ ! -e "$R2/$WF" ] || why="$why; shipped without a cloud-env.json"

# the settings step reads the tool and the token reference from pack.json; an unset reference reads empty
R=$T/c; mkdir "$R" && git -C "$R" init -q -b main && echo '{}' >"$R/cloud-env.json" && apply "$ON" "$R" >/dev/null
s1=$(cd "$R" && GITHUB_OUTPUT=$T/o1 bash -e -c "$(step_run "$WF" settings)" && cat "$T/o1")
apply "$REF" "$R" >/dev/null
s2=$(cd "$R" && GITHUB_OUTPUT=$T/o2 bash -e -c "$(step_run "$WF" settings)" && cat "$T/o2")
[ "$s1" = $'package=github:example-org/cloud-tool#v1.2.3\ntoken_ref=' ] || why="$why; settings without a ref: $s1"
[ "$s2" = $'package=github:example-org/cloud-tool#v1.2.3\ntoken_ref=op://ci/cloudflare-edit/credential' ] || why="$why; settings with a ref: $s2"

# pull requests: the offline check, with no token in reach
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "npx $*" >>"$NPX_LOG"; env | grep -E "^(CLOUDFLARE|OP_)" >>"$NPX_LOG"; exit 0\n' >"$T/bin/npx"; chmod +x "$T/bin/npx"
(cd "$R" && NPX_LOG=$T/npx.log PKG=github:example-org/cloud-tool#v1.2.3 PATH="$T/bin:$PATH" bash -e -c "$(step_run "$WF" check)") || why="$why; check step failed"
[ "$(cat "$T/npx.log")" = "npx -y github:example-org/cloud-tool#v1.2.3 apply cloud-env.json --check --offline" ] || why="$why; check ran: $(cat "$T/npx.log")"
has "pull_request" "$(step_if "$R/$WF" check)" || why="$why; check not limited to pull requests"
grep -q 'secrets\.' <(sed -n '/- name: check/,/- name: /p' "$R/$WF" | sed '$d') && why="$why; the check step reads a secret"

# after merge: apply only on a push to the default branch, only with a token reference, the token from 1Password
for s in token apply; do c=$(step_if "$R/$WF" "$s"); has "github.ref_name == github.event.repository.default_branch" "$c" && has "steps.cfg.outputs.token_ref != ''" "$c" || why="$why; $s runs ungated: $c"; done
c=$(step_if "$R/$WF" inert); has "steps.cfg.outputs.token_ref == ''" "$c" || why="$why; no inert notice: $c"
grep -q 'uses: 1password/load-secrets-action@[0-9a-f]\{40\}' "$R/$WF" && grep -q 'OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}' "$R/$WF" \
  && grep -q 'CLOUDFLARE_API_TOKEN: ${{ steps.cfg.outputs.token_ref }}' "$R/$WF" || why="$why; token not read through the pinned 1Password action"
[ "$(step_run "$R/$WF" apply)" = 'npx -y "$PKG" apply cloud-env.json' ] || why="$why; apply step: $(step_run "$R/$WF" apply)"
grep -q 'paths: \[cloud-env.json\]' "$R/$WF" && [ "$(grep -c 'paths: \[cloud-env.json\]' "$R/$WF")" = 2 ] || why="$why; starts on changes other than cloud-env.json"

# the overlay's cloud_env is validated before anything is written
for bad in 'o["cloud_env"]={package:"github:x/y",token_ref:"vault/item"}' 'o["cloud_env"]={package:"",token_ref:null}' 'o["cloud_env"]={package:"github:x/y",vault:"ci"}' 'o["cloud_env"]={package:"github:x/y",token_ref:"ops_eyJhbGciOi"}'; do
  ov "$T/bad.json" "$bad"; out=$(node bin/repo-standards.mjs block --overlay "$T/bad.json" --profile internal 2>&1) && why="$why; accepted $bad"
  has "cloud_env" "$out" || why="$why; $bad: $out"
done

if [ -z "$why" ]; then ok cloud-env-apply-opt-in; else fail cloud-env-apply-opt-in "$why"; fi
done_cases
