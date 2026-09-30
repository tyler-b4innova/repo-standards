// Model and effort pins. A repository never chooses a model or effort: each person's app (or the org launcher) does.
// Apply removes these keys from the root .claude/settings.json and .codex/config.toml; the offline check fails on them.
const CLAUDE = ["model", "effortLevel"], CLAUDE_ENV = ["ANTHROPIC_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_EFFORT_LEVEL"];
const EFFORT = ["model", "model_reasoning_effort"];
// A Codex key path (segments) is a pin: model and effort at the top or in a profile, the default subagent model.
const isPin = (k) => (k.length === 1 && EFFORT.includes(k[0])) || (k.length === 2 && k[0] === "agents" && k[1] === "default_subagent_model")
  || (k.length === 3 && k[0] === "profiles" && EFFORT.includes(k[2]));
// An inline table under these paths can hold a pin: `fast = { model = "x" }` in [profiles], `profiles = {…}` at the top.
const holds = (k) => (k.length === 1 && ["agents", "profiles"].includes(k[0])) || (k.length === 2 && k[0] === "profiles");

// The pinned keys in a parsed settings.json, as names ("model", "env.ANTHROPIC_MODEL").
export const claudePins = (s) => [...CLAUDE.filter((k) => s?.[k] !== undefined), ...CLAUDE_ENV.filter((k) => s?.env?.[k] !== undefined).map((k) => `env.${k}`)];

export function stripClaudePins(s) {
  for (const k of CLAUDE) delete s[k];
  if (s.env) { for (const k of CLAUDE_ENV) delete s.env[k]; if (!Object.keys(s.env).length) delete s.env; }
  return s;
}

// A dotted TOML key ('a."b.c".d') as segments.
function segments(s) {
  const out = [];
  for (const m of s.trim().matchAll(/\s*("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+)\s*(\.|$)/g)) out.push(m[1].replace(/^["']|["']$/g, ""));
  return out;
}

// The pins in a config.toml, line by line: [{ line, key, table, inline }] with the dotted key ("profiles.fast.model"),
// the line index of the table header it sits under (-1: top level), and inline: true when the pin is inside an inline
// table (apply leaves that line to a person; the check still fails). Lines inside multi-line strings are skipped.
export function codexPins(text) {
  let table = [], header = -1, open = null;
  const out = [];
  (text ?? "").split("\n").forEach((l, i) => {
    if (open) { if (l.includes(open)) open = null; return; } // inside a multi-line string
    const t = l.trim();
    if (t.startsWith("[[")) { table = null; header = i; return; } // an array of tables holds no pin
    const h = t.match(/^\[([^\]]+)\]\s*(#.*)?$/);
    if (h) { table = segments(h[1]); header = i; return; }
    const kv = t.match(/^((?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_. -])+?)\s*=\s*(.*)$/);
    if (!kv) return;
    const val = kv[2];
    for (const q of ['"""', "'''"]) if (val.startsWith(q) && val.split(q).length === 2) open = q;
    if (table === null) return;
    const key = [...table, ...segments(kv[1])];
    if (isPin(key)) out.push({ line: i, key: key.join("."), table: header, inline: false });
    else if (holds(key) && val.startsWith("{") && /(^|[{,\s])(model|model_reasoning_effort|default_subagent_model)\s*=/.test(val))
      out.push({ line: i, key: `${key.join(".")} (inline table)`, table: header, inline: true });
  });
  return out;
}
