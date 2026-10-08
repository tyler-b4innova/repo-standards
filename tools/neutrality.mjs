#!/usr/bin/env node
// Org-neutrality check for this engine: no organization names, no hosts beyond vendor docs and
// package registries, no account, App or vault identifiers.
//   node tools/neutrality.mjs            scan tracked files at HEAD
//   node tools/neutrality.mjs --history  scan every commit reachable from HEAD (another branch is checked in its own pull request): added lines, messages, author and committer
//   node tools/neutrality.mjs --stdin    scan text on stdin (used by the self-test)
// Organization names are held only as sha256 digests of lowercase tokens, so this file names none.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const TOKENS = new Set([
  "486bacc5c2d8a71a73d51bf8e522deaa264ec2628dca2955da1e9b8e00f21943",
  "e3f97c807e4b6a7e54650fe4cd5373f7c78c68bd8908715d47f321bc4d3f3116",
  "d47d5e0f45dd47ac4d76f29c98b92e284906eb7966c6333e1b579a552a59514a",
  "4a41917505ec0b60113a7b7812d888db64c5ce8a5409b80a793d76c67450d86a",
]);
const HOSTS = new Set([
  "github.com", "api.github.com", "uploads.github.com", "docs.github.com", "users.noreply.github.com",
  "registry.npmjs.org", "www.npmjs.com", "npmjs.com",
  "code.claude.com", "docs.anthropic.com", "claude.ai",
  "learn.chatgpt.com", "developers.openai.com", "chatgpt.com",
  "developers.cloudflare.com", "challenges.cloudflare.com", "cache.agilebits.com", "json-schema.org", "docs.sentry.io",
  "example.com", "example.org", "example.net",
  "octocoders.io", // the example org host in GitHub's documented webhook payloads
]);
// GitHub-owned avatar hosts (avatars.githubusercontent.com, avatars1.githubusercontent.com, ...) in the same documented payloads.
const HOST_PATTERNS = [/^avatars\d*\.githubusercontent\.com$/];
const TLD = "com|net|org|io|dev|app|ai|co|ca|us|uk|cloud|site|xyz|tech|info|biz|me";
const RULES = [
  [/(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])/i, "32-hex identifier (account or zone id)"],
  [/\bIv[0-9]{1,2}[A-Za-z0-9.]{14,}\b/, "GitHub App client id"],
  [/\b(app|installation|client)[_-]?id\b["'\s:=]+\d{4,}/i, "App or installation id"],
  [/\b(?=[a-z0-9]{26}\b)(?=[a-z]*\d)[a-z0-9]{26}\b/, "26-char vault id"],
];

export function findings(text, where) {
  const out = [];
  text.split("\n").forEach((line, i) => {
    const at = `${where}:${i + 1}`;
    for (const t of line.toLowerCase().split(/[^a-z0-9]+/)) {
      if (t && TOKENS.has(createHash("sha256").update(t).digest("hex"))) out.push(`${at}: organization name`);
    }
    // A host is a.b.tld anywhere, or a.tld after a scheme, "@" or a quote (one-dot code such as obj.org is skipped).
    for (const m of line.matchAll(new RegExp(`(^|[^a-z0-9.-])((?:[a-z0-9-]+\\.)+(?:${TLD}))(?![a-z0-9-])`, "gi"))) {
      const host = m[2].toLowerCase();
      const urlish = /(:\/\/|@|["'`])$/.test(line.slice(0, m.index + m[1].length));
      if (host.split(".").length < 3 && !urlish) continue;
      if (!HOSTS.has(host) && !host.endsWith(".example.com") && !HOST_PATTERNS.some((r) => r.test(host))) out.push(`${at}: host ${host}`);
    }
    for (const [re, what] of RULES) if (re.test(line)) out.push(`${at}: ${what}`);
  });
  return out;
}

const git = (...a) => execFileSync("git", a, { encoding: "utf8", maxBuffer: 1 << 28 });
let found = [];
if (process.argv.includes("--stdin")) {
  found = findings(readFileSync(0, "utf8"), "stdin");
} else if (process.argv.includes("--history")) {
  for (const sha of git("rev-list", "HEAD").split("\n").filter(Boolean)) {
    found.push(...findings(git("show", "-s", "--format=%an <%ae>%n%cn <%ce>%n%B", sha), `${sha.slice(0, 7)} meta`));
    const added = git("show", "--format=", "--unified=0", "--no-color", sha).split("\n").filter((l) => l.startsWith("+") && !l.startsWith("+++"));
    found.push(...findings(added.join("\n"), `${sha.slice(0, 7)} diff`));
  }
} else {
  for (const f of git("ls-files").split("\n").filter(Boolean)) {
    let text;
    try {
      text = readFileSync(f, "utf8");
    } catch {
      continue;
    }
    if (!text.includes("\0")) found.push(...findings(text, f));
  }
}
if (found.length) {
  console.error(`neutrality: ${found.length} finding(s)\n  ${[...new Set(found)].join("\n  ")}`);
  process.exit(1);
}
console.log("neutrality: clean");
