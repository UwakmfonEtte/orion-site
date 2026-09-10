/**
 * GET /api/count -> { count }
 *
 * Public, and deliberately nothing else: the footer wants a tally, and a tally
 * is the only thing anyone unauthenticated should be able to learn about the
 * waitlist. Handles and wallets live behind /api/export.
 */

import { neon } from "@neondatabase/serverless";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;

export default async function handler(req, res) {
  if (!CONN) return res.status(200).json({ count: null });
  try {
    const sql = neon(CONN);
    const [{ count }] = await sql`SELECT count(*)::int AS count FROM waitlist`;
    res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=120");
    return res.status(200).json({ count });
  } catch {
    // Table not created yet is the normal pre-launch state, not an error.
    return res.status(200).json({ count: 0 });
  }
}
