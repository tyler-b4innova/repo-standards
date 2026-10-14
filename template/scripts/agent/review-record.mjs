import { createHash } from "node:crypto";

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
  const valid = [];
  for (let i = 0; i <= index; i++) {
    const r = records[i];
    if (!validReviewRecord(r) || r.base !== target.base || r.panel !== target.panel) continue;
    if (r.phase === "full") { valid[i] = true; continue; }
    for (let p = i - 1; p >= 0; p--) if (valid[p] && records[p].head === r.from) { valid[i] = await continues(r.from, r.head); break; }
  }
  return Boolean(valid[index]);
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
