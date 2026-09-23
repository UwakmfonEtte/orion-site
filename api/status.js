/**
 * GET /api/status?handle=someone -> where that handle stands
 *
 *   { handle, state, pass, verified }
 *
 * state is one of:
 *   - "accepted" when the handle is on the selected list
 *   - "review" while the application is still pending judgement
 *   - "unaccepted" when it was not selected
 *   - "none" when there is no application on file
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

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;
const HANDLE_RE = /^[A-Za-z0-9_]{1,15}$/;
const APPROVED_ENV_KEYS = ["APPROVED_HANDLES", "SELECTED_HANDLES", "ALLOWED_HANDLES"];

function parseApprovedHandles() {
  const raw = APPROVED_ENV_KEYS
    .map((key) => process.env[key])
    .find((value) => typeof value === "string" && value.trim().length > 0);

  if (!raw) return new Set();

  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      return new Set(parsed.map((value) => String(value).trim().replace(/^@+/, "").toLowerCase()).filter(Boolean));
    }
  } catch {}

  return new Set(
    raw
      .split(/[\n,\r\t\s]+/)
      .map((value) => value.trim().replace(/^@+/, "").toLowerCase())
      .filter((value) => HANDLE_RE.test(value))
  );
}

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const handle = String(req.query.handle || "").trim().replace(/^@+/, "");
  if (!HANDLE_RE.test(handle)) {
    return res.status(400).json({ error: "invalid_handle" });
  }

  const approved = parseApprovedHandles();
  const isApproved = approved.has(handle.toLowerCase());

  if (!CONN) {
    if (isApproved) {
      return res.status(200).json({ handle, state: "accepted", pass: null, verified: false });
    }
    return res.status(200).json({ handle, state: "none", pass: null, verified: false });
  }

  try {
    const sql = neon(CONN);
    const [row] = await sql`
      SELECT handle, pass, verified FROM waitlist
       WHERE lower(handle) = ${handle.toLowerCase()} LIMIT 1`;

    res.setHeader("Cache-Control", "public, s-maxage=20, stale-while-revalidate=60");
    if (!row) {
      if (isApproved) {
        return res.status(200).json({ handle, state: "accepted", pass: null, verified: false });
      }
      return res.status(200).json({ handle, state: "none", pass: null, verified: false });
    }

    if (isApproved) {
      return res.status(200).json({
        handle: row.handle,
        state: "accepted",
        pass: row.pass,
        verified: Boolean(row.verified),
      });
    }

    return res.status(200).json({
      handle: row.handle,
      state: "review",
      pass: row.pass,
      verified: Boolean(row.verified),
    });
  } catch (err) {
    console.error("status lookup failed", err);
    return res.status(500).json({ error: "server_error" });
  }
}
