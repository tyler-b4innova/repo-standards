#!/usr/bin/env bash
# PR helper over the GitHub REST API only. Auth: GH_TOKEN, GITHUB_TOKEN, else `gh auth token`.
# Repo: GH_REPO, else the origin remote. API: GITHUB_API_URL (default https://api.github.com).
#   pr.sh open [--base B] [--dry-run] [--] "<title>" <body-file>  draft PR (reused if open for this head and base); push first
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
  local u="$API/repos/$REPO${2:+/$2}"
  case $2 in /*) u="$API$2" ;; esac # an absolute API path, e.g. /user
  ST=$(curl "${a[@]}" "$u") || ST=000
  R=$(cat "$TMP")
}
req() { api "$@"; case $ST in 2??) ;; *) die "$1 $2 -> HTTP $ST: ${R:0:300}" ;; esac; }
js() { # js '<expr over d (JSON on stdin) and a (args)>' [args...]
  node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')||'null');const a=process.argv.slice(1);const r=($1);if(r!==undefined&&r!=='')console.log(typeof r==='string'?r:JSON.stringify(r))" -- "${@:2}"
}
CLOSES='(closes|fixes|resolves) #[0-9]+'

enc() { node -e 'console.log(encodeURIComponent(process.argv[1]).replace(/%2F/g,"/"))' "$1"; }
open_pr() {
  local title="" body="" base="" dry=0 branch n payload q
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -gt 1 ] || die "--base needs a branch"; base=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --) shift; break ;;
      -?*) die "unknown option $1 (titles starting with - go after --)" ;;
      *) if [ -z "$title" ]; then title=$1; else body=$1; fi; shift ;;
    esac
  done
  for a in "$@"; do if [ -z "$title" ]; then title=$a; elif [ -z "$body" ]; then body=$a; else die "unexpected argument: $a"; fi; done
  [ -n "$title" ] && [ -f "$body" ] || die 'usage: pr.sh open [--base B] [--dry-run] [--] "<title>" <body-file>'
  grep -qiE "$CLOSES" "$body" || die "body must link its issue: Closes #N (or Fixes/Resolves #N)"
  branch=$(git branch --show-current)
  [ -n "$branch" ] || die "detached HEAD; check out a branch first"
  [ -n "$base" ] || base=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
  [ -z "$base" ] || git check-ref-format --branch "$base" >/dev/null 2>&1 || die "invalid base branch: $base"
  payload=$(node -e 'const [t,b,h,base]=process.argv.slice(1);console.log(JSON.stringify({title:t,body:require("fs").readFileSync(b,"utf8"),head:h,base:base||"<default-branch>",draft:true}))' -- "$title" "$body" "$branch" "$base")
  if [ $dry = 1 ]; then echo "POST $API/repos/$REPO/pulls (or PATCH the open PR for $branch into ${base:-the default branch})"; echo "$payload"; return; fi
  if [ -z "$base" ]; then req GET ""; base=$(js 'd.default_branch' <<<"$R"); payload=$(js '({...d,base:a[0]})' "$base" <<<"$payload"); fi
  [ "$branch" != "$base" ] || die "on $base; create a branch first"
  api GET "branches/$(enc "$branch")"
  [ "$ST" = 200 ] || die "branch $branch is not on GitHub (HTTP $ST); run: git push -u origin HEAD"
  [ "$(js 'd.commit.sha' <<<"$R")" = "$(git rev-parse HEAD)" ] || die "local HEAD differs from $branch on GitHub; push first: git push origin HEAD"
  q=$(node -e 'console.log(new URLSearchParams({state:"open",head:process.argv[1],base:process.argv[2]}).toString())' -- "${REPO%%/*}:$branch" "$base")
  req GET "pulls?$q"
  # reuse only a PR whose head and base both match (the filter is advisory; check it here)
  n=$(js 'String((d.find(p=>p.state==="open"&&p.head.ref===a[0]&&p.base.ref===a[1]&&(!p.head.repo||p.head.repo.full_name.toLowerCase()===a[2].toLowerCase()))||{}).number||"")' "$branch" "$base" "$REPO" <<<"$R")
  if [ -n "$n" ]; then req PATCH "pulls/$n" "$(js '({title:d.title,body:d.body})' <<<"$payload")"
  else req POST pulls "$payload"; n=$(js 'String(d.number)' <<<"$R"); fi
  req GET "pulls/$n"
  [ "$(js '[d.state,d.head.ref,d.base.ref].join(" ")' <<<"$R")" = "open $branch $base" ] || die "PR #$n read back as $(js '[d.state,d.head.ref,"->",d.base.ref].join(" ")' <<<"$R"), not open $branch -> $base"
  js 'd.html_url' <<<"$R"
}

status() {
  local p runs st='{}' top review
  req GET "pulls/$1"; p=$R
  req GET "commits/$(js 'd.head.sha' <<<"$p")/check-runs?per_page=100"; runs=$R
  # With the org App posting `review` (the base branch's pack.json review_status), DONE also needs that status green
  # on the head. The base decides: a branch cut before the release carries an older pack.
  top=$(git rev-parse --show-toplevel)
  api GET "contents/scripts/agent/pack.json?ref=$(enc "$(js 'd.base.ref' <<<"$p")")"
  if [ "$ST" = 200 ]; then review=$(js 'String(!!JSON.parse(Buffer.from(d.content,"base64").toString()).review_status)' <<<"$R")
  elif [ "$ST" = 404 ]; then review=$(node -p 'try { !!require(process.argv[1]).review_status } catch { false }' "$top/scripts/agent/pack.json")
  else die "reading the base branch's pack.json -> HTTP $ST; cannot tell whether review is required"; fi
  if [ "$review" = true ]; then req GET "commits/$(js 'd.head.sha' <<<"$p")/status"; st=$R; fi
  R=$runs
  node -e '
    const [p, { check_runs: runs = [] }, { statuses = [] }] = process.argv.slice(1, 4).map(JSON.parse), why = [], need = process.argv[5] === "true";
    const closes = new RegExp(process.argv[4], "i").test(p.body || ""), gate = runs.filter((c) => c.name === "gate");
    console.log(`${p.html_url}\nstate=${p.merged ? "merged" : p.state} head=${p.head.sha.slice(0, 7)} closes=${closes}`);
    for (const c of runs) console.log(`  ${c.name}: ${c.conclusion || c.status}`);
    if (!(p.merged || p.state === "open")) why.push("PR closed without merge");
    if (!closes) why.push("body lacks Closes #N");
    if (!gate.length) why.push("no gate check on the head SHA");
    else if (!gate.every((c) => c.conclusion === "success")) why.push("gate " + gate.map((c) => c.conclusion || c.status).join(","));
    const review = statuses.find((x) => x.context === "review"); // newest first
    if (need) console.log(`  review: ${review ? `${review.state} (${review.description})` : "not posted"}`);
    if (need && review?.state !== "success") why.push(review ? `review ${review.state}: ${review.description}` : "no review status on the head SHA yet (the org App posts it)");
    const red = runs.filter((c) => c.name !== "gate" && /^(failure|timed_out|cancelled|action_required)$/.test(c.conclusion || ""));
    if (red.length) console.log(`also failing (not required for DONE; fix or explain): ${red.map((c) => c.name).join(", ")}`);
    console.log(why.length ? "NOT DONE: " + why.join("; ") : "DONE");
    process.exitCode = why.length ? 1 : 0;
  ' "$p" "$runs" "$st" "$CLOSES" "$review"
}

evidence() {
  local pr=${1:-} top branch sha body id f me paths=()
  shift || true
  [ "${1:-}" != -- ] || shift
  [ -n "$pr" ] && [ $# -gt 0 ] || die "usage: pr.sh evidence <pr> <file>..."
  top=$(git rev-parse --show-toplevel); branch=$(git branch --show-current)
  req GET "pulls/$pr"
  [ "$(js 'd.head.ref' <<<"$R")" = "$branch" ] || die "PR #$pr is not for the current branch $branch"
  mkdir -p "$top/.evidence"
  # only the named captures: never sweep other .evidence/ files or anything already staged
  for f in "$@"; do [ -f "$f" ] || die "no such file: $f"; cp -- "$f" "$top/.evidence/"; paths+=(".evidence/${f##*/}"); done
  cd "$top"
  git add -f -- "${paths[@]}"
  git commit -q -m "chore: evidence for #$pr" -- "${paths[@]}"
  sha=$(git rev-parse HEAD)
  # drop them again before pushing: the captures stay reachable at $sha, and the tip never carries .evidence/
  git rm -q -- "${paths[@]}"
  git commit -q -m "chore: drop .evidence/ from the branch tip" -- "${paths[@]}"
  git push -q origin HEAD
  body=$(node -e '
    const [server, repo, sha, ...files] = process.argv.slice(1), out = ["<!-- std:evidence -->", "### Evidence", ""];
    for (const f of files.map((p) => p.split("/").pop())) {
      const url = `${server}/${repo}/blob/${sha}/.evidence/${encodeURIComponent(f)}`;
      out.push(/\.(png|jpe?g|gif|webp)$/i.test(f) ? `![${f}](${url}?raw=true)` : `[${f}](${url})`, "");
    }
    console.log(JSON.stringify({ body: out.join("\n") + `Pinned to ${sha}.` }));
  ' -- "${GITHUB_SERVER_URL:-https://github.com}" "$REPO" "$sha" "${paths[@]}")
  # update only our own marked comment (an app token cannot read /user: it posts a new one)
  api GET /user; me=""; [ "$ST" != 200 ] || me=$(js 'd.login' <<<"$R")
  req GET "issues/$pr/comments?per_page=100"
  id=$(js 'String((d.find(c=>a[0]&&c.user?.login===a[0]&&(c.body||"").includes("<!-- std:evidence -->"))||{}).id||"")' "$me" <<<"$R")
  if [ -n "$id" ]; then req PATCH "issues/comments/$id" "$body"; else req POST "issues/$pr/comments" "$body"; fi
  js 'd.html_url' <<<"$R"
  echo "pr.sh: the review status reads this evidence on the org's next check (gate reads it on the next push)" >&2
}

