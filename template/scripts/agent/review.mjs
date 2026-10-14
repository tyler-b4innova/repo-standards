import { parseReviewRecord, outstandingReviewFindings, reviewRecordChain, verifiedReviewChain } from "./review-record.mjs";

// The review rule for a pull request: everything that lives in its conversation, not its code. Gate checks the code;
// this checks the Codex verdict and its threads and the evidence comment for UI changes. It only reads, through the caller's GitHub API function, so a launcher or merge helper can ask it before
// merging (a pack-sync PR gets no exemption: a person fixes it on their own branch, or it is reviewed like any other):
//   reviewStatus({ api, owner, repo, pr }) -> null | { state: "success"|"failure"|"pending", description, sha, base, base_sha, target_url, details }
// api(method, path, body?) resolves parsed JSON, null for a 404, and throws on any other failure. Paths are from the
// API root ("/repos/o/r/pulls/7"); GraphQL is api("POST", "/graphql", { query, variables }).
// null: not an engine-managed repository, or a draft.

const b64 = (f) => (f?.content ? JSON.parse(Buffer.from(f.content, "base64").toString("utf8")) : null);
const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
const short = (s) => s.slice(0, 7);
// The last producer of pinned .evidence/ links stopped at 09:56Z on 2026-10-13: pinned comments created or edited from this instant on are refused.
const PINNED_CUTOVER = Date.parse("2026-10-13T10:00:00Z");

