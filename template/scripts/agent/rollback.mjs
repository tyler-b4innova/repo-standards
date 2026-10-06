// Compare production source, build output and migrations with the PR base; never access Cloudflare.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, mkdtempSync, rmSync, symlinkSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, posix, join, relative } from "node:path";
import { parse } from "./staging.mjs";
import { scan } from "./jsscan.mjs";
import { build, effectiveConfig, rootFile, workerFiles, buildCommand, readConfig } from "./release-config.mjs";
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

// SQL tokenization: comments and quoted strings cannot become commands or statement boundaries.
// Quoted identifiers are kept (including SQLite's backticks/brackets); single quotes are literals.
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
      tokens.push(c === "'" ? "<literal>" : "\0" + value.toLowerCase()); continue;
    }
    if (c === ";") { if (tokens.length) result.push(tokens); tokens = []; i++; continue; }
    const word = text.slice(i).match(/^[\w$]+/);
    if (word) { tokens.push(word[0].toLowerCase()); i += word[0].length; }
    else { tokens.push(c); i++; }
  }
  if (tokens.length) result.push(tokens);
  return result;
}
const isTrigger = (t) => t[0] === "create" && (t[1] === "trigger" || (["temp", "temporary"].includes(t[1]) && t[2] === "trigger"));
const productionEnv = (cfg) => cfg.env?.production ? { ...cfg, ...cfg.env.production, name: cfg.env.production.name ?? `${cfg.name}-production` } : cfg;
const name = (token) => token?.replace(/^\0/, "");
const phrase = (t, a, b) => t.some((v, i) => v === a && t[i + 1] === b);
function tableAt(t, i) {
  if (t.slice(i, i + 3).join(" ") === "if not exists") i += 3;
  if (t.slice(i, i + 2).join(" ") === "if exists") i += 2;
  if (t[i + 1] === ".") i += 2;
  return [name(t[i]), i + 1];
}
function sqlHazards(sql, freshTables, freshColumns, existingTables = new Set(), existingColumns = new Set()) {
  const hazards = [];
  for (let t of typeof sql === "string" ? statements(sql) : sql) {
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
      if (!existingTables.has(table)) freshTables.add(table);
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
        const defaultValue = constraints.slice(defaultAt + 1).find((v) => v !== "(");
        if (constraints.some((v) => ["unique", "primary", "check", "references", "generated"].includes(v))) hazards.push([`${table}.${name(t[col])}`, "ADD may narrow writes with a constraint"]);
        else if (phrase(constraints, "not", "null") && defaultAt < 0) hazards.push([`${table}.${name(t[col])}`, "ADD NOT NULL without a default"]);
        else if (phrase(constraints, "not", "null") && defaultValue === "null") hazards.push([`${table}.${name(t[col])}`, "ADD NOT NULL with a NULL default"]);
        else if (!existingColumns.has(`${table}.${name(t[col])}`)) freshColumns.add(`${table}.${name(t[col])}`);
      } else {
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
            if (target.length === 1 && /^[\w$\0]+$/.test(target[0])) cols.push(name(target[0]));
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
      if (!freshTables.has(table)) hazards.push([table, "CREATE TRIGGER changes persistent behavior"]);
      // Split every SQL separator, including those inside triggers, so later commands
      // cannot be swallowed by identifiers named BEGIN/END. Inspect the first body command here;
      // subsequent body commands are ordinary statements in the outer loop.
      const bodyStart = t.findIndex((v, i) => i > t.indexOf("on") && v === "begin" && ["select", "insert", "update", "delete", "replace", "with"].includes(t[i + 1]));
      if (bodyStart < 0) hazards.push([table, "cannot positively classify trigger body"]);
      else hazards.push(...sqlHazards([t.slice(bodyStart + 1)], freshTables, freshColumns, existingTables, existingColumns));
    } else if (t[0] === "create" && t[1] === "unique" && t[2] === "index") {
      const table = tableAt(t, t.indexOf("on") + 1)[0];
      if (!freshTables.has(table)) hazards.push([table, "CREATE UNIQUE INDEX narrows valid writes"]);
    } else if (t[0] === "create" && ["index", "view"].includes(t[1])) {
      // A non-unique index or a new view does not constrain existing writes.
      continue;
    } else if (t[0] === "insert" && t.includes("into") && !t.includes("conflict") && !t.includes("replace")) {
      continue;
    } else if (["begin", "commit", "end", "rollback", "savepoint", "release"].includes(t[0])) {
      continue;
    } else {
      hazards.push([name(t[1]) ?? "<statement>", "SQL is not positively classified as expand-only"]);
    }
  }
  return hazards;
}

