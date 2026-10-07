// Portal pass: every staging and preview Worker refuses a request without a short-lived pass signed by the org's
// client portal. Production (env.ENVIRONMENT === "production") never checks. In the Worker's fetch handler (or its
// middleware), before anything else:
//   import { portalPass } from "../scripts/agent/portal-pass.mjs";
//   const denied = await portalPass(request, env); if (denied) return denied;
// With static assets, set `assets.run_worker_first: true` so the files are gated too.
// The pass: a JWT signed with Ed25519 (header alg "EdDSA" and a kid), keys from the portal's JWKS (env.PORTAL_JWKS_URL,
// cached 10 minutes, refetched once on an unknown kid); iss = env.PORTAL_ISSUER (the portal origin); aud (a string or a
// list) names env.PORTAL_AUD (this Worker's name); sub "user:…", "agent:…" or "test:…"; exp − iat at most 900 seconds;
// 60 seconds of clock skew. Read from `Authorization: Bearer`, then the `__Host-portal_pass` cookie, then a one-time
// `?portal_pass=` query, which redirects to the same URL without it and sets the cookie. Anything else: an empty 401.
// Plain WebCrypto, no dependencies: runs in workerd and Node 22+.

const COOKIE = "__Host-portal_pass", QUERY = "portal_pass", SKEW = 60, MAX_LIFE = 900, JWKS_TTL = 600_000, REFETCH_GAP = 60_000;
const jwksCache = new Map(); // url -> { keys, at, refetchedAt, failedUntil, pending }

const unb64 = (s) => {
  if (typeof s !== "string" || !/^[A-Za-z0-9_-]*$/.test(s)) throw new Error("not base64url");
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};
const part = (s) => JSON.parse(new TextDecoder().decode(unb64(s)));

// The pass's claims when it is valid for this Worker, else null. `jwks(kid)` returns the matching JWK or null.
export async function verifyPass(token, { aud, issuer, jwks, now = Math.floor(Date.now() / 1000) }) {
  try {
    const parts = String(token).split(".");
    if (parts.length !== 3) return null;
    const header = part(parts[0]), claims = part(parts[1]);
    if (header.alg !== "EdDSA" || typeof header.kid !== "string" || !header.kid) return null;
    const jwk = await jwks(header.kid);
    if (!jwk || jwk.kty !== "OKP" || jwk.crv !== "Ed25519" || typeof jwk.x !== "string") return null;
    const key = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", x: jwk.x }, { name: "Ed25519" }, false, ["verify"]);
    const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    if (!(await crypto.subtle.verify({ name: "Ed25519" }, key, unb64(parts[2]), signed))) return null;
    const { iss, sub, exp, iat } = claims, auds = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (iss !== issuer || !aud || !auds.includes(aud)) return null;
    if (typeof sub !== "string" || !/^(user|agent|test):.+/.test(sub)) return null;
    if (!Number.isFinite(exp) || !Number.isFinite(iat) || exp - iat > MAX_LIFE || exp <= iat) return null;
    if (now > exp + SKEW || iat > now + SKEW) return null;
    return claims;
  } catch {
    return null;
  }
}

// The JWK for `kid` from the JWKS at `url`: cached for 10 minutes; an unknown kid refetches once (at most once a minute,
// so a stream of made-up kids cannot hammer the portal). Loads are shared; failures deny uncached keys for one minute.
function keyring(url, fetcher) {
  const load = async () => {
    const r = await fetcher(url, { headers: { accept: "application/json" } });
    if (!r.ok) throw new Error(`JWKS ${r.status}`);
    const body = await r.json();
    return Array.isArray(body?.keys) ? body.keys : [];
  };
  const refresh = (c) => {
    // Reserve every load before awaiting it, including the first load and TTL refreshes.
    c.pending ??= load().then((keys) => {
      c.keys = keys;
      c.at = Date.now();
      c.failedUntil = 0;
      return keys;
    }).catch(() => {
      c.failedUntil = Date.now() + REFETCH_GAP;
      return [];
    }).finally(() => { c.pending = null; });
    return c.pending;
  };
  return async (kid) => {
    let c = jwksCache.get(url);
    const t = Date.now();
    if (!c) {
      c = { keys: [], at: 0, refetchedAt: 0, failedUntil: 0, pending: null };
      jwksCache.set(url, c);
    }
    const fresh = c.at && t - c.at <= JWKS_TTL;
    let k = fresh && c.keys.find((x) => x.kid === kid);
    if (k) return k; // A usable cached key never waits behind an unknown-kid refetch.
    if (t < c.failedUntil) return null;
    if (c.pending || !fresh || c.failedUntil) {
      const keys = await refresh(c);
      // This load already checked the current JWKS; an unknown kid needs no second fetch.
      return keys.find((x) => x.kid === kid) ?? null;
    }
    if (t - c.refetchedAt > REFETCH_GAP) {
      c.refetchedAt = t;
      k = (await refresh(c)).find((x) => x.kid === kid);
    }
    return k ?? null;
  };
}

// Refusals and the cookie redirect carry noindex too: gate's preview noindex probe passes without a pass.
const denied = () => new Response(null, { status: 401, headers: { "WWW-Authenticate": 'Bearer realm="portal"', "Cache-Control": "no-store", "X-Robots-Tag": "noindex" } });

// null: the request may proceed. Otherwise the Response to return (the 401, or the redirect that sets the cookie).
export async function portalPass(request, env, { fetch: fetcher = globalThis.fetch } = {}) {
  if (env?.ENVIRONMENT === "production") return null;
  const aud = env?.PORTAL_AUD, issuer = env?.PORTAL_ISSUER, url = env?.PORTAL_JWKS_URL;
  if (!aud || !issuer || !url) return denied(); // fail closed: a misconfigured staging Worker is never open
  const opts = { aud, issuer, jwks: keyring(url, fetcher) };
  const bearer = (request.headers.get("authorization") ?? "").match(/^Bearer\s+(\S+)$/i)?.[1];
  if (bearer && (await verifyPass(bearer, opts))) return null;
  // a valid query pass always becomes the cookie and leaves the URL, even when an older cookie is still valid
  const u = new URL(request.url), q = u.searchParams.get(QUERY);
  const claims = q && (await verifyPass(q, opts));
  if (claims) {
    u.searchParams.delete(QUERY);
    const age = Math.max(1, Math.floor(claims.exp - Date.now() / 1000));
    return new Response(null, { status: 302, headers: {
      Location: u.toString(), "Cache-Control": "no-store", "X-Robots-Tag": "noindex",
      "Set-Cookie": `${COOKIE}=${q}; HttpOnly; Secure; SameSite=None; Path=/; Max-Age=${age}`,
    } });
  }
  const cookie = (request.headers.get("cookie") ?? "").split(";").map((c) => c.trim()).find((c) => c.startsWith(`${COOKIE}=`))?.slice(COOKIE.length + 1);
  if (cookie && (await verifyPass(cookie, opts))) return null;
  return denied();
}
