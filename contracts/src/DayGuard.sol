// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DayGuard
 * @notice The staking, lending and rental modules take the length of a "day"
 *         as a constructor argument so a testnet can run time fast. On a real
 *         network that argument is a loaded footgun: deploy with the testnet
 *         value and a 30-day loan becomes liquidatable after 30 minutes. So
 *         anything other than a true day is refused unless the chain is a
 *         known test network.
 */
library DayGuard {
    uint256 internal constant REAL_DAY = 86400;

    function check(uint256 daySeconds) internal view {
        require(daySeconds > 0, "bad day");
        if (daySeconds == REAL_DAY) return;
        uint256 id = block.chainid;
        // 31337 local (anvil/foundry), 46630 Robinhood Chain testnet, 11155111 Sepolia
        require(id == 31337 || id == 46630 || id == 11155111, "fast clock is testnet only");
    }
}
