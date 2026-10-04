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
# step_key <workflow> <step name> <key>: that key's value in the step (if, uses, args)
step_key() { node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").split("\n"),i=L.findIndex(l=>l.trim()==="- name: "+process.argv[2]);for(let j=i+1;i>=0&&j<L.length&&!/^\s*- /.test(L[j]);j++){const m=L[j].match(new RegExp("^\\s*"+process.argv[3]+": (.*)$"));if(m){console.log(m[1]);process.exit(0)}}process.exit(1)' "$1" "$2" "$3"; }
step_if() { step_key "$1" "$2" if; }

ON=$T/on.json OFF=$T/off.json REF=$T/ref.json ACT=example-org/cloud-tool@v1.2.3
ov "$ON" 'o["cloud_env"]={action:"example-org/cloud-tool@v1.2.3",token_ref:null}'
ov "$REF" 'o["cloud_env"]={action:"example-org/cloud-tool@v1.2.3",token_ref:"op://ci/cloudflare-edit/credential"}'
ov "$OFF" ''
why=""

# shipped only with both the overlay's action and the repository's cloud-env.json; removing the file retires it
R=$T/a; mkdir "$R" && git -C "$R" init -q -b main && echo '{}' >"$R/cloud-env.json"
apply "$OFF" "$R" >/dev/null; [ ! -e "$R/$WF" ] || why="$why; shipped without the overlay's cloud_env"
apply "$ON" "$R" >/dev/null; [ -f "$R/$WF" ] && grep -q "  $WF$" "$R/standards.lock" || why="$why; not shipped and locked with both"
commit "$R"; out=$(cd "$R" && scripts/agent/setup.sh --check 2>&1) || why="$why; check failed: $out"
git -C "$R" rm -q cloud-env.json; out=$(apply "$ON" "$R"); [ ! -e "$R/$WF" ] && has "-$WF" "$out" && ! grep -q "$WF" "$R/standards.lock" || why="$why; kept after cloud-env.json went: $out"
R2=$T/b; mkdir "$R2" && git -C "$R2" init -q -b main && apply "$ON" "$R2" >/dev/null; [ ! -e "$R2/$WF" ] || why="$why; shipped without a cloud-env.json"

# the settings step reads the token reference from pack.json; an unset reference reads empty
R=$T/c; mkdir "$R" && git -C "$R" init -q -b main && echo '{}' >"$R/cloud-env.json" && apply "$ON" "$R" >/dev/null
s1=$(cd "$R" && GITHUB_OUTPUT=$T/o1 bash -e -c "$(step_run "$WF" settings)" && cat "$T/o1")
apply "$REF" "$R" >/dev/null
s2=$(cd "$R" && GITHUB_OUTPUT=$T/o2 bash -e -c "$(step_run "$WF" settings)" && cat "$T/o2")
[ "$s1" = 'token_ref=' ] || why="$why; settings without a ref: $s1"
[ "$s2" = 'token_ref=op://ci/cloudflare-edit/credential' ] || why="$why; settings with a ref: $s2"

# the overlay's action runs both steps; the template names none (it is rendered from the overlay)
grep -q 'example-org' "$ENGINE/template/$WF" && why="$why; the template names an action"
for s in check apply; do [ "$(step_key "$R/$WF" "$s" uses)" = "$ACT" ] || why="$why; $s uses $(step_key "$R/$WF" "$s" uses)"; done
[ "$(step_key "$R/$WF" check args)" = "--check --offline" ] || why="$why; check args: $(step_key "$R/$WF" check args)"
step_key "$R/$WF" apply args >/dev/null && why="$why; apply passes args"

# pull requests and manual runs check with no secret in reach; only main applies, and only with a token reference
c=$(step_if "$R/$WF" check); has "pull_request" "$c" && has "workflow_dispatch" "$c" || why="$why; check runs on: $c"
grep -q 'secrets\.' <(sed -n '/- name: check/,/- name: /p' "$R/$WF" | sed '$d') && why="$why; the check step reads a secret"
for s in token apply; do c=$(step_if "$R/$WF" "$s"); has "github.ref == 'refs/heads/main'" "$c" && has "steps.cfg.outputs.token_ref != ''" "$c" && has "github.event_name != 'pull_request'" "$c" || why="$why; $s runs ungated: $c"; done
c=$(step_if "$R/$WF" inert); has "steps.cfg.outputs.token_ref == ''" "$c" && has "refs/heads/main" "$c" || why="$why; no inert notice: $c"
grep -q 'uses: 1password/load-secrets-action@[0-9a-f]\{40\}' "$R/$WF" && grep -q 'OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}' "$R/$WF" \
  && grep -q 'CLOUDFLARE_API_TOKEN: ${{ steps.cfg.outputs.token_ref }}' "$R/$WF" || why="$why; token not read through the pinned 1Password action"
# triggers: cloud-env.json changes on pull requests and on pushes to main only, plus a manual run (onboarding)
trig=$(node -e 'const y=require("fs").readFileSync(process.argv[1],"utf8");console.log(y.slice(y.indexOf("\non:"),y.indexOf("\npermissions:")))' "$R/$WF")
has "workflow_dispatch:" "$trig" && has "branches: [main]" "$trig" && [ "$(grep -c 'paths: \[cloud-env.json\]' <<<"$trig")" = 2 ] && ! has staging "$trig" || why="$why; triggers: $trig"

# the overlay's cloud_env is validated before anything is written
for bad in 'o["cloud_env"]={action:"x/y@v1",token_ref:"vault/item"}' 'o["cloud_env"]={action:"",token_ref:null}' 'o["cloud_env"]={action:"x/y",token_ref:null}' 'o["cloud_env"]={action:"x/y@v1",vault:"ci"}' 'o["cloud_env"]={action:"x/y@v1",token_ref:"ops_eyJhbGciOi"}'; do
  ov "$T/bad.json" "$bad"; out=$(node bin/repo-standards.mjs block --overlay "$T/bad.json" --profile internal 2>&1) && why="$why; accepted $bad"
  has "cloud_env" "$out" || why="$why; $bad: $out"
done

if [ -z "$why" ]; then ok cloud-env-apply-opt-in; else fail cloud-env-apply-opt-in "$why"; fi
done_cases
