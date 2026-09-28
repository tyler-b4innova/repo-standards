// The `review` verdict for a pull request: everything that lives in its conversation, not its code. Gate checks the
// code; this checks the Codex verdict and its threads, the evidence comment for UI changes, and a promotion's design
// sign-off. It only reads, through the caller's GitHub API function, so the org launcher (every tick), an org's merge
// helper and scripts/agent/verdict-recheck share one rule:
//   reviewStatus({ api, owner, repo, pr }) -> null | { state: "success"|"failure"|"pending", description, sha, base, base_sha, target_url, details }
// api(method, path, body?) resolves parsed JSON, null for a 404, and throws on any other failure. Paths are from the
// API root ("/repos/o/r/pulls/7"); GraphQL is api("POST", "/graphql", { query, variables }).
// null: not an engine-managed repository, a draft, or the base branch's pack leaves review to gate (review_status off).
// postReviews (below) is the posting loop both the launcher and scripts/agent/verdict-recheck run.

const b64 = (f) => (f?.content ? JSON.parse(Buffer.from(f.content, "base64").toString("utf8")) : null);
const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
const short = (s) => s.slice(0, 7);

// files: optional { pack, std } already read (gate passes its checkout's); otherwise read on the PR's base branch.
export async function reviewStatus({ api, owner, repo, pr: n, files, now = Date.now(), serverUrl = "https://github.com", force = false }) {
  const R = `/repos/${owner}/${repo}`;
  const all = async (path) => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `${path}${path.includes("?") ? "&" : "?"}per_page=100&page=${p}`)) ?? []; out.push(...b); if (b.length < 100) return out; } };
  const pr = await api("GET", `${R}/pulls/${n}`);
  if (!pr || (pr.state ?? "open") !== "open" || pr.draft) return null;
  const head = pr.head.sha;
  // The rule and whether the org posts it come from the base branch (the org's current pack and the repository's
  // settings there), so a pull request cut before a pack release is judged like any other, and cannot relax its own review.
  const read = async (f) => b64(await api("GET", `${R}/contents/${f}?ref=${encodeURIComponent(pr.base?.sha ?? pr.base?.ref ?? "")}`));
  const pack = files?.pack ?? (await read("scripts/agent/pack.json")), std = files?.std ?? (await read("standards.json")) ?? {};
  if (!pack) return null;
  if (!pack.review_status && !force) return null; // gate's own steps still enforce this for the org
  // base, base_sha: what was judged against (the pack is read at that commit); a poster re-reads the PR and posts only
  // if its head and base (ref and commit) are unchanged.
  const verdict = (state, description, details = []) => ({ state, description: description.slice(0, 140), sha: head, base: pr.base?.ref ?? null, base_sha: pr.base?.sha ?? null, target_url: pr.html_url, details });
  if (pack.sync_app_login && pr.user?.login === pack.sync_app_login && /^standards\/v\d+\.\d+\.\d+$/.test(pr.head.ref))
    return verdict("success", "pack sync pull request: gate and the pack's own CI cover it");

  const info = (await api("GET", R)) ?? {};
  const uiOpt = std.ui_paths, inc = (Array.isArray(uiOpt) ? uiOpt : uiOpt?.include ?? pack.ui_paths ?? []).map(glob);
  const ign = [...(pack.ui_ignore ?? []), ...(uiOpt?.ignore ?? [])].map(glob);
  const ui = (fs) => fs.filter((f) => inc.some((r) => r.test(f)) && !ign.some((r) => r.test(f)));
  const listedFiles = await all(`${R}/pulls/${n}/files`), changed = ui(listedFiles.map((f) => f.filename));
  // GitHub lists at most 3,000 files; a larger diff cannot be judged, so it fails closed.
  if (pr.changed_files > listedFiles.length)
    return verdict("failure", `GitHub lists ${listedFiles.length} of ${pr.changed_files} changed files, so UI changes cannot be judged; split the PR`);
  const parts = [await design(), await codex()].filter(Boolean);
  const failed = parts.find((p) => p.state === "failure"), pending = parts.find((p) => p.state === "pending");
  const details = parts.flatMap((p) => p.details ?? [p.description]);
  if (failed) return verdict("failure", failed.description, details);
  if (pending) return verdict("pending", pending.description, details);
  return verdict("success", parts.map((p) => p.description).join("; "), details);

  // A promotion (staged flow: default branch into another branch) needs no evidence comment (it is on the original
  // PRs), but a design change needs an APPROVED review on the current head from a person with write access.
  // Any other PR changing UI paths needs a trusted evidence comment.
  async function design() {
    const flow = std.flow ?? info.custom_properties?.flow;
    if (flow === "staged" && pr.head.ref === info.default_branch && pr.base.ref !== info.default_branch) {
      if (!changed.length || std.design_signoff === false || pack.design_signoff === false) return { state: "success", description: "promotion: no design sign-off needed" };
      const latest = new Map();
      for (const r of await all(`${R}/pulls/${n}/reviews`)) latest.set(r.user?.login, r);
      for (const r of latest.values()) {
        if (r.state !== "APPROVED" || r.commit_id !== head || r.user?.type !== "User" || r.user.login === pr.user?.login) continue;
        const perm = await api("GET", `${R}/collaborators/${r.user.login}/permission`);
        if (["admin", "maintain", "write"].includes(perm?.permission)) return { state: "success", description: `design change approved by @${r.user.login}` };
      }
      return { state: "failure", description: `design change in this promotion needs a person's approval on ${short(head)}` };
    }
    if (!changed.length) return null;
    return evidence();
  }

  // Accepted: a trusted comment whose images are all in this repo at a commit in the PR head's history, covering
  // before and after at 400 and 1280px for web changes and paired before-N/after-N pages for documents, with no later
  // commit touching a UI path (evidence goes stale when the UI changes).
  async function evidence() {
    const isDoc = (f) => /\.(docx|pptx|xlsx|odt|odp|ods|pdf)$/i.test(f), docs = changed.some(isDoc), web = changed.some((f) => !isDoc(f));
    const trusted = pack.evidence_trusted_authors ?? ["pr_author", "app"];
    const trust = (c) => (trusted.includes("pr_author") && c.user?.login === pr.user.login) || (trusted.includes("app") && c.performed_via_github_app) || trusted.includes(c.user?.login);
    const esc = (s) => s.replace(/[.]/g, "\\.");
    const pin = new RegExp(`^${esc(serverUrl)}/${esc(`${owner}/${repo}`)}/(?:blob|raw)/([0-9a-f]{40})/(\\.evidence/[^?#]+)(?:[?#].*)?$`, "i");
    const bad = [];
    for (const c of await all(`${R}/issues/${n}/comments`)) {
      const urls = [...new Set(c.body?.match(/https?:\/\/[^\s)"'<>]*\/\.evidence\/[^\s)"'<>]*/g) ?? [])];
      const who = `${c.html_url} by @${c.user?.login}`;
      if (!urls.length) continue;
      if (!trust(c)) { bad.push(`${who}: not a trusted author (${trusted.join(", ")}; PR author @${pr.user.login})`); continue; }
      // Existence by directory listing (one read per commit and folder): the file endpoint returns the image
      // itself and refuses files over 1 MB, which full-page captures often are.
      const miss = [], listed = new Map(), decode = (x) => { try { return decodeURIComponent(x); } catch { return null; } };
      for (const u of urls) {
        const m = u.match(pin), path = m && decode(m[2]), dir = path?.split("/").slice(0, -1).join("/"), key = path && `${m[1]}:${dir}`;
        if (path && !listed.has(key)) { const l = await api("GET", `${R}/contents/${dir}?ref=${m[1]}`); listed.set(key, new Set(Array.isArray(l) ? l.map((f) => f.path) : [])); } // a file, not a folder: nothing listed
        if (!path || !listed.get(key).has(path)) miss.push(u); // an undecodable path is unresolved, never an error
      }
      if (miss.length) { bad.push(`${who}: unresolved (need this repo, a 40-hex SHA, the file): ${miss.join(" ")}`); continue; }
      const shas = [...new Set(urls.map((u) => u.match(pin)[1]))], names = urls.map((u) => decode(u.match(pin)[2]));
      // Distinct images: a file counts for one state only. A file named like a viewport capture is never a page.
      const img = (nm, st) => new RegExp(`(^|[/_-])${st}[_-]`, "i").test(nm) && !new RegExp(`(^|[/_-])${st === "before" ? "after" : "before"}[_-]`, "i").test(nm);
      const shot = (st, w) => names.some((nm) => img(nm, st) && new RegExp(`(^|[^0-9])${w}\\.(png|jpe?g|webp|gif)$`, "i").test(nm));
      const pages = (st) => new Set(names.map((nm) => nm.split("/").pop().match(new RegExp(`^${st}-0*(\\d+)\\.(png|jpe?g|webp|gif)$`, "i"))?.[1]).filter((x) => x && !["400", "1280"].includes(x)));
      const [pb, pa] = [pages("before"), pages("after")], paired = [...pb].some((x) => pa.has(x));
      const gaps = [...(web ? ["before", "after"].flatMap((st) => [400, 1280].filter((w) => !shot(st, w)).map((w) => `${st} ${w}px`)) : []),
        ...(docs && !paired ? [!pb.size ? "before pages" : !pa.size ? "after pages" : "a page with both before and after"] : [])];
      const need = [web && "before and after captures at 400 and 1280px", docs && "before and after page images (before-N, after-N)"].filter(Boolean).join(" and ");
      if (gaps.length) { bad.push(`${who}: needs ${need} (missing ${gaps.join(", ")})`); continue; }
      // In the head's history, and no later commit (each against its first parent) touches a UI path.
      let stale = "", outside = "";
      // Both lists are paginated: a comparison's commits and a commit's files each come a page at a time.
      const paged = async (path, key) => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `${path}?per_page=100&page=${p}`))?.[key] ?? []; out.push(...b); if (b.length < 100) return out; } };
      for (const s of shas) {
        const cmp = await api("GET", `${R}/compare/${s}...${head}?per_page=100&page=1`);
        if (!cmp || !["ahead", "identical"].includes(cmp.status)) { outside = s; break; }
        const commits = (cmp.commits ?? []).length < 100 ? cmp.commits ?? [] : await paged(`${R}/compare/${s}...${head}`, "commits");
        for (const k of commits) {
          const all3k = await paged(`${R}/commits/${k.sha}`, "files"); // GitHub lists at most 3,000: treat a capped commit as a UI change
          const files = all3k.map((f) => f.filename).filter((f) => !f.startsWith(".evidence/"));
          if (all3k.length >= 3000 || ui(files).length) { stale = k.sha; break; }
        }
        if (stale) break;
      }
      if (outside) { bad.push(`${who}: evidence commit ${short(outside)} is not in this PR's history`); continue; }
      if (stale) { bad.push(`${who}: UI changed after the evidence (commit ${short(stale)}); capture again`); continue; }
      return { state: "success", description: "evidence accepted", details: [`evidence: accepted ${c.html_url}`] };
    }
    return { state: "failure", description: `UI paths changed (${changed.slice(0, 3).join(", ")}) but no accepted evidence comment`, details: [`UI paths changed: ${changed.join(", ")}`, ...bad.map((b) => `rejected: ${b}`)] };
  }

  // Codex verdict on the current head: its summary comment shows this head as Completed, after the head's push and any
  // base change, and every Codex thread is resolved. Repositories without Codex reviews, or with codex_review off, are exempt.
  async function codex() {
    if (std.codex_review === false || pack.codex_review === false) return { state: "success", description: "Codex review off for this repo" };
    const bot = (u) => /codex/i.test(u?.login ?? "") && u?.type === "Bot", MARK = "<!-- codex-pull-request-review-summary -->";
    const comments = await all(`${R}/issues/${n}/comments`);
    const summary = comments.filter((c) => bot(c.user) && c.body?.includes(MARK)).at(-1);
    const row = summary?.body.match(/\|[^|\n]*Code Review[^|\n]*\|([^|\n]*)\|\s*`([0-9a-f]{7,40})`\s*\|/i);
    // The head's push time is server-recorded (its first pull_request gate run); the latest base change moves it.
    const timeline = await all(`${R}/issues/${n}/timeline`);
    const at = (ev) => timeline.filter((e) => e.event === ev).map((e) => Date.parse(e.created_at));
    const baseAt = Math.max(0, ...at("base_ref_changed"));
    const runs = (await api("GET", `${R}/actions/runs?head_sha=${head}&event=pull_request&per_page=100`))?.workflow_runs ?? [];
    const pushedAt = Math.max(Math.min(...runs.map((r) => Date.parse(r.created_at)), now), baseAt);
    const reviews = await all(`${R}/pulls/${n}/reviews`);
    const reviewed = (row && head.startsWith(row[2]) && /Completed/i.test(row[1]) && Date.parse(summary.updated_at) >= pushedAt)
      || reviews.some((r) => bot(r.user) && r.commit_id === head && Date.parse(r.submitted_at) >= baseAt);
    if (!summary && !reviewed) {
      // Codex skips drafts and may skip bot PRs, so sample up to 20 recent ready PRs by people.
      let seen = false;
      for (const p of ((await api("GET", `${R}/pulls?state=all&per_page=40`)) ?? []).filter((p) => p.number !== n && !p.draft && p.user?.type !== "Bot").slice(0, 20))
        if (((await api("GET", `${R}/issues/${p.number}/comments?per_page=100`)) ?? []).some((c) => bot(c.user) && c.body?.includes(MARK))) { seen = true; break; }
      if (!seen) return { state: "success", description: "no Codex reviews on this repo's recent PRs" };
    }
    if (reviewed) {
      const query = `query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:1){nodes{author{login} url}}}}}}}`;
      const threads = [];
      for (let c = null; ; ) {
        const page = (await api("POST", "/graphql", { query, variables: { o: owner, r: repo, n, c } }))?.data?.repository?.pullRequest?.reviewThreads;
        if (!page) throw new Error("could not read review threads");
        threads.push(...page.nodes);
        if (!page.pageInfo?.hasNextPage) break;
        c = page.pageInfo.endCursor;
      }
      const open = threads.filter((t) => !t.isResolved && /codex/i.test(t.comments.nodes[0]?.author?.login ?? ""));
      if (open.length) return { state: "failure", description: `${open.length} unresolved Codex thread(s): fix each or reply why, then resolve`, details: open.map((t) => `open: ${t.comments.nodes[0].url}`) };
      return { state: "success", description: `Codex verdict on ${short(head)}, no open findings` };
    }
    const since = Math.max(pushedAt, ...at("ready_for_review")), mins = Math.floor((now - since) / 60000);
    if (mins < 20) return { state: "pending", description: `awaiting a Codex verdict for ${short(head)} (${mins} min)` };
    return { state: "failure", description: `no Codex verdict for ${short(head)} after ${mins} min; request a review` };
  }
}

