# Orion contracts

Smart contracts for the Orion / Liquid Constellations mint and the products built
on its treasury. Mainnet is not deployed. A full copy runs on Robinhood Chain
testnet (see below).

## What's here

| Contract | Job |
| --- | --- |
| `OrionNFT.sol` | The mainnet mint. ERC-721, capped at 1,555, Merkle allowlist, price locked after the first mint, every wei goes to the treasury. |
| `OrionTestNFT.sol` | Testnet stand-in: public mint, supply and per-wallet cap set at deploy (50 and 2 on the public testnet). Same money flow. |
| `OrionTreasury.sol` | Multisig-owned vault. Redemption burns an Orion and pays its share of the assets less a 5% fee that stays behind, so backing per Orion only rises. Also the balance sheet the modules plug into. |
| `OrionStaking.sol` | Stake an Orion, earn 100 points for every full 24 hours (whole days, no per-second drip). Unstake anytime: unstaking pays your waiting rewards and cashes in the points of the Orions that leave, in the same transaction. Shares the Yield Treasury's realized profit among current stakers by points. |
| `OrionLending.sol` | Borrow ETH against an Orion, up to the redeem value. The 5%-a-year interest is taken up front: you receive the value less the interest and repay only the value. Unpaid past the due date plus a 3-day grace, anyone can liquidate and the Orion is burned. |
| `OrionRental.sol` | The protocol rents Orions it owns: 10% of backing per 30 days, perks (no points) for the renter, who never holds the token. |
| `OrionRoyaltySplitter.sol` | Receives the 10% ERC-2981 royalty. `release()` (after the mint closes) sends 80% to the treasury and 20% to the Yield Treasury. |
| `OrionYieldTreasury.sol` | Owner-run vault for the 20% royalty share. Realized profit is pushed to stakers through `distributeProfit`. |
| `DayGuard.sol` | Refuses a shortened "day" anywhere but a known test network. |

## Rules worth knowing

- **Redeem, borrow and rent open only once the mint is closed** (sold out, or closed by
  the owner). While minting is open at a fixed price, a ratcheting fee would let late
  minters buy in below backing.
- **Loans can be at most the redeem value**, not the full backing. Otherwise borrowing and
  never repaying would be a way to leave without paying the 5% fee.
- **At most half of the treasury can be lent out**, so redemptions always have cash behind them.
- **Wiring is one-time and closes with the mint.** The NFT, lending and rental modules are
  set once, before the mint closes, and each must prove it was built for this treasury and
  this NFT. A compromised owner cannot wire a draining module after launch.
- **No unlimited admin withdraw.** `emergencyWithdraw` only works before the NFT is wired.
- Ownership moves in two steps and cannot be renounced.

## Status

An independent red-team review (two rounds) found no permissionless way to extract value
or lock funds; the findings it did raise are fixed, or listed as open decisions for the
owner. This is an internal review, not a professional third-party audit, and one should
happen before real money is involved. 222 tests, plus a stateful fuzz of four invariants
(loan book matches loans, supply math, backing never falls, no redeemer is stranded).

Open decisions (not bugs): pause and `closeMint()` are owner-controlled, so redemption
liveness depends on the multisig; the final redeemer's 5% is stranded; whether to add late
interest or a liquidator bounty; the mint price cannot be corrected after the first mint;
the Merkle root can be changed by the owner.

## Robinhood Chain testnet

`script/DeployTestnetFull.s.sol` deploys and wires everything with real 86400-second days:
a 30-day loan is 30 days and points arrive in whole 24-hour steps. Supply is 50, two per wallet. The test
site is `testnet.html` in the site root. `test/TestnetNumbers.t.sol` pins the deployed
configuration's figures to the wei.

## Working with this code

Dependencies (OpenZeppelin, forge-std) aren't committed - install them locally:

```shell
forge install foundry-rs/forge-std --no-git
forge install OpenZeppelin/openzeppelin-contracts --no-git
forge build
forge test -vv
```
