/**
 * GET /api/collab-export?key=<ADMIN_KEY>            -> CSV of every request
 * GET /api/collab-export?key=...&format=json        -> the same as JSON
 * GET /api/collab-export?key=...&img=12&which=rep   -> one proof image
 *
 * The CSV carries every field except the image data, which would make it
 * unopenable - a single base64 screenshot is longer than a spreadsheet cell
 * can hold. Instead each row gets a column of ready-made URLs pointing back
 * at this same endpoint, so a reviewer clicks straight from the sheet to
 * the proof.
 *
 * Behind ADMIN_KEY, the same one that guards the waitlist export. This
 * returns names, contacts and screenshots people sent in confidence.
 */

import { neon } from "@neondatabase/serverless";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;
const IMAGES = { size: "size_img", rep: "rep_img", interest: "interest_img" };

function keyMatches(given, expected) {
  if (typeof given !== "string" || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < given.length; i++) diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

function csvCell(v) {
  if (v === null || v === undefined) return "";
  const s = String(v);
  // A leading =, +, - or @ makes Excel treat the cell as a formula, so a
  // community name starting with one becomes executable on open.
  const safe = /^[=+\-@]/.test(s) ? "'" + s : s;
  return /[",\n\r]/.test(safe) ? '"' + safe.replace(/"/g, '""') + '"' : safe;
}

export default async function handler(req, res) {
  const admin = process.env.ADMIN_KEY;
  if (!admin) return res.status(500).json({ error: "not_configured" });
  if (!keyMatches(String(req.query.key || ""), admin)) {
    return res.status(401).json({ error: "unauthorized" });
  }
  if (!CONN) return res.status(500).json({ error: "not_configured" });

  const sql = neon(CONN);

  // ---- one image, streamed as a real file rather than a data URL --------
  if (req.query.img) {
    const col = IMAGES[String(req.query.which || "")];
    const id = Number(req.query.img);
    if (!col || !Number.isInteger(id)) return res.status(400).json({ error: "bad_request" });
    try {
      const rows = await sql(`SELECT ${col} AS img FROM collab WHERE id = $1`, [id]);
      const data = rows[0]?.img;
      if (!data) return res.status(404).json({ error: "no_image" });
      const m = /^data:(image\/(?:png|jpeg|webp));base64,(.+)$/.exec(data);
      if (!m) return res.status(404).json({ error: "no_image" });
      res.setHeader("Content-Type", m[1]);
      res.setHeader("Content-Disposition",
        `inline; filename="collab-${id}-${req.query.which}.${m[1].split("/")[1]}"`);
      res.setHeader("Cache-Control", "private, no-store");
      return res.status(200).send(Buffer.from(m[2], "base64"));
    } catch (err) {
      console.error("collab image failed", err);
      return res.status(500).json({ error: "server_error" });
    }
  }

  // ---- the list --------------------------------------------------------
  try {
    const rows = await sql`
      SELECT id, community, rep_name, rep_contact, size_claim, size_link,
             rep_link, interest_link, collab_post, spots, reviewed, submitted_at,
             (size_img IS NOT NULL)     AS has_size_img,
             (rep_img IS NOT NULL)      AS has_rep_img,
             (interest_img IS NOT NULL) AS has_interest_img
        FROM collab
       ORDER BY submitted_at ASC`;

    const proto = (req.headers["x-forwarded-proto"] || "https").split(",")[0];
    const host = req.headers.host || "";
    const imgUrl = (id, which) =>
      `${proto}://${host}/api/collab-export?key=${encodeURIComponent(req.query.key)}&img=${id}&which=${which}`;

    const shaped = rows.map(r => ({
      ...r,
      size_img_url:     r.has_size_img     ? imgUrl(r.id, "size")     : "",
      rep_img_url:      r.has_rep_img      ? imgUrl(r.id, "rep")      : "",
      interest_img_url: r.has_interest_img ? imgUrl(r.id, "interest") : "",
    }));

    if (req.query.format === "json") {
      res.setHeader("Cache-Control", "no-store");
      return res.status(200).json({ count: shaped.length, rows: shaped });
    }

    const cols = ["id", "community", "rep_name", "rep_contact", "size_claim",
                  "size_link", "size_img_url", "rep_link", "rep_img_url",
                  "interest_link", "interest_img_url", "collab_post", "spots",
                  "reviewed", "submitted_at"];
    const csv = [cols.join(","),
                 ...shaped.map(r => cols.map(c => csvCell(r[c])).join(","))].join("\n");

    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", 'attachment; filename="orion-collab-requests.csv"');
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).send("﻿" + csv);   // BOM so Excel reads UTF-8
  } catch (err) {
    console.error("collab export failed", err);
    return res.status(500).json({ error: "server_error" });
  }
}
