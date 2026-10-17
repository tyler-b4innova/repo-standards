// Compare production source, build output and migrations with the PR base; never access Cloudflare.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, realpathSync, readFileSync, mkdtempSync, rmSync, symlinkSync, readdirSync, lstatSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, posix, join, relative } from "node:path";
import { parse } from "./staging.mjs";
import { scan } from "./jsscan.mjs";
import { build, effectiveConfig, rootFile, workerFiles, buildCommand, readConfig, installBuildDependencies } from "./release-config.mjs";
const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: "pipe", maxBuffer: 1 << 26 });
const read = (f) => existsSync(f) ? readFileSync(f, "utf8") : null;
const before = (base, f) => { try { return git("show", `${base}:${f}`); } catch { return null; } };
const configFile = /(?:^|\/)wrangler\.(jsonc?|toml)$/;
function config(text, file) {
  if (text === null) return {};
  if (file.endsWith(".toml")) {
    const r = spawnSync("python3", ["-c", "import json,sys,tomllib; print(json.dumps(tomllib.loads(sys.stdin.read())))"], { input: text, encoding: "utf8" });
    if (r.status !== 0) throw new Error(`${file}: cannot safely parse TOML; install Python 3.11+`);
    return JSON.parse(r.stdout);
  }
  const c = parse(text);
  if (!c || typeof c !== "object" || Array.isArray(c)) throw new Error(`${file}: invalid Wrangler config`);
  return c;
}
const get = (o, path) => path.split(".").reduce((v, k) => v?.[k], o);
function entries(c, key) {
  const v = get(c, key) ?? [];
  if (!Array.isArray(v) || v.some((b) => !b || typeof b !== "object")) throw new Error(`cannot safely read ${key}`);
  return v;
}
const kinds = ["d1_databases", "kv_namespaces", "r2_buckets", "queues.producers", "services", "durable_objects.bindings"];
const bindingName = (b) => b.binding ?? b.name;
const wranglerNames = ["wrangler.json", "wrangler.jsonc", "wrangler.toml"], configExt = /\.(jsonc?|toml)$/;
// Repo-relative path, or null for anything that would leave the repository (release-config's declaredWorkers and workerFiles report those).
const repoPath = (p) => {
  if (typeof p !== "string" || !p) return null;
  const n = posix.normalize(p.split("\\").join("/")).replace(/\/+$/, "");
  return !n || n === ".." || n.startsWith("../") || posix.isAbsolute(n) ? null : n;
};
// Wrangler configs a standards.json declares, whatever they are named: each workers entry (a config file, a directory whose one config
// `tree` holds, or {config, release_workers}) and every release_workers path. `tree` is the same side's repository files; `isLink` says whether
// a path is a symlink on that side. An entry whose path goes through a symlink is not followed: it is noted, not compared.
function declaredConfigs(text, tree, isLink, notes) {
  const std = JSON.parse(text ?? "{}") ?? {}, found = [];
  // An entry whose path goes through a symlink is not followed (the base tree holds the link, not its target): it is noted, not compared.
  const linked = (n) => n.split("/").some((_, i, parts) => isLink(parts.slice(0, i + 1).join("/")));
  const skip = (what, n) => {
    const note = `rollback: ${what} ${n} has a symlink in its path; it is not compared (its target is not followed)`;
    if (!notes.includes(note)) notes.push(note);
  };
  const file = (p, what) => { const n = repoPath(p); if (!n || !configExt.test(n)) return; if (linked(n)) skip(what, n); else found.push(n); };
  const entry = (p) => {
    const n = repoPath(p);
    if (!n) return;
    if (linked(n)) return skip("workers entry", n);
    // A path holding one of wranglerNames is a directory whatever its name (declaredWorkers finds it the same way on disk); otherwise it is a config file.
    const inside = wranglerNames.map((name) => posix.join(n, name)).filter((f) => tree.has(f));
    if (inside.length) found.push(...inside);
    else if (configExt.test(n) && ![...tree].some((f) => f.startsWith(`${n}/`))) found.push(n);
  };
  for (const p of Array.isArray(std.release_workers) ? std.release_workers : []) file(p, "release_workers entry");
  for (const w of Array.isArray(std.workers) ? std.workers : []) {
    const object = w && typeof w === "object" && !Array.isArray(w);
    entry(object ? w.config : w);
    for (const p of object && Array.isArray(w.release_workers) ? w.release_workers : []) file(p, "release_workers entry");
  }
  return found;
}

