#!/usr/bin/env bash
# PR helper over the GitHub REST API (GraphQL only for review threads: status, resolve; the draft toggle: ready; auto-merge: arm). Auth: GH_TOKEN, GITHUB_TOKEN, else `gh auth token`.
# Repo: GH_REPO, else the origin remote. API: GITHUB_API_URL (default https://api.github.com).
#   pr.sh open [--base B] [--dry-run] [--claimed-ok] [--] "<title>" <body-file>  draft PR (reused if open for this head and base); push first
#                                         --claimed-ok skips the check that refuses an issue the launcher claimed (label agent-claimed) unless the branch is its agent/N-* or retro/N-*
#   pr.sh status <pr>                   checks on the head SHA and open review threads, then DONE or NOT DONE: <reasons>
#   pr.sh evidence <pr> <file>...         upload captures as attachments (gh 2.99+) in one marked comment; no commit, no push
#   pr.sh feedback <pr>                   comments and reviews newer than the last push, with ids
#   pr.sh reply <pr> <comment-id> "<text>"  reply on the review thread, else as a PR comment
#   pr.sh resolve <pr> <comment-id>       resolve the review thread holding that comment, only when its first comment is a review bot's (a person's thread: reply instead)
#   pr.sh ready <pr>                      mark the draft ready once: only when `gate.mjs local` passed on the pushed head, tree clean; GraphQL
#   pr.sh arm <pr>                        squash auto-merge on a ready PR, only when its base branch rules require both gate and review; never merges
set -euo pipefail
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "pr.sh: $*" >&2; exit 1; }
API=${GITHUB_API_URL:-https://api.github.com}
REPO=${GH_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#/+$##; s#\.git$##; s#.*[:/]([^/:]+/[^/:]+)$#\1#' || true)}
[ -n "$REPO" ] || [ "${1:-}" = --help ] || [ "${1:-}" = -h ] || die "no origin remote; set GH_REPO=owner/name"
TMP=$(mktemp); EVD=""; trap 'rm -rf "$TMP" "$EVD"' EXIT
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
  local title="" body="" base="" dry=0 claimed_ok=0 branch n nums payload q
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -gt 1 ] || die "--base needs a branch"; base=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --claimed-ok) claimed_ok=1; shift ;;
      --) shift; break ;;
      -?*) die "unknown option $1 (titles starting with - go after --)" ;;
      *) if [ -z "$title" ]; then title=$1; else body=$1; fi; shift ;;
    esac
  done
  for a in "$@"; do if [ -z "$title" ]; then title=$a; elif [ -z "$body" ]; then body=$a; else die "unexpected argument: $a"; fi; done
  [ -n "$title" ] && [ -f "$body" ] || die 'usage: pr.sh open [--base B] [--dry-run] [--claimed-ok] [--] "<title>" <body-file>'
  grep -qiE "$CLOSES" "$body" || die "body must link its issue: Closes #N (or Fixes/Resolves #N)"
  nums=$(grep -oiE "$CLOSES" "$body" | grep -oE '[0-9]+$' | sort -un) # same-repo only: owner/name#N does not match CLOSES
  branch=$(git branch --show-current)
  [ -n "$branch" ] || die "detached HEAD; check out a branch first"
  [ -n "$base" ] || base=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
  [ -z "$base" ] || git check-ref-format --branch "$base" >/dev/null 2>&1 || die "invalid base branch: $base"
  payload=$(node -e 'const [t,b,h,base]=process.argv.slice(1);console.log(JSON.stringify({title:t,body:require("fs").readFileSync(b,"utf8"),head:h,base:base||"<default-branch>",draft:true}))' -- "$title" "$body" "$branch" "$base")
  if [ $dry = 1 ]; then echo "POST $API/repos/$REPO/pulls (or PATCH the open PR for $branch into ${base:-the default branch})"; echo "$payload"; return; fi
  if [ -z "$base" ]; then req GET ""; base=$(js 'd.default_branch' <<<"$R"); payload=$(js '({...d,base:a[0]})' "$base" <<<"$payload"); fi
  [ "$branch" != "$base" ] || die "on $base; create a branch first"
  # an issue the launcher claimed is worked on its own branch; another PR closing it would collide with that attempt
  if [ $claimed_ok = 0 ]; then
    for n in $nums; do
      api GET "issues/$n"
      case $ST in 200) ;; 404) continue ;; *) die "issue #$n: could not read its labels (HTTP $ST)" ;; esac
      [ "$(js 'String((d.labels||[]).some(l=>l.name==="agent-claimed"))' <<<"$R")" = true ] || continue
      case "$branch" in "agent/$n"-?* | "retro/$n"-?*) ;; *) die "issue #$n is claimed by the launcher (label agent-claimed; its branch is agent/$n-<slug> or retro/$n-<slug>): let that attempt finish, or remove agent-claimed first" ;; esac
    done
  fi
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
  local p runs threads q
  req GET "pulls/$1"; p=$R
  req GET "commits/$(js 'd.head.sha' <<<"$p")/check-runs?per_page=100"; runs=$R
  # The org rulesets also require every review thread resolved (answer or fix each, then resolve it).
  q=$(node -e 'const [o, n, pr] = process.argv.slice(1); console.log(JSON.stringify({ query: "query($o:String!,$n:String!,$pr:Int!){repository(owner:$o,name:$n){pullRequest(number:$pr){reviewThreads(first:100){totalCount nodes{isResolved comments(first:1){nodes{url}}}}}}}", variables: { o, n, pr: +pr } }))' -- "${REPO%%/*}" "${REPO#*/}" "$1")
  req POST /graphql "$q"; threads=$R
  node -e '
    const [p, { check_runs: runs = [] }, t] = process.argv.slice(1, 4).map(JSON.parse), why = [];
    const closes = new RegExp(process.argv[4], "i").test(p.body || ""), gate = runs.filter((c) => c.name === "gate");
    console.log(`${p.html_url}\nstate=${p.merged ? "merged" : p.state} head=${p.head.sha.slice(0, 7)} closes=${closes}`);
    for (const c of runs) console.log(`  ${c.name}: ${c.conclusion || c.status}`);
    if (!(p.merged || p.state === "open")) why.push("PR closed without merge");
    if (!closes) why.push("body lacks Closes #N");
    if (!gate.length) why.push("no gate check on the head SHA");
    else if (!gate.every((c) => c.conclusion === "success")) why.push("gate " + gate.map((c) => c.conclusion || c.status).join(","));
    const rt = t?.data?.repository?.pullRequest?.reviewThreads;
    if (!rt) why.push("could not read review threads: " + JSON.stringify(t?.errors ?? t).slice(0, 200));
    else {
      const open = rt.nodes.filter((x) => !x.isResolved);
      for (const x of open) console.log(`  unresolved: ${x.comments.nodes[0]?.url ?? "(no comment)"}`);
      if (open.length) why.push(`${open.length} unresolved review thread(s): fix or reply, then resolve`);
      if (rt.totalCount > rt.nodes.length) why.push(`${rt.totalCount} review threads; only the first ${rt.nodes.length} were read`);
    }
    const red = runs.filter((c) => c.name !== "gate" && /^(failure|timed_out|cancelled|action_required)$/.test(c.conclusion || ""));
    if (red.length) console.log(`also failing (not required for DONE; fix or explain): ${red.map((c) => c.name).join(", ")}`);
    console.log(why.length ? "NOT DONE: " + why.join("; ") : "DONE");
    process.exitCode = why.length ? 1 : 0;
  ' "$p" "$runs" "$threads" "$CLOSES"
}

