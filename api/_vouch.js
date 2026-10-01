import { createHmac } from "node:crypto";

export const VOUCHES_REQUIRED = 3;
export const VOUCHES_PER_WITNESS = 3;

const HANDLE_RE = /^[A-Za-z0-9_]{1,15}$/;

export function normHandle(value) {
  return typeof value === "string" ? value.trim().replace(/^@+/, "").toLowerCase() : "";
}

export function validHandle(value) {
  return HANDLE_RE.test(String(value || ""));
}

export function countDistinctVerifiedVouchers(rows) {
  const witnesses = new Set();
  for (const row of rows || []) {
    const witness = normHandle(row?.witness);
    if (row?.verified === true && validHandle(witness)) witnesses.add(witness);
  }
  return witnesses.size;
}

export function maySponsorAnother({ approved, earnedVouching, sponsoredCount }) {
  return (approved === true || earnedVouching === true) &&
    Number(sponsoredCount) < VOUCHES_PER_WITNESS;
}

function secret() {
  const value = process.env.VOUCH_SECRET || process.env.ADMIN_KEY || process.env.DATABASE_URL || process.env.POSTGRES_URL;
  if (!value) throw new Error("not_configured");
  return value;
}

export function pairCode(witness, nominee) {
  const digest = createHmac("sha256", secret())
    .update(`${normHandle(witness)}>${normHandle(nominee)}`)
    .digest("hex")
    .toUpperCase();
  return `ORI-${digest.slice(0, 6)}`;
}

export function proofText(witness, nominee, code) {
  return `Vouching for @${normHandle(nominee)} to join Orion.\n\n${code}\n\n` +
    `This post confirms I own @${normHandle(witness)}. You can delete it once the vouch goes through.`;
}

export function checkEligibility({
  witness,
  nominee,
  approved,
  earnedVouching,
  sponsoredCount,
  nomineeHasPass,
}) {
  if (!validHandle(witness) || !validHandle(nominee)) return "invalid_handle";
  if (normHandle(witness) === normHandle(nominee)) return "self_vouch";
  if (!approved && !earnedVouching) return "not_eligible_to_vouch";
  if (!maySponsorAnother({ approved, earnedVouching, sponsoredCount })) {
    return "witness_exhausted";
  }
  if (nomineeHasPass) return "already_holds_pass";
  return null;
}