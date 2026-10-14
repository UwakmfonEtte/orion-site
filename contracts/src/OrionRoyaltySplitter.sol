// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ISplitterTreasury {
    function mintClosed() external view returns (bool);
}

/**
 * @title OrionRoyaltySplitter
 * @notice The royalty receiver. Marketplaces pay creator royalties (10%) to the
 *         address the NFT names via ERC-2981; this is that address. Anyone can
 *         then call release() and the balance splits 80% to the Liquid Backing
 *         Treasury and 20% to the Yield Treasury.
 *
 * There is no owner and nothing to configure: the split and both destinations
 * are fixed at construction.
 *
 * release() waits until the mint is closed. Royalties paid into the backing
 * treasury while minting is open would lift backing above the fixed mint price
 * and let whoever mints next buy in below it, so the money simply sits here
 * until the mint is over.
 *
 * The treasury checks `treasury()` and `nft()` once, when it wires this in as a
 * depositor, exactly as it does for the lending and rental modules.
 */
contract OrionRoyaltySplitter is ReentrancyGuard {
    uint256 public constant TREASURY_BPS = 8000;      // 80% to the backing
    uint256 public constant BPS = 10_000;

    address public immutable BACKING;                  // the Liquid Backing Treasury
    address public immutable YIELD;                    // the Yield Treasury
    address public immutable NFT_ADDRESS;

    event Received(address indexed from, uint256 amount);
    event Released(uint256 toBacking, uint256 toYield);

    constructor(address backing, address yieldTreasury, address nftAddress) {
        require(backing != address(0) && backing.code.length > 0, "backing not a contract");
        require(yieldTreasury != address(0) && yieldTreasury.code.length > 0, "yield not a contract");
        require(nftAddress != address(0) && nftAddress.code.length > 0, "nft not a contract");
        BACKING = backing;
        YIELD = yieldTreasury;
        NFT_ADDRESS = nftAddress;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function treasury() external view returns (address) {
        return BACKING;
    }

    function nft() external view returns (address) {
        return NFT_ADDRESS;
    }

    /// @notice Split whatever royalties have arrived. Anyone may call it.
    function release() external nonReentrant {
        require(ISplitterTreasury(BACKING).mintClosed(), "mint still open");
        uint256 bal = address(this).balance;
        require(bal > 0, "nothing to release");
        uint256 toBacking = (bal * TREASURY_BPS) / BPS;
        uint256 toYield = bal - toBacking;
        (bool a, ) = BACKING.call{value: toBacking}("");
        require(a, "backing transfer failed");
        (bool b, ) = YIELD.call{value: toYield}("");
        require(b, "yield transfer failed");
        emit Released(toBacking, toYield);
    }
}
