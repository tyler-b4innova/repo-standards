// The `review` verdict for a pull request: everything that lives in its conversation, not its code. Gate checks the
// code; this checks the Codex verdict and its threads, the evidence comment for UI changes, and a promotion's design
// sign-off. It only reads, through the caller's GitHub API function, so the org launcher (every tick), TYNTY's merge
// helper and scripts/agent/verdict-recheck share one rule:
//   reviewStatus({ api, owner, repo, pr }) -> null | { state: "success"|"failure"|"pending", description, sha, target_url, details }
// api(method, path, body?) resolves parsed JSON, null for a 404, and throws on any other failure. Paths are from the
// API root ("/repos/o/r/pulls/7"); GraphQL is api("POST", "/graphql", { query, variables }).
// null: not an engine-managed repository, a draft, or the repository's pack leaves review to gate (review_status off).

const b64 = (f) => (f?.content ? JSON.parse(Buffer.from(f.content, "base64").toString("utf8")) : null);
const glob = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
const short = (s) => s.slice(0, 7);

// files: optional { pack, std } already read (gate passes its checkout's); otherwise read at the PR head.
export async function reviewStatus({ api, owner, repo, pr: n, files, now = Date.now(), serverUrl = "https://github.com", force = false }) {
  const R = `/repos/${owner}/${repo}`;
  const all = async (path) => { const out = []; for (let p = 1; ; p++) { const b = (await api("GET", `${path}${path.includes("?") ? "&" : "?"}per_page=100&page=${p}`)) ?? []; out.push(...b); if (b.length < 100) return out; } };
  const pr = await api("GET", `${R}/pulls/${n}`);
  if (!pr || (pr.state ?? "open") !== "open" || pr.draft) return null;
  const head = pr.head.sha;
  const read = async (f) => b64(await api("GET", `${R}/contents/${f}?ref=${head}`));
  const pack = files?.pack ?? (await read("scripts/agent/pack.json")), std = files?.std ?? (await read("standards.json")) ?? {};
  if (!pack) return null;
  if (!pack.review_status && !force) return null; // gate's own steps still enforce this for the org
  const verdict = (state, description, details = []) => ({ state, description: description.slice(0, 140), sha: head, target_url: pr.html_url, details });
  if (pack.sync_app_login && pr.user?.login === pack.sync_app_login && /^standards\/v\d+\.\d+\.\d+$/.test(pr.head.ref))
    return verdict("success", "pack sync pull request: gate and the pack's own CI cover it");

  const info = (await api("GET", R)) ?? {};
  const uiOpt = std.ui_paths, inc = (Array.isArray(uiOpt) ? uiOpt : uiOpt?.include ?? pack.ui_paths ?? []).map(glob);
  const ign = [...(pack.ui_ignore ?? []), ...(uiOpt?.ignore ?? [])].map(glob);
  const ui = (fs) => fs.filter((f) => inc.some((r) => r.test(f)) && !ign.some((r) => r.test(f)));
  const changed = ui((await all(`${R}/pulls/${n}/files`)).map((f) => f.filename));
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
      const miss = [], listed = new Map();
      for (const u of urls) {
        const m = u.match(pin), dir = m?.[2].split("/").slice(0, -1).join("/"), key = m && `${m[1]}:${dir}`;
        if (m && !listed.has(key)) listed.set(key, new Set(((await api("GET", `${R}/contents/${dir}?ref=${m[1]}`)) ?? []).map((f) => f.path)));
        if (!m || !listed.get(key).has(decodeURIComponent(m[2]))) miss.push(u);
      }
      if (miss.length) { bad.push(`${who}: unresolved (need this repo, a 40-hex SHA, the file): ${miss.join(" ")}`); continue; }
      const shas = [...new Set(urls.map((u) => u.match(pin)[1]))], names = urls.map((u) => decodeURIComponent(u.match(pin)[2]));
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
      for (const s of shas) {
        const cmp = await api("GET", `${R}/compare/${s}...${head}`);
        if (!cmp || !["ahead", "identical"].includes(cmp.status)) { outside = s; break; }
        for (const k of cmp.commits ?? []) {
          const files = ((await api("GET", `${R}/commits/${k.sha}`))?.files ?? []).map((f) => f.filename).filter((f) => !f.startsWith(".evidence/"));
          if (ui(files).length) { stale = k.sha; break; }
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
