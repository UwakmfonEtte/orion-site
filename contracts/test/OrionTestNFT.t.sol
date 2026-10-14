// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionTestNFT} from "../src/OrionTestNFT.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";

contract OrionTestNFTTest is Test {
    OrionTestNFT nft;
    OrionTreasury treasury;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    uint256 constant PRICE = 0.001 ether;

    function setUp() public {
        treasury = new OrionTreasury(owner);
        nft = new OrionTestNFT(owner, payable(address(treasury)), PRICE, 50, 5);
        vm.startPrank(owner);
        treasury.setNftContract(address(nft));
        treasury.setDonationSink(payable(owner));
        vm.stopPrank();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    // ---- minting ---------------------------------------------------------

    function test_publicMintAnyoneCanMint() public {
        vm.prank(stranger);
        nft.mint{value: PRICE}(1);
        assertEq(nft.ownerOf(1), stranger);
        assertEq(nft.totalMinted(), 1);
    }

    function test_mintSeveralAssignsSequentialIds() public {
        vm.prank(alice);
        nft.mint{value: PRICE * 3}(3);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
        assertEq(nft.ownerOf(3), alice);
        assertEq(nft.mintedBy(alice), 3);
        vm.prank(bob);
        nft.mint{value: PRICE}(1);
        assertEq(nft.ownerOf(4), bob);
    }

    function test_everyWeiOfThePriceGoesToTheTreasury() public {
        vm.prank(alice);
        nft.mint{value: PRICE * 4}(4);
        assertEq(address(treasury).balance, PRICE * 4);
        assertEq(address(nft).balance, 0);
    }

    function test_overpaymentIsRefunded() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mint{value: PRICE + 0.5 ether}(1);
        assertEq(before - alice.balance, PRICE);
        assertEq(address(treasury).balance, PRICE);
    }

    function test_underpaymentReverts() public {
        vm.prank(alice);
        vm.expectRevert("insufficient payment");
        nft.mint{value: PRICE * 2 - 1}(2);
    }

    function test_zeroQuantityReverts() public {
        vm.prank(alice);
        vm.expectRevert("quantity is zero");
        nft.mint{value: 0}(0);
    }

    function test_walletLimitIsFivePerWalletInTotal() public {
        vm.startPrank(alice);
        nft.mint{value: PRICE * 3}(3);
        nft.mint{value: PRICE * 2}(2);
        vm.expectRevert("wallet limit reached");
        nft.mint{value: PRICE}(1);
        vm.stopPrank();
        assertEq(nft.mintedBy(alice), 5);
    }

    function test_cannotMintMoreThanFiveAtOnce() public {
        vm.prank(alice);
        vm.expectRevert("wallet limit reached");
        nft.mint{value: PRICE * 6}(6);
    }

    function test_supplyIsCappedAtFifty() public {
        // ten wallets x 5 = 50
        for (uint160 i = 1; i <= 10; i++) {
            address w = address(i + 1000);
            vm.deal(w, 1 ether);
            vm.prank(w);
            nft.mint{value: PRICE * 5}(5);
        }
        assertEq(nft.totalMinted(), 50);
        assertEq(nft.remainingSupply(), 0);

        address late = address(99999);
        vm.deal(late, 1 ether);
        vm.prank(late);
        vm.expectRevert("not enough left");
        nft.mint{value: PRICE}(1);
    }

    function test_partialFillRevertsWhenNotEnoughLeft() public {
        for (uint160 i = 1; i <= 9; i++) {
            address w = address(i + 1000);
            vm.deal(w, 1 ether);
            vm.prank(w);
            nft.mint{value: PRICE * 5}(5);
        }
        // 45 minted, 5 left: a buyer asking for 5 is fine, a second one is not.
        vm.prank(alice);
        nft.mint{value: PRICE * 5}(5);
        vm.prank(bob);
        vm.expectRevert("not enough left");
        nft.mint{value: PRICE}(1);
    }

    // ---- controls ---------------------------------------------------------

    function test_priceLocksAfterFirstMint() public {
        vm.prank(owner);
        nft.setMintPriceWei(0.002 ether);
        assertEq(nft.mintPriceWei(), 0.002 ether);

        vm.prank(alice);
        nft.mint{value: 0.002 ether}(1);

        vm.prank(owner);
        vm.expectRevert("mint already started");
        nft.setMintPriceWei(PRICE);
    }

    function test_onlyOwnerAdmin() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        nft.setMintPriceWei(1);
        vm.expectRevert();
        nft.setBaseURI("x");
        vm.expectRevert();
        nft.pause();
        vm.stopPrank();
    }

    function test_pausedBlocksMint() public {
        vm.prank(owner);
        nft.pause();
        vm.prank(alice);
        vm.expectRevert();
        nft.mint{value: PRICE}(1);
    }

    function test_renounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert("renounce disabled");
        nft.renounceOwnership();
    }

    function test_tokenURIUsesBase() public {
        vm.prank(owner);
        nft.setBaseURI("https://oriongqgc.space/testnet/meta/");
        vm.prank(alice);
        nft.mint{value: PRICE}(1);
        assertEq(nft.tokenURI(1), "https://oriongqgc.space/testnet/meta/1");
    }

    // ---- the whole loop: mint -> treasury -> redeem with the fee ----------

    function test_fullLoopMintThenRedeemKeepsTheFee() public {
        vm.prank(alice);
        nft.mint{value: PRICE * 2}(2);       // tokens 1,2
        vm.prank(bob);
        nft.mint{value: PRICE * 2}(2);       // tokens 3,4
        assertEq(address(treasury).balance, PRICE * 4);
        assertEq(treasury.backingPerToken(), PRICE);

        uint256 expected = treasury.redeemValue();    // 0.95 * PRICE
        assertEq(expected, PRICE - (PRICE * 500) / 10_000);

        // Redemption is shut while the mint is open; the owner closes it.
        vm.startPrank(alice);
        nft.setApprovalForAll(address(treasury), true);
        vm.expectRevert("mint still open");
        treasury.redeem(1);
        vm.stopPrank();
        vm.prank(owner);
        nft.closeMint();

        vm.startPrank(alice);
        nft.setApprovalForAll(address(treasury), true);
        uint256 before = alice.balance;
        treasury.redeem(1);
        vm.stopPrank();

        assertEq(alice.balance - before, expected);
        assertEq(nft.ownerOf(1), treasury.BURN_ADDRESS());
        // three Orions left sharing the treasury, each now backed by MORE than PRICE
        assertEq(address(treasury).balance, PRICE * 4 - expected);
        assertGt(treasury.backingPerToken(), PRICE);
    }

    function test_strangerETHIsReroutedNotPooled() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(1);
        uint256 backing = treasury.backingPerToken();

        uint256 ownerBefore = owner.balance;
        vm.prank(stranger);
        (bool ok, ) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(treasury.backingPerToken(), backing);   // unchanged
        assertEq(owner.balance - ownerBefore, 1 ether);  // went to the sink
    }

    // ---- closing the mint ---------------------------------------------------

    function test_ownerCanCloseTheMintAndNothingMintsAfter() public {
        assertFalse(nft.mintClosed());
        vm.prank(owner);
        nft.closeMint();
        assertTrue(nft.mintClosed());
        vm.prank(alice);
        vm.expectRevert("mint is closed");
        nft.mint{value: PRICE}(1);
    }

    function test_onlyOwnerCanCloseTheMint() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.closeMint();
    }

    function test_sellingOutClosesTheMintByItself() public {
        for (uint160 i = 1; i <= 10; i++) {
            address w = address(i + 1000);
            vm.deal(w, 1 ether);
            vm.prank(w);
            nft.mint{value: PRICE * 5}(5);
        }
        assertTrue(nft.mintClosed());
    }

    // ---- wiring ---------------------------------------------------------

    function test_mintRefusesAnUnwiredTreasury() public {
        OrionTreasury other = new OrionTreasury(owner);          // never wired to this nft
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(other)), PRICE, 50, 5);
        vm.prank(owner);
        other.setDonationSink(payable(owner));                   // the case that used to eat the money
        vm.prank(alice);
        vm.expectRevert("treasury not wired");
        n2.mint{value: PRICE}(1);
    }

    function test_ownershipTransferNeedsTheNewOwnerToAccept() public {
        vm.prank(owner);
        nft.transferOwnership(stranger);
        assertEq(nft.owner(), owner);
        vm.prank(stranger);
        nft.acceptOwnership();
        assertEq(nft.owner(), stranger);
    }
}
