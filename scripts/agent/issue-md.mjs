// Markdown reading shared by pr.sh (open, status) and gate.mjs (issue): code fences, the closing-issue link, the
// Goal and Acceptance criteria sections. One copy, so the helper that writes the description and the gate that checks it agree.
export const PR_BODY_MAX = 65536; // GitHub rejects a longer pull request description (HTTP 422)
export const SHORT_SECTIONS = "add concise `## Goal` and `## Acceptance criteria` sections to the issue";

// CommonMark fences: an opening run of 3+ backticks or tildes (up to 3 spaces of indent; a backtick fence's info
// string has no backtick) closes only on the same character, at least as long, with nothing after it. An unclosed
// fence runs to the end. true marks a line inside a fence or on its delimiter.
export function fenceMask(lines) {
  let open = null;
  return lines.map((l) => {
    const m = l.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (open) {
      if (m && m[1][0] === open.ch && m[1].length >= open.len && !m[2].trim()) open = null;
      return true;
    }
    if (m && !(m[1][0] === "`" && m[2].includes("`"))) { open = { ch: m[1][0], len: m[1].length }; return true; }
    return false;
  });
}

// The issue a description closes: the first Closes/Fixes/Resolves (any tense) #N outside fences, HTML comments and inline code.
export function closingIssue(text) {
  const lines = text.split(/\r?\n/), fenced = fenceMask(lines);
  const prose = lines.filter((_, k) => !fenced[k]).join("\n")
    .replace(/<!--[\s\S]*?(-->|$)/g, " ")
    .replace(/(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)/g, " ");
  return prose.match(/(?<![\w-])(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?):?\s+#(\d+)\b/i)?.[1] ?? null;
}

// [{ name, lines }] for the level-2 sections named Goal or Acceptance criteria outside fences; [] when neither.
export function goalSections(text) {
  const ls = text.split(/\r?\n/), fenced = fenceMask(ls), out = [];
  let cur = null;
  ls.forEach((l, k) => {
    const h = !fenced[k] && l.match(/^##\s+(.+?)\s*#*\s*$/);
    if (h || (!fenced[k] && /^#\s/.test(l))) { cur = h && /^(goal|acceptance criteria)$/i.test(h[1]) ? { name: h[1], lines: [] } : null; if (cur) out.push(cur); }
    else if (cur) cur.lines.push(l);
  });
  return out;
}

// Headings outside fences pushed down to ### or lower, so a quoted issue cannot open a section of its own.
export function demote(lines) {
  const fenced = fenceMask(lines);
  return lines.map((l, k) => {
    const h = !fenced[k] && l.match(/^(#{1,6})(\s.*)$/);
    return h ? "#".repeat(Math.min(6, Math.max(3, h[1].length + 1))) + h[2] : l;
  }).join("\n").trim();
}

// [start, end) of the first level-2 section outside fences whose heading matches `head` (end = next level-2 heading or the end); null when absent.
export function sectionBounds(lines, head) {
  const fenced = fenceMask(lines), i = lines.findIndex((l, k) => !fenced[k] && head.test(l));
  if (i < 0) return null;
  const j = lines.findIndex((l, k) => k > i && !fenced[k] && /^##\s/.test(l));
  return [i, j < 0 ? lines.length : j];
}
