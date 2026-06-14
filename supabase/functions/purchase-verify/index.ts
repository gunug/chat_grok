// Verifies a Google Play in-app purchase server-side, then grants credits via
// app_top_up (idempotent by purchase token). The app calls this after a
// successful purchase with { productId, purchaseToken }.
//
// Secrets: GOOGLE_PLAY_SA_B64 = base64 of a service account JSON (the shared
// android-ai-apis publisher SA) that can view this app's purchases in Play.
// SUPABASE_* are auto-injected. (Shared platform — see PLATFORM_CREDITS_GUIDE.md)

import { createClient } from "jsr:@supabase/supabase-js@2";

const SERVICE_KEY = "chat_grok";
const PACKAGE = "com.onethelab.simplechatbot";

// productId -> price in KRW. app_top_up turns KRW into credits via krw_per_credit
// (default 1 → 5000원 = 5000 크레딧). Add new packs here.
const CATALOG: Record<string, number> = {
  "credit_5000": 5000,
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "content-type": "application/json" },
  });
}

// ── Google OAuth (service account → access token) via Web Crypto ─────────────
function b64urlBytes(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlStr(str: string): string {
  return b64urlBytes(new TextEncoder().encode(str));
}
function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function googleAccessToken(
  sa: { client_email: string; private_key: string },
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64urlStr(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64urlStr(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  ));
  const jwt = `${unsigned}.${b64urlBytes(sig)}`;
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const j = await r.json();
  if (!j.access_token) {
    throw new Error("token exchange failed: " + JSON.stringify(j).slice(0, 200));
  }
  return j.access_token as string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const saB64 = Deno.env.get("GOOGLE_PLAY_SA_B64");
  if (!url || !anon || !serviceRole) {
    return json({ error: "server misconfigured" }, 500);
  }
  if (!saB64) {
    return json({ error: "server misconfigured: no GOOGLE_PLAY_SA_B64" }, 500);
  }

  // Identify the buyer from their JWT.
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const productId = String(body?.productId ?? "");
  const purchaseToken = String(body?.purchaseToken ?? "");
  const krw = CATALOG[productId];
  if (!krw) return json({ error: "unknown_product" }, 400);
  if (!purchaseToken) return json({ error: "missing_token" }, 400);

  // Verify the purchase with Google Play.
  let accessToken: string;
  try {
    accessToken = await googleAccessToken(JSON.parse(atob(saB64)));
  } catch (e) {
    return json(
      { error: "google_auth_failed", detail: String(e).slice(0, 200) },
      500,
    );
  }
  const vurl =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE}/purchases/products/${productId}/tokens/${
      encodeURIComponent(purchaseToken)
    }`;
  const vres = await fetch(vurl, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!vres.ok) {
    const detail = (await vres.text()).slice(0, 300);
    return json({ error: "verify_failed", status: vres.status, detail }, 502);
  }
  const purchase = await vres.json();
  // purchaseState: 0 = Purchased, 1 = Cancelled, 2 = Pending
  if (purchase.purchaseState !== 0) {
    return json({ error: "not_purchased", state: purchase.purchaseState }, 402);
  }

  // Grant credits (idempotent: app_top_up no-ops if the token was already used).
  const admin = createClient(url, serviceRole);
  const { data: balance, error } = await admin.rpc("app_top_up", {
    p_user: user.id,
    p_service: SERVICE_KEY,
    p_store: "play",
    p_token: purchaseToken,
    p_krw_paid: krw,
  });
  if (error) return json({ error: "grant_failed", detail: error.message }, 500);

  return json({ ok: true, productId, krw, balanceCredits: balance });
});