// SQLite folds ASCII letters only (its default case folding); every other character is itself, so 'Ä' and 'ä' are two names.
const asciiLower = (s) => s.replace(/[A-Z]+/g, (m) => m.toLowerCase());
// SQL tokenization: comments and quoted strings cannot become commands or statement boundaries.
// Names are normalised here, once, for every statement kind: one layer of "…", `…`, […] or '…' is stripped, doubled quotes are
// unescaped and ASCII letters are folded to lower case. A quoted name keeps a marker: \0 for "…", `…` and […], \x01 for '…', which
// SQLite also accepts as a name. A marked token never equals a bare keyword, so a string in a value position cannot match one;
// name() strips either marker wherever a name is read.
function statements(text) {
  const result = []; let tokens = [], i = 0;
  while (i < text.length) {
    const c = text[i], n = text[i + 1];
    if (/\s/.test(c)) { i++; continue; }
    if (c === "-" && n === "-") { const end = text.indexOf("\n", i + 2); i = end < 0 ? text.length : end; continue; }
    if (c === "/" && n === "*") { const end = text.indexOf("*/", i + 2); if (end < 0) throw new Error("unterminated SQL comment"); i = end + 2; continue; }
    if (["'", '"', "`", "["].includes(c)) {
      const end = c === "[" ? "]" : c; let value = "", closed = false; i++;
      while (i < text.length) {
        if (text[i] === end) {
          if (text[i + 1] === end && c !== "[") { value += end; i += 2; continue; }
          i++; closed = true; break;
        }
        value += text[i++];
      }
      if (!closed) throw new Error("unterminated SQL quote");
      tokens.push((c === "'" ? "\x01" : "\0") + asciiLower(value)); continue;
    }
    if (c === ";") { if (tokens.length) result.push(tokens); tokens = []; i++; continue; }
    const word = text.slice(i).match(/^[\w$]+/);
    if (word) { tokens.push(asciiLower(word[0])); i += word[0].length; }
    else { tokens.push(c); i++; }
  }
  if (tokens.length) result.push(tokens);
  return result;
}
const isTrigger = (t) => t[0] === "create" && (t[1] === "trigger" || (["temp", "temporary"].includes(t[1]) && t[2] === "trigger"));
// A trigger body command that only RAISEs, optionally WHERE-conditioned: it reads and writes nothing but its own abort.
const raisesOnly = (t) => {
  if (t[0] !== "select" || t[1] !== "raise" || t[2] !== "(" || !["abort", "fail", "ignore", "rollback"].includes(t[3])) return false;
  let depth = 0, i = 2;
  for (; i < t.length; i++) { if (t[i] === "(") depth++; else if (t[i] === ")" && --depth === 0) break; }
  return i < t.length && (i + 1 === t.length || t[i + 1] === "where");
};
const productionEnv = (cfg) => cfg.env?.production ? { ...cfg, ...cfg.env.production, name: cfg.env.production.name ?? `${cfg.name}-production` } : cfg;
const name = (token) => token?.replace(/^[\0\x01]/, "");
// The object an unclassified statement names is its second token; a string literal there is not an object name.
const objectOf = (t) => t[1] === undefined ? "<statement>" : t[1].startsWith("\x01") ? "<literal>" : name(t[1]);
const phrase = (t, a, b) => t.some((v, i) => v === a && t[i + 1] === b);
function tableAt(t, i) {
  if (t.slice(i, i + 3).join(" ") === "if not exists") i += 3;
  if (t.slice(i, i + 2).join(" ") === "if exists") i += 2;
  if (t[i + 1] === ".") i += 2;
  return [name(t[i]), i + 1];
}
function recordReplacingTables(sql, replacingTables) {
  for (const t of statements(sql)) {
    const tableAtIndex = ["temp", "temporary"].includes(t[1]) ? 2 : 1;
    if (t[0] === "create" && t[tableAtIndex] === "table" && phrase(t, "conflict", "replace"))
      replacingTables.add(tableAt(t, tableAtIndex + 1)[0]);
  }
}
// folderTables: the tables this migrations folder's new files create (earlier files, and earlier in this one). Only these may be a trigger's table.
function sqlHazards(sql, freshTables, freshColumns, existingTables = new Set(), existingColumns = new Set(), replacingTables = new Set(), history = false, folderTables = new Set()) {
  const hazards = [], commands = typeof sql === "string" ? statements(sql) : sql;
  for (let k = 0; k < commands.length; k++) {
    let t = commands[k];
    // WITH statements execute the command after their parenthesized CTE bodies.
    if (t[0] === "with") {
      let depth = 0;
      const start = t.findIndex((v, i) => {
        if (v === "(") depth++; else if (v === ")") depth--;
        return i > 0 && depth === 0 && ["select", "insert", "replace", "update", "delete"].includes(v);
      });
      if (start >= 0) t = t.slice(start);
    }
    if (t[0] === "create" && t[1] === "table") {
      const [table, start] = tableAt(t, t.indexOf("table") + 1);
      if (existingTables.has(table)) continue;
      folderTables.add(table);
      // A repeated CREATE (including IF NOT EXISTS) cannot establish column freshness.
      if (freshTables.has(table)) continue;
      freshTables.add(table);
      // Column starts at the first parenthesis or a top-level comma; table constraints are excluded.
      let depth = 0, columnStart = false;
      for (const v of t.slice(start)) {
        if (v === "(") { depth++; if (depth === 1) columnStart = true; }
        else if (v === ")") depth--;
        else if (v === "," && depth === 1) columnStart = true;
        else if (columnStart) {
          if (!["constraint", "primary", "unique", "check", "foreign"].includes(v) && !existingColumns.has(`${table}.${name(v)}`)) freshColumns.add(`${table}.${name(v)}`);
          columnStart = false;
        }
      }
      continue;
    }
    if (t[0] === "alter" && t[1] === "table") {
      const [table, i] = tableAt(t, 2), op = t[i];
      if (op === "add") {
        let col = i + 1; if (t[col] === "column") col++;
        const constraints = t.slice(col + 1), defaultAt = constraints.indexOf("default");
        if (phrase(constraints, "conflict", "replace")) replacingTables.add(table);
        const defaultValue = constraints.slice(defaultAt + 1).find((v) => v !== "(");
        if (constraints.some((v) => ["unique", "primary", "check", "references", "generated"].includes(v))) hazards.push([`${table}.${name(t[col])}`, "ADD may narrow writes with a constraint"]);
        else if (phrase(constraints, "not", "null") && defaultAt < 0) hazards.push([`${table}.${name(t[col])}`, "ADD NOT NULL without a default"]);
        else if (phrase(constraints, "not", "null") && defaultValue === "null") hazards.push([`${table}.${name(t[col])}`, "ADD NOT NULL with a NULL default"]);
        else if (!existingColumns.has(`${table}.${name(t[col])}`)) freshColumns.add(`${table}.${name(t[col])}`);
      } else {
        if (history && op === "rename") {
          if (t[i + 1] === "to") {
            const renamed = name(t[i + 2]);
            freshTables.add(renamed);
            for (const column of [...freshColumns]) if (column.startsWith(`${table}.`)) freshColumns.add(`${renamed}.${column.slice(table.length + 1)}`);
            if (replacingTables.has(table)) replacingTables.add(renamed);
          } else {
            const col = i + 1 + (t[i + 1] === "column" ? 1 : 0);
            if (t[col + 1] === "to") freshColumns.add(`${table}.${name(t[col + 2])}`);
          }
        }
        let col = i + 1; if (t[col] === "column") col++;
        const object = op === "rename" && t[i + 1] === "to" ? table : `${table}.${name(t[col])}`;
        // SQLite type changes require reconstruction; unsupported ALTER forms are never assumed expand-only.
        hazards.push([object, op === "drop" ? "DROP COLUMN" : op === "rename" ? "RENAME" : "ALTER may narrow a type or constraint"]);
      }
    } else if (t[0] === "drop" && t[1] === "table") {
      hazards.push([tableAt(t, 2)[0], "DROP TABLE"]);
    } else if (t[0] === "insert" && t[1] === "or" && t[2] === "replace") {
      hazards.push([tableAt(t, t.indexOf("into") + 1)[0], "INSERT OR REPLACE data rewrite"]);
    } else if (["delete", "update", "replace", "with", "insert"].includes(t[0]) && (t.includes("delete") || t.includes("update") || t[0] === "replace")) {
      // Includes WITH ... UPDATE/DELETE; unknown targets fail conservatively.
      const del = t.indexOf("delete"), upd = t.indexOf("update");
      if (del >= 0) {
        const [table] = tableAt(t, t.indexOf("from", del) + 1);
        if (!freshTables.has(table)) hazards.push([table, "DELETE data rewrite"]);
      } else if (upd >= 0) {
        const [table] = tableAt(t, upd + 1 + (t[upd + 1] === "or" ? 2 : 0));
        const set = t.indexOf("set", upd);
        let depth = 0, target = [], cols = [], assigning = true, understood = set >= 0;
        for (const v of t.slice(set + 1)) {
          if (depth === 0 && ["where", "returning", "from", "order", "limit"].includes(v)) break;
          if (depth === 0 && v === ",") { assigning = true; target = []; continue; }
          if (depth === 0 && v === "=" && assigning) {
            // Tuple assignment and unknown target syntax need a contract too.
            if (target.length === 1 && /^[\w$\0\x01]+$/.test(target[0])) cols.push(name(target[0]));
            else understood = false;
            assigning = false;
          } else if (assigning) target.push(v);
          if (v === "(") depth++; else if (v === ")") depth--;
        }
        if (assigning || depth !== 0) understood = false;
        if (!freshTables.has(table) && (!understood || !cols.length || cols.some((c) => !freshColumns.has(`${table}.${c}`))))
          hazards.push([table, "UPDATE data rewrite of an existing column"]);
      } else hazards.push([tableAt(t, t.indexOf("into") + 1)[0], "REPLACE data rewrite"]);
    } else if (t[0] === "drop" && ["view", "index", "trigger"].includes(t[1])) {
      hazards.push([tableAt(t, 2)[0], `DROP ${t[1].toUpperCase()}`]);
    } else if (isTrigger(t)) {
      const table = tableAt(t, t.indexOf("on") + 1)[0];
      // Only a table this folder creates is new to the previous release; the name is normalised like every other.
      const created = folderTables.has(table);
      if (!created) hazards.push([table, "CREATE TRIGGER changes persistent behavior"]);
      // Split every SQL separator, including those inside triggers, so later commands cannot be swallowed by identifiers named BEGIN/END.
      // The body is every command up to its END statement; each is classified here, and a RAISE-only command only on a created table.
      const bodyStart = t.findIndex((v, i) => i > t.indexOf("on") && v === "begin" && ["select", "insert", "update", "delete", "replace", "with"].includes(t[i + 1]));
      const end = commands.findIndex((c, i) => i > k && c.length === 1 && c[0] === "end");
      if (bodyStart < 0 || end < 0) hazards.push([table, "cannot positively classify trigger body"]);
      else {
        for (const command of [t.slice(bodyStart + 1), ...commands.slice(k + 1, end)])
          if (!(created && raisesOnly(command))) hazards.push(...sqlHazards([command], freshTables, freshColumns, existingTables, existingColumns, replacingTables, history, folderTables));
        k = end;
      }
    } else if (t[0] === "create" && t[1] === "unique" && t[2] === "index") {
      const table = tableAt(t, t.indexOf("on") + 1)[0];
      if (!freshTables.has(table)) hazards.push([table, "CREATE UNIQUE INDEX narrows valid writes"]);
    } else if (t[0] === "create" && ["index", "view"].includes(t[1])) {
      // A non-unique index or a new view does not constrain existing writes.
      continue;
    } else if (t[0] === "insert" && t.includes("into") && !t.includes("replace")) {
      const table = tableAt(t, t.indexOf("into") + 1)[0];
      const nonReplacing = t[1] === "or" && ["ignore", "abort", "fail", "rollback"].includes(t[2]);
      const doNothing = phrase(t, "on", "conflict") && phrase(t, "do", "nothing") && !phrase(t, "do", "update");
      if (t.includes("conflict") && !doNothing) hazards.push([table, "SQL is not positively classified as expand-only"]);
      else if (replacingTables.has(table) && !nonReplacing) hazards.push([table, "INSERT may inherit ON CONFLICT REPLACE data rewrite"]);
    } else if (["begin", "commit", "end", "rollback", "savepoint", "release"].includes(t[0])) {
      continue;
    } else {
      hazards.push([objectOf(t), "SQL is not positively classified as expand-only"]);
    }
  }
  return hazards;
}

