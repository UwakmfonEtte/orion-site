/**
 * GET /api/stats -> the public tallies the page shows
 *
 *   { supply, waitlist, verified, updated }
 *
 * Counts only. Same rule as /api/count, which this supersedes for the page:
 * a tally tells an onlooker how the drop is going, which is the point of
 * showing it, while naming anybody is a different decision entirely and is
 * not this endpoint's to make.
 */

import { neon } from "@neondatabase/serverless";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;
const SUPPLY = Number(process.env.SUPPLY) || 1555;

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const out = {
    supply: SUPPLY, waitlist: 0, verified: 0,
    updated: new Date().toISOString(),
  };
  if (!CONN) return finish(res, out);

  try {
    const sql = neon(CONN);
    const [w] = await sql`
      SELECT count(*)::int AS total,
             count(*) FILTER (WHERE verified)::int AS verified
        FROM waitlist`;
    out.waitlist = w.total;
    out.verified = w.verified;
    return finish(res, out);
  } catch (err) {
    /* Table not created yet is the normal pre-launch state, not an error. */
    return finish(res, out);
  }
}

function finish(res, out) {
  res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=120");
  return res.status(200).json(out);
}
