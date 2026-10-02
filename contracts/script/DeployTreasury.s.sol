// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";

/**
 * Usage:
 *   forge script script/DeployTreasury.s.sol:DeployTreasury \
 *     --rpc-url <RPC_URL> --broadcast --verify
 *
 * Set these in your shell (never commit them):
 *   SAFE_ADDRESS   - the Gnosis Safe multisig that will own the treasury
 *   PRIVATE_KEY    - the deployer key (does NOT become the owner; only pays gas)
 */
contract DeployTreasury is Script {
    function run() external returns (OrionTreasury treasury) {
        address safe = vm.envAddress("SAFE_ADDRESS");
        require(safe != address(0), "SAFE_ADDRESS not set");

        vm.startBroadcast();
        treasury = new OrionTreasury(safe);
        vm.stopBroadcast();

        console.log("OrionTreasury deployed at:", address(treasury));
        console.log("Owner (should be the Safe):", treasury.owner());
    }
}