// Build each revision's production artifact; source-only inventory misses adapter bindings.
function productionInventory({ built = false } = {}) {
  const root = rootFile();
  if (!root) return new Map();
  const std = JSON.parse(read("standards.json") ?? "{}"), pkg = JSON.parse(read("package.json") ?? "{}");
  const files = [root, ...workerFiles(std, root)];
  if (!built) {
    if (buildCommand(std, pkg)) installBuildDependencies(pkg);
    build(std, pkg, false, { quiet: true });
  }
  return new Map(files.map((file, i) => {
    const resolved = effectiveConfig(file, false, { redirect: i === 0 });
    if (resolved.cfg.name !== readConfig(file).name) throw new Error(`${file}: production build targets a different Worker`);
    return [relative(process.cwd(), file), { file: relative(process.cwd(), resolved.file).split("\\").join("/"), cfg: resolved.cfg }];
  }));
}
function installBuildDependencies(pkg) {
  if (!Object.keys({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.optionalDependencies }).length || existsSync("node_modules")) return;
  const pm = existsSync("pnpm-lock.yaml") ? "pnpm" : existsSync("yarn.lock") ? "yarn" : "npm";
  const args = pm === "pnpm" ? ["install", "--frozen-lockfile"] : pm === "yarn" ? ["install", existsSync(".yarnrc.yml") ? "--immutable" : "--frozen-lockfile"] : existsSync("package-lock.json") ? ["ci"] : ["install", "--no-package-lock"];
  const command = pm === "npm" ? "npm" : "npx";
  const installArgs = pm === "npm" ? args : ["--yes", "--package", "corepack@0.34.6", "corepack", pm, ...args];
  const corepackHome = pm === "npm" ? null : mkdtempSync(join(tmpdir(), "rollback-corepack-"));
  try {
    const env = corepackHome ? { ...process.env, COREPACK_HOME: corepackHome, COREPACK_ENABLE_AUTO_PIN: "0" } : process.env;
    const result = spawnSync(command, installArgs, { stdio: "ignore", env });
    if (result.status !== 0) throw new Error("cannot install production build dependencies; resolved production rollback comparison is required");
  } finally { if (corepackHome) rmSync(corepackHome, { recursive: true, force: true }); }
}
function baseInventory(base, directory) {
  execFileSync("git", ["clone", "--shared", "--no-checkout", "--quiet", process.cwd(), directory], { stdio: "pipe" });
  execFileSync("git", ["-C", directory, "checkout", "--detach", "--quiet", base], { stdio: "pipe" });
  const cwd = process.cwd();
  // Reuse installed dependencies only for the same dependency manifest and lockfiles.
  const pkg = JSON.parse(read(join(directory, "package.json")) ?? "{}"), current = JSON.parse(read("package.json") ?? "{}");
  const dependencies = (p) => JSON.stringify([p.dependencies, p.devDependencies, p.optionalDependencies]);
  const local = pkg.workspaces || existsSync(join(directory, "pnpm-workspace.yaml")) || Object.values({ ...pkg.dependencies, ...pkg.devDependencies }).some((v) => /^(file|link|workspace):/.test(v));
  const same = !local && dependencies(pkg) === dependencies(current) && ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", ".yarnrc.yml"].every((f) => read(f) === read(join(directory, f)));
  if (existsSync("node_modules") && same) symlinkSync(join(cwd, "node_modules"), join(directory, "node_modules"), "dir");
  try {
    process.chdir(directory);
    return productionInventory();
  } finally { process.chdir(cwd); }
}

