/**
 * Shared, dependency-free validation and derivation.
 *
 * Split out from the route handlers so it can be exercised directly by
 * test/security.test.mjs. Anything the client sends is hostile until proven
 * otherwise; anything derivable is derived here rather than trusted.
 */

/** The 88 IAU-recognised constellations. Also the allowlist for the field —
 *  the client sends a constellation, but only a value from this exact set is
 *  ever stored, which is what keeps arbitrary text out of the CSV export. */
export const IAU = ['Andromeda','Antlia','Apus','Aquarius','Aquila','Ara','Aries','Auriga',
'Bootes','Caelum','Camelopardalis','Cancer','Canes Venatici','Canis Major',
'Canis Minor','Capricornus','Carina','Cassiopeia','Centaurus','Cepheus','Cetus',
'Chamaeleon','Circinus','Columba','Coma Berenices','Corona Australis',
'Corona Borealis','Corvus','Crater','Crux','Cygnus','Delphinus','Dorado','Draco',
'Equuleus','Eridanus','Fornax','Gemini','Grus','Hercules','Horologium','Hydra',
'Hydrus','Indus','Lacerta','Leo','Leo Minor','Lepus','Libra','Lupus','Lynx','Lyra',
'Mensa','Microscopium','Monoceros','Musca','Norma','Octans','Ophiuchus','Orion',
'Pavo','Pegasus','Perseus','Phoenix','Pictor','Pisces','Piscis Austrinus','Puppis',
'Pyxis','Reticulum','Sagitta','Sagittarius','Scorpius','Sculptor','Scutum',
'Serpens','Sextans','Taurus','Telescopium','Triangulum','Triangulum Australe',
'Tucana','Ursa Major','Ursa Minor','Vela','Virgo','Volans','Vulpecula'];

export const SUPPLY = 1600;

/** X handles: letters, digits, underscore, 1-15. Deliberately the strictest
 *  reading of X's own rule — it is also what makes the handle safe to place in
 *  HTML, a URL and a CSV cell without further treatment. */
const HANDLE_RE = /^[A-Za-z0-9_]{1,15}$/;
const WALLET_RE = /^0x[a-fA-F0-9]{40}$/;
const ENS_RE = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.eth$/i;

/** Hosts a status link may legitimately come from. Compared against the
 *  parsed hostname, never matched inside the raw string — "evil.com/x.com/..."
 *  and "https://x.com@evil.com/..." both have to fail. */
const X_HOSTS = new Set(['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com',
                         'mobile.twitter.com', 'mobile.x.com']);

/** Longest input accepted before anything else happens. Guards against a
 *  megabyte of text being regexed or sliced. */
const MAX_FIELD = 512;

export function hashOf(handle) {
  let h = 5381;
  for (const c of handle.toLowerCase()) h = ((h * 33) ^ c.charCodeAt(0)) >>> 0;
  return h;
}

/** Pass number, serial and constellation all follow from the handle. The
 *  client computes them for display; the server recomputes them so a crafted
 *  request cannot claim No. 0001 or a constellation it was not given. */
export function derive(handle) {
  const h = hashOf(handle);
  return {
    pass: (h % SUPPLY) + 1,
    serial: 'ORI-' + h.toString(16).toUpperCase().padStart(8, '0').slice(0, 4) + '-' +
            ((h * 2654435761) >>> 0).toString(16).toUpperCase().slice(0, 4),
    constellation: IAU[(h >>> 7) % IAU.length]
  };
}

function str(v) {
  if (typeof v === 'string') return v;
  if (v === null || v === undefined) return '';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return '';                       // objects/arrays are never a valid field
}

/**
 * Validates a status URL and confirms the author is `handle`.
 *
 * Without the author check, any live X post satisfies the requirement — you
 * could paste someone else's viral tweet and never post at all. The URL is
 * parsed rather than pattern-matched so host spoofing fails properly.
 */
export function checkQuote(raw, handle) {
  const s = str(raw).trim();
  if (!s || s.length > MAX_FIELD) return { ok: false, error: 'invalid_quote' };

  let u;
  try { u = new URL(s); } catch { return { ok: false, error: 'invalid_quote' }; }

  if (u.protocol !== 'https:' && u.protocol !== 'http:') {
    return { ok: false, error: 'invalid_quote' };          // javascript:, data:
  }
  if (!X_HOSTS.has(u.hostname.toLowerCase())) {
    return { ok: false, error: 'invalid_quote' };
  }

  const parts = u.pathname.split('/').filter(Boolean);
  if (parts.length < 3) return { ok: false, error: 'invalid_quote' };

  const [author, kind, id] = parts;
  if (kind !== 'status' && kind !== 'statuses') return { ok: false, error: 'invalid_quote' };
  if (!/^\d{5,25}$/.test(id)) return { ok: false, error: 'invalid_quote' };
  if (!HANDLE_RE.test(author)) return { ok: false, error: 'invalid_quote' };
  if (author.toLowerCase() !== handle.toLowerCase()) {
    return { ok: false, error: 'quote_not_yours' };
  }

  // Rebuilt canonically from the VALIDATED handle rather than the raw path
  // segment: X treats handles case-insensitively, so keying off `author`
  // would store the same post twice under different casing. Query strings
  // and fragments are dropped, so tracking junk never reaches storage.
  return { ok: true, url: `https://x.com/${handle}/status/${id}`, tweetId: id };
}

/**
 * Full submission check. Returns either { ok:false, error } or { ok:true,
 * record } where every field of `record` is server-derived or server-validated.
 */
export function validateSubmission(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, error: 'bad_json' };
  }

  const handle = str(body.handle).trim().replace(/^@+/, '');
  if (!HANDLE_RE.test(handle)) return { ok: false, error: 'invalid_handle' };

  const wallet = str(body.wallet).trim();
  if (wallet.length > MAX_FIELD) return { ok: false, error: 'invalid_wallet' };
  const isHex = WALLET_RE.test(wallet);
  const isEns = ENS_RE.test(wallet);
  if (!isHex && !isEns) return { ok: false, error: 'invalid_wallet' };

  const q = checkQuote(body.quoteUrl, handle);
  if (!q.ok) return { ok: false, error: q.error };

  // Every task must be declared complete. This is not proof — a scripted
  // request can assert it — but it makes the requirement explicit at the
  // boundary, and `verified` below is what actually gates the allowlist.
  const tasks = body.tasks;
  if (!Array.isArray(tasks) || tasks.length !== 5 || !tasks.every(t => t === true)) {
    return { ok: false, error: 'tasks_incomplete' };
  }

  const d = derive(handle);

  return {
    ok: true,
    record: {
      handle,
      // normalised: 0x addresses lowercased, ENS lowercased
      wallet: isHex ? wallet.toLowerCase() : wallet.toLowerCase(),
      quoteUrl: q.url,
      tweetId: q.tweetId,
      pass: d.pass,
      serial: d.serial,
      constellation: d.constellation
    }
  };
}

/**
 * CSV cell escaping.
 *
 * Two separate problems. Quoting handles commas/quotes/newlines. The leading
 * apostrophe handles formula injection: a cell opening with = + - @ (or tab /
 * carriage return) is executed as a formula by Excel and Sheets, which is a
 * remote-code path that arrives through a file rather than a request.
 */
export function csvCell(v) {
  let s = v === null || v === undefined ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