// Judge and post `review` for pull requests (the launcher's tick, verdict-recheck): every open PR sharing a head is
// judged and the worst verdict is posted once per head; a PR that moves while being judged (head, base, state, draft)
// gets `pending` instead, on its old and new heads, so an earlier success never stands for an unjudged state.
//   postReviews({ api, owner, repo, prs | all: true, dryRun, force, serverUrl, log }) -> { posted, failed }
export async function postReviews({ api, owner, repo, prs = [], all = false, dryRun = false, force = false, serverUrl = "https://github.com", log = console.log }) {
  const listOpen = async () => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `/repos/${owner}/${repo}/pulls?state=open&per_page=100&page=${p}`)) ?? []; out.push(...b); if (b.length < 100) return out; } };
  const open = (await listOpen()).filter((p) => !p.draft);
  const nums = all ? open.map((p) => p.number) : [...prs];
  // A commit status belongs to the commit, not the pull request: every open PR whose head is that commit is judged,
  // and the worst result is posted, so one PR's success never satisfies a sibling's failed review.
  const rank = { failure: 2, pending: 1, success: 0 }, done = new Set();
  let failed = 0, posted = 0;
  const post = async (sha, state, description, target_url) => {
    try { await api("POST", `/repos/${owner}/${repo}/statuses/${sha}`, { state, context: "review", description: description.slice(0, 140), target_url }); posted++; return true; }
    catch (e) { failed++; log(`could not post review on ${sha.slice(0, 7)} (${e.message}); GH_TOKEN must be the org App's token with statuses: write`); return false; }
  };
  const snap = (p) => ({ sha: p?.head?.sha, base: p?.base?.ref ?? null, base_sha: p?.base?.sha ?? null });
  const same = (now, j) => now?.head?.sha === j.sha && (now?.base?.ref ?? null) === j.base && (now?.base?.sha ?? null) === j.base_sha && (now?.state ?? "open") === "open" && !now?.draft;
  // One PR's failure never stops the rest: an evaluation that errors posts pending on the head it was reading (an
  // earlier success must not outlive what could not be judged). Callers run one pass at a time (the launcher's tick).
  const each = async (pr) => {
    let before;
    try { await one(pr, (b) => (before = b)); }
    catch (e) {
      failed++;
      log(`#${pr}: review could not be evaluated (${e.message})`);
      if (before?.head?.sha && !dryRun && !force) await post(before.head.sha, "pending", `#${pr}: review could not be evaluated; retrying`, before.html_url);
    }
  };
  for (const pr of nums) await each(pr);
  return { posted, failed };

  async function one(pr, seen) {
    const before = await api("GET", `/repos/${owner}/${repo}/pulls/${pr}`);
    seen(before);
    const first = await reviewStatus({ api, owner, repo, pr, force, serverUrl });
    if (!first) {
      // Its head's other open PRs are judged in their own right (one may target a base where review is on).
      for (const s of await listOpen()) if (!s.draft && s.head?.sha === before?.head?.sha && !nums.includes(s.number)) nums.push(s.number); // re-listed: a sibling opened meanwhile counts
      // Nothing to judge (draft, closed, not engine-managed, or review off on its base) - unless it moved meanwhile:
      // then a success already on the commit may not stand for its new base, so it goes pending until the next run.
      const now = await api("GET", `/repos/${owner}/${repo}/pulls/${pr}`);
      if (before?.head?.sha && !same(now, snap(before)) && (now?.state ?? "open") === "open" && !now?.draft && !dryRun && !force) {
        for (const h of new Set([before.head.sha, now.head.sha]))
          if (await post(h, "pending", `#${pr} changed while being judged; re-judging`, now.html_url)) log(`#${pr}: changed while being judged; posted review=pending on ${h.slice(0, 7)}`);
      } else log(`#${pr}: nothing to post (draft, closed, not engine-managed, or the pack leaves review to gate)`);
      return;
    }
    if (done.has(first.sha)) return;
    done.add(first.sha);
    let r = first, from = pr;
    const judged = new Map([[pr, first]]);
    const judge = async (list) => {
      for (const s of list.filter((p) => !p.draft && p.head?.sha === first.sha && !judged.has(p.number))) {
        const other = await reviewStatus({ api, owner, repo, pr: s.number, force, serverUrl });
        // A sibling judged null (review off on its base) is still re-read: a retarget could make it need review.
        judged.set(s.number, other ?? snap(s));
        if (other && rank[other.state] > rank[r.state]) { r = other; from = s.number; }
      }
    };
    await judge(open);
    await judge(await listOpen()); // re-listed right before posting: a PR opened on this head meanwhile is judged too
    const tag = from === pr ? "" : ` (from #${from}, which shares this head)`;
    for (const d of r.details ?? []) log(`#${from} ${r.sha.slice(0, 7)}: ${d}`);
    log(`#${pr} ${r.sha.slice(0, 7)}: review=${r.state} (${r.description})${tag}`);
    if (dryRun || force) { log(`#${pr}: not posted (${force ? "--force only evaluates" : "dry run"})`); return; }
    // Every judged PR on this head must be as it was judged (head, base ref and commit, open and ready). If one moved,
    // the verdict is not posted, and pending replaces any earlier success on the commit until the next run judges it.
    let moved = 0;
    const heads = new Set([r.sha]);
    for (const [n, j] of judged) {
      const now = await api("GET", `/repos/${owner}/${repo}/pulls/${n}`);
      if (same(now, j)) continue;
      moved = n;
      // a PR that moved to another head: that head may carry an older success too
      if (now?.head?.sha && (now.state ?? "open") === "open" && !now.draft) heads.add(now.head.sha);
    }
    if (moved) {
      for (const h of heads) if (await post(h, "pending", `#${moved} changed while being judged; re-judging`, r.target_url)) log(`#${pr}: #${moved} changed while being judged; posted review=pending on ${h.slice(0, 7)}`);
      return;
    }
    // A success is judged once more right before it is posted: evidence deleted or a thread opened meanwhile wins.
    if (r.state === "success") {
      const again = await reviewStatus({ api, owner, repo, pr: from, force, serverUrl });
      if (!again || again.sha !== r.sha || again.state !== "success") { r = again && again.sha === r.sha ? again : { ...r, state: "pending", description: `#${from} changed while being judged; re-judging` }; }
    }
    if (await post(r.sha, r.state, from === pr ? r.description : `#${from}: ${r.description}`, r.target_url)) log(`#${pr}: posted review=${r.state}`);
  }
}

// A GitHub REST caller for scripts: token from the environment, 404 as null, any other failure thrown.
export function restApi({ token, base = process.env.GITHUB_API_URL || "https://api.github.com", graphql = process.env.GITHUB_GRAPHQL_URL }) {
  const root = base.replace(/\/$/, ""), gql = graphql || (root.endsWith("/api/v3") ? root.replace(/\/v3$/, "/graphql") : `${root}/graphql`);
  return async (method, path, body) => {
    const r = await fetch(path === "/graphql" ? gql : `${root}${path}`, { method, headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", ...(body && { "Content-Type": "application/json" }) }, body: body && JSON.stringify(body) });
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
    return r.status === 204 ? {} : r.json();
  };
}