evidence() {
  local pr=${1:-} head me old out url newid keep kurl stray patch f ext i=0 args=() body major minor
  shift || true
  [ "${1:-}" != -- ] || shift
  [ -n "$pr" ] && [ $# -gt 0 ] || die "usage: pr.sh evidence <pr> <file>..."
  # gh attaches at most 50 files per command, and this helper posts one command per comment
  [ $# -le 50 ] || die "pr.sh evidence takes at most 50 files per comment (gh attaches 50 per command); got $#"
  # uploads are gh's: attachments need gh 2.99 or later (the flag is absent before it)
  local v; v=$(gh --version 2>/dev/null | sed -n '1s/^gh version \([0-9.]*\).*/\1/p') || true
  IFS=. read -r major minor _ <<<"$v" || true
  [ -n "$v" ] && { [ "${major:-0}" -gt 2 ] || { [ "${major:-0}" -eq 2 ] && [ "${minor:-0}" -ge 99 ]; }; } || die "pr.sh evidence uploads with gh --attach, which needs gh 2.99 or later (found: ${v:-none})"
  for f in "$@"; do
    [ -f "$f" ] || die "no such file: $f"
    case "$(printf '%s' "${f##*.}" | tr A-Z a-z)" in png | jpg | jpeg | gif | webp | mp4 | mov | webm) ;; *) die "unsupported evidence file: $f (images: png, jpg, jpeg, gif, webp; video: mp4, mov, webm)" ;; esac
  done
  req GET "pulls/$pr"
  [ "$(js 'd.head.ref' <<<"$R")" = "$(git branch --show-current)" ] || die "PR #$pr is not for the current branch $(git branch --show-current)"
  head=$(js 'd.head.sha' <<<"$R")
  # the captures are of this checkout, so it must be the PR head the marker names
  [ "$head" = "$(git rev-parse HEAD)" ] || die "local HEAD ${head:0:7} is not the PR head $(git rev-parse --short HEAD); push first"
  # uploads reject app tokens (404), so the comment is a person's; /user names the login that owns the old one
  api GET /user; [ "$ST" = 200 ] || die "evidence uploads need a person's token (GH_TOKEN or gh auth login)"
  me=$(js 'd.login' <<<"$R")
  req GET "issues/$pr/comments?per_page=100"
  old=$(js 'd.filter(c=>c.user?.login===a[0]&&(c.body||"").startsWith("<!-- std:evidence")).map(c=>c.id).join(" ")' "$me" <<<"$R")
  # each capture is copied under a plain name; the body embeds images by file name (alt text) and gh appends videos
  EVD=$(mktemp -d); body="$EVD/body.md"
  printf '<!-- std:evidence head=%s -->\n### Evidence\n\n' "$head" >"$body"
  for f in "$@"; do
    i=$((i + 1)); ext=$(printf '%s' "${f##*.}" | tr A-Z a-z); cp -- "$f" "$EVD/$i.$ext"
    case "$ext" in
      mp4 | mov | webm) args+=(--attach "./$i.$ext") ;;
      *) printf '![%s](./%s.%s)\n\n' "${f##*/}" "$i" "$ext" >>"$body"; args+=(--attach "./$i.$ext#${f##*/}") ;;
    esac
  done
  if ! out=$(cd "$EVD" && GH_TOKEN=$TOKEN gh pr comment "$pr" -R "$REPO" --body-file body.md "${args[@]}"); then
    # gh can fail after posting a partial comment: remove this login's marked comments that were not there before
    api GET "issues/$pr/comments?per_page=100"
    if [ "$ST" = 200 ]; then
      stray=$(js 'd.filter(c=>c.user?.login===a[0]&&(c.body||"").startsWith("<!-- std:evidence")&&!a[1].split(" ").includes(String(c.id))).map(c=>c.id).join(" ")' "$me" "$old" <<<"$R")
      for id in $stray; do api DELETE "issues/comments/$id"; done
    fi
    die "gh pr comment failed; the previous evidence comment is unchanged"
  fi
  url=$(printf '%s\n' "$out" | tail -n 1)
  newid=${url##*issuecomment-}
  case "$newid" in '' | *[!0-9]*) die "could not read the posted comment's id from: $url" ;; esac
  if [ -z "$old" ]; then
    kurl=$url
  else
    # keep the oldest comment (its id and URL stay the same across re-runs): it takes the new body, the new comment goes
    set -- $old; keep=$1; shift
    api GET "issues/comments/$newid"; [ "$ST" = 200 ] || die "could not read the posted comment $newid"
    patch=$(js '({body:d.body})' <<<"$R")
    req PATCH "issues/comments/$keep" "$patch"
    kurl=$(js 'd.html_url' <<<"$R")
    req DELETE "issues/comments/$newid"
    for id in "$@"; do req DELETE "issues/comments/$id"; done
  fi
  printf '%s\n' "$kurl"
  echo "pr.sh: the review rule reads this evidence when the PR is next checked for merge" >&2
}

feedback() {
  local pr=$1 since
  req GET "pulls/$pr"; req GET "commits/$(js 'd.head.sha' <<<"$R")"
  since=$(js 'd.commit.committer.date' <<<"$R")
  echo "since last push: $since (plus review threads nobody has answered, whatever their age)"
  local f='d.filter(c=>!(c.body||"").startsWith("<!-- std:evidence")&&(Date.parse(c.submitted_at||c.updated_at||c.created_at)>Date.parse(a[0])||(c.path&&!c.in_reply_to_id&&!d.some(r=>r.in_reply_to_id===c.id))))' line='(c.body||"").split("\n")[0].slice(0,160)'
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

resolve() {
  [ $# -eq 2 ] || die 'usage: pr.sh resolve <pr> <comment-id>'
  [ -n "$TOKEN" ] || TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  [ -n "$TOKEN" ] || TOKEN=$(gh auth token 2>/dev/null) || die "set GH_TOKEN or run gh auth login"
  local t tid
  # Every thread and every comment in it, page by page; REST ids (fullDatabaseId) can exceed GraphQL's Int.
  t=$(TOKEN=$TOKEN API=$API node -e '
    const [owner, name, pr, id] = process.argv.slice(1), url = process.env.API.replace(/\/$/, "") + "/graphql";
    const gql = async (query, variables) => {
      const r = await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${process.env.TOKEN}`, "Content-Type": "application/json" }, body: JSON.stringify({ query, variables }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || j.errors) { console.error(`graphql: ${r.status} ${JSON.stringify(j.errors ?? j).slice(0, 300)}`); process.exit(2); }
      return j.data;
    };
    const C = "comments(first: 100, after: $c) { pageInfo { hasNextPage endCursor } nodes { fullDatabaseId author { login __typename } } }";
    (async () => {
      for (let after = null; ;) {
        const d = await gql(`query($o: String!, $n: String!, $pr: Int!, $a: String, $c: String) { repository(owner: $o, name: $n) { pullRequest(number: $pr) { reviewThreads(first: 100, after: $a) { pageInfo { hasNextPage endCursor } nodes { id ${C} } } } } }`, { o: owner, n: name, pr: +pr, a: after, c: null });
        const page = d.repository.pullRequest.reviewThreads;
        for (const th of page.nodes) {
          let cs = th.comments;
          for (;;) {
            if (cs.nodes.some((c) => String(c.fullDatabaseId) === id)) { console.log(JSON.stringify({ id: th.id, first: th.comments.nodes[0]?.author ?? null })); return; }
            if (!cs.pageInfo.hasNextPage) break;
            cs = (await gql(`query($t: ID!, $c: String) { node(id: $t) { ... on PullRequestReviewThread { ${C} } } }`, { t: th.id, c: cs.pageInfo.endCursor })).node.comments;
          }
        }
        if (!page.pageInfo.hasNextPage) return;
        after = page.pageInfo.endCursor;
      }
    })();
  ' -- "${REPO%%/*}" "${REPO#*/}" "$1" "$2") || die "could not read the review threads of #$1"
  [ -n "$t" ] || die "no review thread on #$1 holds comment $2 (pr.sh feedback lists the ids)"
  # Only a review bot's thread is resolved here: GraphQL gives a bot the __typename Bot (its login has no [bot] suffix). A person's
  # thread, or one whose first comment came from a deleted account (null), is refused; the person's own thread stays theirs.
  [ "$(js 'String(!!d.first && (d.first.__typename === "Bot" || /\[bot\]$/.test(d.first.login)))' <<<"$t")" = true ] \
    || die "resolve closes review-bot threads only: this thread $(js 'd.first ? "starts with a comment by @" + d.first.login : "starts with a comment from a deleted account"' <<<"$t"), which is not one. Reply on it instead: pr.sh reply $1 $2 \"<text>\""
  tid=$(js 'd.id' <<<"$t")
  req POST /graphql "$(node -e 'console.log(JSON.stringify({ query: "mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}", variables: { t: process.argv[1] } }))' -- "$tid")"
  [ "$(js 'String(d.data?.resolveReviewThread?.thread?.isResolved)' <<<"$R")" = true ] || die "resolving the thread failed: ${R:0:300}"
  echo "resolved the thread holding comment $2"
}

arm() { # arm <pr>: squash auto-merge on a ready PR whose base branch rules require both gate and review; nothing merges or changes here
  [ $# -eq 1 ] || die 'usage: pr.sh arm <pr>'
  req GET "pulls/$1"
  [ "$(js 'd.state' <<<"$R")" = open ] || die "PR #$1 is not open"
  [ "$(js 'String(!!d.draft)' <<<"$R")" = false ] || die "PR #$1 is a draft, so it is not ready; mark it ready with pr.sh ready $1 first"
  local base pid missing rules page n
  base=$(js 'd.base.ref' <<<"$R"); pid=$(js 'd.node_id' <<<"$R")
  # the repository's auto-merge setting is read, never written: an agent does not change merge settings; an org admin does
  req GET ""
  [ "$(js 'String(d.allow_auto_merge === true)' <<<"$R")" = true ] || die "auto-merge is off for this repository; an org admin enables it (pr.sh arm changes no settings)"
  # the base branch's rules, across rulesets, page by page (GitHub returns 30 a page unless asked for more); a token that cannot read them arms nothing
  rules='[]'; page=1
  while :; do
    req GET "rules/branches/$(enc "$base")?per_page=100&page=$page"
    n=$(js 'Array.isArray(d) ? d.length : 0' <<<"$R")
    rules=$(js 'JSON.parse(a[0]).concat(d)' "$rules" <<<"$R")
    [ "$n" -ge 100 ] || break
    page=$((page + 1))
  done
  missing=$(js '["gate", "review"].filter((c) => !d.some((x) => x.type === "required_status_checks" && (x.parameters?.required_status_checks || []).some((y) => y.context === c))).join(", ")' <<<"$rules")
  [ -z "$missing" ] || die "branch $base does not require both gate and review (missing: $missing); auto-merge not armed on #$1"
  req POST /graphql "$(node -e 'console.log(JSON.stringify({ query: "mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){pullRequest{autoMergeRequest{enabledAt}}}}", variables: { id: process.argv[1] } }))' -- "$pid")"
  [ "$(js 'String(!!d.data?.enablePullRequestAutoMerge?.pullRequest?.autoMergeRequest)' <<<"$R")" = true ] && { echo "auto-merge armed on #$1 (squash); it merges once gate and review pass"; return 0; }
  # GitHub refuses auto-merge once the PR is already clean (it can merge now): report it, do not retry or merge by hand
  [ "$(js 'String(/clean status/i.test(JSON.stringify(d.errors || [])))' <<<"$R")" = true ] && die "GitHub did not arm auto-merge on #$1: the PR is already clean, so it can merge now. Stop and report it; do not merge it by hand."
  die "GitHub did not arm auto-merge on #$1: ${R:0:300}"
}

gql_draft() { # gql_draft <pr> convertPullRequestToDraft|markPullRequestReadyForReview <want-draft true|false> [expected-head-sha]
  [ -n "$TOKEN" ] || { TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}; [ -n "$TOKEN" ] || TOKEN=$(gh auth token 2>/dev/null) || die "set GH_TOKEN or run gh auth login"; }
  req GET "pulls/$1"
  req POST /graphql "$(node -e 'console.log(JSON.stringify({ query: `mutation($id:ID!){${process.argv[2]}(input:{pullRequestId:$id}){pullRequest{isDraft}}}`, variables: { id: process.argv[1] } }))' -- "$(js 'd.node_id' <<<"$R")" "$2")"
  [ "$(js 'String(!!d.errors)' <<<"$R")" = false ] || die "$2 failed: ${R:0:300}"
  req GET "pulls/$1"
  [ "$(js 'String(!!d.draft)' <<<"$R")" = "$3" ] || die "PR #$1 did not become draft=$3 (read back $(js 'd.draft' <<<"$R"))"
  if [ -n "${4:-}" ] && [ "$(js 'd.head.sha' <<<"$R")" != "$4" ]; then
    gql_draft "$1" convertPullRequestToDraft true
    die "PR #$1 head moved during the toggle (${4:0:7} -> now another commit); it is a draft again. Run the local gate on the new head, then pr.sh ready $1"
  fi
}

ready() {
  [ $# -eq 1 ] || die 'usage: pr.sh ready <pr>'
  local head file
  # A ready flip made inside Actions (GITHUB_TOKEN, or GH_TOKEN set from github.token) does not fire ready_for_review, so the full gate would never run.
  [ "${GITHUB_ACTIONS:-}" != true ] || die "ready cannot run inside GitHub Actions: a flip made there would not start the full gate. Run it from an agent or person session"
  req GET "pulls/$1"
  [ "$(js 'd.state' <<<"$R")" = open ] || die "PR #$1 is not open"
  [ "$(js 'String(!!d.draft)' <<<"$R")" = true ] || { echo "PR #$1 is already ready"; return; }
  [ "$(git branch --show-current)" = "$(js 'd.head.ref' <<<"$R")" ] || die "PR #$1 is not for the current branch $(git branch --show-current)"
  head=$(git rev-parse HEAD)
  [ "$(js 'd.head.sha' <<<"$R")" = "$head" ] || die "local HEAD ${head:0:7} is not the PR head $(js 'd.head.sha.slice(0,7)' <<<"$R"); push first"
  [ -z "$(git status --porcelain --untracked-files=all)" ] || die "uncommitted or untracked files; the local gate must pass on exactly the pushed head"
  file=$(git rev-parse --git-path std-local-gate)
  [ -f "$file" ] && [ "$(cat "$file")" = "$head" ] || die "no passing local gate for ${head:0:7}; run: node scripts/agent/gate.mjs local"
  gql_draft "$1" markPullRequestReadyForReview false "$head"
  echo "PR #$1 is ready at ${head:0:7}; the full gate runs once on this head"
}

cmd=${1:-}
shift || true
case "$cmd" in
  open) open_pr "$@" ;;
  status | feedback) [ $# -eq 1 ] || die "usage: pr.sh $cmd <pr>"; "$cmd" "$1" ;;
  evidence | reply | resolve | ready | arm) "$cmd" "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
