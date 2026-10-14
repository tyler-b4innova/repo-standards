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

// A later empty clean report cannot erase a known finding: only an explicit
// independently verified disposition removes it from the outstanding ledger.
export function outstandingReviewFindings(records) {
  const pending = new Map();
  for (const r of records) {
    for (const o of r.outcomes) if (o.status !== "blocking") pending.delete(o.id);
    for (const f of r.findings) pending.set(f.id, f);
  }
  return [...pending.values()];
}