// Build each revision's production artifact; source-only inventory misses adapter bindings.
function productionInventory({ built = false, buildContext } = {}) {
  const root = rootFile();
  if (!root) return new Map();
  const std = JSON.parse(read("standards.json") ?? "{}"), pkg = JSON.parse(read("package.json") ?? "{}");
  const files = [root, ...workerFiles(std, root)];
  if (!built) {
    const command = buildCommand(std, pkg);
    const options = command ? installBuildDependencies(pkg, buildContext) : {};
    build(std, pkg, false, { quiet: true, ...options });
  }
  return new Map(files.map((file, i) => {
    const resolved = effectiveConfig(file, false, { redirect: i === 0 });
    if (resolved.cfg.name !== readConfig(file).name) throw new Error(`${file}: production build targets a different Worker`);
    return [relative(process.cwd(), file), { file: relative(process.cwd(), resolved.file).split("\\").join("/"), cfg: resolved.cfg }];
  }));
}
function baseInventory(base, directory, buildContext) {
  // The clone is this run's own directory; trust it by command-line config where the running user's config is not read (a hidden HOME).
  execFileSync("git", ["clone", "--shared", "--no-checkout", "--quiet", process.cwd(), directory], { stdio: "pipe" });
  const own = ["-c", `safe.directory=${realpathSync(directory)}`];
  // A shallow source can hold a fetched base outside the history copied by clone.
  try { execFileSync("git", ["-C", directory, ...own, "cat-file", "-e", `${base}^{commit}`], { stdio: "pipe" }); }
  catch { execFileSync("git", ["-C", directory, ...own, "fetch", "--no-tags", "--depth=1", "--", process.cwd(), base], { stdio: "pipe" }); }
  execFileSync("git", ["-C", directory, ...own, "checkout", "--detach", "--quiet", base], { stdio: "pipe" });
  const cwd = process.cwd();
  // Reuse installed dependencies only for the same dependency manifest and lockfiles.
  const pkg = JSON.parse(read(join(directory, "package.json")) ?? "{}"), current = JSON.parse(read("package.json") ?? "{}");
  const dependencies = (p) => JSON.stringify([p.dependencies, p.devDependencies, p.optionalDependencies]);
  const local = pkg.workspaces || existsSync(join(directory, "pnpm-workspace.yaml")) || Object.values({ ...pkg.dependencies, ...pkg.devDependencies }).some((v) => /^(file|link|workspace):/.test(v));
  const same = !local && dependencies(pkg) === dependencies(current) && ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", ".yarnrc.yml"].every((f) => read(f) === read(join(directory, f)));
  if (existsSync("node_modules") && same) symlinkSync(join(cwd, "node_modules"), join(directory, "node_modules"), "dir");
  try {
    process.chdir(directory);
    return productionInventory({ buildContext });
  } finally { process.chdir(cwd); }
}

