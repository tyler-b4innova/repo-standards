#!/usr/bin/env node
// Affected-test selection for a pull request.
//   select.mjs [plan] [--base <ref>] [--files a,b] [--json]   what runs and why
//   select.mjs --list e2e|unit|all                             ALL (run the whole suite), or the selected test files, one per line (empty = none)
// Two rules, nothing else:
//  1. E2E is selected at app scope. A change to any file outside the tests (the app, a workspace package it uses, data, docs) runs the app's whole e2e
//     suite: an e2e test exercises the app over HTTP, which no import graph can enumerate. A change that touches only test files runs those tests
//     (and the tests importing a changed test helper).
//  2. Unit tests (node:test, vitest, mocha, jest tests outside an e2e/ directory) are selected by import-graph reachability from the changed files.
//     A test is always run when anything it depends on loads code the tracer cannot resolve to concrete files (a computed or template import or
//     require, import.meta.glob, an unresolved or workspace package import, a file read, a spawned process). No exemptions.
// The full suite runs for: any event but pull_request, an unknown base, a deleted file, a configuration or dependency change, "affected": false in
// standards.json, GATE_SELECT=full. standards.json "affected" may be {"smoke": [globs] (always run), "foundations": [globs] (always full)}.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { posix } from "node:path";
import { fileURLToPath } from "node:url";

const git = (...a) => execFileSync("git", a, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28 });
const globRe = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
const isSpec = (f) => /\.(spec|test)\.[cm]?[jt]sx?$/.test(f);
const inTestDir = (f) => /(^|\/)(tests?|e2e|__tests__)\//.test(f);
const SOURCE = /\.(?:[cm]?[jt]sx?|astro|svelte|vue|css|scss|html)$/;
const SKIP = /(^|\/)(node_modules|dist|build|\.astro|\.next|\.wrangler|coverage|test-results|playwright-report)\//;
// Configuration and dependencies: a change can break any test.
const FOUNDATIONS = ["**/package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "yarn.lock", ".yarnrc.yml", ".npmrc",
  "**/*.config.*", "**/tsconfig*.json", "**/wrangler.{json,jsonc,toml}", "**/wrangler.*.{json,jsonc,toml}", "standards.json", ".github/workflows/**", "scripts/agent/**",
  ".node-version", ".nvmrc", ".tool-versions", ".env*", "**/.env*"].map(globRe);
