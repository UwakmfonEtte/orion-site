/**
 * GET /api/eth-price -> { usd, source, at }
 *
 * The page shows the treasury in dollars as well as ETH, which needs a
 * price. This endpoint exists so the browser never sees the Alchemy key.
 *
 * That is the whole point of it. An API key in front-end JavaScript is not
 * a secret - it is published, readable by anyone who opens view-source, and
 * billable to whoever put it there. Proxying costs one function call and
 * keeps the key in the environment where it belongs.
 *
 * Set ALCHEMY_API_KEY in Vercel. Without it the endpoint still answers,
 * using ETH_USD_FALLBACK (default 2700) and saying so in `source`, so the
 * page renders a sensible figure rather than a blank or a crash.
 */

const KEY = process.env.ALCHEMY_API_KEY;
const FALLBACK = Number(process.env.ETH_USD_FALLBACK) || 2700;

/* A serverless instance may be reused across requests, so a module-level
   cache spares the upstream most calls. The CDN header below does the
   heavier lifting; this only helps within one warm instance. */
let cache = { usd: 0, at: 0 };
const TTL_MS = 5 * 60 * 1000;

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const now = Date.now();
  if (cache.usd && now - cache.at < TTL_MS) {
    return send(res, cache.usd, "cache", cache.at);
  }

  if (!KEY) return send(res, FALLBACK, "fallback", now);

  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 6000);
    const r = await fetch(
      `https://api.g.alchemy.com/prices/v1/${KEY}/tokens/by-symbol?symbols=ETH`,
      { signal: ctl.signal, headers: { accept: "application/json" } }
    );
    clearTimeout(timer);
    if (!r.ok) throw new Error("upstream_" + r.status);

    const d = await r.json();
    const usd = Number(d?.data?.[0]?.prices?.[0]?.value);
    if (!Number.isFinite(usd) || usd <= 0) throw new Error("bad_shape");

    cache = { usd, at: now };
    return send(res, usd, "alchemy", now);
  } catch (err) {
    /* Never log the key or the full URL it sits in. A price lookup failing
       is a cosmetic problem, so the page gets the fallback and carries on. */
    console.error("eth price lookup failed:", err.message);
    return send(res, cache.usd || FALLBACK, cache.usd ? "stale" : "fallback", now);
  }
}

function send(res, usd, source, at) {
  // Cached at the edge: the treasury figure does not need to be to the
  // second, and this keeps the upstream call count near zero under load.
  res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=900");
  return res.status(200).json({ usd: Math.round(usd * 100) / 100, source, at });
}
