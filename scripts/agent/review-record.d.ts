export interface ReviewFinding { id: string; text: string }
export interface OutstandingReviewFinding extends ReviewFinding { sourceId?: string }
export interface ReviewOutcome { id: string; status: "fixed" | "rejected" | "blocking"; reason: string; evidence: string }
export interface ReviewRecord {
  schema: 1;
  head: string;
  base: string;
  panel: string;
  phase: "full" | "followup";
  from?: string;
  verdict: "clean" | "findings";
  findings: ReviewFinding[];
  outcomes: ReviewOutcome[];
}
export function validReviewRecord(value: unknown): value is ReviewRecord;
export function parseReviewRecord(body: string | null | undefined): ReviewRecord | null;
export function renderReviewRecord(record: ReviewRecord): string;
export function outstandingReviewFindings(records: ReviewRecord[]): OutstandingReviewFinding[];
