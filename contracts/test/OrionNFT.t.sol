// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionNFT} from "../src/OrionNFT.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract OrionNFTTest is Test {
    OrionNFT nft;

    address multisig = makeAddr("multisig");
    address payable treasury = payable(makeAddr("treasury"));

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger"); // not on the allowlist

    bytes32[] aliceProof;
    bytes32[] bobProof;
    bytes32 root;

    uint256 constant PRICE = 0.004 ether; // stand-in for "$12 worth of ETH"

    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    /// @dev Tiny 2-leaf tree so proofs are hand-computable: root = hash(leafA, leafB) sorted.
    function _buildTwoLeafTree(address a, address b) internal pure returns (bytes32 rootOut, bytes32[] memory proofA, bytes32[] memory proofB) {
        bytes32 leafA = _leaf(a);
        bytes32 leafB = _leaf(b);
        rootOut = leafA < leafB ? keccak256(abi.encodePacked(leafA, leafB)) : keccak256(abi.encodePacked(leafB, leafA));
        proofA = new bytes32[](1);
        proofA[0] = leafB;
        proofB = new bytes32[](1);
        proofB[0] = leafA;
    }

    function setUp() public {
        (root, aliceProof, bobProof) = _buildTwoLeafTree(alice, bob);
        nft = new OrionNFT(multisig, treasury, PRICE);
        vm.prank(multisig);
        nft.setMerkleRoot(root);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(stranger, 1 ether);
    }

    // ---------------------------------------------------------------
    // Basic mint flow
    // ---------------------------------------------------------------

    function test_allowlistedCanMint() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.totalMinted(), 1);
        assertTrue(nft.hasMinted(alice));
    }

    function test_mintForwardsExactPriceToTreasury() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);
        assertEq(treasury.balance, PRICE);
    }

    function test_overpaymentIsRefunded() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mint{value: PRICE + 0.01 ether}(aliceProof);
        // spent exactly PRICE (plus gas, untracked here) - refund returned the rest
        assertEq(before - alice.balance, PRICE);
        assertEq(treasury.balance, PRICE);
    }

    function test_tokenIdsStartAtOne() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);
        vm.prank(bob);
        nft.mint{value: PRICE}(bobProof);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), bob);
    }

    // ---------------------------------------------------------------
    // Allowlist enforcement
    // ---------------------------------------------------------------

    function test_nonAllowlistedCannotMint() public {
        vm.prank(stranger);
        vm.expectRevert("not on allowlist");
        nft.mint{value: PRICE}(aliceProof); // wrong proof for this address too
    }

    function test_cannotReuseSomeoneElsesProof() public {
        vm.prank(bob);
        vm.expectRevert("not on allowlist");
        nft.mint{value: PRICE}(aliceProof);
    }

    function test_mintRevertsWhenRootUnset() public {
        OrionNFT fresh = new OrionNFT(multisig, treasury, PRICE);
        vm.prank(alice);
        vm.expectRevert("allowlist not set");
        fresh.mint{value: PRICE}(aliceProof);
    }

    // ---------------------------------------------------------------
    // One mint per address
    // ---------------------------------------------------------------

    function test_cannotMintTwice() public {
        vm.startPrank(alice);
        nft.mint{value: PRICE}(aliceProof);
        vm.expectRevert("already minted");
        nft.mint{value: PRICE}(aliceProof);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Payment
    // ---------------------------------------------------------------

    function test_underpaymentReverts() public {
        vm.prank(alice);
        vm.expectRevert("insufficient payment");
        nft.mint{value: PRICE - 1}(aliceProof);
    }

    // ---------------------------------------------------------------
    // Owner controls
    // ---------------------------------------------------------------

    function test_onlyOwnerCanSetMintPrice() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.setMintPriceWei(1 ether);
    }

    function test_mintPriceCanBeAdjustedBeforeFirstMint() public {
        vm.startPrank(multisig);
        nft.setMintPriceWei(1 ether); // still pre-launch, should be fine
        vm.stopPrank();
        assertEq(nft.mintPriceWei(), 1 ether);
    }

    function test_mintPriceLocksAfterFirstMint() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);

        vm.prank(multisig);
        vm.expectRevert("mint already started");
        nft.setMintPriceWei(1 ether);
    }

    function test_onlyOwnerCanSetMerkleRoot() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.setMerkleRoot(bytes32(uint256(1)));
    }

    function test_onlyOwnerCanSetBaseURI() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.setBaseURI("ipfs://evil/");
    }

    function test_onlyOwnerCanPause() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.pause();
    }

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(multisig);
        vm.expectRevert("renounce disabled");
        nft.renounceOwnership();
        assertEq(nft.owner(), multisig);
    }

    function test_tokenURIUsesBaseURI() public {
        vm.prank(multisig);
        nft.setBaseURI("ipfs://CID/");
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);
        assertEq(nft.tokenURI(1), "ipfs://CID/1");
    }

    // ---------------------------------------------------------------
    // Pausing
    // ---------------------------------------------------------------

    function test_pausedBlocksMint() public {
        vm.prank(multisig);
        nft.pause();
        vm.prank(alice);
        vm.expectRevert();
        nft.mint{value: PRICE}(aliceProof);
    }

    // ---------------------------------------------------------------
    // Supply cap
    // ---------------------------------------------------------------

    function test_remainingSupplyTracksMints() public {
        assertEq(nft.remainingSupply(), 1555);
        vm.prank(alice);
        nft.mint{value: PRICE}(aliceProof);
        assertEq(nft.remainingSupply(), 1554);
    }

    function test_cannotMintPastMaxSupply() public {
        // Drive totalMinted to MAX_SUPPLY via storage cheat (minting 1555 real
        // allowlisted addresses would dominate this test's runtime for no
        // extra signal - the boundary check is what's under test).
        vm.store(address(nft), bytes32(uint256(9)), bytes32(uint256(1555))); // totalMinted slot (verified via `forge inspect OrionNFT storage-layout`)
        vm.prank(alice);
        vm.expectRevert("sold out");
        nft.mint{value: PRICE}(aliceProof);
    }
}
