/**
 * POST /api/waitlist   -> { ok: true, pass, constellation }
 *
 * Persists one waitlist entry. This is the endpoint that has to be reliable:
 * everything else on the site is presentation, but a lost row here is a lost
 * allowlist spot that nobody finds out about until mint day.
 *
 * Storage is Neon Postgres, added through the Vercel Marketplace. (Vercel's own
 * KV and Postgres products were sunset — KV stores moved to Upstash Redis in
 * Dec 2024 — so the marketplace providers are the current path.)
 *
 * Setup:
 *   Vercel dashboard -> Storage -> Create Database -> Neon (Postgres)
 *   Connect it to this project. It injects DATABASE_URL automatically.
 *
 * The table is created on first write, so there is no migration step to forget.
 */

import { neon } from "@neondatabase/serverless";

const CONN = process.env.DATABASE_URL || process.env.POSTGRES_URL;

/* Handles and wallets are re-validated here even though the page checks them.
   Client-side validation is a courtesy to honest users; it stops nothing that
   is sent deliberately. */
const HANDLE = /^[A-Za-z0-9_]{1,15}$/;
const WALLET = /^0x[a-fA-F0-9]{40}$/;
const ENS = /^[a-z0-9-]{3,}\.eth$/i;
const QUOTE = /^https?:\/\/(x|twitter)\.com\/[^/]+\/status\/\d+/i;

let ready = false;

async function ensureTable(sql) {
  if (ready) return;
  await sql`
    CREATE TABLE IF NOT EXISTS waitlist (
      handle        text PRIMARY KEY,
      constellation text        NOT NULL,
      pass          integer     NOT NULL,
      serial        text        NOT NULL,
      quote_url     text        NOT NULL,
      wallet        text        NOT NULL,
      submitted_at  timestamptz NOT NULL DEFAULT now(),
      updated_at    timestamptz NOT NULL DEFAULT now()
    )`;
  // Ordering the export by signup time is the common read; index it.
  await sql`CREATE INDEX IF NOT EXISTS waitlist_submitted_idx ON waitlist (submitted_at)`;
  ready = true;
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

  const b = typeof req.body === "string" ? safeParse(req.body) : req.body;
  if (!b) return res.status(400).json({ error: "bad_json" });

  const handle = String(b.handle || "").trim().replace(/^@+/, "");
  const wallet = String(b.wallet || "").trim();
  const quote = String(b.quoteUrl || "").trim();
  const constellation = String(b.constellation || "").trim().slice(0, 40);
  const pass = Number(b.pass);
  const serial = String(b.serial || "").trim().slice(0, 32);

  if (!HANDLE.test(handle)) return res.status(400).json({ error: "invalid_handle" });
  if (!WALLET.test(wallet) && !ENS.test(wallet)) return res.status(400).json({ error: "invalid_wallet" });
  if (!QUOTE.test(quote)) return res.status(400).json({ error: "invalid_quote" });
  if (!Number.isInteger(pass) || pass < 1 || pass > 3333) return res.status(400).json({ error: "invalid_pass" });

  try {
    const sql = neon(CONN);
    await ensureTable(sql);

    /* Upsert on handle: someone who comes back with a corrected wallet should
       update their row, not be rejected or duplicated. submitted_at is kept
       from the original claim so queue position is not lost by editing. */
    await sql`
      INSERT INTO waitlist (handle, constellation, pass, serial, quote_url, wallet)
      VALUES (${handle}, ${constellation}, ${pass}, ${serial}, ${quote}, ${wallet})
      ON CONFLICT (handle) DO UPDATE SET
        wallet     = EXCLUDED.wallet,
        quote_url  = EXCLUDED.quote_url,
        updated_at = now()`;

    const [{ count }] = await sql`SELECT count(*)::int AS count FROM waitlist`;
    return res.status(200).json({ ok: true, handle, pass, constellation, count });
  } catch (err) {
    console.error("waitlist write failed", err);
    return res.status(500).json({ error: "write_failed" });
  }
}

function safeParse(s) {
  try { return JSON.parse(s); } catch { return null; }
}
