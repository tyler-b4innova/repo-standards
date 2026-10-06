// Compare production's source configuration and migrations with the PR base, without remote access.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, posix } from "node:path";
import { parse } from "./staging.mjs";
import { scan } from "./jsscan.mjs";
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
  for (let t of statements(sql)) {
    // WITH statements execute the command after their parenthesized CTE bodies.
    if (t[0] === "with") {
      let depth = 0;
      const start = t.findIndex((v, i) => {
        if (v === "(") depth++; else if (v === ")") depth--;
        return i > 0 && depth === 0 && ["select", "insert", "replace", "update", "delete"].includes(v);
      });
      if (start >= 0) t = t.slice(start);
    }
    if (t[0] === "create" && t.includes("table")) {
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
        if (phrase(constraints, "not", "null") && defaultAt < 0) hazards.push([`${table}.${name(t[col])}`, "ADD NOT NULL without a default"]);
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
        const set = t.indexOf("set", upd), end = t.findIndex((v, i) => i > set && ["where", "returning"].includes(v));
        const assignments = t.slice(set + 1, end < 0 ? undefined : end);
        const cols = assignments.flatMap((v, i) => assignments[i + 1] === "=" ? [name(v)] : []);
        if (!freshTables.has(table) && (!cols.length || cols.some((c) => !freshColumns.has(`${table}.${c}`))))
          hazards.push([table, "UPDATE data rewrite of an existing column"]);
      } else hazards.push([tableAt(t, t.indexOf("into") + 1)[0], "REPLACE data rewrite"]);
    }
  }
  return hazards;
}

export function rollbackFindings() {
  const errors = [], notes = [];
  const event = JSON.parse(read(process.env.GITHUB_EVENT_PATH ?? "") ?? "{}");
  const draft = process.env.ROLLBACK_DRAFT === "true" || (!process.env.ROLLBACK_DRAFT && event.pull_request?.draft === true);
  let base = process.env.ROLLBACK_BASE || event.pull_request?.base?.sha || event.merge_group?.base_sha;
  const files = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0").filter(Boolean);
  const relevant = files.some((f) => configFile.test(f));
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
    const dirs = new Set();
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
    for (const file of configs) {
      const a = config(before(base, file), file), b = config(read(file), file);
      for (const c of [a, b, a.env?.production ?? {}, b.env?.production ?? {}]) for (const db of entries(c, "d1_databases")) {
        const dir = db.migrations_dir ?? c.migrations_dir ?? "migrations";
        if (typeof dir !== "string") throw new Error(`${file}: invalid migrations_dir`);
        dirs.add(posix.normalize(posix.join(dirname(file), dir)));
      }
      for (const [label, oldConfig, newConfig] of [[file, a, b], [`${file} env.production`, a.env?.production ?? {}, b.env?.production ?? {}]]) {
        for (const kind of kinds) {
          const present = new Set(entries(newConfig, kind).map(bindingName));
          for (const binding of entries(oldConfig, kind)) if (!present.has(bindingName(binding))) errors.push(`${label}: removed production binding ${kind} ${bindingName(binding)}`);
        }
      }
      const oldClasses = exports(a, file, (f) => before(base, f)), newClasses = exports(b, file, read);
      const bound = [...entries(a, "durable_objects.bindings"), ...entries(b, "durable_objects.bindings"), ...entries(a.env?.production ?? {}, "durable_objects.bindings"), ...entries(b.env?.production ?? {}, "durable_objects.bindings")].filter((v) => !v.script_name).map((v) => v.class_name);
      for (const name of new Set(bound)) if (oldClasses?.has(name) && !newClasses?.has(name)) errors.push(`${file}: removed or renamed Durable Object class ${name} while still bound in this release`);
      const previous = new Map(entries(a, "migrations").map((m) => [m.tag, JSON.stringify(m)]));
      for (const m of entries(b, "migrations")) if (previous.get(m.tag) !== JSON.stringify(m)) {
        for (const name of [...(m.deleted_classes ?? []), ...(m.renamed_classes ?? []).map((r) => r.from)])
          if (bound.includes(name)) errors.push(`${file}: Durable Object class ${name} deleted_classes/renamed_classes while still bound in this release`);
      }
    }
    const contracts = JSON.parse(read("rollback-contracts.json") ?? "{}");
    const freshTables = new Set(), freshColumns = new Set();
    // New tables/columns are expand targets only when absent from all base migration history.
    const oldTables = new Set(), oldColumns = new Set();
    const migrations = (paths) => paths.filter((f) => f.endsWith(".sql") && [...dirs].some((d) => f.startsWith(`${d}/`))).sort();
    for (const f of migrations(oldFiles)) {
      sqlHazards(before(base, f), oldTables, oldColumns);
      if (!files.includes(f) || read(f) === null) errors.push(`${f}: historical D1 migration removed; retain migration history`);
    }
    for (const f of migrations(files)) {
      if (oldFiles.includes(f)) {
        if (read(f) !== before(base, f)) errors.push(`${f}: historical D1 migration changed; add a new expand-only migration`);
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
  return { errors: errors.map((e) => `rollback: ${e}`), notes, draft };
}
