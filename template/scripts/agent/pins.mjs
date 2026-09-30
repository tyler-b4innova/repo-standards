// Model and effort pins. A repository never chooses a model or effort: each person's app (or the org launcher) does.
// Apply removes these keys from the root .claude/settings.json and .codex/config.toml; the offline check fails on them.
const CLAUDE = ["model", "effortLevel"], CLAUDE_ENV = ["ANTHROPIC_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_EFFORT_LEVEL"];
const CODEX = [/^model$/, /^model_reasoning_effort$/, /^agents\.default_subagent_model$/, /^profiles\.[^.]+\.(model|model_reasoning_effort)$/];

// The pinned keys in a parsed settings.json, as names ("model", "env.ANTHROPIC_MODEL").
export const claudePins = (s) => [...CLAUDE.filter((k) => s?.[k] !== undefined), ...CLAUDE_ENV.filter((k) => s?.env?.[k] !== undefined).map((k) => `env.${k}`)];

export function stripClaudePins(s) {
  for (const k of CLAUDE) delete s[k];
  if (s.env) { for (const k of CLAUDE_ENV) delete s.env[k]; if (!Object.keys(s.env).length) delete s.env; }
  return s;
}

// The pinned keys in a config.toml, line by line: [{ line, key, table }] with the full dotted key ("profiles.fast.model")
// and the line index of the table header it sits under (-1: top level).
const path = (s) => s.split(".").map((p) => p.trim().replace(/^["']|["']$/g, "")).join(".");
export function codexPins(text) {
  let table = "", header = -1;
  const out = [];
  (text ?? "").split("\n").forEach((l, i) => {
    const t = l.trim();
    if (t.startsWith("[[")) { table = null; header = i; return; } // an array of tables holds no pin
    const h = t.match(/^\[([^\]]+)\]\s*(#.*)?$/);
    if (h) { table = path(h[1]); header = i; return; }
    const k = t.match(/^([A-Za-z0-9_.\-"' ]+?)\s*=/);
    if (!k || table === null) return;
    const key = [table, path(k[1])].filter(Boolean).join(".");
    if (CODEX.some((r) => r.test(key))) out.push({ line: i, key, table: header });
  });
  return out;
}
