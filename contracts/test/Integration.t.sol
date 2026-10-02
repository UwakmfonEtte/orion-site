// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionNFT} from "../src/OrionNFT.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";
import {MintReceiverReenterer} from "./mocks/MintReceiverReenterer.sol";

/// @notice Exercises the full real-world path: mint funds the treasury, then
///         a holder redeems their pass against it. The two contracts are
///         never tested together anywhere else.
contract IntegrationTest is Test {
    OrionNFT nft;
    OrionTreasury treasury;

    address multisig = makeAddr("multisig");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant PRICE = 0.004 ether;

    bytes32[] aliceProof;
    bytes32[] bobProof;

    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function setUp() public {
        treasury = new OrionTreasury(multisig);
        nft = new OrionNFT(multisig, payable(address(treasury)), PRICE);

        bytes32 leafA = _leaf(alice);
        bytes32 leafB = _leaf(bob);
        bytes32 root = leafA < leafB
            ? keccak256(abi.encodePacked(leafA, leafB))
            : keccak256(abi.encodePacked(leafB, leafA));

        aliceProof = new bytes32[](1);
        aliceProof[0] = leafB;
        bobProof = new bytes32[](1);
        bobProof[0] = leafA;

        vm.startPrank(multisig);
        nft.setMerkleRoot(root);
        treasury.setNftContract(address(nft));
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    function test_mintFundsTreasuryThenHolderRedeems() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);
        assertEq(address(treasury).balance, PRICE);

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        uint256 before = alice.balance;
        treasury.redeem(1);
        vm.stopPrank();

        // Alice is the only holder, so she gets the whole treasury back.
        assertEq(alice.balance - before, PRICE);
        assertEq(address(treasury).balance, 0);
        assertEq(nft.ownerOf(1), treasury.BURN_ADDRESS());
    }

    function test_twoMintsThenOneRedeemSplitsCorrectly() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);
        vm.prank(bob);
        nft.mint{value: PRICE}(bobProof);
        assertEq(address(treasury).balance, PRICE * 2);

        // 1,555-token max supply, but only 2 actually minted so far - backingPerToken
        // divides by what's actually minted (2), not the eventual max (1,555),
        // or the other 1,553 tokens' never-to-exist share would strand this ETH.
        uint256 remaining = nft.totalMinted() - treasury.redeemedCount();
        assertEq(remaining, 2);
        uint256 expectedPayout = (PRICE * 2) / remaining;

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        uint256 before = alice.balance;
        treasury.redeem(1);
        vm.stopPrank();

        assertEq(alice.balance - before, expectedPayout);
        assertEq(address(treasury).balance, PRICE * 2 - expectedPayout);
    }

    /// @notice Regression test for the fixed mint-order bug: a contract that
    ///         reenters redeem() from onERC721Received now sees the treasury
    ///         already paid for *this* mint, not a stale pre-payment balance.
    function test_reentrantRedeemDuringMintSeesFullySettledState() public {
        OrionTreasury t2 = new OrionTreasury(multisig);
        OrionNFT n2 = new OrionNFT(multisig, payable(address(t2)), PRICE);
        MintReceiverReenterer attacker = new MintReceiverReenterer(n2, t2);

        bytes32 leaf = _leaf(address(attacker));
        vm.startPrank(multisig);
        n2.setMerkleRoot(leaf); // single-leaf tree: root == leaf, empty proof
        t2.setNftContract(address(n2));
        vm.stopPrank();

        attacker.approveTreasuryForAll();
        vm.deal(address(attacker), 1 ether);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(address(attacker));
        attacker.doMint{value: PRICE}(emptyProof);

        assertTrue(attacker.reentered());
        // Treasury received exactly PRICE from this mint before the hook
        // fired, and this is the only token ever minted, so the reentrant
        // redeem() - seeing fully-settled state - pays out the whole thing,
        // identical to what a sequential mint-then-redeem would produce.
        assertEq(attacker.reentrantPayout(), PRICE);
        assertEq(address(t2).balance, 0);
    }

    function test_cannotRedeemBeforeNftWired() public {
        OrionTreasury freshTreasury = new OrionTreasury(multisig);
        OrionNFT freshNft = new OrionNFT(multisig, payable(address(freshTreasury)), PRICE);

        vm.prank(multisig);
        freshNft.setMerkleRoot(bytes32(uint256(1))); // irrelevant root, just needs to be non-zero
        vm.deal(address(freshTreasury), 1 ether);

        vm.prank(alice);
        vm.expectRevert("redemption not open");
        freshTreasury.redeem(1); // nftContract never set on this treasury
    }
}
