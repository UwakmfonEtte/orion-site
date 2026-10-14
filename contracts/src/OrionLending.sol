// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DayGuard} from "./DayGuard.sol";

interface ITreasuryLending {
    function redeemValue() external view returns (uint256);
    function lend(address to, uint256 principal, uint256 payout) external;
    function repayLoan(uint256 principal) external payable;
    function writeOffDefault(uint256 principal) external;
}

/**
 * @title OrionLending
 * @notice Borrow ETH against an Orion. The Orion is held here until the loan
 *         is repaid; if it is not repaid by the due date anyone can liquidate,
 *         and the Orion is burned. No auction.
 *
 * The most you can borrow is the redeem value - the backing share LESS the
 * 5% redemption fee - not the full backing. That is deliberate. If the loan
 * could be the full backing, borrowing and never repaying would be a way to
 * leave the treasury without paying the fee: more than a redemption would pay,
 * funded out of the ratchet the other holders are owed. At the redeem value,
 * walking away from a loan costs the other holders exactly what the same
 * holder redeeming would have, so defaulting is never better than redeeming.
 *
 * Interest is fixed (5% a year, pro-rated to the term) and TAKEN UP FRONT. The
 * borrower is paid the principal less that interest and repays only the
 * principal, so nothing extra is collected when they pay back. It is the same
 * whether they repay on day one or on the last day (no gaming the clock), and
 * it goes straight into the treasury, raising backing for every holder.
 *
 * A loan not repaid by its due date can still be repaid for a grace period
 * of 3 days. Only after that can anyone liquidate, so a repayment already in
 * flight at the deadline cannot be front-run into losing the Orion.
 *
 * `DAY` is a constructor argument so a testnet can run time fast; DayGuard
 * refuses a non-86400 value anywhere but a known test network.
 */
contract OrionLending is ReentrancyGuard {
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant RATE_BPS = 500;            // 5% a year
    uint256 public constant GRACE_DAYS = 3;

    IERC721 public immutable NFT;
    ITreasuryLending public immutable TREASURY;
    uint256 public immutable DAY;

    struct Loan {
        address borrower;
        uint256 principal;      // what is owed back
        uint256 interest;       // already kept at the start, not owed again
        uint256 due;
        bool open;
    }
    mapping(uint256 => Loan) public loans;             // by token id

    /// @notice Per-wallet history, kept so a holder can see what they did with their Orions.
    mapping(address => uint256) public borrowsBy;
    mapping(address => uint256) public repaymentsBy;       // credited to the borrower, whoever paid
    mapping(address => uint256) public liquidatedOf;       // Orions burned because the loan went unpaid

    event Borrowed(address indexed borrower, uint256 indexed tokenId, uint256 principal, uint256 interest, uint256 payout, uint256 due);
    event Repaid(address indexed payer, uint256 indexed tokenId, uint256 paid);
    event Liquidated(address indexed by, uint256 indexed tokenId, uint256 principal);

    constructor(address nftAddress, address treasuryAddress, uint256 daySeconds) {
        require(nftAddress != address(0) && nftAddress.code.length > 0, "nft not a contract");
        require(treasuryAddress != address(0) && treasuryAddress.code.length > 0, "treasury not a contract");
        DayGuard.check(daySeconds);
        NFT = IERC721(nftAddress);
        TREASURY = ITreasuryLending(treasuryAddress);
        DAY = daySeconds;
    }

    /// @dev The treasury checks this once, when it wires this module in.
    function treasury() external view returns (address) {
        return address(TREASURY);
    }

    function nft() external view returns (address) {
        return address(NFT);
    }

    /// @notice The largest principal: the redeem value. The borrower is paid
    ///         this less the up-front interest for the chosen term.
    function maxBorrow() public view returns (uint256) {
        return TREASURY.redeemValue();
    }

    /// @notice What the borrower actually receives for a principal and term.
    function payoutFor(uint256 principal, uint256 termDays) public pure returns (uint256) {
        return principal - interestFor(principal, termDays);
    }

    function interestFor(uint256 principal, uint256 termDays) public pure returns (uint256) {
        return (principal * RATE_BPS * termDays) / (365 * 10_000);
    }

    /// @notice What it takes to get the Orion back: the principal, nothing more.
    function owed(uint256 tokenId) public view returns (uint256) {
        Loan memory l = loans[tokenId];
        return l.open ? l.principal : 0;
    }

    function borrow(uint256 tokenId, uint256 termDays, uint256 amount) external nonReentrant {
        require(termDays == 30 || termDays == 90 || termDays == 180, "term must be 30, 90 or 180 days");
        require(!loans[tokenId].open, "already borrowed against");
        require(NFT.ownerOf(tokenId) == msg.sender, "not your token");
        require(amount > 0 && amount <= maxBorrow(), "over the borrow limit");

        uint256 interest = interestFor(amount, termDays);
        uint256 payout = amount - interest;
        require(payout > 0, "loan too small");
        uint256 due = block.timestamp + termDays * DAY;
        loans[tokenId] = Loan(msg.sender, amount, interest, due, true);
        borrowsBy[msg.sender] += 1;

        NFT.transferFrom(msg.sender, address(this), tokenId);   // collateral in first
        TREASURY.lend(msg.sender, amount, payout);               // then the money out

        emit Borrowed(msg.sender, tokenId, amount, interest, payout, due);
    }

    /// @notice Anyone may repay; the Orion always goes back to the borrower.
    function repay(uint256 tokenId) external payable nonReentrant {
        Loan memory l = loans[tokenId];
        require(l.open, "no open loan");
        uint256 total = l.principal;
        require(msg.value >= total, "pay the principal");

        loans[tokenId].open = false;
        repaymentsBy[l.borrower] += 1;

        TREASURY.repayLoan{value: total}(l.principal);
        NFT.transferFrom(address(this), l.borrower, tokenId);

        uint256 extra = msg.value - total;
        if (extra > 0) {
            (bool ok, ) = msg.sender.call{value: extra}("");
            require(ok, "refund failed");
        }
        emit Repaid(msg.sender, tokenId, total);
    }

    /// @notice Past the due date plus the grace period, anyone can end the
    ///         loan. The Orion is burned.
    function liquidate(uint256 tokenId) external nonReentrant {
        Loan memory l = loans[tokenId];
        require(l.open, "no open loan");
        require(block.timestamp > l.due + GRACE_DAYS * DAY, "not past the grace period");

        loans[tokenId].open = false;
        liquidatedOf[l.borrower] += 1;

        NFT.transferFrom(address(this), BURN_ADDRESS, tokenId);
        TREASURY.writeOffDefault(l.principal);
        emit Liquidated(msg.sender, tokenId, l.principal);
    }
}
