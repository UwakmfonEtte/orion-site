# Orion Collective — waitlist site

Waitlist and founding-pass site for **Orion**, a 1,555-piece collection minted at
0.006 ETH and backed by a
Liquid Backing Treasury.

Static HTML with one serverless function. No build step, no framework, no
dependencies — `index.html` is the whole front end.

## Layout

```
index.html          the site
api/score.js        Sorsa Score proxy (currently unused — see below)
archive/            earlier design directions, kept for reference
```

## Running locally

Open `index.html` in a browser. That is the entire setup.

To exercise `api/score.js` as well, run `vercel dev` from this directory.

## Deploying

Import the repo on Vercel. It is detected as a static site and the `api/`
directory is picked up automatically — no configuration needed.

## The waitlist store

Neon Postgres, added through the Vercel Marketplace. (Vercel's own KV and
Postgres products were sunset — KV stores moved to Upstash Redis in December
2024 — so marketplace providers are the current path.)

**Setup**

1. Vercel dashboard → **Storage** → **Create Database** → **Neon**
2. Connect it to this project. `DATABASE_URL` is injected automatically.
3. Add an env var **`ADMIN_KEY`** — any long random string. It guards the export.
4. Redeploy.

The table is created on the first write, so there is no migration step.

**Endpoints**

| Route | Access | Purpose |
|---|---|---|
| `POST /api/waitlist` | public | Save one entry. Upserts on handle. |
| `GET /api/count` | public | Tally only — no handles, no wallets. |
| `GET /api/export?key=…` | `ADMIN_KEY` | Full CSV. This is the allowlist. |

```bash
curl -o allowlist.csv "https://your-domain/api/export?key=$ADMIN_KEY"
curl "https://your-domain/api/export?key=$ADMIN_KEY&format=json"
```

**Schema**

```sql
handle        text PRIMARY KEY
constellation text
pass          integer
serial        text
quote_url     text
wallet        text
submitted_at  timestamptz   -- kept from the original claim
updated_at    timestamptz   -- moves when someone corrects their wallet
```

Re-submitting the same handle updates the wallet and quote but keeps
`submitted_at`, so editing a typo never costs queue position.

The page works in both places: inside claude.ai it writes to the artifact
document store, on a real domain it posts to `/api/waitlist`. If neither is
reachable the submit **fails loudly** rather than showing success — a waitlist
that quietly drops signups is the one bug worth being noisy about.

## Security

`node --test test/security.test.mjs` — 22 adversarial tests covering the
submission boundary. They assert rejection, not "probably fine".

All checking and derivation live in `api/_validate.js`, kept free of database
imports so it can be attacked directly by the tests.

**What is enforced**

| Attack | Defence |
|---|---|
| SQL injection | Neon's tagged template compiles to `$1` placeholders with a separate params array — verified, not assumed |
| XSS | Handles are `[A-Za-z0-9_]{1,15}`; every render escapes; the one raw use is inside `encodeURIComponent` |
| Quoting someone else's post | The status URL author must equal the submitting handle |
| Host spoofing (`x.com@evil.com`, `x.com.evil.com`) | URL is parsed and the hostname matched against an allowlist, never pattern-matched in the raw string |
| `javascript:` / `data:` URLs | Protocol restricted to http/https |
| Claiming pass No. 0001 | Pass, serial and constellation are recomputed server-side and the client's values discarded |
| CSV formula injection | Cells opening `= + - @ TAB CR` are prefixed with `'` |
| Prototype pollution | `__proto__` in the body cannot reach the record |
| Type confusion | Objects and arrays in string fields are rejected, never coerced |
| Oversize payloads | Body capped at 4 KB, fields at 512 chars |
| Bulk fake signups | 6 submissions per IP per hour, keyed on a salted hash |

**Tasks before wallet** — enforced in three places, and only the last one
counts:

1. The submit button is `disabled` until all four are clicked
2. The click handler re-checks before sending
3. `api/waitlist.js` rejects the request unless all four flags are `true`

The first two are conveniences. A scripted request can still assert the flags,
which is why the quote-ownership check matters: to be recorded at all, you must
supply a real status URL **authored by the handle you are claiming**. That is
the part which cannot be faked without actually posting.

**Not yet verified** — that the post genuinely quotes *your* whitelist post, and
that the repost, like and reply happened. Those need X data, which Sorsa can
supply (`/quotes`, `/retweeters`, `/comments`). The `verified` column exists for
exactly that: run a batch check before mint and only export `verified = true`.

**Caveat** — inside claude.ai the page writes to the artifact document store
directly, so only the client-side gates apply there. The Vercel deployment is
the one with server-side enforcement.

## Passes

Every pass is derived from the X handle alone — no lookup, no external service:

- **Number** — `hash(handle) % 1555 + 1`
- **Constellation** — one of the 88 IAU-recognised constellations, the same set
  used as the collection's trait list
- **Serial** — `ORI-XXXX-XXXX`

Deterministic by design: a handle always yields the same pass, so the card can be
regenerated at any time without storing it.

## Sorsa (not currently in use)

The waitlist was originally gated on a [Sorsa Score](https://sorsa.io) of 300+.
That gate has been removed and access is open to everyone; `api/score.js` remains
in place in case it is reinstated.

Verified endpoint contract, for whoever picks it up next:

```
GET https://api.sorsa.io/v3/score?username=<handle>
Header: ApiKey: <key>

200 -> {"score": 5116.587}     float
400 -> {"message":"user_link, username or user_id required"}
404 -> {"message":"User not found."}
```

Observed range — the largest crypto accounts sit around 3,900–5,120
(VitalikButerin 5117, cobie 4285, punk6529 4282, beeple 4136, zachxbt 4130,
farokh 3904). The index is crypto-scoped, so a 404 generally means "no crypto
footprint" rather than "no such account".

If reinstated: set `SORSA_API_KEY` in Vercel's environment settings and set
`SCORE_API = "/api/score"` near the top of the script in `index.html`. **The key
must never be committed or shipped to the browser** — that is the only reason the
proxy exists.

## Notes

- Two themes: dark is the sky as observed, light is the chart as printed. The
  hero canvas re-renders per theme rather than being recoloured.
- The hero cycles six real constellations — Orion, Ursa Major, Cassiopeia,
  Cygnus, Scorpius, Lyra — with stars placed by real position and sized by real
  apparent magnitude.
- Motion is disabled under `prefers-reduced-motion`.
