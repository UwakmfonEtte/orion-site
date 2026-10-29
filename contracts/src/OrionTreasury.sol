// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev What this treasury needs from the NFT side: how many exist, and
///      whether minting is over. Not ERC721Enumerable's totalSupply() - that
///      would still count burned tokens unless the NFT tracks burns, which a
///      plain transfer to the dead address doesn't.
interface IMintCounter {
    function totalMinted() external view returns (uint256);
    function mintClosed() external view returns (bool);
}

/// @dev Modules (lending, rental) prove they were built for this treasury
///      by pointing back at it. Checked once, when the owner wires them in.
interface IModule {
    function treasury() external view returns (address);
    function nft() external view returns (address);
}

/**
 * @title OrionTreasury
 * @notice Holds the ETH backing the Orion passes and pays it out on
 *         redemption. Also the balance sheet the lending and rental modules
 *         plug into.
 *
 * Deliberately boring: the owner is meant to be a multisig (Gnosis Safe), not an
 * EOA. Deposits are safe to make before mint; redemption is not reachable
 * until the NFT is wired in and the mint is closed.
 *
 * Wiring (`setNftContract`, `setLendingModule`, `setRentalModule`) is
 * one-time. Once redemption is live, swapping any of them would let a
 * compromised or coerced multisig redirect holders' money. A wrong address
 * before launch means a fresh deploy, not a mutable setter.
 *
 * Each redemption burns the token (sends it to the dead address, since plain
 * ERC-721 has no required burn()) and pays an equal share of the assets:
 * assets / (tokens minted - tokens redeemed - tokens defaulted). The redemption
 * fee (5%) is never paid out; it stays and is spread across the Orions still
 * outstanding, so backing per Orion ratchets upward with every redemption.
 *
 * ASSETS = ETH balance + loans outstanding. A loan moves ETH out of the
 * balance but the principal is still owed to the treasury, so counting it keeps
 * backing per Orion from sagging while a loan is open. Interest is taken up
 * front (the borrower is paid the principal less the interest), so it raises
 * backing the moment a loan is made. The lending module caps a loan's principal
 * at the redeem value, so a borrower who never repays and is liquidated is left
 * holding LESS than a redemption would have paid, and the other holders keep
 * the difference.
 *
 * REDEMPTION AND LOANS OPEN ONLY ONCE THE MINT IS CLOSED. While minting is
 * open at a fixed price, a redemption fee that ratchets backing above that
 * price would let a late minter buy in below backing and redeem the surplus.
 *
 * Only the multisig and the wired NFT / rental module ever add ETH that
 * redemptions divide up. Anyone else's ETH is rerouted to donationSink.
 */
