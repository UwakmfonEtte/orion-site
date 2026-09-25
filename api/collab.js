/**
 * POST /api/collab  -> store one collaboration request
 *
 * The proofs are the awkward part. A screenshot is the only thing that
 * actually shows a member count or a community vote, but files mean object
 * storage, a token, and a bill. So the page downscales each image to a long
 * edge of 1400 and re-encodes it as JPEG before it is ever sent - which
 * turns a 6MB phone screenshot into roughly 200KB - and it is stored as a
 * data URL in Postgres alongside the rest of the row.
 *
 * That keeps the whole feature on the database that already exists, with
 * nothing new to pay for, and it means an export is one query rather than a
 * join against a bucket. The cap below is the backstop: the client should
 * never send anything near it, and anything that does is refused rather
 * than quietly filling the database.
 */

import { neon } from "@neondatabase/serverless";
import { createHash } from "node:crypto";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;

const MAX_BODY  = 3_000_000;   // three images plus fields, with room to spare
const MAX_IMG   = 900_000;     // per image, base64 - the client sends ~200KB
const MAX_FIELD = 300;
const RATE_WINDOW = "1 hour";
const RATE_MAX = 5;            // a community applies once, not repeatedly

const LINK_HOSTS = /^(www\.|mobile\.)?(x\.com|twitter\.com|discord\.gg|discord\.com|t\.me|telegram\.me|telegram\.org)$/i;

let ready = false;
async function ensureSchema(sql) {
  if (ready) return;
  await sql`
    CREATE TABLE IF NOT EXISTS collab (
      id            bigserial PRIMARY KEY,
      community     text        NOT NULL,
      rep_name      text        NOT NULL,
      rep_contact   text        NOT NULL,
      size_claim    text        NOT NULL,
      size_link     text        NOT NULL,
      size_img      text,
      rep_link      text,
      rep_img       text,
      interest_link text        NOT NULL,
      interest_img  text,
      collab_post   boolean     NOT NULL,
      spots         integer     NOT NULL,
      reviewed      boolean     NOT NULL DEFAULT false,
      submitted_at  timestamptz NOT NULL DEFAULT now()
    )`;
  // The "prove your role" step was removed from the form - this column
  // predates that and existing deployments still have it NOT NULL.
  await sql`ALTER TABLE collab ALTER COLUMN rep_link DROP NOT NULL`;
  await sql`CREATE INDEX IF NOT EXISTS collab_submitted_idx ON collab (submitted_at)`;
  await sql`
    CREATE TABLE IF NOT EXISTS collab_hits (
      ip_hash text        NOT NULL,
      hit_at  timestamptz NOT NULL DEFAULT now()
    )`;
  await sql`CREATE INDEX IF NOT EXISTS collab_hits_idx ON collab_hits (ip_hash, hit_at)`;
  ready = true;
}

function clientIp(req) {
  const fwd = req.headers["x-forwarded-for"];
  if (typeof fwd === "string" && fwd) return fwd.split(",")[0].trim();
  return req.headers["x-real-ip"] || req.socket?.remoteAddress || "unknown";
}
function hashIp(ip) {
  const salt = process.env.ADMIN_KEY || process.env.DATABASE_URL || "orion";
  return createHash("sha256").update(salt + "|" + ip).digest("hex").slice(0, 32);
}

const text = (v, max = MAX_FIELD) =>
  typeof v === "string" ? v.trim().slice(0, max) : "";

/** Parsed, never pattern-matched, so "discord.gg.evil.test" cannot pass. */
function link(v) {
  const s = text(v, 500);
  if (!s) return null;
  let u;
  try { u = new URL(s); } catch { return null; }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  if (!LINK_HOSTS.test(u.hostname)) return null;
  return u.origin + u.pathname + (u.search || "");
}

/** Only real raster data URLs, and only ones small enough to have come
 *  through the downscaler. An SVG is excluded on purpose - it can carry
 *  script, and these get rendered back in an admin's browser. */
function image(v) {
  if (typeof v !== "string" || !v) return null;
  if (v.length > MAX_IMG) return "TOO_LARGE";
  if (!/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(v)) return null;
  return v;
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "method_not_allowed" });
  }
  if (!CONN) return res.status(500).json({ error: "not_configured" });

  let body = req.body;
  if (typeof body === "string") {
    if (body.length > MAX_BODY) return res.status(413).json({ error: "too_large" });
    try { body = JSON.parse(body); } catch { return res.status(400).json({ error: "bad_json" }); }
  }
  if (!body || typeof body !== "object") return res.status(400).json({ error: "bad_json" });

  const community   = text(body.community);
  const repName     = text(body.repName);
  const repContact  = text(body.repContact);
  const sizeClaim   = text(body.sizeClaim, 40);
  const spots       = Math.floor(Number(body.spots));
  const collabPost  = body.collabPost === true || body.collabPost === "yes";

  const sizeLink     = link(body.sizeLink);
  // No longer collected from the form - the person submitting has already
  // introduced themselves, and in practice it's a collab manager applying
  // on the community's behalf, so a separate "prove your role" link only
  // added friction. Kept nullable server-side for any request that still
  // sends one.
  const repLink      = body.repLink ? link(body.repLink) : null;
  const interestLink = link(body.interestLink);

  const sizeImg     = image(body.sizeImg);
  const repImg      = body.repImg ? image(body.repImg) : null;
  const interestImg = image(body.interestImg);

  if (!community || !repName || !repContact) return res.status(400).json({ error: "missing_fields" });
  if (!sizeClaim) return res.status(400).json({ error: "missing_size" });
  if (!sizeLink || !interestLink) return res.status(400).json({ error: "bad_link" });
  if (!Number.isFinite(spots) || spots < 1 || spots > 1555) return res.status(400).json({ error: "bad_spots" });
  if (sizeImg === "TOO_LARGE" || repImg === "TOO_LARGE" || interestImg === "TOO_LARGE") {
    return res.status(413).json({ error: "image_too_large" });
  }

  try {
    const sql = neon(CONN);
    await ensureSchema(sql);

    const ipHash = hashIp(clientIp(req));
    const [{ n }] = await sql`
      SELECT count(*)::int AS n FROM collab_hits
       WHERE ip_hash = ${ipHash} AND hit_at > now() - ${RATE_WINDOW}::interval`;
    if (n >= RATE_MAX) {
      res.setHeader("Retry-After", "3600");
      return res.status(429).json({ error: "rate_limited" });
    }
    await sql`INSERT INTO collab_hits (ip_hash) VALUES (${ipHash})`;

    const [row] = await sql`
      INSERT INTO collab (community, rep_name, rep_contact, size_claim, size_link,
                          size_img, rep_link, rep_img, interest_link, interest_img,
                          collab_post, spots)
      VALUES (${community}, ${repName}, ${repContact}, ${sizeClaim}, ${sizeLink},
              ${sizeImg}, ${repLink}, ${repImg}, ${interestLink}, ${interestImg},
              ${collabPost}, ${spots})
      RETURNING id`;

    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json({ ok: true, id: row.id, community });
  } catch (err) {
    console.error("collab write failed", err);
    return res.status(500).json({ error: "server_error" });
  }
}
