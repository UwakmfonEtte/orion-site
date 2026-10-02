# Orion contracts

Smart contracts for the Orion / Liquid Constellations mint. Pre-deployment: nothing
here is on any chain yet.

## What's here

- **`src/OrionNFT.sol`** — ERC-721, hard-capped at 1,555. Merkle-proof allowlist mint
  (membership decided off-chain by the waitlist/vouch system, proven cheaply
  on-chain). Mint price is set once before the first mint and locked for the rest of
  the sale. Every wei paid forwards straight to the treasury; overpayment is refunded.
- **`src/OrionTreasury.sol`** — multisig-owned vault holding the ETH backing every
  unredeemed pass. `redeem(tokenId)` burns the token and pays out an equal share of
  the balance, based on the actual circulating supply. Deposits are restricted to the
  multisig and the wired NFT contract; anything else is rerouted to a separate
  address rather than diluting what holders are owed.
- **`script/DeployTreasury.s.sol`** — deployment script for the treasury, taking the
  multisig (Safe) address as the owner.

## Status

Both contracts have been through a full internal security review (a dedicated
red-team pass, not a professional third-party audit) and every finding from it is
either fixed or a deliberate, documented tradeoff - see the NatSpec comments in each
contract for the reasoning behind each safeguard.

Not yet done: a deploy script for `OrionNFT`, the off-chain Merkle allowlist
generator, testnet/mainnet deployment, and the mint site's web3 wiring. All on hold
pending the multisig being created and the team's go-ahead.

## Working with this code

Dependencies (OpenZeppelin, forge-std) aren't committed - install them locally:

```shell
forge install foundry-rs/forge-std --no-git
forge install OpenZeppelin/openzeppelin-contracts --no-git
```

```shell
forge build
forge test -vv
```

52 tests across unit and integration coverage, including a proven reentrancy attack,
access-control checks on every owner-only function, and the economic edge cases
(partial mint, double redemption, empty treasury).
