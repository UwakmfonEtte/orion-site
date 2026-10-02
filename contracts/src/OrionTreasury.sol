// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev The one thing this treasury needs from the NFT side: how many exist
///      right now. Not ERC721Enumerable's totalSupply() - that would still
///      count burned/redeemed tokens unless the NFT contract itself tracks
///      burns, which plain transfer-to-dead-address doesn't. OrionNFT exposes
///      totalMinted() directly for this reason.
interface IMintCounter {
    function totalMinted() external view returns (uint256);
}

/**
 * @title OrionTreasury
 * @notice Holds the ETH backing up to 1,555 Orion passes and pays it out on
 *         redemption.
 *
 * Deliberately boring: the owner is meant to be a multisig (Gnosis Safe), not an
 * EOA. The NFT contract isn't deployed yet, so `nftContract` starts unset and
 * redemption simply reverts until it is - deposits are safe to make before
 * mint, redemption just isn't reachable yet.
 *
 * `nftContract` is one-time-settable rather than owner-updatable forever: once
 * redemption is live, swapping it out would let a compromised or coerced
 * multisig redirect every future redemption through a different ownerOf()
 * check. If it's ever set wrong before launch, the fix is a fresh deploy and
 * moving the (still-unredeemed) balance over, not a mutable setter here.
 *
 * Each redemption burns the token (sends it to the standard dead address,
 * since plain ERC-721 has no required burn() function) and pays out an equal
 * share of whatever ETH is left: balance / (tokens actually minted so far -
 * tokens already redeemed). Dividing by the eventual max of 1,555 instead of
 * the real circulating count would strand ETH permanently whenever the mint
 * hasn't fully sold out - there would be no way for the un-minted tokens to
 * ever exist and claim their share.
 *
 * That equal-share math only stays fair if every wei in the pool came from
 * the same fixed mint price - which is why mint proceeds are the only
 * outside money this contract retains (see receive()), and why OrionNFT's
 * mint price is locked the moment the first token mints. Without both of
 * those, a late/cheap contribution (an underpriced mint, or anyone's direct
 * deposit) could be minted-and-redeemed immediately for more than it put in,
 * at the expense of everyone who paid the real price.
 */
contract OrionTreasury is Ownable, ReentrancyGuard, Pausable {
    uint256 public constant MAX_SUPPLY = 1555;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public nftContract;
    uint256 public redeemedCount;
    mapping(uint256 => bool) public redeemed;
    address payable public donationSink;

    event Deposited(address indexed from, uint256 amount);
    event NftContractSet(address indexed nft);
    event Redeemed(address indexed holder, uint256 indexed tokenId, uint256 payout);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event DonationSinkUpdated(address indexed sink);
    event DonationRerouted(address indexed from, uint256 amount);

    /// @param initialOwner The multisig (e.g. a Gnosis Safe) that controls this treasury.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Where unsolicited ETH gets forwarded, rather than joining the
    ///         redeemable pool. Owner-updatable, not one-time: this is just a
    ///         routing address, not a security-critical wiring like nftContract.
    function setDonationSink(address payable sink) external onlyOwner {
        require(sink != address(0), "zero address");
        donationSink = sink;
        emit DonationSinkUpdated(sink);
    }

    /**
     * @dev Only the multisig (intentional top-ups) and the wired NFT contract
     *      (mint proceeds) ever join the pool that redeem() divides up.
     *      Anyone else's ETH is forwarded straight to donationSink instead of
     *      being retained - an unsolicited deposit would otherwise inflate
     *      balance/remaining for every existing holder based on nothing they
     *      contributed, which is exactly the kind of mispriced-share bug a
     *      mint-then-redeem could exploit even with mint price held constant.
     */
    receive() external payable nonReentrant {
        if (msg.sender == owner() || msg.sender == nftContract) {
            emit Deposited(msg.sender, msg.value);
            return;
        }
        require(donationSink != address(0), "donations not accepted yet");
        (bool ok, ) = donationSink.call{value: msg.value}("");
        require(ok, "reroute failed");
        emit DonationRerouted(msg.sender, msg.value);
    }

    /// @notice One-time wiring of the NFT contract, once it's deployed and live.
    /// @dev This is the one call where getting it wrong is unrecoverable -
    ///      it's intentionally one-time (see contract-level note). A plain
    ///      address(0)-and-nonzero check would accept literally any contract,
    ///      including an attacker-controlled one whose totalMinted() lies, so
    ///      this confirms there's real code at the address and that it
    ///      actually answers the one function this treasury depends on,
    ///      before locking it in forever.
    function setNftContract(address nft) external onlyOwner {
        require(nftContract == address(0), "nft already set");
        require(nft != address(0), "zero address");
        require(nft.code.length > 0, "not a contract");
        // Reverts (rather than returning silently) if `nft` doesn't actually
        // implement totalMinted() - exactly the failure mode worth catching.
        IMintCounter(nft).totalMinted();
        nftContract = nft;
        emit NftContractSet(nft);
    }

    function _remainingSupply() internal view returns (uint256) {
        uint256 minted = IMintCounter(nftContract).totalMinted();
        return minted - redeemedCount;
    }

    /// @notice Current ETH each remaining, unredeemed token would receive right now.
    function backingPerToken() external view returns (uint256) {
        if (nftContract == address(0)) return 0;
        uint256 remaining = _remainingSupply();
        if (remaining == 0) return 0;
        return address(this).balance / remaining;
    }

    /**
     * @notice Burn your Orion pass and claim its share of the treasury.
     * @dev Caller must have approved this contract to move `tokenId` first
     *      (setApprovalForAll or approve) - standard ERC-721 pattern, nothing
     *      custom. State is finalized before either external call (burn
     *      transfer, then ETH send), on top of the reentrancy guard.
     */
    function redeem(uint256 tokenId) external nonReentrant whenNotPaused {
        require(nftContract != address(0), "redemption not open");
        require(!redeemed[tokenId], "already redeemed");

        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "not the owner");

        uint256 remaining = _remainingSupply();
        require(remaining > 0, "nothing left to redeem");
        uint256 payout = address(this).balance / remaining;
        require(payout > 0, "treasury has no balance");

        redeemed[tokenId] = true;
        redeemedCount += 1;

        nft.transferFrom(msg.sender, BURN_ADDRESS, tokenId);

        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "ETH transfer failed");

        emit Redeemed(msg.sender, tokenId, payout);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Pre-launch escape hatch for the multisig - recovering from a
     *         bad deploy, wrong early deposit, etc.
     * @dev Permanently disabled once nftContract is wired. Redemption going
     *      live means real holders now have a specific, owed claim on this
     *      balance; an unlimited withdraw at that point is a full-drain
     *      vector available to a single compromised or coerced multisig,
     *      against funds that are no longer the project's to move. The
     *      tradeoff this accepts: if a bug is found post-launch, the fix is
     *      pause() (stops redemption) plus a new deployment going forward,
     *      not migrating this contract's balance out from under holders.
     */
    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(nftContract == address(0), "redemption is live");
        require(to != address(0), "zero address");
        require(amount <= address(this).balance, "insufficient balance");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit EmergencyWithdraw(to, amount);
    }

    /// @dev Same reasoning as OrionNFT: renouncing before setNftContract() is
    ///      ever called would freeze every deposit here permanently, with no
    ///      other owner-only function left to recover it.
    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }
}
