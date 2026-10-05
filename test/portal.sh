#!/usr/bin/env bash
# The portal pass: staging and preview Workers refuse requests without a short-lived Ed25519 pass the org's portal
# signs. Through the applied scripts/agent/portal-pass.mjs of a fixture repository, against a local JWKS server.
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD OV=$PWD/examples/overlay.json
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
R=$T/site; git init -q -b main "$R"
node "$ENGINE/bin/repo-standards.mjs" apply --overlay "$OV" --version 0.1.0 --target "$R" >/dev/null
[ -f "$R/scripts/agent/portal-pass.mjs" ] && grep -q '  scripts/agent/portal-pass.mjs$' "$R/standards.lock" || { fail portal-pass-verifies "not shipped or not locked"; done_cases; exit 1; }
cat > "$T/drive.mjs" <<'JS'
import { createServer } from "node:http";
const { portalPass } = await import(process.argv[2]);
const b64 = (b) => Buffer.from(b).toString("base64url");
const pair = async (kid) => {
  const k = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  return { kid, priv: k.privateKey, jwk: { ...(await crypto.subtle.exportKey("jwk", k.publicKey)), kid, use: "sig", alg: "EdDSA" } };
};
const k1 = await pair("k1"), k2 = await pair("k2"), stray = await pair("k1");
let served = [k1.jwk], hits = 0;
const srv = createServer((req, res) => { hits++; res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ keys: served })); });
await new Promise((r) => srv.listen(0, "127.0.0.1", r));
const local = `http://127.0.0.1:${srv.address().port}/jwks`;
// The Worker fetches its configured https JWKS URL; the stand-in fetch carries it to the local server.
const fetcher = (u, init) => fetch(local, init);
const now = Math.floor(Date.now() / 1000), ISS = "https://portal.example.com";
const sign = async (k, claims, header = {}) => {
  const h = b64(JSON.stringify({ alg: "EdDSA", typ: "JWT", kid: k.kid, ...header })), p = b64(JSON.stringify(claims));
  return `${h}.${p}.${b64(await crypto.subtle.sign({ name: "Ed25519" }, k.priv, new TextEncoder().encode(`${h}.${p}`)))}`;
};
const good = { iss: ISS, aud: "site-staging", sub: "user:42", iat: now, exp: now + 600 };
let n = 0;
const env = () => ({ ENVIRONMENT: "staging", PORTAL_AUD: "site-staging", PORTAL_ISSUER: ISS, PORTAL_JWKS_URL: `https://portal.example.com/jwks/${++n}` });
const call = (e, { headers = {}, query = "" } = {}) => portalPass(new Request(`https://site-staging.example.com/a/b?x=1${query}`, { headers }), e, { fetch: fetcher });
const out = {}, why = (id, m) => (out[id] ??= []).push(m);
// a refusal says noindex too, so gate's preview noindex probe passes on a gated Worker
const is401 = async (r, id, what) => { if (!(r && r.status === 401 && /Bearer realm="portal"/.test(r.headers.get("www-authenticate") ?? "") && r.headers.get("x-robots-tag") === "noindex" && (await r.text()) === "")) why(id, `${what}: ${r?.status}`); };

