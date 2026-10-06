// Repo-owned local Worker data, shared by the offline check and the local gate.
export function localConfig(value) {
  if (value === false) return false;
  if (value === undefined) return { command: "node_modules/.bin/wrangler dev --local --ip 127.0.0.1 --port 8787", url: "http://127.0.0.1:8787", ready: "/" };
  const bad = () => { throw new Error('standards.json local must be false or {command, url, ready}: a local-only command, an http(s) loopback URL and a readiness path'); };
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some((k) => !["command", "url", "ready"].includes(k))
    || typeof value.command !== "string" || !value.command.trim() || typeof value.url !== "string" || typeof value.ready !== "string") bad();
  let url;
  try { url = new URL(value.url); } catch { bad(); }
  if (!["http:", "https:"].includes(url.protocol) || !(url.hostname === "localhost" || url.hostname === "[::1]" || /^127\.(\d{1,3}\.){2}\d{1,3}$/.test(url.hostname))
    || url.username || url.password || url.search || url.hash || !value.ready.startsWith("/") || value.ready.startsWith("//") || value.ready.includes("\\")) bad();
  try { if (new URL(value.ready, url).origin !== url.origin) bad(); } catch { bad(); }
  return value;
}
