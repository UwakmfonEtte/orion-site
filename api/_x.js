const OEMBED = "https://publish.twitter.com/oembed";

export async function fetchPost(url, { timeoutMs = 8000 } = {}) {
  const query = new URLSearchParams({ url, omit_script: "1", dnt: "true" });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${OEMBED}?${query}`, {
      signal: controller.signal,
      headers: { "User-Agent": "orion-site/1.0 (vouch verification)" },
    });
    if (response.status === 404) return { ok: false, reason: "not_found" };
    if (response.status === 403) return { ok: false, reason: "protected" };
    if (response.status === 429) return { ok: false, reason: "rate_limited" };
    if (!response.ok) return { ok: false, reason: `http_${response.status}` };

    const data = await response.json();
    const author = String(data.author_url || "").split("/").filter(Boolean).pop() || "";
    return { ok: true, author, text: stripTags(data.html || "") };
  } catch (error) {
    return { ok: false, reason: error.name === "AbortError" ? "timeout" : "network" };
  } finally {
    clearTimeout(timer);
  }
}

function stripTags(html) {
  return String(html)
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&mdash;/g, "—")
    .replace(/\s+/g, " ")
    .trim();
}

export function authorIs(author, handle) {
  return String(author || "").toLowerCase() === String(handle || "").toLowerCase();
}

export function containsCode(text, code) {
  const normalizedText = String(text).toUpperCase().replace(/[\s\u200B-\u200D]/g, "");
  const normalizedCode = String(code).toUpperCase().replace(/\s/g, "");
  return normalizedText.includes(normalizedCode);
}