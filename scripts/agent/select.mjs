#!/usr/bin/env node
// Affected-test selection: the tests a pull request's changes can reach, plus a smoke set. Nothing is skipped because it was not understood.
//   select.mjs [plan] [--base <ref>] [--files a,b] [--json]   what runs and why
//   select.mjs --list playwright|node|all                      ALL (the full suite runs), or the selected test files, one per line (empty = none)
// A test is a file named *.spec.* or *.test.* (js, ts, mjs, cjs, jsx, tsx). One that imports node:test, vitest, mocha or jest globals is a node test; the rest are taken to be Playwright specs.
// The import graph (relative imports, tsconfig path aliases, import.meta.glob, CSS and HTML references) is followed from each changed file to the tests
// that depend on it. A test also depends on the page file serving each route it visits (src/pages, pages) and on the file defining each API route
// it names. Anything this cannot place runs the full suite: a deleted file, a file no test reaches, a configuration or dependency change, an import it
// cannot resolve, an unknown base. standards.json "affected": false always runs the full suite; GATE_SELECT=full|scoped overrides for one run.
// "affected" may also be {"smoke": [globs], "foundations": [globs] (always full), "inert": [globs] (never selects)}.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { posix } from "node:path";
import { fileURLToPath } from "node:url";

const git = (...a) => execFileSync("git", a, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28 });
const globRe = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\{([^}]+)\}/g, (_, a) => `(${a.split(",").join("|")})`)
  .replace(/\*\*\//g, "\0").replace(/\*\*/g, "\x01").replace(/\*/g, "[^/]*").replace(/\0/g, "(.*/)?").replace(/\x01/g, ".*") + "$");
const isTest = (f) => /\.(spec|test)\.[cm]?[jt]sx?$/.test(f);
const SOURCE = /\.(?:[cm]?[jt]sx?|astro|svelte|vue|css|scss|md|mdx|html|json)$/;
const SKIP = /(^|\/)(node_modules|dist|build|\.astro|\.next|\.wrangler|coverage|test-results|playwright-report)\//;
const SUPPORT = /(^|\/)(support|helpers|fixtures|utils)\//;
// Shared foundations: a change to one can break any test.
const FOUNDATIONS = ["package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "yarn.lock", ".yarnrc.yml", ".npmrc",
  "**/*.config.*", "**/tsconfig*.json", "**/wrangler.{json,jsonc,toml}", "**/wrangler.*.{json,jsonc,toml}", "standards.json", ".github/workflows/**", "scripts/agent/**", ".node-version", ".nvmrc", ".tool-versions", ".env*", "**/.env*"].map(globRe);
// Files no test exercises.
const INERT = ["docs/**", "**/*.md", "LICENSE", "**/LICENSE", "**/LICENSE.*", ".github/ISSUE_TEMPLATE/**", ".github/PULL_REQUEST_TEMPLATE.md", ".github/CODEOWNERS", ".agents/**", ".claude/**", ".codex/**",
  ".gitignore", ".gitattributes", ".gitleaks.toml", ".gitleaksignore", ".vscode/**", ".idea/**", "**/*.d.ts"].map(globRe);
const isPage = (f) => /^(src\/)?pages\//.test(f) && !f.replace(/^(src\/)?pages\//, "").split("/").some((p) => p.startsWith("_"));
const pageRoute = (f) => { const r = "/" + f.replace(/^(src\/)?pages\//, "").replace(/\.[^./]+$/, "").replace(/(^|\/)index$/, "").replace(/\[\.\.\.[^\]]+\]/g, "**").replace(/\[[^\]]+\]/g, "*"); return r.length > 1 ? r.replace(/\/+$/, "") : r; };
const seg = (r) => r.split("/").filter(Boolean);
const same = (p, q) => p === q || p === "*" || q === "*" || p.startsWith(":") || q.startsWith(":");
function routeMatches(a, b) {
  const x = seg(a), y = seg(b);
  for (const [open, other] of [[x, y], [y, x]]) {
    if (open.at(-1) !== "**") continue;
    const prefix = open.slice(0, -1);
    return other.length >= prefix.length && prefix.every((p, i) => same(p, other[i]));
  }
  return x.length === y.length && x.every((p, i) => same(p, y[i]));
}
const isApi = (r) => /^\/(?:api|hooks)(?:\/|$)/.test(r);
const PATTERNS = [
  /\bimport\s+(?:[\w*${}\s,]+?\s+from\s+)?['"]([^'"\n]+)['"]/g,
  /\bexport\s+(?:\*(?:\s+as\s+\w+)?|\{[^}]*\})\s+from\s+['"]([^'"\n]+)['"]/g,
  /\bimport\(\s*['"]([^'"\n]+)['"]\s*\)/g,
  /\brequire\(\s*['"]([^'"\n]+)['"]\s*\)/g,
  /@import\s+(?:url\()?['"]([^'"\n]+)['"]/g,
  /\bnew URL\(\s*['"](\.{1,2}\/[^'"\n]+)['"]\s*,\s*import\.meta\.url/g,
  /<(?:script|link|img|source)\b[^>]*?\b(?:src|href)=["'](\.{1,2}\/[^"'\n]+)["']/g,
  /^layout:\s*["']?(\.{1,2}\/[^"'\s]+)["']?\s*$/gm,
];
const specifiers = (text) => { const out = new Set(); for (const p of PATTERNS) for (const m of text.matchAll(p)) out.add(m[1]); return [...out]; };
const globImports = (text) => {
  const out = new Set();
  for (const c of text.matchAll(/import\.meta\.glob\(\s*(\[[^\]]*\]|(["'`])[^"'`\n]*\2)/g)) for (const p of c[1].matchAll(/(["'`])([^"'`\n]+)\1/g)) if (/^[./]/.test(p[2])) out.add(p[2]);
  for (const c of text.matchAll(/\bimport\(\s*`(\.{1,2}\/[^`$]*)\$\{/g)) out.add(`${c[1]}**`);
  return [...out];
};
const pathLiterals = (text) => {
  const out = new Set();
  for (const m of text.matchAll(/(["'`])((?:\\.|(?!\1)[^\\\n])*)\1/g)) {
    let v = m[2].replace(/^(?:\$\{[^}]*\})+(?=\/)/, "");
    if (!v.startsWith("/")) continue;
    v = v.split(/[?#]/)[0].replace(/\$\{[^}]*\}/g, "*");
    if (/^\/[A-Za-z0-9_\-./:*[\]]*$/.test(v)) out.add(v.length > 1 ? v.replace(/\/+$/, "") : v);
  }
  return [...out];
};
// tsconfig "paths" / "baseUrl" (JSON with comments), so an aliased import is an edge and not a silent gap.
function aliases(read) {
  const out = [];
  for (const f of ["tsconfig.json", "jsconfig.json"]) {
    const t = read(f);
    if (t == null) continue;
    let o; try { o = JSON.parse(t.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'])\/\/[^\n]*/g, "$1").replace(/,(\s*[}\]])/g, "$1")); } catch { continue; }
    const base = posix.normalize(o.compilerOptions?.baseUrl ?? ".");
    if (o.compilerOptions?.baseUrl !== undefined) out.push({ prefix: "", base });
    for (const [k, v] of Object.entries(o.compilerOptions?.paths ?? {})) for (const t2 of v) out.push({ prefix: k.replace(/\*$/, ""), exact: !k.endsWith("*"), base: posix.normalize(posix.join(base, t2.replace(/\*$/, ""))) });
  }
  return out;
}

/** The import graph of `files` (repo-relative posix paths); `read(f)` returns a file's text or null. */
export function buildGraph(files, read, deps = new Set()) {
  const set = new Set(files), src = files.filter((f) => SOURCE.test(f) && !SKIP.test(f) && !f.endsWith(".json"));
  const text = new Map(src.map((f) => [f, read(f) ?? ""]));
  const alias = aliases(read), unresolved = [];
  const exts = ["", ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".astro", ".css", ".json", "/index.ts", "/index.tsx", "/index.js", "/index.mjs"];
  const find = (base) => {
    for (const e of exts) if (set.has(base + e)) return base + e;
    // TypeScript imports name the emitted extension: ./a.js is ./a.ts
    const t = base.replace(/\.[cm]?js$/, "");
    if (t !== base) for (const e of [".ts", ".tsx", ".mts", ".cts"]) if (set.has(t + e)) return t + e;
    return null;
  };
  const imports = new Map(), literals = new Map();
  for (const [f, t] of text) {
    const to = new Set();
    for (const s of specifiers(t)) {
      const spec = s.split(/[?#]/)[0];
      if (spec.startsWith(".")) { const r = find(posix.normalize(posix.join(posix.dirname(f), spec))); if (r) to.add(r); continue; }
      if (/^(node|cloudflare|https?|data|astro|virtual|npm|bun|jsr):/.test(spec) || spec.startsWith("/") && !set.has(spec.slice(1))) continue;
      let hit = null;
      for (const a of alias) { if (a.exact ? spec === a.prefix : spec.startsWith(a.prefix)) { hit = find(posix.normalize(a.exact ? a.base : posix.join(a.base, spec.slice(a.prefix.length)))); if (hit) break; } }
      if (hit) { to.add(hit); continue; }
      if (spec.startsWith("/") && set.has(spec.slice(1))) { to.add(spec.slice(1)); continue; }
      const name = /^@[^/]+\/[^/]+|^[^/@#$~][^/]*|^[@#$~][^/]*/.exec(spec)?.[0];
      if (!name || deps.has(name) || NODE_BUILTIN.has(name) || !deps.size && !/^[@#$~]/.test(spec)) continue; // a package
      unresolved.push({ file: f, text: `${f} imports ${s}` });
    }
    for (const g of globImports(t)) {
      const m = globRe(g.startsWith("/") ? g.slice(1) : posix.normalize(posix.join(posix.dirname(f), g)));
      for (const o of files) if (o !== f && m.test(o)) to.add(o);
    }
    imports.set(f, to); literals.set(f, pathLiterals(t));
  }
  const pages = new Map(); for (const f of files) if (isPage(f) && !SKIP.test(f)) pages.set(pageRoute(f), f);
  const owners = new Map();
  for (const [f, rs] of literals) {
    if (isTest(f) || f.endsWith(".d.ts") || SUPPORT.test(f)) continue;
    for (const r of rs) if (isApi(r) && seg(r).length > 1) { if (!owners.has(r)) owners.set(r, new Set()); owners.get(r).add(f); }
  }
  const edges = new Map([...imports].map(([f, t]) => [f, new Set(t)]));
  for (const [f, rs] of literals) {
    const own = edges.get(f), test = isTest(f), caller = test || /^(src|tests?|e2e)\//.test(f);
    for (const r of rs) {
      if (isApi(r)) { if (caller) for (const [o, fs] of owners) if (routeMatches(r, o)) for (const x of fs) if (x !== f) own.add(x); continue; }
      if (test) for (const [route, page] of pages) if (routeMatches(r, route)) own.add(page);
    }
  }
  return { edges, imports, literals, pages, unresolved, text };
}
const NODE_BUILTIN = new Set(["assert", "buffer", "child_process", "cluster", "crypto", "dns", "events", "fs", "http", "http2", "https", "net", "os", "path", "perf_hooks", "process", "querystring", "readline", "stream", "string_decoder", "timers", "tls", "url", "util", "v8", "vm", "worker_threads", "zlib", "module", "test"]);

/** The tests that reach `file`: { test, chain } with the shortest dependency chain from the test to the file. */
function reaching(graph, file) {
  const rev = new Map();
  for (const [from, to] of graph.edges) for (const t of to) { if (!rev.has(t)) rev.set(t, new Set()); rev.get(t).add(from); }
  const parent = new Map([[file, null]]), queue = [file], tests = [];
  while (queue.length) {
    const cur = queue.shift();
    for (const d of rev.get(cur) ?? []) {
      if (parent.has(d)) continue;
      parent.set(d, cur);
      if (isTest(d)) { tests.push(d); continue; }
      queue.push(d);
    }
  }
  return tests.map((test) => { const chain = []; for (let at = test; at; at = parent.get(at)) chain.push(at); return { test, chain }; });
}

/**
 * @param {{ files: string[], changed: string[], deleted?: string[], read: (f: string) => string|null, config?: object, deps?: Set<string>, forced?: string|null }} input
 * @returns {{ mode: "full"|"scoped", full: string[], notes: string[], tests: Map<string, string[]>, kinds: Map<string, "playwright"|"node">, universe: string[] }}
 */
export function select({ files, changed, deleted = [], read, config = {}, deps = new Set(), forced = null }) {
  const graph = buildGraph(files, read, deps);
  const universe = files.filter((f) => isTest(f) && !SKIP.test(f)).sort();
  const kinds = new Map(universe.map((t) => [t, /node:test|['"](?:vitest|mocha|@jest\/globals|bun:test)['"]/.test(graph.text.get(t) ?? read(t) ?? "") ? "node" : "playwright"]));
  const reasons = new Map(), full = [], notes = [];
  const why = (t, r) => { if (!reasons.has(t)) reasons.set(t, []); const l = reasons.get(t); if (!l.includes(r)) l.push(r); };
  const extra = (k) => (Array.isArray(config[k]) ? config[k] : []).map(globRe);
  const foundations = [...FOUNDATIONS, ...extra("foundations")], inert = [...INERT, ...extra("inert")], smokeGlobs = extra("smoke");
  if (forced) full.push(forced);
  if (!universe.length) full.push("no *.spec.* or *.test.* file was found, so there is nothing to place");
  for (const f of deleted) full.push(`${f} was deleted, and what depended on it cannot be listed`);
  // An import the graph cannot resolve matters only in a file some test depends on.
  const live = new Set(universe), todo = [...universe];
  while (todo.length) for (const x of graph.edges.get(todo.pop()) ?? []) if (!live.has(x)) { live.add(x); todo.push(x); }
  const lost = graph.unresolved.filter((u) => live.has(u.file)).map((u) => u.text);
  if (lost.length) full.push(`${lost.length} import(s) the graph cannot resolve, e.g. ${lost[0]}`);
  for (const f of changed) {
    if (isTest(f)) { if (set(universe, f)) why(f, `${f} changed`); else full.push(`${f} is a test file the selection cannot find`); continue; }
    if (foundations.some((r) => r.test(f))) { full.push(`${f} is a shared foundation (configuration, dependencies, workflows or tooling)`); continue; }
    const reached = reaching(graph, f);
    if (reached.length) { for (const { test, chain } of reached) why(test, `${f} changed: ${chain.join(" -> ")}`); continue; }
    if (inert.some((r) => r.test(f))) { notes.push(`${f} is documentation or tooling no test exercises`); continue; }
    // A file a test reads by name (a fixture, a data file).
    const readers = universe.filter((t) => (graph.text.get(t) ?? read(t) ?? "").includes(posix.basename(f)));
    if (readers.length && !SOURCE.test(f)) { for (const t of readers) why(t, `${f} changed: ${t} reads it`); continue; }
    full.push(`no test reaches ${f}`);
  }
  // Smoke tests, and tests whose pages, API routes and imports cannot be derived, always run.
  for (const t of universe) {
    const head = (read(t) ?? "").split("\n").slice(0, 5);
    if (head.some((l) => l.trim() === "// @smoke") || smokeGlobs.some((r) => r.test(t))) why(t, "the smoke set always runs");
    const own = graph.edges.get(t) ?? new Set();
    if (![...own].some((x) => !SUPPORT.test(x) && !isTest(x))) why(t, "its pages and imports cannot be derived, so it always runs");
  }
  return { mode: full.length ? "full" : "scoped", full, notes, tests: reasons, kinds, universe };
}
const set = (arr, v) => arr.includes(v);

/** The changed files against the pull request's base. `null` base: it cannot be named. */
export function context({ env = process.env, base = "", files = "" } = {}) {
  let event = {};
  if (env.GITHUB_EVENT_PATH && existsSync(env.GITHUB_EVENT_PATH)) { try { event = JSON.parse(readFileSync(env.GITHUB_EVENT_PATH, "utf8")); } catch {} }
  if (files) return { changed: files.split(",").map((f) => f.trim()).filter(Boolean), deleted: [], base: "(--files)" };
  let sha = base || env.GATE_BASE || "";
  try {
    const head = git("rev-parse", "HEAD").trim(), parents = git("rev-list", "--parents", "-n", "1", "HEAD").trim().split(" ").slice(1);
    if (!sha && head !== event.pull_request?.head?.sha && parents.length === 2) sha = parents[0];
    else if (sha || event.pull_request?.base?.sha || event.merge_group?.base_sha) sha = git("merge-base", sha || event.pull_request?.base?.sha || event.merge_group.base_sha, "HEAD").trim();
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
  const std = (() => { try { return JSON.parse(readFileSync("standards.json", "utf8")); } catch { return {}; } })();
  const cfg = config ?? std.affected;
  const pkg = (() => { try { return JSON.parse(readFileSync("package.json", "utf8")); } catch { return {}; } })();
  const deps = new Set(Object.keys({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.optionalDependencies, ...pkg.peerDependencies }));
  const tracked = git("ls-files", "-co", "--exclude-standard", "-z").split("\0").filter(Boolean).filter((f) => existsSync(f));
  const read = (f) => { try { return readFileSync(f, "utf8"); } catch { return null; } };
  const ctx = context({ env, base, files });
  const override = env.GATE_SELECT ?? "";
  let forced = null;
  if (cfg === false) forced = 'standards.json sets "affected": false';
  else if (override === "full") forced = "GATE_SELECT=full";
  else if (ctx.base === null) forced = "the pull request's base cannot be found in this checkout";
  const result = select({ files: tracked, changed: ctx.changed, deleted: ctx.deleted, read, config: cfg && typeof cfg === "object" ? cfg : {}, deps, forced });
  return { ...result, base: ctx.base, changed: ctx.changed, deleted: ctx.deleted };
}

export function describe(r) {
  const total = r.universe.length, lines = [`select: ${r.mode === "full" ? `FULL suite (${total} test files)` : `${r.tests.size} of ${total} test files`}${r.base ? ` (base ${String(r.base).slice(0, 9)})` : ""}; ${r.changed.length} changed file(s)${r.deleted.length ? `, ${r.deleted.length} deleted` : ""}`];
  for (const w of r.full) lines.push(`  full because ${w}`);
  for (const n of r.notes) lines.push(`  note: ${n}`);
  if (r.mode === "scoped") for (const [t, w] of [...r.tests].sort(([a], [b]) => (a < b ? -1 : 1))) lines.push(`  ${t} [${r.kinds.get(t)}]: ${w[0]}`);
  return lines.join("\n");
}
/** The selected test files of one kind; null when the full suite runs. */
export const listFor = (r, kind = "all") => (r.mode === "full" ? null : [...r.tests.keys()].filter((t) => kind === "all" || r.kinds.get(t) === kind).sort());
export function summarize(text, env = process.env) {
  if (env.GITHUB_STEP_SUMMARY) { try { appendFileSync(env.GITHUB_STEP_SUMMARY, `\n\`\`\`\n${text}\n\`\`\`\n`); } catch {} }
  return text;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const a = process.argv.slice(2), opt = (n) => { const i = a.indexOf(`--${n}`); return i >= 0 ? a[i + 1] ?? "" : ""; };
  const known = (a[0] ?? "plan");
  if (known !== "plan" && !known.startsWith("--")) { console.error("usage: select.mjs [plan] [--base <ref>] [--files a,b] [--json] | --list playwright|node|all"); process.exit(2); }
  try { process.chdir(git("rev-parse", "--show-toplevel").trim()); } catch {}
  const r = plan({ base: opt("base"), files: opt("files") });
  if (a.includes("--list")) { const l = listFor(r, opt("list") || "all"); console.log(l === null ? "ALL" : l.join("\n")); }
  else if (a.includes("--json")) console.log(JSON.stringify({ mode: r.mode, full: r.full, notes: r.notes, tests: Object.fromEntries(r.tests) }, null, 2));
  else console.log(summarize(describe(r)));
}