export function rollbackFindings({ built = false } = {}) {
  const errors = [], notes = [];
  const event = JSON.parse(read(process.env.GITHUB_EVENT_PATH ?? "") ?? "{}");
  const draft = process.env.ROLLBACK_DRAFT === "true" || (!process.env.ROLLBACK_DRAFT && event.pull_request?.draft === true);
  let base = process.env.ROLLBACK_BASE || event.pull_request?.base?.sha || event.merge_group?.base_sha;
  const files = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0").filter(Boolean);
  const relevant = files.some((f) => configFile.test(f));
  let baseDirectory;
  try {
    if (!base && process.env.GITHUB_EVENT_NAME === "workflow_dispatch") base = git("rev-parse", "HEAD^1").trim();
    if (!base) {
      for (const ref of ["origin/HEAD", "origin/main", "main"]) {
        try { base = git("merge-base", ref, "HEAD").trim(); break; } catch {}
      }
    }
    if (!base) {
      if (relevant) throw new Error("comparison base missing; fetch the PR base or set ROLLBACK_BASE to its commit");
      return { errors, notes, draft };
    }
    git("cat-file", "-e", `${base}^{commit}`);
    const oldFiles = git("ls-tree", "-r", "--name-only", "-z", base).split("\0").filter(Boolean);
    const declared = (text) => JSON.parse(text ?? "{}").release_workers ?? [];
    const configs = [...new Set([...oldFiles, ...files].filter((f) => configFile.test(f)).concat(declared(before(base, "standards.json")), declared(read("standards.json"))))];
    baseDirectory = mkdtempSync(join(tmpdir(), "rollback-base-"));
    const newProduction = productionInventory({ built }), oldProduction = baseInventory(base, baseDirectory);
    const pairs = configs.map((file) => ({ label: file, afile: file, bfile: file, a: config(before(base, file), file), b: config(read(file), file) }));
    for (const file of new Set([...oldProduction.keys(), ...newProduction.keys()])) {
      const a = oldProduction.get(file), b = newProduction.get(file);
      pairs.push({ label: `${file} resolved production`, afile: a?.file ?? file, bfile: b?.file ?? file, a: a?.cfg ?? {}, b: b?.cfg ?? {} });
    }
    const dirs = new Set();
    // Both release inventories contribute references, including callers of another Worker.
    const dependencies = new Map();
    for (const { a, b } of pairs) for (const cfg of [a, b]) for (const c of [cfg, productionEnv(cfg)]) {
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
      for (const [path, c] of [[afile, a], [bfile, b], [afile, a.env?.production ?? {}], [bfile, b.env?.production ?? {}]]) for (const db of entries(c, "d1_databases")) {
        const dir = db.migrations_dir ?? c.migrations_dir ?? "migrations";
        if (typeof dir !== "string") throw new Error(`${file}: invalid migrations_dir`);
        dirs.add(posix.normalize(posix.join(dirname(path), dir)));
      }
      for (const [label, oldConfig, newConfig] of [[file, a, b], [`${file} env.production`, a.env?.production ?? {}, b.env?.production ?? {}]]) {
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
    const oldTables = new Set(), oldColumns = new Set();
    const migrations = (root) => {
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
      for (const dir of dirs) walk(dir);
      return [...new Set(found)].sort();
    };
    const oldMigrations = migrations(baseDirectory), newMigrations = migrations(".");
    for (const f of oldMigrations) {
      sqlHazards(read(join(baseDirectory, f)), oldTables, oldColumns);
      if (!newMigrations.includes(f)) errors.push(`${f}: historical D1 migration removed; retain migration history`);
    }
    for (const f of newMigrations) {
      if (oldMigrations.includes(f)) {
        if (read(f) !== read(join(baseDirectory, f))) errors.push(`${f}: historical D1 migration changed; add a new expand-only migration`);
        continue;
      }
      const sql = read(f), hazards = sqlHazards(sql, freshTables, freshColumns, oldTables, oldColumns);
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
  finally { if (baseDirectory) rmSync(baseDirectory, { recursive: true, force: true }); }
  return { errors: errors.map((e) => `rollback: ${e}`), notes, draft };
}
