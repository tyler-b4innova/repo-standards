import { createHash } from "node:crypto";

// GitHub's per-comment transport capacity is not a limit on a review or response.
// Publish every part before its manifest, and verify the complete payload on reads.
const COMMENT_CAPACITY = 65536;
const digest = (body) => createHash("sha256").update(body).digest("hex");
export function splitComment(body, kind) {
  if (body.length <= COMMENT_CAPACITY) return [body];
  const hash = digest(body), comments = [];
  for (let at = 0; at < body.length;) {
    const header = `<!-- std:multipart-part ${JSON.stringify({ kind, hash, index: comments.length })} -->\n`;
    let end = Math.min(body.length, at + COMMENT_CAPACITY - header.length);
    if (end < body.length && /[\uD800-\uDBFF]/.test(body[end - 1])) end--;
    comments.push(header + body.slice(at, end)); at = end;
  }
  comments.push(`<!-- std:multipart ${JSON.stringify({ kind, hash, parts: comments.length })} -->`);
  return comments;
}
export function joinComment(body, comments, kind) {
  const manifest = /^<!-- std:multipart (\{[^\n]*\}) -->$/.exec(body ?? "");
  if (!manifest) return body;
  try {
    const m = JSON.parse(manifest[1]);
    if (m.kind !== kind || !/^[0-9a-f]{64}$/.test(m.hash) || !Number.isSafeInteger(m.parts) || m.parts < 1) return null;
    const parts = new Map();
    for (const c of comments) {
      const hit = /^<!-- std:multipart-part (\{[^\n]*\}) -->\n([\s\S]*)$/.exec(c.body ?? "");
      if (!hit) continue;
      const p = JSON.parse(hit[1]);
      if (p.kind !== kind || p.hash !== m.hash || !Number.isSafeInteger(p.index) || p.index < 0 || p.index >= m.parts) continue;
      if (parts.has(p.index) && parts.get(p.index) !== hit[2]) return null;
      parts.set(p.index, hit[2]);
    }
    if (parts.size !== m.parts) return null;
    const result = [...parts].sort(([a], [b]) => a - b).map(([, text]) => text).join("");
    return digest(result) === m.hash ? result : null;
  } catch { return null; }
}
export function parseReviewComments(comments) {
  return comments.flatMap((comment) => {
    const body = joinComment(comment.body, comments, "std:review");
    if (body == null && /^<!-- std:multipart /.test(comment.body ?? "") && (comment.body ?? "").includes('"kind":"std:review"')) throw new Error("incomplete or changed multipart review comment");
    const record = parseReviewRecord(body);
    return record ? [{ comment, record, body }] : [];
  });
}

// The shared contract for the org App's completed full/follow-up review. A record is
// evidence only when its caller also checks the comment's author, head and base.
const sha = (x) => typeof x === "string" && /^[0-9a-f]{40}$/.test(x);
const words = (x) => typeof x === "string" && Boolean(x.trim());
const unique = (xs) => new Set(xs.map((x) => x?.id)).size === xs.length;

export function validReviewRecord(r) {
  return Boolean(r && r.schema === 1 && sha(r.head) && sha(r.base) && words(r.panel)
    && ["full", "followup"].includes(r.phase)
    && (r.phase === "full" ? r.from === undefined : sha(r.from))
    && ["clean", "findings"].includes(r.verdict)
    && Array.isArray(r.findings) && unique(r.findings)
    && r.findings.every((f) => words(f?.id) && words(f?.text))
    && Array.isArray(r.outcomes) && unique(r.outcomes)
    && r.outcomes.every((o) => words(o?.id) && ["fixed", "rejected", "blocking"].includes(o.status) && words(o.reason) && words(o.evidence))
    && (r.verdict === "clean" ? !r.findings.length && r.outcomes.every((o) => o.status !== "blocking") : r.findings.length > 0));
}

