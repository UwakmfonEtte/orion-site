// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionTestNFT} from "../src/OrionTestNFT.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";
import {OrionLending} from "../src/OrionLending.sol";
import {OrionRental} from "../src/OrionRental.sol";

/// The public testnet exactly as deployed: price 0.001 ETH, 50 Orions, 2 per
/// wallet (two are minted here and the owner closes the mint), real
/// 86400-second days. Every figure is written out by hand, so a change to any
/// formula shows up here as a number that no longer matches.
contract TestnetNumbersTest is Test {
    OrionTestNFT nft;
    OrionTreasury treasury;
    OrionLending lending;
    OrionRental rental;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant PRICE = 0.001 ether;
    uint256 constant DAY = 86400;

    function setUp() public {
        vm.warp(1_700_000_000);
        treasury = new OrionTreasury(owner);
        nft = new OrionTestNFT(owner, payable(address(treasury)), PRICE, 50, 2);
        lending = new OrionLending(address(nft), address(treasury), DAY);
        rental = new OrionRental(owner, address(nft), address(treasury), DAY);
        vm.startPrank(owner);
        treasury.setNftContract(address(nft));
        treasury.setDonationSink(payable(owner));
        treasury.setLendingModule(address(lending));
        treasury.setRentalModule(address(rental));
        vm.stopPrank();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.prank(alice);
        nft.mint{value: PRICE}(1);
        vm.prank(bob);
        nft.mint{value: PRICE}(1);
        vm.prank(owner);
        nft.closeMint();                                 // 2 minted, mint closed by the team
    }

    function test_theBackingNumbers() public view {
        assertEq(address(treasury).balance, 0.002 ether);
        assertEq(treasury.totalAssets(), 0.002 ether);
        assertEq(treasury.backingPerToken(), 0.001 ether);
        assertEq(treasury.redeemValue(), 0.00095 ether);          // 0.001 less the 5% fee (0.00005)
        assertEq(lending.maxBorrow(), 0.00095 ether);
    }

    function test_theThirtyDayLoanToTheWei() public {
        uint256 principal = 0.00095 ether;                       // 950_000_000_000_000
        // interest = 950e12 * 500 * 30 / (365 * 10000) = 3_904_109_589_041 (rounded down)
        assertEq(lending.interestFor(principal, 30), 3_904_109_589_041);
        assertEq(lending.payoutFor(principal, 30), 950_000_000_000_000 - 3_904_109_589_041);
        // 90 and 180 days
        assertEq(lending.interestFor(principal, 90), 11_712_328_767_123);
        assertEq(lending.interestFor(principal, 180), 23_424_657_534_246);

        uint256 before = alice.balance;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(lending), true);
        lending.borrow(1, 30, principal);
        vm.stopPrank();

        assertEq(alice.balance - before, 946_095_890_410_959);   // she receives principal less interest
        (, uint256 owedP, uint256 interest, uint256 due, bool open) = lending.loans(1);
        assertEq(owedP, principal);
        assertEq(interest, 3_904_109_589_041);
        assertEq(due, block.timestamp + 30 days);
        assertEq(due - block.timestamp, 2_592_000);              // 30 real days, in seconds
        assertTrue(open);
        assertEq(lending.owed(1), principal);                    // repaying costs the principal, nothing more
        assertEq(treasury.loansOutstanding(), principal);
        assertEq(treasury.totalAssets(), 0.002 ether + 3_904_109_589_041);   // the interest already lifted assets
        assertEq(address(treasury).balance, 0.002 ether - 946_095_890_410_959);
    }

    function test_repayingGivesTheOrionBack() public {
        uint256 principal = 0.00095 ether;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(lending), true);
        lending.borrow(1, 30, principal);
        skip(10 days);
        lending.repay{value: principal}(1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), alice);
        assertEq(treasury.loansOutstanding(), 0);
        assertEq(treasury.totalAssets(), 0.002 ether + 3_904_109_589_041);
    }

    function test_nothingCanBeLiquidatedUntilDuePlusThreeDays() public {
        uint256 principal = 0.00095 ether;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(lending), true);
        lending.borrow(1, 30, principal);
        vm.stopPrank();
        skip(33 days);                                           // due + 3 days exactly: still inside the grace
        vm.expectRevert("not past the grace period");
        lending.liquidate(1);
        skip(1);
        lending.liquidate(1);
        assertEq(nft.ownerOf(1), 0x000000000000000000000000000000000000dEaD);
    }

    function test_aSecondLoanIsRefusedByTheFiftyPercentCap() public {
        uint256 principal = 0.00095 ether;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(lending), true);
        lending.borrow(1, 30, principal);
        vm.stopPrank();
        vm.startPrank(bob);
        nft.setApprovalForAll(address(lending), true);
        vm.expectRevert("utilization cap");
        lending.borrow(2, 30, principal);
        vm.stopPrank();
    }

    function test_redeemPaysTheShareLessFiveNotTheFullPrice() public {
        uint256 before = alice.balance;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(treasury), true);
        treasury.redeem(1);
        vm.stopPrank();
        assertEq(alice.balance - before, 0.00095 ether);
        assertEq(treasury.totalAssets(), 0.00105 ether);         // the 0.00005 fee stays for the last holder
        assertEq(treasury.redeemValue(), 0.0009975 ether);       // 0.00105 x 95%
    }

    function test_rentCostsTenPercentOfBackingPer30Days() public {
        // backing is 0.001, so 30 days = 0.0001, 90 days = 0.0003, 7 days = 0.0001 * 7/30
        assertEq(rental.rentCost(30), 0.0001 ether);
        assertEq(rental.rentCost(90), 0.0003 ether);
        assertEq(rental.rentCost(7), 23_333_333_333_333);
    }

    // ---- the 50 / 2 limits ------------------------------------------------

    function test_supplyIsFiftyAndTwoPerWallet() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 2);
        vm.prank(owner);
        t2.setNftContract(address(n2));
        assertEq(n2.MAX_SUPPLY(), 50);
        assertEq(n2.MAX_PER_WALLET(), 2);
        for (uint160 i = 1; i <= 25; i++) {             // 25 wallets x 2 = 50
            address w = address(i + 5000);
            vm.deal(w, 1 ether);
            vm.prank(w);
            n2.mint{value: PRICE * 2}(2);
        }
        assertEq(n2.totalMinted(), 50);
        assertTrue(n2.mintClosed());                     // sold out closes it
        address late = address(9999);
        vm.deal(late, 1 ether);
        vm.prank(late);
        vm.expectRevert("not enough left");
        n2.mint{value: PRICE}(1);
    }

    function test_aWalletCannotTakeThree() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 2);
        vm.prank(owner);
        t2.setNftContract(address(n2));
        vm.deal(carol, 1 ether);
        vm.startPrank(carol);
        vm.expectRevert("wallet limit reached");
        n2.mint{value: PRICE * 3}(3);
        n2.mint{value: PRICE}(1);
        n2.mint{value: PRICE}(1);
        vm.expectRevert("wallet limit reached");
        n2.mint{value: PRICE}(1);
        vm.stopPrank();
        assertEq(n2.mintedBy(carol), 2);
    }

    // ---- per-wallet history ---------------------------------------------------

    function test_theHistoryCountersFollowWhatAWalletDoes() public {
        uint256 principal = 0.00095 ether;
        assertEq(nft.mintedBy(alice), 1);
        assertEq(nft.balanceOf(alice), 1);

        vm.startPrank(alice);
        nft.setApprovalForAll(address(lending), true);
        lending.borrow(1, 30, principal);
        assertEq(nft.balanceOf(alice), 0);               // the token left her wallet...
        assertEq(nft.mintedBy(alice), 1);                // ...but "minted" does not forget it
        assertEq(lending.borrowsBy(alice), 1);
        lending.repay{value: principal}(1);
        vm.stopPrank();
        assertEq(lending.repaymentsBy(alice), 1);
        assertEq(nft.balanceOf(alice), 1);

        vm.startPrank(alice);
        nft.setApprovalForAll(address(treasury), true);
        treasury.redeem(1);
        vm.stopPrank();
        assertEq(treasury.redeemedBy(alice), 1);
        assertEq(treasury.redeemedBy(bob), 0);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.mintedBy(alice), 1);
    }

    function test_aStrangerPayingTheLoanCreditsTheBorrower() public {
        uint256 principal = 0.00095 ether;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(lending), true);
        lending.borrow(1, 30, principal);
        vm.stopPrank();
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        lending.repay{value: principal}(1);
        assertEq(lending.repaymentsBy(alice), 1);
        assertEq(lending.repaymentsBy(carol), 0);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_aLiquidatedLoanIsRecordedAgainstTheBorrower() public {
        uint256 principal = 0.00095 ether;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(lending), true);
        lending.borrow(1, 30, principal);
        vm.stopPrank();
        skip(33 days + 1);
        vm.prank(bob);
        lending.liquidate(1);
        assertEq(lending.liquidatedOf(alice), 1);
        assertEq(lending.liquidatedOf(bob), 0);
        assertEq(lending.repaymentsBy(alice), 0);
        assertEq(nft.mintedBy(alice), 1);
        assertEq(nft.balanceOf(alice), 0);
    }

    function test_rentalsAreCountedPerRenter() public {
        vm.startPrank(owner);
        nft.setApprovalForAll(address(rental), true);
        vm.stopPrank();
        // the owner holds no Orion here, so give them bob's
        vm.prank(bob);
        nft.transferFrom(bob, owner, 2);
        vm.prank(owner);
        rental.list(2);
        uint256 cost = rental.rentCost(7);
        vm.prank(alice);
        rental.rent{value: cost}(2, 7);
        assertEq(rental.rentalsBy(alice), 1);
        assertEq(rental.rentalsBy(bob), 0);
    }
}