contract OrionTreasury is Ownable2Step, ReentrancyGuard, Pausable {
    uint256 public constant MAX_SUPPLY = 999;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice 5% of each redemption stays in the treasury. Nobody is paid it.
    uint256 public constant REDEMPTION_FEE_BPS = 500;
    /// @notice At most half of all assets can be out on loan at once, so
    ///         redemptions always have cash behind them.
    uint256 public constant MAX_UTILIZATION_BPS = 5000;

    address public nftContract;
    address public lendingModule;
    address public rentalModule;
    address public royaltySplitter;

    uint256 public redeemedCount;
    /// @notice How many Orions each wallet has redeemed (burned for ETH). A memory aid.
    mapping(address => uint256) public redeemedBy;
    uint256 public defaultedCount;
    uint256 public loansOutstanding;
    mapping(uint256 => bool) public redeemed;
    address payable public donationSink;

    event Deposited(address indexed from, uint256 amount);
    event NftContractSet(address indexed nft);
    event LendingModuleSet(address indexed module);
    event RentalModuleSet(address indexed module);
    event RoyaltySplitterSet(address indexed splitter);
    event Redeemed(address indexed holder, uint256 indexed tokenId, uint256 payout, uint256 fee);
    event LoanIssued(address indexed to, uint256 principal, uint256 payout, uint256 outstanding);
    event LoanRepaid(uint256 principal, uint256 outstanding);
    event LoanDefaulted(uint256 principal, uint256 outstanding);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event DonationSinkUpdated(address indexed sink);
    event DonationRerouted(address indexed from, uint256 amount);

    /// @param initialOwner The multisig (e.g. a Gnosis Safe) that controls this treasury.
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------

    /// @notice Where unsolicited ETH goes instead of joining the pool.
    function setDonationSink(address payable sink) external onlyOwner {
        require(sink != address(0), "zero address");
        donationSink = sink;
        emit DonationSinkUpdated(sink);
    }

    receive() external payable nonReentrant {
        if (msg.sender == owner() || msg.sender == nftContract || msg.sender == rentalModule
            || msg.sender == royaltySplitter) {
            emit Deposited(msg.sender, msg.value);
            return;
        }
        require(donationSink != address(0), "donations not accepted yet");
        (bool ok, ) = donationSink.call{value: msg.value}("");
        require(ok, "reroute failed");
        emit DonationRerouted(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // One-time wiring
    // ------------------------------------------------------------------

    /// @dev Confirms real code that answers the interface this treasury
    ///      depends on, before locking the address in forever.
    function setNftContract(address nft) external onlyOwner {
        require(nftContract == address(0), "nft already set");
        require(nft != address(0), "zero address");
        require(nft.code.length > 0, "not a contract");
        IMintCounter(nft).totalMinted();
        IMintCounter(nft).mintClosed();
        nftContract = nft;
        emit NftContractSet(nft);
    }

    /// @dev Modules are wired while the mint is still open, i.e. before any
    ///      holder has a claim on this balance. Afterwards a compromised owner
    ///      could wire a module that simply drains the treasury, so the slot
    ///      closes with the mint. A module must also prove it was built for
    ///      THIS treasury and THIS nft: a copy of the same bytecode pointed at
    ///      a stranger's collection would otherwise pass.
    function setLendingModule(address module) external onlyOwner {
        require(lendingModule == address(0), "lending already set");
        require(nftContract != address(0), "wire the nft first");
        require(module != address(0) && module.code.length > 0, "not a contract");
        require(IModule(module).treasury() == address(this), "module is for another treasury");
        require(IModule(module).nft() == nftContract, "module is for another nft");
        require(!_mintClosed(), "wire modules before the mint closes");
        lendingModule = module;
        emit LendingModuleSet(module);
    }

    function setRentalModule(address module) external onlyOwner {
        require(rentalModule == address(0), "rental already set");
        require(nftContract != address(0), "wire the nft first");
        require(module != address(0) && module.code.length > 0, "not a contract");
        require(IModule(module).treasury() == address(this), "module is for another treasury");
        require(IModule(module).nft() == nftContract, "module is for another nft");
        require(!_mintClosed(), "wire modules before the mint closes");
        rentalModule = module;
        emit RentalModuleSet(module);
    }

    /// @notice The royalty splitter, which forwards the backing's 80% of
    ///         royalties here. Same rules as the other modules: one-time, before
    ///         the mint closes, and it must prove it was built for this treasury
    ///         and this nft.
    function setRoyaltySplitter(address splitter) external onlyOwner {
        require(royaltySplitter == address(0), "splitter already set");
        require(nftContract != address(0), "wire the nft first");
        require(splitter != address(0) && splitter.code.length > 0, "not a contract");
        require(IModule(splitter).treasury() == address(this), "module is for another treasury");
        require(IModule(splitter).nft() == nftContract, "module is for another nft");
        require(!_mintClosed(), "wire modules before the mint closes");
        royaltySplitter = splitter;
        emit RoyaltySplitterSet(splitter);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice ETH in hand plus ETH out on loan.
    function totalAssets() public view returns (uint256) {
        return address(this).balance + loansOutstanding;
    }

    function _remainingSupply() internal view returns (uint256) {
        uint256 minted = IMintCounter(nftContract).totalMinted();
        return minted - redeemedCount - defaultedCount;
    }

    function _mintClosed() internal view returns (bool) {
        return IMintCounter(nftContract).mintClosed();
    }

    /// @notice True once the NFT is wired and its mint is over.
    function mintClosed() external view returns (bool) {
        return nftContract != address(0) && _mintClosed();
    }

    /// @notice What each outstanding Orion is backed by right now.
    function backingPerToken() external view returns (uint256) {
        if (nftContract == address(0)) return 0;
        uint256 remaining = _remainingSupply();
        if (remaining == 0) return 0;
        return totalAssets() / remaining;
    }

    /// @notice What a redemption pays right now: the backing share less the fee.
    function redeemValue() public view returns (uint256) {
        if (nftContract == address(0)) return 0;
        uint256 remaining = _remainingSupply();
        if (remaining == 0) return 0;
        uint256 share = totalAssets() / remaining;
        return share - (share * REDEMPTION_FEE_BPS) / 10_000;
    }

    // ------------------------------------------------------------------
    // Redemption
    // ------------------------------------------------------------------

    /**
     * @notice Burn your Orion and claim its share of the assets, less the 5%
     *         fee, which stays behind for everyone still holding.
     * @dev Caller must have approved this contract for `tokenId`. State is
     *      finalized before either external call, on top of the guard.
     */
    function redeem(uint256 tokenId) external nonReentrant whenNotPaused {
        require(nftContract != address(0), "redemption not open");
        require(_mintClosed(), "mint still open");
        require(!redeemed[tokenId], "already redeemed");

        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "not the owner");

        uint256 remaining = _remainingSupply();
        require(remaining > 0, "nothing left to redeem");
        uint256 share = totalAssets() / remaining;
        uint256 fee = (share * REDEMPTION_FEE_BPS) / 10_000;
        uint256 payout = share - fee;
        require(payout > 0, "treasury has no balance");
        require(payout <= address(this).balance, "treasury is lent out");

        redeemed[tokenId] = true;
        redeemedCount += 1;
        redeemedBy[msg.sender] += 1;

        nft.transferFrom(msg.sender, BURN_ADDRESS, tokenId);

        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "ETH transfer failed");

        emit Redeemed(msg.sender, tokenId, payout, fee);
    }

    // ------------------------------------------------------------------
    // Lending hooks - callable only by the wired lending module
    // ------------------------------------------------------------------

    modifier onlyLender() {
        require(msg.sender == lendingModule && msg.sender != address(0), "not the lending module");
        _;
    }

    /// @notice Record `principal` as owed and pay the borrower `payout`.
    /// @dev Interest is taken up front: the borrower receives the principal
    ///      less the interest, and owes only the principal. The difference
    ///      (`principal - payout`) is therefore already in the treasury's
    ///      assets the moment the loan is made, which raises backing for every
    ///      holder at once. Nothing extra has to be collected at repayment.
    function lend(address to, uint256 principal, uint256 payout) external onlyLender nonReentrant whenNotPaused {
        require(_mintClosed(), "mint still open");
        require(payout > 0 && payout <= principal, "bad loan");
        require(payout <= address(this).balance, "insufficient balance");
        require(loansOutstanding + principal <= (totalAssets() * MAX_UTILIZATION_BPS) / 10_000, "utilization cap");
        loansOutstanding += principal;
        (bool ok, ) = to.call{value: payout}("");
        require(ok, "loan transfer failed");
        emit LoanIssued(to, principal, payout, loansOutstanding);
    }

    /// @notice Take back the principal. That is the whole repayment: the
    ///         interest was already kept when the loan was made.
    function repayLoan(uint256 principal) external payable onlyLender nonReentrant {
        require(principal <= loansOutstanding, "more than outstanding");
        require(msg.value >= principal, "short of principal");
        loansOutstanding -= principal;
        emit LoanRepaid(principal, loansOutstanding);
    }

    /// @notice A loan was liquidated: the collateral is gone, so one fewer
    ///         Orion shares the assets and the principal is written off.
    function writeOffDefault(uint256 principal) external onlyLender nonReentrant {
        require(principal <= loansOutstanding, "more than outstanding");
        loansOutstanding -= principal;
        defaultedCount += 1;
        emit LoanDefaulted(principal, loansOutstanding);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Pre-launch escape hatch for the multisig. Permanently disabled
     *         once nftContract is wired: from then on holders have a specific
     *         claim on this balance and an unlimited withdraw would be a
     *         full-drain vector.
     */
    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(nftContract == address(0), "redemption is live");
        require(to != address(0), "zero address");
        require(amount <= address(this).balance, "insufficient balance");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit EmergencyWithdraw(to, amount);
    }

    /// @dev Renouncing before wiring would freeze every deposit permanently.
    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }
}
