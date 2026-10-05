// A small JavaScript/TypeScript lexer for the standards checks: it tells comments from strings, template literals and
// regular expressions, which a regex over the text cannot. scan(text) -> { comments: [text], code: the source with
// comments removed and string, template and regex contents blanked (their delimiters kept), source: the source with
// only the comments removed }.
const KEYWORDS = new Set(["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]);

export function scan(text) {
  const comments = [], ranges = [];
  let code = "", i = 0, last = ""; // last: the previous significant token's final character, or a keyword
  const braces = []; // per open `{`: true when it opened a template literal's ${ } substitution
  const regexAllowed = () => last === "" || /[(,=:[!&|?{};+\-*%<>~^]$/.test(last) || KEYWORDS.has(last);
  const blank = (s) => s.replace(/[^\n]/g, " ");
  const template = () => { // from just after a ` (or a substitution's closing }) to the closing ` or the next ${
    let out = "";
    while (i < text.length) {
      const c = text[i];
      if (c === "\\") { out += "  "; i += 2; continue; }
      if (c === "`") { i++; code += out + "`"; last = "`"; return; }
      if (c === "$" && text[i + 1] === "{") { i += 2; code += out + "${"; braces.push(true); last = "{"; return; }
      out += c === "\n" ? "\n" : " "; i++;
    }
    code += out;
  };
  while (i < text.length) {
    const c = text[i], n = text[i + 1];
    if (c === "/" && n === "/") { const e = text.indexOf("\n", i); const end = e < 0 ? text.length : e; comments.push(text.slice(i, end)); ranges.push([i, end]); i = end; continue; }
    if (c === "/" && n === "*") { const e = text.indexOf("*/", i + 2); const end = e < 0 ? text.length : e + 2; comments.push(text.slice(i, end)); ranges.push([i, end]); code += blank(text.slice(i, end)).replace(/ +/g, " "); i = end; continue; }
    if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== c && text[j] !== "\n") j += text[j] === "\\" ? 2 : 1;
      code += c + blank(text.slice(i + 1, j)) + c; i = j + 1; last = c; continue;
    }
    if (c === "`") { code += "`"; i++; template(); continue; }
    if (c === "}" && braces.length && braces.at(-1)) { braces.pop(); code += "}"; i++; template(); continue; }
    if (c === "/" && regexAllowed()) {
      let j = i + 1, cls = false;
      while (j < text.length && text[j] !== "\n" && (cls || text[j] !== "/")) {
        if (text[j] === "\\") j++;
        else if (text[j] === "[") cls = true;
        else if (text[j] === "]") cls = false;
        j++;
      }
      while (/[a-z]/i.test(text[j + 1] ?? "")) j++;
      code += "/" + blank(text.slice(i + 1, j)) + "/"; i = j + 1; last = "/r"; continue;
    }
    if (c === "{") braces.push(false);
    else if (c === "}") braces.pop();
    if (/[A-Za-z_$]/.test(c)) {
      const w = text.slice(i).match(/^[\w$]+/)[0];
      code += w; i += w.length; last = KEYWORDS.has(w) ? w : "a"; continue;
    }
    if (!/\s/.test(c)) last = c === ")" || c === "]" ? "a" : c;
    code += c; i++;
  }
  let source = "", at = 0;
  for (const [a, b] of ranges) { source += text.slice(at, a) + (text.slice(a, b).includes("\n") ? "\n" : " "); at = b; }
  return { comments, code, source: source + text.slice(at) };
}
