// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {OrionNFT} from "../../src/OrionNFT.sol";
import {OrionTreasury} from "../../src/OrionTreasury.sol";

/**
 * @notice Pre-approves the treasury for all future tokens, then mints. If
 *         OrionNFT ever called _safeMint before forwarding payment to the
 *         treasury, onERC721Received would fire mid-mint, while the treasury
 *         hasn't been paid for *this* mint yet - a reentrant redeem() here
 *         would be paid from a smaller, stale balance than the real
 *         post-mint state. With payment-before-mint, this same reentrant
 *         call instead sees the fully-settled, correct balance.
 */
contract MintReceiverReenterer is IERC721Receiver {
    OrionNFT public nft;
    OrionTreasury public treasury;
    bool public reentered;
    uint256 public reentrantPayout;

    constructor(OrionNFT _nft, OrionTreasury _treasury) {
        nft = _nft;
        treasury = _treasury;
    }

    function approveTreasuryForAll() external {
        nft.setApprovalForAll(address(treasury), true);
    }

    function doMint(bytes32[] calldata proof) external payable {
        nft.mint{value: msg.value}(proof);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        if (!reentered) {
            reentered = true;
            uint256 before = address(this).balance;
            treasury.redeem(tokenId);
            reentrantPayout = address(this).balance - before;
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
