/**
 * GET /api/export?key=<ADMIN_KEY>          -> CSV of the whole waitlist
 * GET /api/export?key=<ADMIN_KEY>&format=json
 * GET /api/count                            (see api/count.js) -> public tally
 *
 * This is the allowlist. Every wallet address anyone submitted is in here, so
 * it is behind a secret that is NOT the database URL and NOT anything the
 * front end knows. Set ADMIN_KEY in Vercel's environment settings to a long
 * random string.
 *
 *   curl -o allowlist.csv "https://your-domain/api/export?key=..."
 */

import { neon } from "@neondatabase/serverless";
import { csvCell } from "./_validate.js";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;

/* Constant-time-ish compare. Not a defence against a determined attacker on a
   serverless platform, but it costs nothing and avoids the trivially
   exploitable early-exit of ===. */
function keyMatches(given, expected) {
  if (typeof given !== "string" || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < given.length; i++) diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

export default async function handler(req, res) {
  const admin = process.env.ADMIN_KEY;
  if (!admin) {
    console.error("ADMIN_KEY is not set — refusing to expose the waitlist");
    return res.status(500).json({ error: "not_configured" });
  }
  if (!keyMatches(String(req.query.key || ""), admin)) {
    return res.status(401).json({ error: "unauthorized" });
  }
  if (!CONN) return res.status(500).json({ error: "not_configured" });

  try {
    const sql = neon(CONN);
    const rows = await sql`
      SELECT handle, constellation, pass, serial, wallet, quote_url,
             tweet_id, verified, submitted_at, updated_at
        FROM waitlist
       ORDER BY submitted_at ASC`;

    if (req.query.format === "json") {
      res.setHeader("Cache-Control", "no-store");
      return res.status(200).json({ count: rows.length, rows });
    }

    const cols = ["handle", "constellation", "pass", "serial", "wallet",
                  "quote_url", "tweet_id", "verified", "submitted_at", "updated_at"];
    const csv = [cols.join(","),
                 ...rows.map(r => cols.map(c => csvCell(r[c])).join(","))].join("\n");

    // utf-8 BOM so Excel does not mangle the file on open
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", 'attachment; filename="orion-waitlist.csv"');
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).send("﻿" + csv);
  } catch (err) {
    console.error("export failed", err);
    return res.status(500).json({ error: "read_failed" });
  }
}
