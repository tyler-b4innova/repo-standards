#!/usr/bin/env node
// The review rule as a launcher or merge helper calls it: the package export `repo-standards/review`, for one pull
// request, against the GitHub API at GITHUB_API_URL (a stand-in in tests). Prints the verdict's details and
// description; exits 0 on success or when not judged (null), 1 on failure or pending.
//   GITHUB_API_URL=… GITHUB_REPOSITORY=o/r node test/review-run.mjs <pr>
import { reviewStatus } from "repo-standards/review";

const root = process.env.GITHUB_API_URL.replace(/\/$/, ""), gql = process.env.GITHUB_GRAPHQL_URL || `${root}/graphql`;
const [owner, repo] = process.env.GITHUB_REPOSITORY.split("/");
const api = async (method, path, body) => {
  const r = await fetch(path === "/graphql" ? gql : `${root}${path}`, { method, headers: { Authorization: "Bearer t", Accept: "application/vnd.github+json", ...(body && { "Content-Type": "application/json" }) }, body: body && JSON.stringify(body) });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return r.json();
};
let v;
try { v = await reviewStatus({ api, owner, repo, pr: Number(process.argv[2]) }); }
catch (e) { console.log(`review: error: ${e.message}`); process.exit(1); }
if (!v) { console.log("review: not judged (draft, closed, or not engine-managed)"); process.exit(0); }
for (const d of v.details ?? []) console.log(`review: ${d}`);
console.log(`review ${v.state} on ${v.sha.slice(0, 7)}: ${v.description}`);
process.exit(v.state === "success" ? 0 : 1);
