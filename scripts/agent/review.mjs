// The `review` verdict for a pull request: everything that lives in its conversation, not its code. Gate checks the
// code; this checks the Codex verdict and its threads, the evidence comment for UI changes, and a promotion's design
// sign-off. It only reads, through the caller's GitHub API function, so the org launcher (every tick), an org's merge
// helper and scripts/agent/verdict-recheck share one rule (a pack-sync PR gets no exemption: a person fixes it on
// their own branch, or it is reviewed like any other):
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
  // A promotion (the default branch into another) is judged by the default branch's pack: that is where sync lands a
  // release, and the production branch only gets it through this very promotion.
  const info = (await api("GET", R)) ?? {};
  // Only this repository's own default branch promotes: a fork's branch of the same name is an ordinary PR.
  const promotion = Boolean(info.default_branch) && pr.head?.repo?.full_name === `${owner}/${repo}` && pr.head?.ref === info.default_branch && pr.base?.ref !== info.default_branch;
  const cfgRef = promotion ? pr.head.sha : pr.base?.sha ?? pr.base?.ref ?? "";
  const read = async (f) => b64(await api("GET", `${R}/contents/${f}?ref=${encodeURIComponent(cfgRef)}`));
  const pack = files?.pack ?? (await read("scripts/agent/pack.json")), std = files?.std ?? (await read("standards.json")) ?? {};
  if (!pack) return null;
  if (!pack.review_status && !force) return null; // gate's own steps still enforce this for the org
  // base, base_sha: what was judged against (the pack is read at that commit); a poster re-reads the PR and posts only
  // if its head and base (ref and commit) are unchanged.
  const verdict = (state, description, details = []) => ({ state, description: description.slice(0, 140), sha: head, base: pr.base?.ref ?? null, base_sha: pr.base?.sha ?? null, target_url: pr.html_url, details });

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
    if (flow === "staged" && promotion) {
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

// Judge and post `review` for pull requests (the launcher's tick, verdict-recheck). A status belongs to a commit, so
// every open ready PR on the head is read and judged in three full passes; only when all three agree is the worst
// verdict of the last one posted. Anything that moved meanwhile (head, base ref or commit, state, draft, verdict)
// or could not be judged gets `pending` on every head involved, so an earlier success never stands for a state that
// was not judged. Callers run one pass at a time (the launcher's tick).
//   postReviews({ api, owner, repo, prs | all: true, dryRun, force, serverUrl, log }) -> { posted, failed }
export async function postReviews({ api, owner, repo, prs = [], all = false, dryRun = false, force = false, serverUrl = "https://github.com", log = console.log }) {
  const R = `/repos/${owner}/${repo}`;
  const listOpen = async () => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `${R}/pulls?state=open&per_page=100&page=${p}`)) ?? []; out.push(...b); if (b.length < 100) return out; } };
  const rank = { failure: 2, pending: 1, success: 0 }, done = new Set();
  let failed = 0, posted = 0;
  const post = async (sha, state, description, target_url) => {
    if (dryRun || force) { log(`${sha.slice(0, 7)}: would post review=${state} (${description}); ${force ? "--force only evaluates" : "dry run"}`); return false; }
    try { await api("POST", `${R}/statuses/${sha}`, { state, context: "review", description: description.slice(0, 140), target_url }); posted++; log(`${sha.slice(0, 7)}: posted review=${state} (${description.slice(0, 140)})`); return true; }
    catch (e) { failed++; log(`could not post review on ${sha.slice(0, 7)} (${e.message}); GH_TOKEN must be the org App's token with statuses: write`); return false; }
  };
  const ready = (p) => Boolean(p) && (p.state ?? "open") === "open" && !p.draft;
  const shape = (p) => JSON.stringify([p?.head?.sha ?? null, p?.base?.ref ?? null, p?.base?.sha ?? null, ready(p)]);
  // Every open ready PR on `sha`: the PR as read and its verdict (null where review does not apply).
  let seen = new Set(); // every head observed for the current target, so an error can pend all of them
  const pass = async (sha) => {
    const out = new Map();
    for (const l of (await listOpen()).filter((p) => !p.draft && p.head?.sha === sha)) {
      const pr = await api("GET", `${R}/pulls/${l.number}`);
      if (ready(pr)) seen.add(pr.head.sha);
      const v = await reviewStatus({ api, owner, repo, pr: l.number, force, serverUrl });
      if (v?.sha) seen.add(v.sha); // the verdict may have seen a newer head than the read above
      out.set(l.number, { pr, v, sig: shape(pr) + JSON.stringify([v?.sha ?? null, v?.base ?? null, v?.base_sha ?? null, v?.state ?? null, v?.description ?? null]) });
    }
    return out;
  };
  const listed = (await listOpen()).filter((p) => !p.draft);
  const targets = all ? listed.map((p) => p.number) : prs;
  for (const n of targets) {
    let sha = listed.find((p) => p.number === n)?.head?.sha; // known from the listing, so an error below can still pend it (--all or not)
    seen = new Set(sha ? [sha] : []);
    try {
      const pr = await api("GET", `${R}/pulls/${n}`);
      if (ready(pr)) seen.add(pr.head.sha);
      if (!ready(pr)) { log(`#${n}: nothing to post (draft or closed)`); continue; }
      sha = pr.head.sha;
      if (done.has(sha)) continue;
      done.add(sha);
      // Three full passes (each PR read and judged again); the verdict posted is the last one, and only if all agree.
      const passes = [await pass(sha), await pass(sha), await pass(sha)], last = passes[2];
      const nums = new Set([n, ...passes.flatMap((x) => [...x.keys()])]);
      const heads = new Set([sha, ...passes.flatMap((x) => [...x.values()].filter((y) => ready(y.pr)).map((y) => y.pr.head.sha))]);
      let moved = !last.has(n) ? n : [...nums].find((k) => passes.some((x) => x.has(k) !== last.has(k) || (x.has(k) && x.get(k).sig !== last.get(k).sig))) ?? 0;
      if (moved) {
        for (const k of nums) { const now = await api("GET", `${R}/pulls/${k}`); if (ready(now)) heads.add(now.head.sha); } // where each PR is now
        for (const h of heads) await post(h, "pending", `#${moved} changed while being judged; re-judging`, pr.html_url);
        continue;
      }
      const b = last;
      const judged = [...b].filter(([, x]) => x.v).sort(([, x], [, y]) => rank[y.v.state] - rank[x.v.state]);
      if (!judged.length) { log(`#${n}: nothing to post (not engine-managed, or review is off on its base)`); continue; }
      const [from, { v }] = judged[0];
      for (const d of v.details ?? []) log(`#${from} ${sha.slice(0, 7)}: ${d}`);
      await post(sha, v.state, from === n ? v.description : `#${from}: ${v.description}`, v.target_url);
    } catch (e) {
      failed++;
      log(`#${n}: review could not be evaluated (${e.message})`);
      for (const h of seen) await post(h, "pending", `#${n}: review could not be evaluated; retrying`, "");
    }
  }
  return { posted, failed };
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
