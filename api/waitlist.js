/**
 * POST /api/waitlist -> { ok, handle, pass, constellation, count }
 *
 * The one endpoint that has to be right. Everything else on the site is
 * presentation; a lost or forged row here is an allowlist spot that nobody
 * notices until mint day.
 *
 * All field checking and all derivation live in _validate.js so they can be
 * attacked directly by test/security.test.mjs rather than only in production.
 *
 * Storage is Neon Postgres via the Vercel Marketplace. (Vercel's own KV and
 * Postgres were sunset; KV moved to Upstash Redis in Dec 2024.)
 *
 *   Vercel -> Storage -> Create Database -> Neon, connect to this project.
 *   DATABASE_URL is injected. The table is created on first write.
 */

import { neon } from "@neondatabase/serverless";
import { createHash } from "node:crypto";
import { validateSubmission } from "./_validate.js";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;

/** Submissions allowed from one address per hour. Generous for a household or
 *  an office behind one NAT, tight enough that scripting thousands of fake
 *  handles is not worth the trouble. */
const RATE_MAX = 6;
const RATE_WINDOW = "1 hour";

/** Bodies larger than this are refused before parsing. */
const MAX_BODY = 4096;

let ready = false;

async function ensureSchema(sql) {
  if (ready) return;
  await sql`
    CREATE TABLE IF NOT EXISTS waitlist (
      handle        text PRIMARY KEY,
      constellation text        NOT NULL,
      pass          integer     NOT NULL,
      serial        text        NOT NULL,
      quote_url     text        NOT NULL,
      tweet_id      text        NOT NULL,
      wallet        text        NOT NULL,
      verified      boolean     NOT NULL DEFAULT false,
      submitted_at  timestamptz NOT NULL DEFAULT now(),
      updated_at    timestamptz NOT NULL DEFAULT now()
    )`;
  await sql`CREATE INDEX IF NOT EXISTS waitlist_submitted_idx ON waitlist (submitted_at)`;
  /* Rate limiting keyed on a salted hash of the address rather than the
     address itself: enough to count against, not a log of who visited. */
  await sql`
    CREATE TABLE IF NOT EXISTS waitlist_hits (
      ip_hash text        NOT NULL,
      hit_at  timestamptz NOT NULL DEFAULT now()
    )`;
  await sql`CREATE INDEX IF NOT EXISTS waitlist_hits_idx ON waitlist_hits (ip_hash, hit_at)`;
  ready = true;
}

function clientIp(req) {
  const fwd = req.headers["x-forwarded-for"];
  if (typeof fwd === "string" && fwd) return fwd.split(",")[0].trim();
  return req.headers["x-real-ip"] || req.socket?.remoteAddress || "unknown";
}

function hashIp(ip) {
  // Salted with a value the client never sees, so the stored hash is not a
  // rainbow-table lookup of the v4 address space.
  const salt = process.env.ADMIN_KEY || process.env.DATABASE_URL || "orion";
  return createHash("sha256").update(salt + "|" + ip).digest("hex").slice(0, 32);
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "method_not_allowed" });
  }
  if (!CONN) {
    console.error("DATABASE_URL is not set — connect a Neon database in Vercel");
    return res.status(500).json({ error: "not_configured" });
  }

  let body = req.body;
  if (typeof body === "string") {
    if (body.length > MAX_BODY) return res.status(413).json({ error: "too_large" });
    try { body = JSON.parse(body); } catch { return res.status(400).json({ error: "bad_json" }); }
  }

  // Every field is either re-validated or recomputed here. Nothing the client
  // asserted about its pass number, serial or constellation is taken on trust.
  const v = validateSubmission(body);
  if (!v.ok) return res.status(400).json({ error: v.error });
  const r = v.record;

  try {
    const sql = neon(CONN);
    await ensureSchema(sql);

    const ipHash = hashIp(clientIp(req));
    const [{ n }] = await sql`
      SELECT count(*)::int AS n FROM waitlist_hits
       WHERE ip_hash = ${ipHash}
         AND hit_at > now() - ${RATE_WINDOW}::interval`;
    if (n >= RATE_MAX) {
      res.setHeader("Retry-After", "3600");
      return res.status(429).json({ error: "rate_limited" });
    }
    await sql`INSERT INTO waitlist_hits (ip_hash) VALUES (${ipHash})`;

    /* Upsert on handle so a corrected wallet updates rather than duplicating.
       submitted_at is deliberately not touched: fixing a typo must not cost
       queue position. verified resets, because the quote changed. */
    await sql`
      INSERT INTO waitlist (handle, constellation, pass, serial, quote_url, tweet_id, wallet)
      VALUES (${r.handle}, ${r.constellation}, ${r.pass}, ${r.serial},
              ${r.quoteUrl}, ${r.tweetId}, ${r.wallet})
      ON CONFLICT (handle) DO UPDATE SET
        wallet     = EXCLUDED.wallet,
        quote_url  = EXCLUDED.quote_url,
        tweet_id   = EXCLUDED.tweet_id,
        verified   = false,
        updated_at = now()`;

    const [{ count }] = await sql`SELECT count(*)::int AS count FROM waitlist`;

    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json({
      ok: true, handle: r.handle, pass: r.pass,
      constellation: r.constellation, count
    });
  } catch (err) {
    // Logged server-side; the client is told nothing about the internals.
    console.error("waitlist write failed", err);
    return res.status(500).json({ error: "write_failed" });
  }
}
