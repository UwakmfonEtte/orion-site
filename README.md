# Orion Collective — waitlist site

Waitlist and founding-pass site for **Orion**, a 3,333-piece collection backed by a
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

Submissions are currently written to the artifact runtime's document store, which
only exists inside claude.ai. **On a real domain that store is not available**, so
before launch this needs a persistent backend — Vercel KV, Supabase and Upstash
Redis all work, and the write is a single call in `index.html` (search for
`waitlist/`).

Each record is:

```json
{
  "handle": "yourhandle",
  "constellation": "Cassiopeia",
  "pass": 417,
  "serial": "ORI-1A2B-3C4D",
  "quoteUrl": "https://x.com/…/status/…",
  "wallet": "0x…",
  "submittedAt": "2026-09-11T…"
}
```

## Passes

Every pass is derived from the X handle alone — no lookup, no external service:

- **Number** — `hash(handle) % 3333 + 1`
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
