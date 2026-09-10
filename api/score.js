/**
 * GET /api/score?handle=<x_handle>  ->  { handle, score }
 *
 * Server-side proxy for the Sorsa Score lookup.
 *
 * The key must never reach the browser. Anything shipped to the client is
 * public, and a leaked key is someone else's bill on your account. It stays
 * in the environment; the browser only ever talks to this endpoint.
 *
 * Deploy: push this folder to Vercel, set SORSA_API_KEY in project settings,
 * then set SCORE_API = "/api/score" at the top of sky.html.
 *
 * ── Endpoint shape, confirmed against the live API ───────────────────
 *   GET https://api.sorsa.io/v3/score?username=<handle>
 *   Header: ApiKey: <key>
 *   200 -> {"score": 5116.587}          float, not an integer
 *   400 -> {"message":"user_link, username or user_id required"}
 *   404 -> {"message":"User not found."}
 *
 * Observed range: the largest crypto accounts land around 3,900–5,120
 * (VitalikButerin 5117, cobie 4285, punk6529 4282, beeple 4136,
 * zachxbt 4130, farokh 3904). Sorsa's score index is crypto-scoped, so a
 * 404 usually means "no crypto footprint", not "no such account".
 * ─────────────────────────────────────────────────────────────────────
 */

const SORSA_BASE = "https://api.sorsa.io/v3";

// Warm-instance cache. Serverless containers are recycled, so this only
// helps while one stays hot — which is exactly the case that matters when a
// launch post sends a few hundred people at the page at once.
const cache = new Map();
const TTL_MS = 5 * 60 * 1000;

export default async function handler(req, res) {
  const handle = (req.query.handle || "").toString().trim().replace(/^@+/, "");

  if (!/^[A-Za-z0-9_]{1,15}$/.test(handle)) {
    return res.status(400).json({ error: "invalid_handle" });
  }
  if (!process.env.SORSA_API_KEY) {
    console.error("SORSA_API_KEY is not set");
    return res.status(500).json({ error: "not_configured" });
  }

  const key = handle.toLowerCase();
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) {
    res.setHeader("X-Cache", "HIT");
    return res.status(200).json({ handle, score: hit.score });
  }

  let r;
  try {
    r = await fetch(`${SORSA_BASE}/score?username=${encodeURIComponent(handle)}`, {
      headers: { ApiKey: process.env.SORSA_API_KEY, Accept: "application/json" }
    });
  } catch (err) {
    console.error("sorsa unreachable", err);
    return res.status(502).json({ error: "upstream_unreachable" });
  }

  if (r.status === 404) return res.status(404).json({ error: "no_account" });
  if (r.status === 429) return res.status(429).json({ error: "rate_limited" });
  if (r.status === 401 || r.status === 403) {
    console.error("sorsa rejected the API key");
    return res.status(500).json({ error: "not_configured" });
  }
  if (!r.ok) {
    console.error("sorsa returned", r.status);
    return res.status(502).json({ error: "unexpected_response" });
  }

  const body = await r.json().catch(() => null);
  const score = body && typeof body.score === "number" ? body.score : null;
  if (score === null) {
    console.error("no score field in", JSON.stringify(body));
    return res.status(502).json({ error: "unexpected_response" });
  }

  cache.set(key, { score, at: Date.now() });
  res.setHeader("Cache-Control", "public, s-maxage=300");
  res.setHeader("X-Cache", "MISS");
  return res.status(200).json({ handle, score });
}
