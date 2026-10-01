import { neon } from "@neondatabase/serverless";
import { createHash } from "node:crypto";
import { APPROVED_HANDLES } from "./_approved.js";
import { authorIs, containsCode, fetchPost } from "./_x.js";
import {
  checkEligibility,
  normHandle,
  pairCode,
  proofText,
  validHandle,
  VOUCHES_PER_WITNESS,
  VOUCHES_REQUIRED,
} from "./_vouch.js";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;
const MAX_BODY = 4096;
const RATE_MAX = 30;
const RATE_WINDOW = "1 hour";

let ready = false;
async function ensureSchema(sql) {
  if (ready) return;
  await sql`
    CREATE TABLE IF NOT EXISTS vouches (
      witness text NOT NULL,
      nominee text NOT NULL,
      proof_url text NOT NULL,
      tweet_id text NOT NULL,
      verified boolean NOT NULL DEFAULT false,
      created_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (witness, nominee)
    )`;
  await sql`ALTER TABLE vouches ADD COLUMN IF NOT EXISTS verified boolean NOT NULL DEFAULT true`;
  await sql`CREATE INDEX IF NOT EXISTS vouches_nominee_idx ON vouches (nominee)`;
  await sql`
    CREATE TABLE IF NOT EXISTS vouch_hits (
      ip_hash text NOT NULL,
      hit_at timestamptz NOT NULL DEFAULT now()
    )`;
  await sql`CREATE INDEX IF NOT EXISTS vouch_hits_idx ON vouch_hits (ip_hash, hit_at)`;
  await sql`
    CREATE TABLE IF NOT EXISTS vouch_slots (
      witness text NOT NULL,
      nominee text NOT NULL,
      sponsor_slot smallint NOT NULL CHECK (sponsor_slot BETWEEN 1 AND 3),
      nominee_slot smallint NOT NULL CHECK (nominee_slot BETWEEN 1 AND 3),
      PRIMARY KEY (witness, nominee),
      UNIQUE (witness, sponsor_slot),
      UNIQUE (nominee, nominee_slot)
    )`;
  await sql`
    INSERT INTO vouch_slots (witness, nominee, sponsor_slot, nominee_slot)
    SELECT witness, nominee, sponsor_position::smallint, nominee_position::smallint
      FROM (
        SELECT lower(witness) AS witness, lower(nominee) AS nominee,
               row_number() OVER (PARTITION BY lower(witness) ORDER BY created_at, lower(nominee)) AS sponsor_position,
               row_number() OVER (PARTITION BY lower(nominee) ORDER BY created_at, lower(witness)) AS nominee_position
          FROM vouches WHERE verified = true
      ) existing
     WHERE sponsor_position <= ${VOUCHES_PER_WITNESS}
       AND nominee_position <= ${VOUCHES_REQUIRED}
    ON CONFLICT DO NOTHING`;
  ready = true;
}

function hashIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  const ip = typeof forwarded === "string" && forwarded
    ? forwarded.split(",")[0].trim()
    : req.headers["x-real-ip"] || req.socket?.remoteAddress || "unknown";
  const salt = process.env.ADMIN_KEY || process.env.DATABASE_URL || "orion";
  return createHash("sha256").update(`${salt}|${ip}`).digest("hex").slice(0, 32);
}

