#!/usr/bin/env bash
# PR helper over the GitHub REST API (GraphQL only for review threads: status, resolve). Auth: GH_TOKEN, GITHUB_TOKEN, else `gh auth token`.
# Repo: GH_REPO, else the origin remote. API: GITHUB_API_URL (default https://api.github.com).
#   pr.sh open [--base B] [--dry-run] [--] "<title>" <body-file>  draft PR (reused if open for this head and base); push first.
#     The body gains `## Issue #N`: the linked issue's Goal and Acceptance criteria (gate's issue step checks it); --dry-run stays offline and shows a placeholder.
#   pr.sh status <pr>                     checks on the head SHA and open review threads, then DONE or NOT DONE: <reasons>
#   pr.sh evidence <pr> <file>...         post SHA-pinned evidence; .evidence/ never stays on the branch tip
#   pr.sh feedback <pr>                   comments and reviews newer than the last push, with ids
#   pr.sh reply <pr> <comment-id> "<text>"  reply on the review thread, else as a PR comment
#   pr.sh resolve <pr> <comment-id>       resolve the review thread holding that comment (after fixing or answering it)
set -euo pipefail
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "pr.sh: $*" >&2; exit 1; }
API=${GITHUB_API_URL:-https://api.github.com}
REPO=${GH_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#/+$##; s#\.git$##; s#.*[:/]([^/:]+/[^/:]+)$#\1#' || true)}
[ -n "$REPO" ] || [ "${1:-}" = --help ] || [ "${1:-}" = -h ] || die "no origin remote; set GH_REPO=owner/name"
TMP=$(mktemp) BODY=$(mktemp); trap 'rm -f "$TMP" "$BODY"' EXIT
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
# quote_issue <body-file> <n> (issue JSON on stdin, empty for a placeholder): the body with its `## Issue #N` section
# (a bare `## Issue #` placeholder too) replaced, else appended: the issue's title, then its Goal and Acceptance criteria
# (the whole body when it has neither), headings demoted to ### or lower. gate.mjs issue reads the same sections.
quote_issue() {
  node -e '
    const fs = require("fs"), [file, n] = process.argv.slice(1), raw = fs.readFileSync(0, "utf8").trim(), body = fs.readFileSync(file, "utf8");
    const parts = (text) => { // [[title, lines]] of the level-2 sections named Goal or Acceptance criteria; [] when neither
      const out = []; let cur = null, fence = false;
      for (const l of text.split(/\r?\n/)) {
        if (/^\s*(```|~~~)/.test(l)) fence = !fence;
        const h = !fence && l.match(/^##\s+(.+?)\s*#*\s*$/);
        if (h || (!fence && /^#\s/.test(l))) { cur = h && /^(goal|acceptance criteria)$/i.test(h[1]) ? [h[1], []] : null; if (cur) out.push(cur); continue; }
        if (cur) cur[1].push(l);
      }
      return out;
    };
    const demote = (lines) => { let fence = false; return lines.map((l) => {
      if (/^\s*(```|~~~)/.test(l)) fence = !fence;
      const h = !fence && l.match(/^(#{1,6})(\s.*)$/);
      return h ? "#".repeat(Math.min(6, Math.max(3, h[1].length + 1))) + h[2] : l;
    }).join("\n").trim(); };
    let sec;
    if (!raw) sec = `## Issue #${n}\n\n(filled from issue #${n}: its title, Goal and Acceptance criteria, when the pull request is opened)`;
    else {
      const d = JSON.parse(raw), p = parts(d.body || "");
      sec = [`## Issue #${n}`, d.title, ...(p.length ? p.map(([t, l]) => `### ${t}\n\n${demote(l)}`) : [demote((d.body || "").split(/\r?\n/))])].filter(Boolean).join("\n\n");
    }
    const lines = body.split("\n"), i = lines.findIndex((l) => new RegExp(`^## Issue #(${n})?\\s*$`).test(l));
    let j = lines.findIndex((l, k) => i >= 0 && k > i && /^##\s/.test(l)); if (j < 0) j = lines.length;
    console.log(i < 0 ? body.replace(/\s*$/, "") + "\n\n" + sec : [...lines.slice(0, i), sec, ...(j < lines.length ? ["", ...lines.slice(j)] : [])].join("\n"));
  ' -- "$1" "$2"
}

enc() { node -e 'console.log(encodeURIComponent(process.argv[1]).replace(/%2F/g,"/"))' "$1"; }
open_pr() {
  local title="" body="" base="" dry=0 branch n payload q issue
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
  issue=$(grep -oiE "$CLOSES" "$body" | head -1 | grep -oE '[0-9]+$')
  branch=$(git branch --show-current)
  [ -n "$branch" ] || die "detached HEAD; check out a branch first"
  [ -n "$base" ] || base=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
  [ -z "$base" ] || git check-ref-format --branch "$base" >/dev/null 2>&1 || die "invalid base branch: $base"
  mkpayload() { payload=$(node -e 'const [t,b,h,base]=process.argv.slice(1);console.log(JSON.stringify({title:t,body:require("fs").readFileSync(b,"utf8").replace(/\n$/,""),head:h,base:base||"<default-branch>",draft:true}))' -- "$title" "$BODY" "$branch" "$base"); }
  if [ $dry = 1 ]; then
    quote_issue "$body" "$issue" </dev/null >"$BODY"; mkpayload
    echo "POST $API/repos/$REPO/pulls (or PATCH the open PR for $branch into ${base:-the default branch})"; echo "$payload"; return
  fi
  if [ -z "$base" ]; then req GET ""; base=$(js 'd.default_branch' <<<"$R"); fi
  [ "$branch" != "$base" ] || die "on $base; create a branch first"
  api GET "branches/$(enc "$branch")"
  [ "$ST" = 200 ] || die "branch $branch is not on GitHub (HTTP $ST); run: git push -u origin HEAD"
  [ "$(js 'd.commit.sha' <<<"$R")" = "$(git rev-parse HEAD)" ] || die "local HEAD differs from $branch on GitHub; push first: git push origin HEAD"
  api GET "issues/$issue"
  [ "$ST" = 200 ] || die "issue #$issue is not in $REPO (HTTP $ST); link the issue this pull request closes"
  [ "$(js 'String(!!d.pull_request)' <<<"$R")" = false ] || die "#$issue is a pull request, not an issue; link the issue this pull request closes"
  quote_issue "$body" "$issue" <<<"$R" >"$BODY" || die "could not quote issue #$issue"
  mkpayload
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
  echo "pr.sh: the review rule reads this evidence when the PR is next checked for merge" >&2
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

resolve() {
  [ $# -eq 2 ] || die 'usage: pr.sh resolve <pr> <comment-id>'
  [ -n "$TOKEN" ] || TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  [ -n "$TOKEN" ] || TOKEN=$(gh auth token 2>/dev/null) || die "set GH_TOKEN or run gh auth login"
  local t
  # Every thread and every comment in it, page by page; REST ids (fullDatabaseId) can exceed GraphQL's Int.
  t=$(TOKEN=$TOKEN API=$API node -e '
    const [owner, name, pr, id] = process.argv.slice(1), url = process.env.API.replace(/\/$/, "") + "/graphql";
    const gql = async (query, variables) => {
      const r = await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${process.env.TOKEN}`, "Content-Type": "application/json" }, body: JSON.stringify({ query, variables }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || j.errors) { console.error(`graphql: ${r.status} ${JSON.stringify(j.errors ?? j).slice(0, 300)}`); process.exit(2); }
      return j.data;
    };
    const C = "comments(first: 100, after: $c) { pageInfo { hasNextPage endCursor } nodes { fullDatabaseId } }";
    (async () => {
      for (let after = null; ;) {
        const d = await gql(`query($o: String!, $n: String!, $pr: Int!, $a: String, $c: String) { repository(owner: $o, name: $n) { pullRequest(number: $pr) { reviewThreads(first: 100, after: $a) { pageInfo { hasNextPage endCursor } nodes { id ${C} } } } } }`, { o: owner, n: name, pr: +pr, a: after, c: null });
        const page = d.repository.pullRequest.reviewThreads;
        for (const th of page.nodes) {
          let cs = th.comments;
          for (;;) {
            if (cs.nodes.some((c) => String(c.fullDatabaseId) === id)) { console.log(th.id); return; }
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
  req POST /graphql "$(node -e 'console.log(JSON.stringify({ query: "mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}", variables: { t: process.argv[1] } }))' -- "$t")"
  [ "$(js 'String(d.data?.resolveReviewThread?.thread?.isResolved)' <<<"$R")" = true ] || die "resolving the thread failed: ${R:0:300}"
  echo "resolved the thread holding comment $2"
}

cmd=${1:-}
shift || true
case "$cmd" in
  open) open_pr "$@" ;;
  status | feedback) [ $# -eq 1 ] || die "usage: pr.sh $cmd <pr>"; "$cmd" "$1" ;;
  evidence | reply | resolve) "$cmd" "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