// verifies: Bearer, cookie, query (302 that sets the cookie and drops the parameter), aud as a list, agent and test subjects
const pass = await sign(k1, good);
if ((await call(env(), { headers: { authorization: `Bearer ${pass}` } })) !== null) why("v", "bearer");
if ((await call(env(), { headers: { cookie: `a=b; __Host-portal_pass=${pass}` } })) !== null) why("v", "cookie");
const r = await call(env(), { query: `&portal_pass=${pass}` });
const loc = r?.headers.get("location"), sc = r?.headers.get("set-cookie") ?? "";
if (!(r?.status === 302 && loc === "https://site-staging.example.com/a/b?x=1" && sc.startsWith(`__Host-portal_pass=${pass};`) && /HttpOnly/.test(sc) && /Secure/.test(sc) && /SameSite=None/.test(sc) && /Path=\//.test(sc) && /Max-Age=(59\d|600)\b/.test(sc))) why("v", `query: ${r?.status} ${loc} ${sc}`);
// a fresh query pass replaces a still-valid cookie and leaves the URL
const fresh = await sign(k1, { ...good, sub: "user:43" }), rc = await call(env(), { headers: { cookie: `__Host-portal_pass=${pass}` }, query: `&portal_pass=${fresh}` });
if (!(rc?.status === 302 && (rc.headers.get("set-cookie") ?? "").startsWith(`__Host-portal_pass=${fresh};`))) why("v", `query beside a cookie: ${rc?.status}`);
for (const [what, c] of [["aud list", { ...good, aud: ["other", "site-staging"] }], ["agent", { ...good, sub: "agent:launcher" }], ["test", { ...good, sub: "test:o/r#7" }]])
  if ((await call(env(), { headers: { authorization: `Bearer ${await sign(k1, c)}` } })) !== null) why("v", what);
// rotation: an unknown kid refetches the JWKS exactly once; a second unknown kid within the minute does not refetch
const e = env(); served = [k1.jwk];
await call(e, { headers: { authorization: `Bearer ${pass}` } }); const before = hits;
served = [k1.jwk, k2.jwk];
if ((await call(e, { headers: { authorization: `Bearer ${await sign(k2, good)}` } })) !== null) why("v", "rotated key");
if (hits !== before + 1) why("v", `rotation fetched ${hits - before} times`);
await is401(await call(e, { headers: { authorization: `Bearer ${await sign({ ...k2, kid: "k3" }, good)}` } }), "v", "unknown kid");
if (hits !== before + 1) why("v", `a second unknown kid refetched (${hits - before})`);
if ((await call(e, { headers: { authorization: `Bearer ${pass}` } })) !== null) why("v", "cached key after rotation");
// concurrent unknown kids share one reserved refetch
const e2 = env(); await call(e2, { headers: { authorization: `Bearer ${pass}` } }); const h1 = hits;
await Promise.all([1, 2, 3, 4, 5].map(async (i) => call(e2, { headers: { authorization: `Bearer ${await sign({ ...k2, kid: `x${i}` }, good)}` } })));
if (hits !== h1 + 1) why("v", `concurrent unknown kids fetched ${hits - h1} times`);

// fails closed: every bad pass, and a staging Worker missing its portal settings, is an empty 401
const bad = [
  ["none", {}],
  ["expired", { authorization: `Bearer ${await sign(k1, { ...good, iat: now - 900, exp: now - 61 })}` }],
  ["too long-lived", { authorization: `Bearer ${await sign(k1, { ...good, exp: now + 901 })}` }],
  ["issued in the future", { authorization: `Bearer ${await sign(k1, { ...good, iat: now + 300, exp: now + 600 })}` }],
  ["wrong aud", { authorization: `Bearer ${await sign(k1, { ...good, aud: "site" })}` }],
  ["wrong iss", { authorization: `Bearer ${await sign(k1, { ...good, iss: "https://evil.example.com" })}` }],
  ["bad sub", { authorization: `Bearer ${await sign(k1, { ...good, sub: "42" })}` }],
  ["alg HS256", { authorization: `Bearer ${await sign(k1, good, { alg: "HS256" })}` }],
  ["alg none", { authorization: `Bearer ${b64(JSON.stringify({ alg: "none", kid: "k1" }))}.${b64(JSON.stringify(good))}.` }],
  ["unknown kid", { authorization: `Bearer ${await sign({ ...k1, kid: "nope" }, good)}` }],
  ["other key, same kid", { authorization: `Bearer ${await sign(stray, good)}` }],
  ["tampered", { authorization: `Bearer ${pass.replace(/\.([^.]+)\./, (m, p) => `.${b64(JSON.stringify({ ...good, sub: "user:1" }))}.`)}` }],
  ["garbage cookie", { cookie: "__Host-portal_pass=x.y.z" }],
];
served = [k1.jwk];
for (const [what, headers] of bad) await is401(await call(env(), { headers }), "c", what);
await is401(await call(env(), { query: `&portal_pass=${await sign(k1, { ...good, aud: "site" })}` }), "c", "bad query pass");
for (const k of ["PORTAL_AUD", "PORTAL_ISSUER", "PORTAL_JWKS_URL"]) { const x = env(); delete x[k]; await is401(await call(x, { headers: { authorization: `Bearer ${pass}` } }), "c", `missing ${k}`); }
await is401(await call({}, {}), "c", "no env");

// production never checks, even without settings or a pass
if ((await call({ ENVIRONMENT: "production" })) !== null) why("p", "production checked");
const h0 = hits; await call({ ENVIRONMENT: "production", PORTAL_AUD: "x", PORTAL_ISSUER: ISS, PORTAL_JWKS_URL: "https://portal.example.com/p" });
if (hits !== h0) why("p", "production fetched the JWKS");
if ((await call({ ENVIRONMENT: "Production", PORTAL_AUD: "x", PORTAL_ISSUER: ISS, PORTAL_JWKS_URL: "https://portal.example.com/q" }))?.status !== 401) why("p", "a near-miss ENVIRONMENT opened the gate");
srv.close();
for (const [k, id] of [["v", "portal-pass-verifies"], ["c", "portal-pass-fail-closed"], ["p", "portal-pass-production-open"]])
  console.log(out[k] ? `FAIL ${id}\n  ${out[k].join("; ")}` : `ok ${id}`);
JS
o=$(node "$T/drive.mjs" "$R/scripts/agent/portal-pass.mjs" 2>&1); echo "$o"
case "$o" in *FAIL*|"") exit 1 ;; esac
