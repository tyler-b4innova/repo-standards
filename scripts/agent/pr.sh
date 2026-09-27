#!/usr/bin/env bash
# PR helper over the GitHub REST API only. Auth: GH_TOKEN, GITHUB_TOKEN, else `gh auth token`.
# Repo: GH_REPO, else the origin remote. API: GITHUB_API_URL (default https://api.github.com).
#   pr.sh open "<title>" <body-file> [--base B] [--dry-run]  draft PR for this branch (reused if open); push first
#   pr.sh status <pr>                     checks on the head SHA, then DONE or NOT DONE: <reasons>
#   pr.sh evidence <pr> <file>...         post SHA-pinned evidence; .evidence/ never stays on the branch tip
#   pr.sh feedback <pr>                   comments and reviews newer than the last push, with ids
#   pr.sh reply <pr> <comment-id> "<text>"  reply on the review thread, else as a PR comment
set -euo pipefail
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "pr.sh: $*" >&2; exit 1; }
API=${GITHUB_API_URL:-https://api.github.com}
REPO=${GH_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#/+$##; s#\.git$##; s#.*[:/]([^/:]+/[^/:]+)$#\1#' || true)}
[ -n "$REPO" ] || [ "${1:-}" = --help ] || [ "${1:-}" = -h ] || die "no origin remote; set GH_REPO=owner/name"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
TOKEN="" ST="" R=""
api() { # api METHOD path [json]: sets ST (HTTP status) and R (body)
  if [ -z "$TOKEN" ]; then
    TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
    [ -n "$TOKEN" ] || TOKEN=$(gh auth token 2>/dev/null) || die "set GH_TOKEN or run gh auth login"
  fi
  local a=(-sS -o "$TMP" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json")
  [ $# -lt 3 ] || a+=(-H "Content-Type: application/json" --data-binary "$3")
  ST=$(curl "${a[@]}" "$API/repos/$REPO${2:+/$2}") || ST=000
  R=$(cat "$TMP")
}
req() { api "$@"; case $ST in 2??) ;; *) die "$1 $2 -> HTTP $ST: ${R:0:300}" ;; esac; }
js() { # js '<expr over d (JSON on stdin) and a (args)>' [args...]
  node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')||'null');const a=process.argv.slice(1);const r=($1);if(r!==undefined&&r!=='')console.log(typeof r==='string'?r:JSON.stringify(r))" "${@:2}"
}
CLOSES='(closes|fixes|resolves) #[0-9]+'

open_pr() {
  local title="" body="" base="" dry=0 branch n payload
  while [ $# -gt 0 ]; do
    case "$1" in --base) base=$2; shift 2 ;; --dry-run) dry=1; shift ;; *) if [ -z "$title" ]; then title=$1; else body=$1; fi; shift ;; esac
  done
  [ -n "$title" ] && [ -f "$body" ] || die 'usage: pr.sh open "<title>" <body-file> [--base B] [--dry-run]'
  grep -qiE "$CLOSES" "$body" || die "body must link its issue: Closes #N (or Fixes/Resolves #N)"
  branch=$(git branch --show-current)
  [ -n "$base" ] || base=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
  payload=$(node -e 'const [t,b,h,base]=process.argv.slice(1);console.log(JSON.stringify({title:t,body:require("fs").readFileSync(b,"utf8"),head:h,base:base||"<default-branch>",draft:true}))' "$title" "$body" "$branch" "$base")
  if [ $dry = 1 ]; then echo "POST $API/repos/$REPO/pulls (or PATCH the open PR for $branch)"; echo "$payload"; return; fi
  if [ -z "$base" ]; then req GET ""; base=$(js 'd.default_branch' <<<"$R"); payload=$(js '({...d,base:a[0]})' "$base" <<<"$payload"); fi
  [ "$branch" != "$base" ] || die "on $base; create a branch first"
  api GET "branches/$branch"
  [ "$ST" = 200 ] || die "branch $branch is not on GitHub (HTTP $ST); run: git push -u origin HEAD"
  [ "$(js 'd.commit.sha' <<<"$R")" = "$(git rev-parse HEAD)" ] || echo "pr.sh: warning: local HEAD differs from origin/$branch; push to update the PR" >&2
  req GET "pulls?state=open&head=${REPO%%/*}:$branch"
  n=$(js 'd.length?String(d[0].number):""' <<<"$R")
  if [ -n "$n" ]; then req PATCH "pulls/$n" "$(js '({title:d.title,body:d.body})' <<<"$payload")"
  else req POST pulls "$payload"; n=$(js 'String(d.number)' <<<"$R"); fi
  req GET "pulls/$n"
  js 'd.html_url' <<<"$R"
}

