import test from "node:test";
import assert from "node:assert/strict";
import {
  VOUCHES_PER_WITNESS,
  VOUCHES_REQUIRED,
  checkEligibility,
  countDistinctVerifiedVouchers,
  maySponsorAnother,
} from "../api/_vouch.js";

test("a new pass requires three distinct verified witnesses", () => {
  assert.equal(VOUCHES_REQUIRED, 3);
  assert.equal(countDistinctVerifiedVouchers([
    { witness: "Alice", verified: true },
    { witness: "alice", verified: true },
    { witness: "Bob", verified: true },
    { witness: "Carol", verified: false },
  ]), 2);
  assert.equal(countDistinctVerifiedVouchers([
    { witness: "Alice", verified: true },
    { witness: "Bob", verified: true },
    { witness: "Carol", verified: true },
  ]), 3);
});

test("each eligible voucher may sponsor at most three accounts", () => {
  assert.equal(VOUCHES_PER_WITNESS, 3);
  assert.equal(maySponsorAnother({ approved: true, sponsoredCount: 2 }), true);
  assert.equal(maySponsorAnother({ approved: true, sponsoredCount: 3 }), false);
  assert.equal(maySponsorAnother({ approved: false, earnedVouching: false, sponsoredCount: 0 }), false);
  assert.equal(maySponsorAnother({ approved: false, earnedVouching: true, sponsoredCount: 0 }), true);
});

test("only selected or fully vouched accounts may sponsor", () => {
  const base = {
    witness: "witness_1",
    nominee: "nominee_1",
    sponsoredCount: 0,
    nomineeHasPass: false,
  };
  assert.equal(checkEligibility({ ...base, approved: true, earnedVouching: false }), null);
  assert.equal(checkEligibility({ ...base, approved: false, earnedVouching: true }), null);
  assert.equal(checkEligibility({ ...base, approved: false, earnedVouching: false }), "not_eligible_to_vouch");
  assert.equal(checkEligibility({ ...base, approved: true, earnedVouching: false, sponsoredCount: 3 }), "witness_exhausted");
});