// pull: the PR as the caller already read it (so the verdict is for exactly that state); read here when omitted.
export async function reviewStatus({ api, owner, repo, pr: n, pull, now = Date.now(), serverUrl = "https://github.com" }) {
  const R = `/repos/${owner}/${repo}`;
  const all = async (path) => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `${path}${path.includes("?") ? "&" : "?"}per_page=100&page=${p}`)) ?? []; out.push(...b); if (b.length < 100) return out; } };
  const pr = pull ?? (await api("GET", `${R}/pulls/${n}`));
  if (!pr || (pr.state ?? "open") !== "open" || pr.draft) return null;
  const head = pr.head.sha;
  // The rule comes from the base branch (the org's current pack and the repository's
  // settings there), so a pull request cut before a pack release is judged like any other, and cannot relax its own review.
  // GitHub may leave pull.base.sha at the commit from when the PR was opened, even after sync updates the base.
  // Resolve the current base ref once, then read both policy files from that exact commit.
  const baseHead = pr.base?.ref
    ? (await api("GET", `${R}/branches/${encodeURIComponent(pr.base.ref)}`))?.commit?.sha
    : pr.base?.sha;
  if (pr.base?.ref && !baseHead) throw new Error(`cannot resolve current base branch ${pr.base.ref}`);
  const cfgRef = baseHead ?? "";
  const read = async (f) => b64(await api("GET", `${R}/contents/${f}?ref=${encodeURIComponent(cfgRef)}`));
  const pack = await read("scripts/agent/pack.json"), std = (await read("standards.json")) ?? {};
  if (!pack) return null;
  // base, base_sha: what was judged against (the pack is read at that commit); a caller re-reads the PR and acts only
  // if its head and base (ref and commit) are unchanged.
  const verdict = (state, description, details = []) => ({ state, description: description.slice(0, 140), sha: head, base: pr.base?.ref ?? null, base_sha: baseHead ?? null, target_url: pr.html_url, details });

  const uiOpt = std.ui_paths, inc = (Array.isArray(uiOpt) ? uiOpt : uiOpt?.include ?? pack.ui_paths ?? []).map(glob);
  const ign = [...(pack.ui_ignore ?? []), ...(uiOpt?.ignore ?? [])].map(glob);
  const ui = (fs) => fs.filter((f) => inc.some((r) => r.test(f)) && !ign.some((r) => r.test(f)));
  // A rename counts by both paths: moving a UI file out of a UI path is a UI change too.
  const paths = (fs) => fs.flatMap((f) => [f.filename, f.previous_filename].filter(Boolean));
  const listedFiles = await all(`${R}/pulls/${n}/files`), changed = [...new Set(ui(paths(listedFiles)))];
  // GitHub lists at most 3,000 files; a larger diff cannot be judged, so it fails closed.
  if (pr.changed_files > listedFiles.length)
    return verdict("failure", `GitHub lists ${listedFiles.length} of ${pr.changed_files} changed files, so UI changes cannot be judged; split the PR`);
  const parts = [await design(), await codex()].filter(Boolean);
  const failed = parts.find((p) => p.state === "failure"), pending = parts.find((p) => p.state === "pending");
  const details = parts.flatMap((p) => p.details ?? [p.description]);
  if (failed) return verdict("failure", failed.description, details);
  if (pending) return verdict("pending", pending.description, details);
  return verdict("success", parts.map((p) => p.description).join("; "), details);

  // A PR changing UI paths needs a trusted evidence comment.
  async function design() {
    if (!changed.length) return null;
    return evidence();
  }

  // Accepted: a trusted comment whose images are GitHub attachments named by their alt text (pr.sh evidence), marked
  // `<!-- std:evidence head=<sha> -->`, covering before and after at 400 and 1280px for web changes and paired
  // before-N/after-N pages for documents. The marked head must be in this PR's history, with no later commit touching a
  // UI path (evidence goes stale when the UI changes). Videos carry no name and need none.
  // The pinned form (`.evidence/` blob links) is accepted only when last written (edited, else created) before PINNED_CUTOVER: such a comment keeps the
  // pre-attachment checks, each link resolving at its commit, with the same naming rules.
  async function evidence() {
    const isDoc = (f) => /\.(docx|pptx|xlsx|odt|odp|ods|pdf)$/i.test(f), docs = changed.some(isDoc), web = changed.some((f) => !isDoc(f));
    const trusted = pack.evidence_trusted_authors ?? ["pr_author", "app"];
    const trust = (c) => (trusted.includes("pr_author") && c.user?.login === pr.user.login) || (trusted.includes("app") && c.performed_via_github_app) || trusted.includes(c.user?.login);
    const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    // attachments and pinned links live on the server the caller names (github.com by default); the host is escaped, never read as a pattern
    const host = escape(serverUrl.replace(/\/+$/, "")), asset = `${host}/user-attachments/assets/[\\w-]+`;
    const ASSET = new RegExp(asset, "g"), NAMED = new RegExp(`!\\[([^\\]]*)\\]\\((${asset})\\)`, "g");
    const pin = new RegExp(`^${host}/${escape(`${owner}/${repo}`)}/(?:blob|raw)/([0-9a-f]{40})/(\\.evidence/[^?#]+)(?:[?#].*)?$`, "i");
    const PINNED = /https?:\/\/[^\s)"'<>]*\/\.evidence\/[^\s)"'<>]*/g;
    const decode = (x) => { try { return decodeURIComponent(x); } catch { return null; } };
    const bad = [];
    // Both lists are paginated: a comparison's commits and a commit's files each come a page at a time.
    const paged = async (path, key) => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `${path}?per_page=100&page=${p}`))?.[key] ?? []; out.push(...b); if (b.length < 100) return out; } };
    // The naming rule on file names or alt text: before and after at 400 and 1280px for web, page images for documents.
    // Returns "" when met, else what is missing. Distinct images: a file counts for one state only, and a file named like
    // a viewport capture is never a page.
    const shape = (names) => {
      const img = (nm, st) => new RegExp(`(^|[/_-])${st}[_-]`, "i").test(nm) && !new RegExp(`(^|[/_-])${st === "before" ? "after" : "before"}[_-]`, "i").test(nm);
      const shot = (st, w) => names.some((nm) => img(nm, st) && new RegExp(`(^|[^0-9])${w}\\.(png|jpe?g|webp|gif)$`, "i").test(nm));
      const pages = (st) => new Set(names.map((nm) => nm.split("/").pop().match(new RegExp(`^${st}-0*(\\d+)\\.(png|jpe?g|webp|gif)$`, "i"))?.[1]).filter((x) => x && !["400", "1280"].includes(x)));
      const [pb, pa] = [pages("before"), pages("after")], paired = [...pb].some((x) => pa.has(x));
      const gaps = [...(web ? ["before", "after"].flatMap((st) => [400, 1280].filter((w) => !shot(st, w)).map((w) => `${st} ${w}px`)) : []),
        ...(docs && !paired ? [!pb.size ? "before pages" : !pa.size ? "after pages" : "a page with both before and after"] : [])];
      const need = [web && "before and after captures at 400 and 1280px", docs && "before and after page images (before-N, after-N)"].filter(Boolean).join(" and ");
      return gaps.length ? `needs ${need} (missing ${gaps.join(", ")})` : "";
    };
    // In the marked head's history, and no later commit (each against its first parent) touches a UI path. "" when so.
    const since = async (sha) => {
      const cmp = await api("GET", `${R}/compare/${sha}...${head}?per_page=100&page=1`);
      if (!cmp || !["ahead", "identical"].includes(cmp.status)) return `evidence commit ${short(sha)} is not in this PR's history`;
      const commits = (cmp.commits ?? []).length < 100 ? cmp.commits ?? [] : await paged(`${R}/compare/${sha}...${head}`, "commits");
      for (const k of commits) {
        const all3k = await paged(`${R}/commits/${k.sha}`, "files"); // GitHub lists at most 3,000: treat a capped commit as a UI change
        const files = paths(all3k).filter((f) => !f.startsWith(".evidence/"));
        if (all3k.length >= 3000 || ui(files).length) return `UI changed after the evidence (commit ${short(k.sha)}); capture again`;
      }
      return "";
    };
    for (const c of await all(`${R}/issues/${n}/comments`)) {
      const body = c.body ?? "";
      const pinned = [...new Set(body.match(PINNED) ?? [])], assets = body.match(ASSET) ?? [];
      const who = `${c.html_url} by @${c.user?.login}`;
      if (!pinned.length && !assets.length && !body.includes("<!-- std:evidence")) continue;
      if (!trust(c)) { bad.push(`${who}: not a trusted author (${trusted.join(", ")}; PR author @${pr.user.login})`); continue; }
      if (pinned.length) {
        // An edit counts: an older pr.sh could rewrite a grandfathered comment in place, keeping its created_at.
        if (!(Date.parse(c.updated_at ?? c.created_at) < PINNED_CUTOVER)) { bad.push(`${who}: pinned .evidence/ links are no longer accepted; re-post with pr.sh evidence`); continue; }
        // Existence by directory listing (one read per commit and folder): the file endpoint returns the image
        // itself and refuses files over 1 MB, which full-page captures often are.
        const miss = [], listed = new Map();
        for (const u of pinned) {
          const m = u.match(pin), path = m && decode(m[2]), dir = path?.split("/").slice(0, -1).join("/"), key = path && `${m[1]}:${dir}`;
          if (path && !listed.has(key)) { const l = await api("GET", `${R}/contents/${dir}?ref=${m[1]}`); listed.set(key, new Set(Array.isArray(l) ? l.map((f) => f.path) : [])); } // a file, not a folder: nothing listed
          if (!path || !listed.get(key).has(path)) miss.push(u); // an undecodable path is unresolved, never an error
        }
        if (miss.length) { bad.push(`${who}: unresolved (need this repo, a 40-hex SHA, the file): ${miss.join(" ")}`); continue; }
        const gap = shape(pinned.map((u) => decode(u.match(pin)[2])));
        if (gap) { bad.push(`${who}: ${gap}`); continue; }
        let why = "";
        for (const s of new Set(pinned.map((u) => u.match(pin)[1]))) if ((why = await since(s))) break;
        if (why) { bad.push(`${who}: ${why}`); continue; }
        return { state: "success", description: "evidence accepted", details: [`evidence: accepted ${c.html_url}`] };
      }
      const mark = body.match(/<!-- std:evidence head=([0-9a-f]{40}) -->/);
      if (!mark) { bad.push(`${who}: no <!-- std:evidence head=<40-hex sha> --> marker; re-post with pr.sh evidence`); continue; }
      if (!assets.length) { bad.push(`${who}: no uploaded image or video`); continue; }
      // One name per upload: a single asset cannot count as several captures.
      const gap = shape([...new Map([...body.matchAll(NAMED)].map((m) => [m[2], m[1]])).values()]);
      if (gap) { bad.push(`${who}: ${gap}`); continue; }
      const why = await since(mark[1]);
      if (why) { bad.push(`${who}: ${why}`); continue; }
      return { state: "success", description: "evidence accepted", details: [`evidence: accepted ${c.html_url}`] };
    }
    return { state: "failure", description: `UI paths changed (${changed.slice(0, 3).join(", ")}) but no accepted evidence comment`, details: [`UI paths changed: ${changed.join(", ")}`, ...bad.map((b) => `rejected: ${b}`)] };
  }

  // Completion covers this candidate. The App attests a complete independent review
  // (including verification of fixes), or GitHub's reviewer completed this exact head.
  async function codex() {
    const comments = await all(`${R}/issues/${n}/comments`);
    const trusted = comments.filter((c) => pack.sync_app_login && c.user?.login === pack.sync_app_login && c.user?.type === "Bot");
    const records = trusted.map((c) => ({ comment: c, record: parseReviewRecord(c.body) })).filter((x) => x.record);
    const current = records.filter((x) => x.record.head === head && x.record.base === baseHead).at(-1);
    const earlier = outstandingReviewFindings((current ? records.slice(0, records.indexOf(current)) : records).map((x) => x.record));
    let appComplete = false;
    if (current) {
      const r = current.record;
      if (r.verdict !== "clean") return { state: "failure", description: "independent review has unresolved findings", details: r.findings.map((f) => `${f.id}: ${f.text}`) };
      if (earlier.some((f) => !r.outcomes.some((o) => o.id === f.id && o.status !== "blocking")))
        return { state: "failure", description: "review has not verified every earlier finding" };
      const later = records.slice(records.indexOf(current) + 1).flatMap((x) => x.record.findings);
      if (later.length) return { state: "failure", description: "later review findings require verification on this candidate", details: later.map((f) => `${f.id}: ${f.text}`) };
      if (r.phase === "followup") {
        const chain = reviewRecordChain(records.map((x) => x.record), records.indexOf(current));
        if (!chain) return { state: "failure", description: "follow-up review is not rooted in a full review" };
        if (!(await verifiedReviewChain(records.map((x) => x.record), records.indexOf(current), async (before, after) =>
          ["ahead", "identical"].includes((await api("GET", `${R}/compare/${before}...${after}`))?.status))))
          return { state: "failure", description: "follow-up review does not continue its reviewed commit; full review required" };
      }
      appComplete = true;
    }
    if (!appComplete && earlier.length) return { state: "failure", description: "earlier independent findings still require explicit verification", details: earlier.map((f) => `${f.id}: ${f.text}`) };
    const bot = (u) => /codex/i.test(u?.login ?? "") && u?.type === "Bot", MARK = "<!-- codex-pull-request-review-summary -->";
    const summary = comments.filter((c) => bot(c.user) && c.body?.includes(MARK)).at(-1);
    const row = summary?.body.match(/\|[^|\n]*Code Review[^|\n]*\|([^|\n]*)\|\s*`([0-9a-f]{7,40})`\s*\|/i);
    const reviews = appComplete ? [] : await all(`${R}/pulls/${n}/reviews`);
    const timeline = appComplete ? [] : await all(`${R}/issues/${n}/timeline`);
    const baseChanges = timeline.filter((e) => e.event === "base_ref_changed").map((e) => Date.parse(e.created_at));
    if (!appComplete && baseChanges.some((at) => !Number.isFinite(at)))
      return { state: "failure", description: "cannot establish when the PR base changed; native review coverage is uncheckable" };
    const baseChangedAt = Math.max(0, ...baseChanges);
    const afterRetarget = (at) => !baseChangedAt || Date.parse(at ?? "") > baseChangedAt;
    // Security activity can edit the shared summary later; its code-review row owns this timestamp.
    const summaryAt = /datetime="([^"]+)"/.exec(row?.[1] ?? "")?.[1];
    // A displayed abbreviation cannot bind coverage to a head: colliding commits
    // can share that prefix. The summary or submitted review must name the full SHA.
    const reviewed = appComplete || (row && /Completed/i.test(row[1]) && row[2] === head && afterRetarget(summaryAt))
      || reviews.some((r) => bot(r.user) && r.commit_id === head && r.state !== "DISMISSED" && r.state !== "PENDING" && afterRetarget(r.submitted_at));
    if (reviewed && !appComplete && baseHead) {
      const comparison = await api("GET", `${R}/compare/${baseHead}...${head}`);
      if (!comparison || !["ahead", "identical"].includes(comparison.status))
        return { state: "failure", description: "reviewed head does not contain the current base; update the branch and review its integration" };
    }
    const query = `query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:1){nodes{author{login} url}}}}}}}`;
    const threads = [];
    for (let c = null; ; ) {
      const page = (await api("POST", "/graphql", { query, variables: { o: owner, r: repo, n, c } }))?.data?.repository?.pullRequest?.reviewThreads;
      if (!page) throw new Error("could not read review threads");
      threads.push(...page.nodes);
      if (!page.pageInfo?.hasNextPage) break;
      c = page.pageInfo.endCursor;
    }
    const open = threads.filter((t) => !t.isResolved);
    if (open.length) return { state: "failure", description: `${open.length} unresolved review thread(s): verify and answer each, then resolve`, details: open.map((t) => `open: ${t.comments.nodes[0]?.url ?? "unknown thread"}`) };
    if (reviewed) return { state: "success", description: appComplete ? "independent review complete for this head and base" : "Codex review complete, no open findings" };
    const readyAt = timeline.filter((e) => e.event === "ready_for_review").map((e) => Date.parse(e.created_at));
    const since = Math.max(Date.parse(pr.created_at ?? 0) || 0, baseChangedAt, ...readyAt), mins = Math.floor((now - since) / 60000);
    const candidate = baseChangedAt ? "this head and base" : "this head";
    if (mins < 20) return { state: "pending", description: `awaiting a completed review of ${candidate} (${mins} min)` };
    return { state: "failure", description: `no completed review of ${candidate} after ${mins} min; request a review` };
  }
}
