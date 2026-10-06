// Repo-owned local Worker data, shared by the offline check and the local gate.
import { effectiveConfig, rootFile } from "./release-config.mjs";

const DEFAULT = { command: "node_modules/.bin/wrangler dev --local --ip 127.0.0.1 --port 8787", url: "http://127.0.0.1:8787", ready: "/" };
export function localConfig(value) {
  if (value === false) return false;
  if (value === undefined) value = DEFAULT;
  const bad = () => { throw new Error('standards.json local must be false or {command, url, ready}: a local-only command, an http(s) loopback URL and a readiness path'); };
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some((k) => !["command", "url", "ready"].includes(k))
    || typeof value.command !== "string" || !value.command.trim() || typeof value.url !== "string" || typeof value.ready !== "string") bad();
  let url;
  try { url = new URL(value.url); } catch { bad(); }
  if (!["http:", "https:"].includes(url.protocol) || !(url.hostname === "localhost" || url.hostname === "[::1]" || /^127\.(\d{1,3}\.){2}\d{1,3}$/.test(url.hostname))
    || url.username || url.password || url.search || url.hash || !value.ready.startsWith("/") || value.ready.startsWith("//") || value.ready.includes("\\")) bad();
  try { if (new URL(value.ready, url).origin !== url.origin) bad(); } catch { bad(); }
  // No shell, package-runner or wrapper: only the repo Wrangler's dev entry point.
  const tokens = value.command.trim().split(/\s+/);
  if (!["wrangler", "node_modules/.bin/wrangler", "./node_modules/.bin/wrangler"].includes(tokens[0]) || tokens[1] !== "dev")
    throw new Error("local command must invoke wrangler dev directly; wrappers require local: false");
  const argv = ["dev"], options = new Set(["--config", "-c", "--env", "-e", "--ip", "--port", "--inspector-port", "--persist-to", "--log-level"]);
  for (let i = 2; i < tokens.length; i++) {
    const token = tokens[i];
    if (token === "--local") continue;
    if (options.has(token)) {
      const arg = tokens[++i];
      if (!arg || arg.startsWith("-") || !/^[a-zA-Z0-9_./:[\]-]+$/.test(arg)) throw new Error(`unsafe local command argument for ${token}`);
      argv.push(token, arg);
    } else if (["--test-scheduled", "--live-reload"].includes(token)) argv.push(token);
    else throw new Error(`local command option refused: ${token}; remote options and local overrides are forbidden`);
  }
  argv.push("--local");
  return { ...value, command: [tokens[0], ...argv].join(" "), argv };
}

// Re-read after build: adapters can generate a different configuration.
export function localWorkerConfig(config) {
  const argv = [...config.argv], files = [];
  for (let i = 1; i < argv.length; i++) if (["--config", "-c"].includes(argv[i])) files.push(argv[++i]);
  if (files.length > 1) throw new Error("local gate supports only one Wrangler config");
  const root = files[0] ?? rootFile();
  if (!root) throw new Error("local Worker needs a Wrangler config; use local: false for no Worker");
  const resolved = effectiveConfig(root, false, { redirect: files.length === 0 });
  const inspect = (value) => {
    if (!value || typeof value !== "object") return;
    if (value.remote === true) throw new Error(`${resolved.file}: remote: true binding refused by local gate`);
    for (const child of Object.values(value)) inspect(child);
  };
  inspect(resolved.cfg);
  if (!files.length) argv.push("--config", resolved.file);
  return argv;
}
