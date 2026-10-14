// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";
import {OrionTestNFT} from "../src/OrionTestNFT.sol";
import {OrionStaking} from "../src/OrionStaking.sol";
import {OrionLending} from "../src/OrionLending.sol";
import {OrionRental} from "../src/OrionRental.sol";
import {OrionYieldTreasury} from "../src/OrionYieldTreasury.sol";
import {OrionRoyaltySplitter} from "../src/OrionRoyaltySplitter.sol";

/**
 * Robinhood Chain testnet (46630): the whole system, wired.
 *
 *   OWNER=<public address> forge script script/DeployTestnetFull.s.sol:DeployTestnetFull \
 *     --rpc-url https://rpc.testnet.chain.robinhood.com --private-key $PRIVATE_KEY --broadcast
 *
 * OWNER must be the address behind PRIVATE_KEY: the wiring calls are
 * owner-only and run from the same broadcast. On testnet that is a throwaway
 * wallet; on mainnet ownership belongs to the multisig and this is not the
 * script to use.
 *
 * DAY is 86400, a real day, so a 30-day loan is 30 days and points come in
 * whole 24-hour steps. Supply is 150, two per wallet.
 *
 * Money flows wired here:
 *   mint ----------------------------> Liquid Backing Treasury
 *   royalty (10%, ERC-2981) ---------> RoyaltySplitter --80%--> Liquid Backing Treasury
 *                                                      --20%--> Yield Treasury
 *   Yield Treasury (realized profit) -> Staking, shared by points
 */
contract DeployTestnetFull is Script {
    uint256 constant MINT_PRICE = 0.001 ether;
    uint256 constant DAY = 86400;
    uint256 constant MAX_SUPPLY = 150;
    uint256 constant MAX_PER_WALLET = 2;
    string constant BASE_URI = "https://oriongqgc.space/testnet/meta/";

    function run() external {
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();
        OrionTreasury treasury = new OrionTreasury(owner);
        OrionTestNFT nft = new OrionTestNFT(owner, payable(address(treasury)), MINT_PRICE, MAX_SUPPLY, MAX_PER_WALLET);
        OrionYieldTreasury yieldTreasury = new OrionYieldTreasury(owner);
        OrionStaking staking = new OrionStaking(address(nft), DAY, address(yieldTreasury));
        OrionLending lending = new OrionLending(address(nft), address(treasury), DAY);
        OrionRental rental = new OrionRental(owner, address(nft), address(treasury), DAY);
        OrionRoyaltySplitter splitter =
            new OrionRoyaltySplitter(address(treasury), address(yieldTreasury), address(nft));

        treasury.setNftContract(address(nft));
        treasury.setDonationSink(payable(owner));
        treasury.setLendingModule(address(lending));
        treasury.setRentalModule(address(rental));
        treasury.setRoyaltySplitter(address(splitter));
        yieldTreasury.setStaking(address(staking));
        nft.setRoyaltyReceiver(address(splitter));
        nft.setBaseURI(BASE_URI);
        vm.stopBroadcast();

        console.log("OWNER     ", owner);
        console.log("TREASURY  ", address(treasury));
        console.log("NFT       ", address(nft));
        console.log("STAKING   ", address(staking));
        console.log("LENDING   ", address(lending));
        console.log("RENTAL    ", address(rental));
        console.log("YIELD     ", address(yieldTreasury));
        console.log("SPLITTER  ", address(splitter));
    }
}
