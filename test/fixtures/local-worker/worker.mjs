// The fixture's real entry point: writes and reads the local KV binding over HTTP.
import credentialProbe from "./.credential-build.mjs";
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === "/hang") { await new Promise((r) => setTimeout(r, 60000)); return new Response("late"); }
    if (path === "/redirect") return Response.redirect("https://example.com/");
    if (path === "/health") return new Response("ready");
    if (path === "/value" && request.method === "PUT") {
      await env.DATA.put("value", await request.text());
      return new Response("saved");
    }
    if (path === "/value") return new Response(await env.DATA.get("value"));
    if (path === "/local-vars") return new Response(env.LOCAL_VALUE);
    if (path === "/credentials") return Response.json({ build: credentialProbe, worker: [env.CLOUDFLARE_API_TOKEN ?? null, env.CLOUDFLARE_API_KEY ?? null, env.CLOUDFLARE_EMAIL ?? null, env.CLOUDFLARE_ACCOUNT_ID ?? null] });
    return new Response("local Worker", { headers: { "X-Robots-Tag": "noindex" } });
  },
};
