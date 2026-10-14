// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DayGuard} from "./DayGuard.sol";

interface ITreasuryRent {
    function backingPerToken() external view returns (uint256);
    function rentalModule() external view returns (address);
    function mintClosed() external view returns (bool);
}

/**
 * @title OrionRental
 * @notice The protocol rents out Orions it already owns. You never lend your own.
 *
 * The owner (the multisig) lists Orions it holds. A renter pays 10% of the
 * current backing per 30 days (pro-rated to a 7, 30 or 90 day term) and gets
 * holder perks for the term. Renting earns NO points: points belong to people
 * who stake an Orion they own.
 *
 * The renter NEVER holds the token. It stays in this contract for the whole
 * term, so a renter cannot redeem it, borrow against it, sell it or stake it.
 * Perks are a record kept here, not a transfer. The ETH goes straight to the
 * treasury and raises backing for every holder.
 *
 * `DAY` is a constructor argument so a testnet can run time fast.
 */
contract OrionRental is Ownable2Step, ReentrancyGuard {
    IERC721 public immutable NFT;
    address public immutable TREASURY_ADDRESS;
    uint256 public immutable DAY;

    uint256 public constant RENT_BPS = 1000;            // 10% of backing per 30 days

    struct Slot {
        bool listed;
        address renter;
        uint256 start;
        uint256 until;
    }
    mapping(uint256 => Slot) public slots;
    uint256[] private _listed;
    mapping(uint256 => uint256) private _index;         // position + 1
    /// @notice How many rentals each wallet has taken, ever. A memory aid, nothing more.
    mapping(address => uint256) public rentalsBy;

    event Listed(uint256 indexed tokenId);
    event Delisted(uint256 indexed tokenId);
    event Rented(address indexed renter, uint256 indexed tokenId, uint256 termDays, uint256 paid, uint256 until);

    constructor(address initialOwner, address nftAddress, address treasuryAddress, uint256 daySeconds)
        Ownable(initialOwner)
    {
        require(nftAddress != address(0) && nftAddress.code.length > 0, "nft not a contract");
        require(treasuryAddress != address(0) && treasuryAddress.code.length > 0, "treasury not a contract");
        DayGuard.check(daySeconds);
        NFT = IERC721(nftAddress);
        TREASURY_ADDRESS = treasuryAddress;
        DAY = daySeconds;
    }

    /// @dev The treasury checks this once, when it wires this module in.
    function treasury() external view returns (address) {
        return TREASURY_ADDRESS;
    }

    function nft() external view returns (address) {
        return address(NFT);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function listed() external view returns (uint256[] memory) {
        return _listed;
    }

    function isActive(uint256 tokenId) public view returns (bool) {
        Slot memory s = slots[tokenId];
        return s.renter != address(0) && block.timestamp < s.until;
    }

    function rentCost(uint256 termDays) public view returns (uint256) {
        uint256 backing = ITreasuryRent(TREASURY_ADDRESS).backingPerToken();
        return (backing * RENT_BPS * termDays) / (30 * 10_000);
    }

    function perksActive(address user) external view returns (bool) {
        for (uint256 i = 0; i < _listed.length; i++) {
            if (slots[_listed[i]].renter == user && isActive(_listed[i])) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Inventory (owner only)
    // ------------------------------------------------------------------

    function list(uint256 tokenId) external onlyOwner nonReentrant {
        require(!slots[tokenId].listed, "already listed");
        slots[tokenId].listed = true;
        _listed.push(tokenId);
        _index[tokenId] = _listed.length;
        NFT.transferFrom(msg.sender, address(this), tokenId);
        emit Listed(tokenId);
    }

    function delist(uint256 tokenId) external onlyOwner nonReentrant {
        require(slots[tokenId].listed, "not listed");
        require(!isActive(tokenId), "rented out");

        uint256 i = _index[tokenId] - 1;
        uint256 last = _listed[_listed.length - 1];
        _listed[i] = last;
        _index[last] = i + 1;
        _listed.pop();
        delete _index[tokenId];
        delete slots[tokenId];

        NFT.transferFrom(address(this), msg.sender, tokenId);
        emit Delisted(tokenId);
    }

    // ------------------------------------------------------------------
    // Renting
    // ------------------------------------------------------------------

    function rent(uint256 tokenId, uint256 termDays) external payable nonReentrant {
        require(termDays == 7 || termDays == 30 || termDays == 90, "term must be 7, 30 or 90 days");
        // Rent is priced against backing and paid into it, so it only makes
        // sense once this module is the treasury's wired rental module and the
        // mint is over: rent paid in while minting is open would lift backing
        // above the mint price for whoever mints next.
        require(ITreasuryRent(TREASURY_ADDRESS).rentalModule() == address(this), "rental not wired");
        require(ITreasuryRent(TREASURY_ADDRESS).mintClosed(), "mint still open");
        require(slots[tokenId].listed, "not for rent");
        require(!isActive(tokenId), "already rented");
        uint256 cost = rentCost(termDays);
        require(cost > 0, "no backing to price against");
        require(msg.value >= cost, "pay the rent");

        uint256 until = block.timestamp + termDays * DAY;
        rentalsBy[msg.sender] += 1;
        slots[tokenId] = Slot(true, msg.sender, block.timestamp, until);

        (bool toTreasury, ) = TREASURY_ADDRESS.call{value: cost}("");
        require(toTreasury, "treasury transfer failed");

        uint256 extra = msg.value - cost;
        if (extra > 0) {
            (bool refunded, ) = msg.sender.call{value: extra}("");
            require(refunded, "refund failed");
        }
        emit Rented(msg.sender, tokenId, termDays, cost, until);
    }

    /// @dev Always refuses: only list() brings a token in.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("use list()");
    }

    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }
}