export function parseReviewRecord(body) {
  // App authorship alone does not attest text copied from an author or provider.
  // Accept only a dedicated review comment, including the Launcher's legacy envelope.
  const match = /^(?:<!-- independent-review sha=[0-9a-f]{40} reviewer=\S+ model=\S+ verdict=(?:clean|findings) -->\r?\n)?<!-- std:review (\{[^\n]*\}) -->/.exec(body ?? "");
  if (!match) return null;
  try { const r = JSON.parse(match[1]); return validReviewRecord(r) ? r : null; }
  catch { return null; }
}

export function renderReviewRecord(r) {
  if (!validReviewRecord(r)) throw new Error("incomplete review record");
  return `<!-- std:review ${JSON.stringify(r).replaceAll("<", "\\u003c").replaceAll(">", "\\u003e")} -->`;
}

// Indices run from the selected record back to its full-review root. Earlier
// positions make orphaned and cyclic chains fail without recursion; a newer
// orphan receipt cannot erase an older valid root for the same commit.
export function reviewRecordChain(records, index = records.length - 1) {
  const target = records[index];
  if (!validReviewRecord(target)) return null;
  if (target.phase === "full") return [index];
  const chains = [];
  for (let i = 0; i <= index; i++) {
    const r = records[i];
    if (!validReviewRecord(r) || r.base !== target.base || r.panel !== target.panel) continue;
    if (r.phase === "full") { chains[i] = [i]; continue; }
    for (let p = i - 1; p >= 0; p--) if (chains[p] && records[p].head === r.from) { chains[i] = [i, ...chains[p]]; break; }
  }
  return chains[index] ?? null;
}

export async function verifiedReviewChain(records, index, continues) {
  const target = records[index];
  if (!validReviewRecord(target)) return false;
  if (target.phase === "full") return true;
  const scope = records.slice(0, index + 1).map((r) => r.base === target.base && r.panel === target.panel ? r : { ...r, phase: "invalid" });
  return Boolean((await reviewRecordValidity(scope, continues))[index]);
}

async function reviewRecordValidity(records, continues) {
  const valid = [];
  const edges = new Map();
  for (let i = 0; i < records.length; i++) {
    const r = records[i];
    if (!validReviewRecord(r)) continue;
    if (r.phase === "full") { valid[i] = true; continue; }
    for (let p = i - 1; p >= 0; p--) if (valid[p] && records[p].head === r.from && records[p].base === r.base && records[p].panel === r.panel) {
      const edge = JSON.stringify([r.from, r.head]);
      if (!edges.has(edge)) edges.set(edge, Promise.resolve(continues(r.from, r.head)));
      valid[i] = await edges.get(edge); break;
    }
  }
  return valid;
}

// Invalid receipts can introduce findings, but cannot claim them fixed/rejected.
export async function verifiedReviewRecords(records, continues) {
  const valid = await reviewRecordValidity(records, continues);
  return records.map((r, i) => valid[i] ? r : { ...r, outcomes: [] });
}

// A later empty clean report cannot erase a known finding: only an explicit
// independently verified disposition removes it from the outstanding ledger.
export function outstandingReviewFindings(records) {
  const contents = new Map();
  for (const r of records) for (const f of r.findings) {
    if (!contents.has(f.id)) contents.set(f.id, new Set());
    contents.get(f.id).add(f.text);
  }
  const pending = new Map();
  for (const r of records) {
    for (const o of r.outcomes) if (o.status !== "blocking") pending.delete(o.id);
    for (const f of r.findings) {
      // An unchanged carried finding keeps its identity. Historical ID reuse for
      // different defects needs distinct explicit dispositions, never a raw ambiguous ID.
      const id = contents.get(f.id).size > 1 ? `reused-finding:${createHash("sha256").update(JSON.stringify([f.id, f.text])).digest("hex")}` : f.id;
      const sourceId = id !== f.id ? f.id : pending.get(id)?.sourceId;
      pending.set(id, { id, text: f.text, ...(sourceId ? { sourceId } : {}) });
    }
  }
  return [...pending.values()];
}
