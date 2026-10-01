/**
 * GET /api/status?handle=someone -> where that handle stands
 *
 *   { handle, state, pass, verified }
 *
 * state is accepted for selected handles, held after three distinct verified
 * vouches, nominated while vouches are still accumulating, unaccepted for
 * rejected waitlist applications, or none when nothing is on file.
 *
 * WHAT THIS DELIBERATELY DOES NOT RETURN
 *
 * The wallet. Never. Handles are already public - everyone who joined
 * posted about it on X - so confirming a handle is on the list tells an
 * enquirer nothing they could not learn by reading the replies to the
 * whitelist post. A wallet address is a different matter entirely and
 * leaves only through /api/export, behind ADMIN_KEY.
 */

import { neon } from "@neondatabase/serverless";
import { APPROVED_HANDLES } from "./_approved.js";
import { countDistinctVerifiedVouchers, VOUCHES_REQUIRED } from "./_vouch.js";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;
const HANDLE_RE = /^[A-Za-z0-9_]{1,15}$/;

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const handle = String(req.query.handle || "").trim().replace(/^@+/, "");
  if (!HANDLE_RE.test(handle)) {
    return res.status(400).json({ error: "invalid_handle" });
  }

  const isApproved = APPROVED_HANDLES.has(handle.toLowerCase());

  if (!CONN) {
    if (isApproved) {
      return res.status(200).json({ handle, state: "accepted", pass: null, verified: false, vouches: 0, required: VOUCHES_REQUIRED, canVouch: true, remaining: 3 });
    }
    return res.status(200).json({ handle, state: "none", pass: null, verified: false, vouches: 0, required: VOUCHES_REQUIRED, canVouch: false, remaining: 0 });
  }

  try {
    const sql = neon(CONN);
    const [row] = await sql`
      SELECT handle, pass, verified FROM waitlist
       WHERE lower(handle) = ${handle.toLowerCase()} LIMIT 1`;

    let voucherRows = [];
    try {
      voucherRows = await sql`
        SELECT DISTINCT s.witness, v.verified
          FROM vouch_slots s
          JOIN vouches v ON lower(v.witness) = s.witness AND lower(v.nominee) = s.nominee
         WHERE s.nominee = ${handle.toLowerCase()} AND v.verified = true`;
    } catch { /* The vouch table is created on first use. */ }
    const vouches = countDistinctVerifiedVouchers(voucherRows);
    const isHeld = vouches >= VOUCHES_REQUIRED;
    let sponsoredCount = 0;
    try {
      const [{ count }] = await sql`
        SELECT count(*)::int AS count
          FROM vouch_slots WHERE witness = ${handle.toLowerCase()}`;
      sponsoredCount = count;
    } catch { /* The vouch table is created on first use. */ }
    const canVouch = isApproved || isHeld;
    const remaining = canVouch ? Math.max(0, 3 - sponsoredCount) : 0;

    res.setHeader("Cache-Control", "public, s-maxage=20, stale-while-revalidate=60");
    if (!row) {
      if (isApproved) {
        return res.status(200).json({ handle, state: "accepted", pass: null, verified: false, vouches, required: VOUCHES_REQUIRED, canVouch, remaining });
      }
      return res.status(200).json({
        handle,
        state: isHeld ? "held" : vouches ? "nominated" : "none",
        pass: null,
        verified: false,
        vouches,
        required: VOUCHES_REQUIRED,
        canVouch,
        remaining,
      });
    }

    if (isApproved) {
      return res.status(200).json({
        handle: row.handle,
        state: "accepted",
        pass: row.pass,
        verified: Boolean(row.verified),
        vouches,
        required: VOUCHES_REQUIRED,
        canVouch,
        remaining,
      });
    }

    return res.status(200).json({
      handle: row.handle,
      state: isHeld ? "held" : vouches ? "nominated" : "unaccepted",
      pass: row.pass,
      verified: Boolean(row.verified),
      vouches,
      required: VOUCHES_REQUIRED,
      canVouch,
      remaining,
    });
  } catch (err) {
    console.error("status lookup failed", err);
    return res.status(500).json({ error: "server_error" });
  }
}