feedback() {
  local pr=$1 since
  req GET "pulls/$pr"; req GET "commits/$(js 'd.head.sha' <<<"$R")"
  since=$(js 'd.commit.committer.date' <<<"$R")
  echo "since last push: $since (plus review threads nobody has answered, whatever their age)"
  local f='d.filter(c=>!(c.body||"").includes("<!-- std:evidence -->")&&(Date.parse(c.submitted_at||c.updated_at||c.created_at)>Date.parse(a[0])||(c.path&&!c.in_reply_to_id&&!d.some(r=>r.in_reply_to_id===c.id))))' line='(c.body||"").split("\n")[0].slice(0,160)'
  req GET "issues/$pr/comments?per_page=100&since=$since"
  js "$f.map(c=>\`issue-comment \${c.id} @\${c.user.login}: \${$line}\`).join('\n')" "$since" <<<"$R"
  req GET "pulls/$pr/comments?per_page=100"
  js "$f.map(c=>\`review-comment \${c.id} @\${c.user.login} \${c.path}:\${c.line??c.original_line}: \${$line}\`).join('\n')" "$since" <<<"$R"
  req GET "pulls/$pr/reviews?per_page=100"
  js "$f.map(c=>\`review \${c.id} @\${c.user.login} \${c.state}: \${$line}\`).join('\n')" "$since" <<<"$R"
}

reply() {
  [ $# -eq 3 ] || die 'usage: pr.sh reply <pr> <comment-id> "<text>"'
  local body
  body=$(node -e 'console.log(JSON.stringify({body:process.argv[1]}))' -- "$3")
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