const NODE_BUILTIN = new Set(["assert", "buffer", "child_process", "crypto", "events", "fs", "http", "https", "net", "os", "path", "process", "stream", "timers", "url", "util", "zlib", "test"]);
const NODE_RUNNER = /node:test|['"](?:vitest|mocha|@jest\/globals|bun:test)['"]/;
// Loads the tracer cannot resolve to files.
const OPAQUE = /import\.meta\.(?:glob|resolve)|require\.resolve|createRequire|\b(?:readFile|readFileSync|createReadStream|spawn|spawnSync|execSync|execFile|execFileSync|fork|eval)\s*\(|new\s+(?:Worker|Function)\b/;
const calls = (t) => [...t.matchAll(/(?<![.\w$])(?:import|require)\s*\(\s*([^)]{0,200})/g)].map((m) => m[1]);
const PLAIN = /^(["'])([^"'\n\\]*)\1\s*(,|$)/;
const PATTERNS = [
  /\bimport\s+(?:[\w*${}\s,]+?\s+from\s+)?['"]([^'"\n]+)['"]/g,
  /\bexport\s+(?:\*(?:\s+as\s+\w+)?|\{[^}]*\})\s+from\s+['"]([^'"\n]+)['"]/g,
  /(?<![.\w$])(?:import|require)\s*\(\s*['"]([^'"\n]+)['"]\s*[,)]/g,
  /@import\s+(?:url\()?['"]([^'"\n]+)['"]/g,
  /<(?:script|link|img|source)\b[^>]*?\b(?:src|href)=["'](\.{1,2}\/[^"'\n]+)["']/g,
];

/** The import graph of `files`, and the files that load something the tracer cannot resolve (`opaque`). */
export function buildGraph(files, read, deps) {
  const set = new Set(files), edges = new Map(), opaque = new Set(), text = new Map();
  const exts = ["", ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".astro", ".css", ".json", "/index.ts", "/index.tsx", "/index.js", "/index.mjs"];
  const find = (base) => {
    for (const e of exts) if (set.has(base + e)) return base + e;
    const t = base.replace(/\.[cm]?js$/, ""); // TypeScript names the emitted extension: ./a.js is ./a.ts
    if (t !== base) for (const e of [".ts", ".tsx", ".mts", ".cts"]) if (set.has(t + e)) return t + e;
    return null;
  };
  for (const f of files) {
    if (!SOURCE.test(f) || SKIP.test(f)) continue;
    const t = read(f) ?? "", to = new Set();
    text.set(f, t);
    if (OPAQUE.test(t) || calls(t).some((a) => !PLAIN.test(a.trimStart()))) opaque.add(f);
    for (const p of PATTERNS) for (const m of t.matchAll(p)) {
      const spec = m[1].split(/[?#]/)[0];
      if (spec.startsWith(".")) { const r = find(posix.normalize(posix.join(posix.dirname(f), spec))); if (r) to.add(r); else opaque.add(f); continue; }
      if (/^(node|cloudflare|https?|data|astro|virtual|npm|bun|jsr):/.test(spec)) continue;
      const name = /^@[^/]+\/[^/]+|^[^/@#$~][^/]*|^[@#$~][^/]*/.exec(spec)?.[0];
      if (!name || !(deps.has(name) || NODE_BUILTIN.has(name))) opaque.add(f); // an alias, a workspace package or an undeclared package
    }
    edges.set(f, to);
  }
  return { edges, opaque, text };
}

/** The tests that depend on `file`, with the shortest chain from the test to it. */
function reaching(edges, tests, file) {
  const rev = new Map();
  for (const [from, to] of edges) for (const t of to) { if (!rev.has(t)) rev.set(t, new Set()); rev.get(t).add(from); }
  const parent = new Map([[file, null]]), queue = [file], out = [];
  while (queue.length) {
    const cur = queue.shift();
    for (const d of rev.get(cur) ?? []) {
      if (parent.has(d)) continue;
      parent.set(d, cur);
      if (tests.has(d)) { out.push(d); continue; }
      queue.push(d);
    }
  }
  return out.map((test) => { const chain = []; for (let at = test; at; at = parent.get(at)) chain.push(at); return { test, chain }; });
}

/**
 * @returns {{ mode: "full"|"scoped", e2eAll: boolean, full: string[], notes: string[], tests: Map<string, string[]>, kinds: Map<string, "e2e"|"unit">, universe: string[] }}
 * `tests` maps each selected test to why; with `e2eAll` every e2e test is selected and the e2e run is not filtered by file.
 */
export function select({ files, changed, deleted = [], read, config = {}, deps = new Set(), forced = null }) {
  const graph = buildGraph(files, read, deps), universe = files.filter((f) => isSpec(f) && !SKIP.test(f)).sort();
  // An e2e test is a Playwright spec, or any test under an e2e/ directory; a unit test is a node-runner test elsewhere.
  const kinds = new Map(universe.map((t) => [t, NODE_RUNNER.test(graph.text.get(t) ?? "") && !/(^|\/)e2e\//.test(t) ? "unit" : "e2e"]));
  const reasons = new Map(), full = [], notes = [], tests = new Set(universe);
  const why = (t, r) => { if (!reasons.has(t)) reasons.set(t, []); if (!reasons.get(t).includes(r)) reasons.get(t).push(r); };
  const globs = (k) => (Array.isArray(config[k]) ? config[k] : []).map(globRe), foundations = [...FOUNDATIONS, ...globs("foundations")];
  if (forced) full.push(forced);
  if (!universe.length) full.push("no *.spec.* or *.test.* file was found, so there is nothing to place");
  for (const f of deleted) if (!isSpec(f)) full.push(`${f} was deleted, and what depended on it cannot be listed`);
  let appChanged = null;
  for (const f of changed) {
    if (isSpec(f)) { if (tests.has(f)) why(f, `${f} changed`); else full.push(`${f} is a test file the selection cannot find`); continue; }
    if (foundations.some((r) => r.test(f))) { full.push(`${f} is configuration or a dependency, which can break any test`); continue; }
    if (inTestDir(f)) { // a test helper: the tests importing it
      const r = reaching(graph.edges, tests, f);
      if (!r.length) full.push(`no test imports the test helper ${f}`);
      for (const { test, chain } of r) why(test, `${f} changed: ${chain.join(" -> ")}`);
      continue;
    }
    appChanged ??= f;
    for (const { test, chain } of reaching(graph.edges, tests, f)) if (kinds.get(test) === "unit") why(test, `${f} changed: ${chain.join(" -> ")}`);
  }
  const e2eAll = appChanged !== null;
  if (e2eAll) for (const t of universe) if (kinds.get(t) === "e2e") why(t, `${appChanged} (outside the tests) changed: the app's whole e2e suite runs`);
  const smoke = globs("smoke");
  for (const t of universe) {
    if ((read(t) ?? "").split("\n").slice(0, 5).some((l) => l.trim() === "// @smoke") || smoke.some((r) => r.test(t))) why(t, "the smoke set always runs");
    if (kinds.get(t) !== "unit") continue;
    const seen = new Set([t]), todo = [t];
    while (todo.length) for (const x of graph.edges.get(todo.pop()) ?? []) if (!seen.has(x)) { seen.add(x); todo.push(x); }
    const o = [...seen].find((x) => graph.opaque.has(x));
    if (o) why(t, `it depends on ${o}, which loads code the tracer cannot resolve, so it always runs`);
  }
  return { mode: full.length ? "full" : "scoped", e2eAll, full, notes, tests: reasons, kinds, universe };
}

/** The changed files against the pull request's base. `null` base: it cannot be named. */
export function context({ env = process.env, base = "", files = "" } = {}) {
  let event = {};
  if (env.GITHUB_EVENT_PATH && existsSync(env.GITHUB_EVENT_PATH)) { try { event = JSON.parse(readFileSync(env.GITHUB_EVENT_PATH, "utf8")); } catch {} }
  if (files) return { changed: files.split(",").map((f) => f.trim()).filter(Boolean), deleted: [], base: "(--files)" };
  let sha = base || env.GATE_BASE || "";
  try {
    const head = git("rev-parse", "HEAD").trim(), parents = git("rev-list", "--parents", "-n", "1", "HEAD").trim().split(" ").slice(1);
    if (!sha && head !== event.pull_request?.head?.sha && parents.length === 2) sha = parents[0];
    else if (sha || event.pull_request?.base?.sha) sha = git("merge-base", sha || event.pull_request.base.sha, "HEAD").trim();
    else for (const r of ["origin/HEAD", "origin/main", "origin/master", "main", "master"]) { try { sha = git("merge-base", r, "HEAD").trim(); break; } catch {} }
    if (!sha) return { changed: [], deleted: [], base: null };
    const changed = [], deleted = [], rows = git("diff", "--name-status", "--no-renames", "-z", sha).split("\0").filter(Boolean);
    for (let i = 0; i + 1 < rows.length; i += 2) (rows[i] === "D" ? deleted : changed).push(rows[i + 1]);
    // Untracked files count where a person is working; a CI checkout holds none that are not build output.
    if (env.GITHUB_ACTIONS !== "true") changed.push(...git("ls-files", "-o", "--exclude-standard", "-z").split("\0").filter(Boolean));
    return { changed: [...new Set(changed)].sort(), deleted: deleted.sort(), base: sha };
  } catch { return { changed: [], deleted: [], base: null }; }
}

/** The whole selection for the checkout in the current directory. */
export function plan({ env = process.env, base = "", files = "", config } = {}) {
  const json = (f) => { try { return JSON.parse(readFileSync(f, "utf8")); } catch { return {}; } };
  const cfg = config ?? json("standards.json").affected, pkg = json("package.json"), local = /^(workspace:|file:|link:|portal:)/;
  const deps = new Set(Object.entries({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.optionalDependencies, ...pkg.peerDependencies }).filter(([, v]) => !local.test(String(v))).map(([n]) => n));
  const tracked = git("ls-files", "-co", "--exclude-standard", "-z").split("\0").filter(Boolean).filter((f) => existsSync(f));
  const read = (f) => { try { return readFileSync(f, "utf8"); } catch { return null; } };
  const ctx = context({ env, base, files });
  let forced = null;
  if (cfg === false) forced = 'standards.json sets "affected": false';
  else if (env.GATE_SELECT === "full") forced = "GATE_SELECT=full";
  else if (env.GITHUB_EVENT_NAME && env.GITHUB_EVENT_NAME !== "pull_request") forced = `a ${env.GITHUB_EVENT_NAME} run is not a pull request`;
  else if (ctx.base === null) forced = "the pull request's base cannot be found in this checkout";
  const result = select({ files: tracked, changed: ctx.changed, deleted: ctx.deleted, read, config: cfg && typeof cfg === "object" ? cfg : {}, deps, forced });
  return { ...result, base: ctx.base, changed: ctx.changed, deleted: ctx.deleted };
}

export function describe(r) {
  const total = r.universe.length, lines = [`select: ${r.mode === "full" ? `FULL suite (${total} test files)` : `${r.tests.size} of ${total} test files${r.e2eAll ? ", the whole e2e suite" : ""}`}${r.base ? ` (base ${String(r.base).slice(0, 9)})` : ""}; ${r.changed.length} changed file(s)${r.deleted.length ? `, ${r.deleted.length} deleted` : ""}`];
  for (const w of r.full) lines.push(`  full because ${w}`);
  if (r.mode === "scoped") for (const [t, w] of [...r.tests].sort(([a], [b]) => (a < b ? -1 : 1))) lines.push(`  ${t} [${r.kinds.get(t)}]: ${w[0]}`);
  return lines.join("\n");
}
/** The selected test files of one kind (e2e, unit, all); null when that kind's whole suite runs. */
export function listFor(r, kind = "all") {
  if (r.mode === "full" || (r.e2eAll && kind === "e2e")) return null;
  return [...r.tests.keys()].filter((t) => kind === "all" || r.kinds.get(t) === kind).sort();
}
export function summarize(text, env = process.env) {
  if (env.GITHUB_STEP_SUMMARY) { try { appendFileSync(env.GITHUB_STEP_SUMMARY, `\n\`\`\`\n${text}\n\`\`\`\n`); } catch {} }
  return text;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const a = process.argv.slice(2), opt = (n) => { const i = a.indexOf(`--${n}`); return i >= 0 ? a[i + 1] ?? "" : ""; };
  if (a[0] && a[0] !== "plan" && !a[0].startsWith("--")) { console.error("usage: select.mjs [plan] [--base <ref>] [--files a,b] [--json] | --list e2e|unit|all"); process.exit(2); }
  try { process.chdir(git("rev-parse", "--show-toplevel").trim()); } catch {}
  const r = plan({ base: opt("base"), files: opt("files") });
  if (a.includes("--list")) { const l = listFor(r, opt("list") || "all"); console.log(l === null ? "ALL" : l.join("\n")); }
  else if (a.includes("--json")) console.log(JSON.stringify({ mode: r.mode, e2eAll: r.e2eAll, full: r.full, tests: Object.fromEntries(r.tests) }, null, 2));
  else console.log(summarize(describe(r)));
}