// Actions event data belongs only to the workflow's checkout, never to sync targets or fixtures.
function workflowCheckout() {
  try {
    if (!process.env.GITHUB_WORKSPACE || realpathSync(git("rev-parse", "--show-toplevel").trim()) !== realpathSync(process.env.GITHUB_WORKSPACE)) return false;
    let origin = "";
    try { origin = git("remote", "get-url", "origin").trim(); } catch {}
    // HTTPS, ssh:// and scp-style origins; local paths have no owner/name identity.
    const match = origin.match(/^(?:(?:https?|ssh|git):\/\/[^/]+\/|[^/\s]+@[^/:]+:)([^/]+\/[^/]+?)\/?$/i);
    const repository = match?.[1].replace(/\.git$/, "");
    return !repository || repository.toLowerCase() === process.env.GITHUB_REPOSITORY?.toLowerCase();
  } catch { return false; }
}

export function rollbackFindings({ built = false } = {}) {
  const errors = [], notes = [];
  const ownCheckout = workflowCheckout();
  const event = ownCheckout ? JSON.parse(read(process.env.GITHUB_EVENT_PATH ?? "") ?? "{}") : {};
  let draft = process.env.ROLLBACK_DRAFT === "true" || (!process.env.ROLLBACK_DRAFT && event.pull_request?.draft === true);
  let base = process.env.ROLLBACK_BASE || event.pull_request?.base?.sha || event.merge_group?.base_sha;
  const files = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0").filter(Boolean);
  let baseDirectory;
  const buildContext = {};
  try {
    if (!base && ownCheckout && process.env.GITHUB_EVENT_NAME === "workflow_dispatch") base = git("rev-parse", "HEAD^1").trim();
    if (!base) {
      for (const ref of ["origin/HEAD", "origin/main", "main"]) {
        try { base = git("merge-base", ref, "HEAD").trim(); break; } catch {}
      }
    }
    if (!base) {
      const remotes = git("remote").trim().split("\n").filter(Boolean);
      if (!remotes.length) {
        notes.push("rollback: no comparison base (no remotes); skipped");
        return { errors, notes, draft };
      }
      // Shallow push checkouts may have no default-branch refs or merge base.
      // Fetch the remote default tip directly instead of exempting the checkout.
      const tried = "merge-base origin/HEAD, origin/main, main (no event PR/merge-group base supplied)";
      if (!remotes.includes("origin")) {
        draft = false;
        throw new Error(`no comparison base; tried ${tried}; origin remote is unavailable`);
      }
      try {
        git("fetch", "--no-tags", "--depth=1", "origin", "HEAD");
        base = git("rev-parse", "--verify", "FETCH_HEAD^{commit}").trim();
        if (!base) throw new Error("empty fetched base");
      } catch (e) {
        draft = false;
        throw new Error(`no comparison base; tried ${tried}, git fetch --no-tags --depth=1 origin HEAD: ${e.message}`);
      }
    }
    try { base = git("rev-parse", "--verify", "--end-of-options", `${base}^{commit}`).trim(); }
    catch {
      const remotes = git("remote").trim().split("\n").filter(Boolean);
      if (!remotes.length) {
        notes.push("rollback: no comparison base (no remotes); skipped");
        return { errors, notes, draft };
      }
      // Missing comparison data is a failure even when draft hazards only warn.
      if (!remotes.includes("origin")) {
        draft = false;
        throw new Error(`comparison base ${base} missing locally and origin remote is unavailable`);
      }
      if (!/^[0-9a-f]{40}([0-9a-f]{24})?$/i.test(base)) {
        draft = false;
        throw new Error(`cannot fetch comparison base ${base}: expected a full commit SHA`);
      }
      try {
        git("fetch", "--no-tags", "--depth=1", "--", "origin", base);
        git("cat-file", "-e", `${base}^{commit}`);
      } catch (e) {
        draft = false;
        throw new Error(`cannot fetch comparison base ${base} from origin: ${e.message}`);
      }
    }
    const oldFiles = git("ls-tree", "-r", "--name-only", "-z", base).split("\0").filter(Boolean);
    // Configs are paired by file name and by the declarations of both sides' standards.json, so a Worker declared on one side is still compared.
    // -z: ls-tree quotes non-ASCII names otherwise, so the exact path is compared unquoted.
    const baseLink = (f) => { try { return git("ls-tree", "-z", base, "--", f).split("\0").some((l) => l.startsWith("120000 ") && l.endsWith(`\t${f}`)); } catch { return false; } };
    const headLink = (f) => { try { return lstatSync(f).isSymbolicLink(); } catch { return false; } };
    const configs = [...new Set([...oldFiles, ...files].filter((f) => configFile.test(f))
      .concat(declaredConfigs(before(base, "standards.json"), new Set(oldFiles), baseLink, notes), declaredConfigs(read("standards.json"), new Set(files), headLink, notes)))];
    baseDirectory = mkdtempSync(join(tmpdir(), "rollback-base-"));
    const newProduction = productionInventory({ built, buildContext }), oldProduction = baseInventory(base, baseDirectory, buildContext);
    const pairs = configs.map((file) => ({ label: file, afile: file, bfile: file, a: config(before(base, file), file), b: config(read(file), file) }));
    for (const file of new Set([...oldProduction.keys(), ...newProduction.keys()])) {
      const a = oldProduction.get(file), b = newProduction.get(file);
      pairs.push({ label: `${file} resolved production`, afile: a?.file ?? file, bfile: b?.file ?? file, a: a?.cfg ?? {}, b: b?.cfg ?? {} });
    }
    const dirs = new Set();
    // The migration folders of a config's D1 databases, relative to the repository root.
    const migrationDirs = (label, path, c) => entries(c, "d1_databases").map((db) => {
      const dir = db.migrations_dir ?? c.migrations_dir ?? "migrations";
      if (typeof dir !== "string") throw new Error(`${label}: invalid migrations_dir`);
      return posix.normalize(posix.join(dirname(path), dir));
    });
    const migrations = (root, list) => {
      const found = [];
      const walk = (dir) => {
        if (posix.isAbsolute(dir) || dir === ".." || dir.startsWith("../")) throw new Error(`migration directory is outside the repository: ${dir}`);
        if (!existsSync(join(root, dir))) return;
        for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
          const file = posix.join(dir, entry.name);
          if (entry.isDirectory()) walk(file);
          else if (entry.isFile() && file.endsWith(".sql")) found.push(file);
          else if (entry.isSymbolicLink()) throw new Error(`cannot safely inventory migration symlink: ${file}`);
        }
      };
      for (const dir of list) walk(dir);
      return [...new Set(found)].sort();
    };
    // A Worker deleted whole: its Wrangler config is gone from the head, no migration file is left in any folder its D1 databases used,
    // and no other config in the head carries its name (a moved config is the same Worker, not a deletion). One that standards.json
    // does not declare (not the repository's root config either, which is the primary Worker unless `workers` lists others) was never
    // released by the gate, so no previous release can need its bindings or migrations: they are not compared, and a note names it.
    // A declared one (in the comparison base's standards.json) is a release the previous deploy still runs, so deleting it whole fails: the declaration goes first.
    const baseStd = JSON.parse(before(base, "standards.json") ?? "{}");
    const normal = (p) => posix.normalize(String(p).split("\\").join("/")).replace(/\/+$/, "");
    const declaredBy = (file) => {
      const listed = [...(Array.isArray(baseStd.release_workers) ? baseStd.release_workers.map((p) => ["release_workers", p]) : []),
        ...(Array.isArray(baseStd.workers) ? baseStd.workers.flatMap((w) => w && typeof w === "object" ? [["workers", w.config], ...(Array.isArray(w.release_workers) ? w.release_workers.map((p) => ["release_workers", p]) : [])] : [["workers", w]]) : [])];
      for (const [key, p] of listed) if (typeof p === "string" && [file, dirname(file)].includes(normal(p))) return `standards.json ${key}`;
      return baseStd.workers === undefined && file === ["wrangler.json", "wrangler.jsonc", "wrangler.toml"].find((f) => before(base, f) !== null) ? "the root Wrangler config, the primary Worker" : null;
    };
    const headNames = new Set(pairs.flatMap((p) => typeof p.b.name === "string" ? [p.b.name] : []));
    const dropped = new Set();
    for (const p of pairs.slice(0, configs.length)) {
      if (before(base, p.label) === null || read(p.label) !== null || (typeof p.a.name === "string" && headNames.has(p.a.name))) continue;
      const mine = [...new Set([...migrationDirs(p.label, p.afile, p.a), ...migrationDirs(p.label, p.afile, p.a.env?.production ?? {})])];
      if (migrations(".", mine).length) continue;
      const by = declaredBy(p.label), worker = typeof p.a.name === "string" ? p.a.name : p.label;
      if (by) errors.push(`${p.label}: Worker ${worker} is deleted whole, but it is declared (${by}), so the previous release still runs it; remove the declaration in an earlier change and release first, then delete the Worker`);
      else { dropped.add(p.label); notes.push(`Worker ${worker} deleted whole (${p.label}${mine.length ? `, migrations ${mine.join(", ")}` : ""}); not declared in standards.json workers or release_workers, so its bindings and migrations are not compared`); }
    }
    // Both release inventories contribute references, including callers of another Worker.
    const dependencies = new Map();
    for (const { label, a, b } of pairs) if (!dropped.has(label)) for (const cfg of [a, b]) for (const c of [cfg, productionEnv(cfg)]) {
      for (const binding of entries(c, "durable_objects.bindings")) {
        const host = binding.script_name ?? c.name;
        if (!host || typeof binding.class_name !== "string") throw new Error("cannot resolve production Durable Object dependency");
        if (!dependencies.has(host)) dependencies.set(host, new Set());
        dependencies.get(host).add(binding.class_name);
      }
    }
    const exports = (cfg, file, reader, visited = new Set()) => {
      if (typeof cfg.main !== "string") return null;
      const entry = posix.normalize(posix.join(dirname(file), cfg.main));
      if (visited.has(entry)) return new Set();
      visited.add(entry);
      const lexed = scan(reader(entry) ?? ""), source = lexed.code;
      const names = new Set([...source.matchAll(/\bexport\s+(?:abstract\s+)?class\s+([\w$]+)/g)].map((m) => m[1]));
      for (const m of source.matchAll(/\bexport\s+(?:const|let|var|function)\s+([\w$]+)/g)) names.add(m[1]);
      for (const m of source.matchAll(/\bexport\s*\{([^}]+)\}/g)) for (const item of m[1].split(",")) {
        const parts = item.trim().split(/\s+as\s+/); if (parts[0]) names.add(parts.at(-1).trim());
      }
      // Follow local star re-exports, which also expose named DO classes from another module.
      for (const m of lexed.source.matchAll(/\bexport\s*\*\s*from\s*["']([^"']+)["']/g)) {
        if (!m[1].startsWith(".")) continue;
        const target = posix.normalize(posix.join(dirname(entry), m[1]));
        const candidates = [target, ...[".ts", ".js", ".mts", ".mjs", "/index.ts", "/index.js"].map((ext) => target + ext)];
        const found = candidates.find((f) => reader(f) !== null);
        if (found) for (const name of exports({ main: posix.basename(found) }, found, reader, visited)) names.add(name);
      }
      return names;
    };
    for (const { label: file, afile, bfile, a, b } of pairs) {
      const gone = dropped.has(file);
      if (!gone) for (const [path, c] of [[afile, a], [bfile, b], [afile, a.env?.production ?? {}], [bfile, b.env?.production ?? {}]]) for (const dir of migrationDirs(file, path, c)) dirs.add(dir);
      for (const [label, oldConfig, newConfig] of gone ? [] : [[file, a, b], [`${file} env.production`, a.env?.production ?? {}, b.env?.production ?? {}]]) {
        for (const kind of kinds) {
          const present = new Set(entries(newConfig, kind).map(bindingName));
          for (const binding of entries(oldConfig, kind)) if (!present.has(bindingName(binding))) errors.push(`${label}: removed production binding ${kind} ${bindingName(binding)}`);
        }
      }
      for (const [oldConfig, newConfig] of [[a, b], [productionEnv(a), productionEnv(b)]]) {
        const oldClasses = exports(oldConfig, afile, (f) => read(join(baseDirectory, f))), newClasses = exports(newConfig, bfile, read);
        const bound = [...new Set([oldConfig.name, newConfig.name].flatMap((host) => [...(dependencies.get(host) ?? [])]))];
        for (const name of bound) if (oldClasses?.has(name) && !newClasses?.has(name)) errors.push(`${file}: removed or renamed Durable Object class ${name} while still bound in this release`);
        const previous = new Map(entries(oldConfig, "migrations").map((m) => [m.tag, JSON.stringify(m)]));
        for (const m of entries(newConfig, "migrations")) if (previous.get(m.tag) !== JSON.stringify(m)) {
          for (const name of [...(m.deleted_classes ?? []), ...(m.renamed_classes ?? []).map((r) => r.from)])
            if (bound.includes(name)) errors.push(`${file}: Durable Object class ${name} deleted_classes/renamed_classes while still bound in this release`);
        }
      }
    }
    const contracts = JSON.parse(read("rollback-contracts.json") ?? "{}");
    const freshTables = new Set(), freshColumns = new Set();
    // New tables/columns are expand targets only when absent from all base migration history.
    const oldTables = new Set(), oldColumns = new Set(), replacingTables = new Set();
    const oldMigrations = migrations(baseDirectory, dirs), newMigrations = migrations(".", dirs);
    // A new file's migrations folder is its own directory (a subfolder is another folder): its tables are the only trigger targets it may use.
    const createdByFolder = new Map();
    // Policies belong to names across all history, regardless of recreation or statement order.
    for (const f of oldMigrations) recordReplacingTables(read(join(baseDirectory, f)), replacingTables);
    for (const f of newMigrations) recordReplacingTables(read(f), replacingTables);
    for (const f of oldMigrations) {
      sqlHazards(read(join(baseDirectory, f)), oldTables, oldColumns, new Set(), new Set(), replacingTables, true);
      if (!newMigrations.includes(f)) errors.push(`${f}: historical D1 migration removed; retain migration history`);
    }
    for (const f of newMigrations) {
      if (oldMigrations.includes(f)) {
        if (read(f) !== read(join(baseDirectory, f))) errors.push(`${f}: historical D1 migration changed; add a new expand-only migration`);
        continue;
      }
      const folder = posix.dirname(f);
      if (!createdByFolder.has(folder)) createdByFolder.set(folder, new Set());
      const sql = read(f), hazards = sqlHazards(sql, freshTables, freshColumns, oldTables, oldColumns, replacingTables, false, createdByFolder.get(folder));
      for (const t of oldTables) freshTables.delete(t);
      for (const c of oldColumns) freshColumns.delete(c);
      const header = sql.match(/^(?:\s|--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/)*/)?.[0] ?? "";
      const marker = header.match(/^\s*--\s*contract:\s*(.+)$/im)?.[1];
      const reference = /(?:#\d+\b|https:\/\/github\.com\/[^\s/]+\/[^\s/]+\/(?:issues|pull)\/\d+\b)/;
      const linked = marker && reference.test(marker) && /[a-z]/i.test(marker.replace(new RegExp(reference.source, "g"), ""));
      for (const [object, reason] of hazards) {
        if (linked && Array.isArray(contracts[f]) && contracts[f].includes(object))
          notes.push(`contract ${f}: ${reason} ${object}; ${marker}. Verify the previous release already stopped using this object`);
        else errors.push(`${f}: ${reason} ${object}; contract requires -- contract: <reason> with an issue/PR link and this object in rollback-contracts.json`);
      }
    }
  } catch (e) { errors.push(e.message); }
  finally {
    if (baseDirectory) rmSync(baseDirectory, { recursive: true, force: true });
    if (buildContext.home) rmSync(buildContext.home, { recursive: true, force: true });
  }
  return { errors: errors.map((e) => `rollback: ${e}`), notes, draft };
}
