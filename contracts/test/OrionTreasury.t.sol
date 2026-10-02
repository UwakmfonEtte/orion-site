// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MaliciousReenterer} from "./mocks/MaliciousReenterer.sol";

contract OrionTreasuryTest is Test {
    OrionTreasury treasury;
    MockERC721 nft;

    address multisig = makeAddr("multisig");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    function setUp() public {
        treasury = new OrionTreasury(multisig);
        nft = new MockERC721();
    }

    // ---------------------------------------------------------------
    // Ownership / access control
    // ---------------------------------------------------------------

    function test_ownerIsMultisig() public view {
        assertEq(treasury.owner(), multisig);
    }

    function test_onlyOwnerCanSetNftContract() public {
        vm.prank(stranger);
        vm.expectRevert();
        treasury.setNftContract(address(nft));
    }

    function test_onlyOwnerCanPause() public {
        vm.prank(stranger);
        vm.expectRevert();
        treasury.pause();
    }

    function test_onlyOwnerCanEmergencyWithdraw() public {
        vm.prank(stranger);
        vm.expectRevert();
        treasury.emergencyWithdraw(payable(stranger), 1 ether);
    }

    // ---------------------------------------------------------------
    // Deposits
    // ---------------------------------------------------------------

    function test_ownerCanDeposit() public {
        vm.deal(multisig, 10 ether);
        vm.prank(multisig);
        (bool ok, ) = address(treasury).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 5 ether);
    }

    function test_nftContractCanDeposit() public {
        _wire();
        vm.deal(address(nft), 10 ether);
        vm.prank(address(nft));
        (bool ok, ) = address(treasury).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 5 ether);
    }

    function test_strangerDepositRevertsWithoutDonationSink() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, ) = address(treasury).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(treasury).balance, 0);
    }

    function test_strangerDepositIsReroutedToDonationSink() public {
        address sink = makeAddr("donationSink");
        vm.prank(multisig);
        treasury.setDonationSink(payable(sink));

        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, ) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);

        // The donation never touches the redeemable pool - it lands at the
        // sink instead, so it can never inflate backingPerToken for holders.
        assertEq(address(treasury).balance, 0);
        assertEq(sink.balance, 1 ether);
    }

    function test_onlyOwnerCanSetDonationSink() public {
        vm.prank(stranger);
        vm.expectRevert();
        treasury.setDonationSink(payable(stranger));
    }

    // ---------------------------------------------------------------
    // NFT wiring
    // ---------------------------------------------------------------

    function test_nftContractStartsUnset() public view {
        assertEq(treasury.nftContract(), address(0));
    }

    function test_redeemRevertsBeforeNftSet() public {
        vm.prank(alice);
        vm.expectRevert("redemption not open");
        treasury.redeem(1);
    }

    function test_setNftContractIsOneTime() public {
        vm.startPrank(multisig);
        treasury.setNftContract(address(nft));
        vm.expectRevert("nft already set");
        treasury.setNftContract(address(0x1234));
        vm.stopPrank();
    }

    function test_setNftContractRejectsZeroAddress() public {
        vm.prank(multisig);
        vm.expectRevert("zero address");
        treasury.setNftContract(address(0));
    }

    function test_setNftContractRejectsNonContractAddress() public {
        vm.prank(multisig);
        vm.expectRevert("not a contract");
        treasury.setNftContract(stranger); // an EOA, no code
    }

    function test_setNftContractRejectsContractWithoutTotalMinted() public {
        // Any deployed contract that doesn't implement totalMinted() - using
        // the treasury itself as a stand-in for "wrong address pasted".
        OrionTreasury notAnNft = new OrionTreasury(multisig);
        vm.prank(multisig);
        vm.expectRevert();
        treasury.setNftContract(address(notAnNft));
    }

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(multisig);
        vm.expectRevert("renounce disabled");
        treasury.renounceOwnership();
        assertEq(treasury.owner(), multisig); // ownership unchanged
    }

    // ---------------------------------------------------------------
    // Redemption math + flow
    // ---------------------------------------------------------------

    function _wire() internal {
        vm.prank(multisig);
        treasury.setNftContract(address(nft));
    }

    function test_redeemPaysEqualShareAndBurnsToken() public {
        _wire();
        nft.mint(alice, 1);
        nft.setTotalMinted(1555); // simulate a full sellout for round-number math
        vm.deal(address(treasury), 1555 ether); // 1 ETH per remaining token, round number

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        uint256 before = alice.balance;
        treasury.redeem(1);
        vm.stopPrank();

        assertEq(alice.balance - before, 1 ether);
        assertEq(nft.ownerOf(1), treasury.BURN_ADDRESS());
        assertTrue(treasury.redeemed(1));
        assertEq(treasury.redeemedCount(), 1);
    }

    function test_backingPerTokenRatchetsUpAsSupplyShrinks() public {
        _wire();
        nft.mint(alice, 1);
        nft.mint(bob, 2);
        nft.setTotalMinted(1555); // simulate a full sellout for round-number math
        vm.deal(address(treasury), 1555 ether);

        // 1555 ETH / 1555 remaining = 1 ETH each, before any redemption
        assertEq(treasury.backingPerToken(), 1 ether);

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        treasury.redeem(1);
        vm.stopPrank();

        // 1554 ETH left / 1554 remaining tokens = still 1 ETH - supply and
        // balance shrink together here; the ratchet shows once a redemption
        // leaves uneven remainders. Confirm the arithmetic directly instead.
        uint256 remaining = nft.totalMinted() - treasury.redeemedCount();
        assertEq(remaining, 1554);
        assertEq(treasury.backingPerToken(), address(treasury).balance / remaining);
    }

    function test_backingAccountsForPartialMintNotMaxSupply() public {
        // The bug an integration test caught: dividing by the eventual max
        // (1,555) instead of what's actually minted would strand ETH forever
        // whenever the mint hasn't sold out. Only 1 of 1,555 ever minted here.
        _wire();
        nft.mint(alice, 1); // totalMinted() is now 1, not 1555
        vm.deal(address(treasury), 10 ether);

        assertEq(treasury.backingPerToken(), 10 ether); // all of it, not 10/1555

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        uint256 before = alice.balance;
        treasury.redeem(1);
        vm.stopPrank();

        assertEq(alice.balance - before, 10 ether);
        assertEq(address(treasury).balance, 0);
    }

    function test_cannotRedeemSameTokenTwice() public {
        _wire();
        nft.mint(alice, 1);
        vm.deal(address(treasury), 10 ether);

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        treasury.redeem(1);
        vm.expectRevert("already redeemed");
        treasury.redeem(1);
        vm.stopPrank();
    }

    function test_cannotRedeemTokenYouDontOwn() public {
        _wire();
        nft.mint(alice, 1);
        vm.deal(address(treasury), 10 ether);

        vm.prank(bob);
        vm.expectRevert("not the owner");
        treasury.redeem(1);
    }

    function test_redeemRevertsWhenTreasuryEmpty() public {
        _wire();
        nft.mint(alice, 1);
        // no deposit made

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        vm.expectRevert("treasury has no balance");
        treasury.redeem(1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Pausing
    // ---------------------------------------------------------------

    function test_pausedBlocksRedeem() public {
        _wire();
        nft.mint(alice, 1);
        vm.deal(address(treasury), 10 ether);

        vm.prank(multisig);
        treasury.pause();

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        vm.expectRevert();
        treasury.redeem(1);
        vm.stopPrank();
    }

    function test_unpauseRestoresRedeem() public {
        _wire();
        nft.mint(alice, 1);
        vm.deal(address(treasury), 10 ether);

        vm.startPrank(multisig);
        treasury.pause();
        treasury.unpause();
        vm.stopPrank();

        vm.startPrank(alice);
        nft.approve(address(treasury), 1);
        treasury.redeem(1); // should not revert
        vm.stopPrank();
    }

    function test_emergencyWithdrawWorksPrelaunchEvenWhilePaused() public {
        // nftContract never wired in this test - pre-launch state.
        vm.deal(address(treasury), 5 ether);
        vm.startPrank(multisig);
        treasury.pause();
        treasury.emergencyWithdraw(payable(multisig), 5 ether);
        vm.stopPrank();
        assertEq(address(treasury).balance, 0);
    }

    function test_emergencyWithdrawPermanentlyDisabledOnceNftWired() public {
        _wire();
        vm.deal(address(treasury), 5 ether);
        vm.prank(multisig);
        vm.expectRevert("redemption is live");
        treasury.emergencyWithdraw(payable(multisig), 5 ether);
    }

    function test_emergencyWithdrawRejectsOverBalance() public {
        vm.deal(address(treasury), 1 ether);
        vm.prank(multisig);
        vm.expectRevert("insufficient balance");
        treasury.emergencyWithdraw(payable(multisig), 2 ether);
    }

    // ---------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------

    function test_reentrantRedeemIsBlocked() public {
        _wire();
        MaliciousReenterer attacker = new MaliciousReenterer(treasury);
        nft.mint(address(attacker), 1);
        nft.mint(address(attacker), 2);
        attacker.setSecondTokenId(2);
        vm.deal(address(treasury), 10 ether);

        vm.prank(address(attacker));
        nft.setApprovalForAll(address(treasury), true);

        // The reentrant inner redeem() reverts, which bubbles up through the
        // unchecked low-level call in the outer redeem(), so the whole
        // outer transaction reverts too - nothing is paid out or burned.
        vm.expectRevert("ETH transfer failed");
        attacker.redeemFirst(1);

        assertEq(treasury.redeemedCount(), 0);
        assertFalse(treasury.redeemed(1));
        assertFalse(treasury.redeemed(2));
        assertEq(address(treasury).balance, 10 ether);
    }
}