status() {
  local p
  req GET "pulls/$1"; p=$R
  req GET "commits/$(js 'd.head.sha' <<<"$p")/check-runs?per_page=100"
  node -e '
    const [p, { check_runs: runs = [] }] = process.argv.slice(1, 3).map(JSON.parse), why = [];
    const closes = new RegExp(process.argv[3], "i").test(p.body || ""), gate = runs.filter((c) => c.name === "gate");
    console.log(`${p.html_url}\nstate=${p.merged ? "merged" : p.state} head=${p.head.sha.slice(0, 7)} closes=${closes}`);
    for (const c of runs) console.log(`  ${c.name}: ${c.conclusion || c.status}`);
    if (!(p.merged || p.state === "open")) why.push("PR closed without merge");
    if (!closes) why.push("body lacks Closes #N");
    if (!gate.length) why.push("no gate check on the head SHA");
    else if (!gate.every((c) => c.conclusion === "success")) why.push("gate " + gate.map((c) => c.conclusion || c.status).join(","));
    console.log(why.length ? "NOT DONE: " + why.join("; ") : "DONE");
    process.exitCode = why.length ? 1 : 0;
  ' "$p" "$R" "$CLOSES"
}

evidence() {
  local pr=${1:-} top branch sha body id f
  shift || true
  [ -n "$pr" ] && [ $# -gt 0 ] || die "usage: pr.sh evidence <pr> <file>..."
  top=$(git rev-parse --show-toplevel); branch=$(git branch --show-current)
  req GET "pulls/$pr"
  [ "$(js 'd.head.ref' <<<"$R")" = "$branch" ] || die "PR #$pr is not for the current branch $branch"
  mkdir -p "$top/.evidence"
  for f in "$@"; do cp "$f" "$top/.evidence/"; done
  git add -f "$top/.evidence"
  git commit -q -m "chore: evidence for #$pr"
  git push -q origin HEAD
  sha=$(git rev-parse HEAD)
  body=$(node -e '
    const [repo, sha, ...files] = process.argv.slice(1), out = ["<!-- std:evidence -->", "### Evidence", ""];
    for (const f of files.map((p) => p.split("/").pop())) {
      const url = `https://github.com/${repo}/blob/${sha}/.evidence/${encodeURIComponent(f)}`;
      out.push(/\.(png|jpe?g|gif|webp)$/i.test(f) ? `![${f}](${url}?raw=true)` : `[${f}](${url})`, "");
    }
    console.log(JSON.stringify({ body: out.join("\n") + `Pinned to ${sha}.` }));
  ' "$REPO" "$sha" "$@")
  req GET "issues/$pr/comments?per_page=100"
  id=$(js 'String((d.find(c=>(c.body||"").includes("<!-- std:evidence -->"))||{}).id||"")' <<<"$R")
  if [ -n "$id" ]; then req PATCH "issues/comments/$id" "$body"; else req POST "issues/$pr/comments" "$body"; fi
  js 'd.html_url' <<<"$R"
  git rm -rq "$top/.evidence"
  git commit -q -m "chore: drop .evidence/ from the branch tip"
  git push -q origin HEAD
}

feedback() {
  local pr=$1 since
  req GET "pulls/$pr"; req GET "commits/$(js 'd.head.sha' <<<"$R")"
  since=$(js 'd.commit.committer.date' <<<"$R")
  echo "since last push: $since"
  local f='d.filter(c=>Date.parse(c.submitted_at||c.updated_at||c.created_at)>Date.parse(a[0])&&!(c.body||"").includes("<!-- std:evidence -->"))' line='(c.body||"").split("\n")[0].slice(0,160)'
  req GET "issues/$pr/comments?per_page=100&since=$since"
  js "$f.map(c=>\`issue-comment \${c.id} @\${c.user.login}: \${$line}\`).join('\n')" "$since" <<<"$R"
  req GET "pulls/$pr/comments?per_page=100&since=$since"
  js "$f.map(c=>\`review-comment \${c.id} @\${c.user.login} \${c.path}:\${c.line??c.original_line}: \${$line}\`).join('\n')" "$since" <<<"$R"
  req GET "pulls/$pr/reviews?per_page=100"
  js "$f.map(c=>\`review \${c.id} @\${c.user.login} \${c.state}: \${$line}\`).join('\n')" "$since" <<<"$R"
}

reply() {
  [ $# -eq 3 ] || die 'usage: pr.sh reply <pr> <comment-id> "<text>"'
  local body
  body=$(node -e 'console.log(JSON.stringify({body:process.argv[1]}))' "$3")
  api POST "pulls/$1/comments/$2/replies" "$body"
  case $ST in 2??) echo "replied on the review thread" ;; *) req POST "issues/$1/comments" "$body"; echo "not a review comment; posted a PR comment" ;; esac
  js 'd.html_url' <<<"$R"
}

cmd=${1:-}
shift || true
case "$cmd" in
  open) open_pr "$@" ;;
  status | feedback) [ $# -eq 1 ] || die "usage: pr.sh $cmd <pr>"; "$cmd" "$1" ;;
  evidence | reply) "$cmd" "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
