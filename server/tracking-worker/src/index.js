// Ember Mail read-receipt Worker.
//   GET  /p/<id>.gif           → records an open, returns a 1×1 transparent GIF (public)
//   GET  /api/opens?keys=k1,k2 → { "<key>": [ { t, ua, city, country, org } ] }   (public: the key IS the credential)
//   GET  /api/health           → { ok: true }                                     (public)
//   GET  /api/opens?ids=a,b    → legacy lookup by pixel id                        (Bearer SECRET, old messages only)
// Per-message read keys: the app picks a random readKey and puts only id = hex(SHA-256(readKey))[0..32] in the
// pixel URL. Recipients see the id but can't derive the key, so only the sender's app can read the opens.
// No shared secret ships in the app.
//   POST /oauth/token          → Google code → tokens (adds the client secret)   (public, PKCE-protected)
//   POST /oauth/refresh        → Google refresh → access token                   (public, needs the refresh token)
// Google client: GOOGLE_CLIENT_ID (plain var in wrangler.toml) + GOOGLE_CLIENT_SECRET (wrangler secret).
// Storage: Workers KV namespace bound as OPENS. Each id keeps at most 50 opens for 90 days.

const GIF = Uint8Array.from(atob("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"), (c) => c.charCodeAt(0));
const ID_RE = /^[a-z0-9]{10,64}$/;

function pixel() {
  return new Response(GIF, {
    headers: {
      "Content-Type": "image/gif",
      "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
      "Pragma": "no-cache",
      "Expires": "0",
    },
  });
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

async function idForKey(key) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

const KEY_RE = /^[a-z0-9]{32}$/;

function authorized(request, env) {
  const header = request.headers.get("Authorization") || "";
  return env.SECRET && header === `Bearer ${env.SECRET}`;
}

async function recordOpen(id, request, env) {
  const key = `o:${id}`;
  const existing = (await env.OPENS.get(key, "json")) || [];
  const cf = request.cf || {};
  existing.push({
    t: Date.now(),
    ua: (request.headers.get("User-Agent") || "").slice(0, 300),
    city: cf.city || null,
    country: cf.country || null,
    org: cf.asOrganization || null,
  });
  await env.OPENS.put(key, JSON.stringify(existing.slice(-50)), { expirationTtl: 60 * 60 * 24 * 90 });
}

const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";

// Forwards a token request to Google with our client credentials attached. The secret never
// leaves the Worker. Only the two grant types the app needs are allowed.
async function googleToken(request, env, kind) {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) return json({ error: "worker_not_configured" }, 500);
  let input;
  try { input = await request.json(); } catch { return json({ error: "bad_request" }, 400); }
  const form = new URLSearchParams({ client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET });
  if (kind === "token") {
    const { code, code_verifier, redirect_uri } = input;
    if (!code || !code_verifier || !/^http:\/\/127\.0\.0\.1:\d{2,5}$/.test(redirect_uri || "")) {
      return json({ error: "bad_request" }, 400);
    }
    form.set("grant_type", "authorization_code");
    form.set("code", code);
    form.set("code_verifier", code_verifier);
    form.set("redirect_uri", redirect_uri);
  } else {
    if (!input.refresh_token) return json({ error: "bad_request" }, 400);
    form.set("grant_type", "refresh_token");
    form.set("refresh_token", input.refresh_token);
  }
  const res = await fetch(GOOGLE_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
  });
  return new Response(await res.text(), {
    status: res.status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Public tracking pixel
    const match = path.match(/^\/p\/([a-z0-9]+)(\.gif)?$/);
    if (match) {
      const id = match[1];
      if (ID_RE.test(id) && request.method === "GET") {
        ctx.waitUntil(recordOpen(id, request, env));
      }
      return pixel();
    }

    if (path === "/oauth/token") return googleToken(request, env, "token");
    if (path === "/oauth/refresh") return googleToken(request, env, "refresh");

    if (path.startsWith("/api/")) {
      if (path === "/api/health") return json({ ok: true });

      if (path === "/api/opens" && url.searchParams.has("keys")) {
        const keys = url.searchParams.get("keys").split(",").map((s) => s.trim()).filter((k) => KEY_RE.test(k)).slice(0, 100);
        const result = {};
        await Promise.all(
          keys.map(async (key) => {
            const opens = await env.OPENS.get(`o:${await idForKey(key)}`, "json");
            if (opens && opens.length) result[key] = opens;
          })
        );
        return json(result);
      }

      if (!authorized(request, env)) return json({ error: "unauthorized" }, 401);

      if (path === "/api/opens") {
        const ids = (url.searchParams.get("ids") || "")
          .split(",")
          .map((s) => s.trim())
          .filter((s) => ID_RE.test(s))
          .slice(0, 100);
        const result = {};
        await Promise.all(
          ids.map(async (id) => {
            const opens = await env.OPENS.get(`o:${id}`, "json");
            if (opens && opens.length) result[id] = opens;
          })
        );
        return json(result);
      }
    }

    return new Response("Not found", { status: 404 });
  },
};