function statusId(raw) {
  let url;
  try { url = new URL(String(raw)); } catch { return null; }
  if (!["https:", "http:"].includes(url.protocol)) return null;
  if (!["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.x.com", "mobile.twitter.com"].includes(url.hostname.toLowerCase())) return null;
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 3 || !["status", "statuses"].includes(parts[1])) return null;
  return /^\d{5,25}$/.test(parts[2]) ? parts[2] : null;
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "method_not_allowed" });
  }
  if (!CONN) return res.status(500).json({ error: "not_configured" });
  if (process.env.VOUCHING_OPEN === "0") return res.status(403).json({ error: "not_configured" });

  let body = req.body;
  if (typeof body === "string") {
    if (body.length > MAX_BODY) return res.status(413).json({ error: "too_large" });
    try { body = JSON.parse(body); } catch { return res.status(400).json({ error: "bad_json" }); }
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return res.status(400).json({ error: "bad_json" });
  }

  const witness = normHandle(body.witness);
  const nominee = normHandle(body.nominee);
  if (!validHandle(witness) || !validHandle(nominee)) {
    return res.status(400).json({ error: "invalid_handle" });
  }
  if (body.action && !["code", "confirm"].includes(body.action)) {
    return res.status(400).json({ error: "invalid_action" });
  }
  const action = body.action === "confirm" ? "confirm" : "code";

  try {
    const sql = neon(CONN);
    await ensureSchema(sql);
    const ipHash = hashIp(req);
    const [{ n: hits }] = await sql`
      SELECT count(*)::int AS n FROM vouch_hits
       WHERE ip_hash = ${ipHash} AND hit_at > now() - ${RATE_WINDOW}::interval`;
    if (hits >= RATE_MAX) {
      res.setHeader("Retry-After", "3600");
      return res.status(429).json({ error: "rate_limited" });
    }
    await sql`INSERT INTO vouch_hits (ip_hash) VALUES (${ipHash})`;

    const [{ sponsoredCount }] = await sql`
      SELECT count(*)::int AS "sponsoredCount"
        FROM vouch_slots WHERE witness = ${witness}`;
    const [{ verifiedVouches }] = await sql`
      SELECT count(DISTINCT s.witness)::int AS "verifiedVouches"
        FROM vouch_slots s
        JOIN vouches v ON lower(v.witness) = s.witness AND lower(v.nominee) = s.nominee
       WHERE s.nominee = ${witness} AND v.verified = true`;
    const [{ nomineeVouches }] = await sql`
      SELECT count(DISTINCT s.witness)::int AS "nomineeVouches"
        FROM vouch_slots s
        JOIN vouches v ON lower(v.witness) = s.witness AND lower(v.nominee) = s.nominee
       WHERE s.nominee = ${nominee} AND v.verified = true`;
    const approved = APPROVED_HANDLES.has(witness);
    const earnedVouching = verifiedVouches >= VOUCHES_REQUIRED;
    const error = checkEligibility({
      witness,
      nominee,
      approved,
      earnedVouching,
      sponsoredCount,
      nomineeHasPass: APPROVED_HANDLES.has(nominee) || nomineeVouches >= VOUCHES_REQUIRED,
    });
    if (error) return res.status(400).json({ error });

    const [existing] = await sql`
      SELECT nominee FROM vouches
       WHERE lower(witness) = ${witness} AND lower(nominee) = ${nominee} LIMIT 1`;
    if (existing) return res.status(400).json({ error: "already_vouched" });

    const code = pairCode(witness, nominee);
    if (action === "code") {
      res.setHeader("Cache-Control", "no-store");
      return res.status(200).json({
        ok: true,
        code,
        text: proofText(witness, nominee, code),
        remaining: VOUCHES_PER_WITNESS - sponsoredCount,
        required: VOUCHES_REQUIRED,
      });
    }

    const tweetId = statusId(body.proofUrl);
    if (!tweetId) return res.status(400).json({ error: "proof_not_found" });
    const post = await fetchPost(String(body.proofUrl));
    if (!post.ok) {
      const status = post.reason === "rate_limited" ? 429 : 400;
      return res.status(status).json({ error: "proof_not_found", reason: post.reason });
    }
    if (!authorIs(post.author, witness)) return res.status(400).json({ error: "proof_not_yours" });
    if (!containsCode(post.text, code)) return res.status(400).json({ error: "proof_missing_code" });

    const [{ latestNomineeVouches }] = await sql`
      SELECT count(DISTINCT s.witness)::int AS "latestNomineeVouches"
        FROM vouch_slots s
        JOIN vouches v ON lower(v.witness) = s.witness AND lower(v.nominee) = s.nominee
       WHERE s.nominee = ${nominee} AND v.verified = true`;
    if (APPROVED_HANDLES.has(nominee) || latestNomineeVouches >= VOUCHES_REQUIRED) {
      return res.status(400).json({ error: "already_holds_pass" });
    }

    let saved;
    for (let attempt = 0; attempt < VOUCHES_PER_WITNESS; attempt++) {
      [saved] = await sql`
        WITH candidate AS (
          SELECT sponsor_slots.slot_number AS sponsor_slot,
                 nominee_slots.slot_number AS nominee_slot
            FROM generate_series(1, ${VOUCHES_PER_WITNESS}) AS sponsor_slots(slot_number)
           CROSS JOIN generate_series(1, ${VOUCHES_REQUIRED}) AS nominee_slots(slot_number)
           WHERE NOT EXISTS (
             SELECT 1 FROM vouch_slots
              WHERE witness = ${witness} AND sponsor_slot = sponsor_slots.slot_number
           )
             AND NOT EXISTS (
             SELECT 1 FROM vouch_slots
              WHERE nominee = ${nominee} AND nominee_slot = nominee_slots.slot_number
           )
           ORDER BY sponsor_slots.slot_number, nominee_slots.slot_number
           LIMIT 1
        ), reserved AS (
          INSERT INTO vouch_slots (witness, nominee, sponsor_slot, nominee_slot)
          SELECT ${witness}, ${nominee}, sponsor_slot::smallint, nominee_slot::smallint FROM candidate
          ON CONFLICT DO NOTHING
          RETURNING witness, nominee
        ), inserted AS (
          INSERT INTO vouches (witness, nominee, proof_url, tweet_id, verified)
          SELECT witness, nominee, ${`https://x.com/${witness}/status/${tweetId}`}, ${tweetId}, true
            FROM reserved
          ON CONFLICT (witness, nominee) DO NOTHING
          RETURNING witness
        )
        SELECT witness FROM inserted`;
      if (saved) break;
      const [existingAfterPost] = await sql`
        SELECT nominee FROM vouches
         WHERE lower(witness) = ${witness} AND lower(nominee) = ${nominee} LIMIT 1`;
      if (existingAfterPost) return res.status(400).json({ error: "already_vouched" });
      const [{ currentCount }] = await sql`
        SELECT count(*)::int AS "currentCount"
          FROM vouch_slots WHERE witness = ${witness}`;
      if (currentCount >= VOUCHES_PER_WITNESS) {
        return res.status(400).json({ error: "witness_exhausted" });
      }
    }
    if (!saved) {
      return res.status(409).json({ error: "try_again" });
    }
    const [{ vouches }] = await sql`
      SELECT count(DISTINCT s.witness)::int AS vouches
        FROM vouch_slots s
        JOIN vouches v ON lower(v.witness) = s.witness AND lower(v.nominee) = s.nominee
       WHERE s.nominee = ${nominee} AND v.verified = true`;

    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json({
      ok: true,
      nominee,
      vouches,
      required: VOUCHES_REQUIRED,
      held: vouches >= VOUCHES_REQUIRED,
      remaining: Math.max(0, VOUCHES_PER_WITNESS - sponsoredCount - 1),
    });
  } catch (err) {
    console.error("vouch failed", err);
    return res.status(500).json({ error: "server_error" });
  }
}