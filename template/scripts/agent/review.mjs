// The review rule for a pull request: everything that lives in its conversation, not its code. Gate checks the code;
// this checks the Codex verdict and its threads, the evidence comment for UI changes, and a promotion's design
// sign-off. It only reads, through the caller's GitHub API function, so a launcher or merge helper can ask it before
// merging (a pack-sync PR gets no exemption: a person fixes it on their own branch, or it is reviewed like any other):
//   reviewStatus({ api, owner, repo, pr }) -> null | { state: "success"|"failure"|"pending", description, sha, base, base_sha, target_url, details }
// api(method, path, body?) resolves parsed JSON, null for a 404, and throws on any other failure. Paths are from the
// API root ("/repos/o/r/pulls/7"); GraphQL is api("POST", "/graphql", { query, variables }).
// null: not an engine-managed repository, or a draft.

const b64 = (f) => (f?.content ? JSON.parse(Buffer.from(f.content, "base64").toString("utf8")) : null);
const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
const short = (s) => s.slice(0, 7);

// pull: the PR as the caller already read it (so the verdict is for exactly that state); read here when omitted.
export async function reviewStatus({ api, owner, repo, pr: n, pull, now = Date.now(), serverUrl = "https://github.com" }) {
  const R = `/repos/${owner}/${repo}`;
  const all = async (path) => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `${path}${path.includes("?") ? "&" : "?"}per_page=100&page=${p}`)) ?? []; out.push(...b); if (b.length < 100) return out; } };
  const pr = pull ?? (await api("GET", `${R}/pulls/${n}`));
  if (!pr || (pr.state ?? "open") !== "open" || pr.draft) return null;
  const head = pr.head.sha;
  // The rule comes from the base branch (the org's current pack and the repository's
  // settings there), so a pull request cut before a pack release is judged like any other, and cannot relax its own review.
  // A promotion (the default branch into another) is judged by the default branch's pack: that is where sync lands a
  // release, and the production branch only gets it through this very promotion.
  const info = (await api("GET", R)) ?? {};
  // Only this repository's own default branch promotes: a fork's branch of the same name is an ordinary PR.
  const promotion = Boolean(info.default_branch) && pr.head?.repo?.full_name === `${owner}/${repo}` && pr.head?.ref === info.default_branch && pr.base?.ref !== info.default_branch;
  // GitHub may leave pull.base.sha at the commit from when the PR was opened, even after sync updates the base.
  // Resolve the current base ref once, then read both policy files from that exact commit.
  const baseHead = promotion ? pr.head.sha : pr.base?.ref
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
          const files = paths(all3k).filter((f) => !f.startsWith(".evidence/"));
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
    // Without a pull_request gate run (a PR older than std-gate), the head commit's date and the PR's creation stand in,
    // so the 20 minutes still run out instead of restarting at every evaluation.
    const commitAt = runs.length ? 0 : Date.parse((await api("GET", `${R}/commits/${head}`))?.commit?.committer?.date ?? 0) || 0;
    const firstRun = runs.length ? Math.min(...runs.map((r) => Date.parse(r.created_at))) : Math.max(Date.parse(pr.created_at ?? 0) || 0, commitAt);
    const pushedAt = Math.max(Math.min(firstRun || now, now), baseAt);
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
