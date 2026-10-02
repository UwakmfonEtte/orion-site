// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrionTreasury} from "../../src/OrionTreasury.sol";

/// @notice Holds two tokens; on receiving its redeem() payout, immediately
///         tries to redeem the second token too, to prove nonReentrant blocks it.
contract MaliciousReenterer {
    OrionTreasury public treasury;
    uint256 public secondTokenId;
    bool public attacked;

    constructor(OrionTreasury _treasury) {
        treasury = _treasury;
    }

    function setSecondTokenId(uint256 id) external {
        secondTokenId = id;
    }

    function redeemFirst(uint256 tokenId) external {
        treasury.redeem(tokenId);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            treasury.redeem(secondTokenId); // must revert: reentrant call
        }
    }
}
