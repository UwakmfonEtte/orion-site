// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionTestNFT} from "../src/OrionTestNFT.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";
import {OrionStaking} from "../src/OrionStaking.sol";
import {OrionRental} from "../src/OrionRental.sol";
import {OrionYieldTreasury} from "../src/OrionYieldTreasury.sol";

/// Points move in whole completed days (100 per Orion per 24h) and only for
/// staked Orions; renting earns none. Real 86400-second days throughout.
contract PointsTest is Test {
    OrionTestNFT nft;
    OrionTreasury treasury;
    OrionStaking staking;
    OrionRental rental;
    OrionYieldTreasury yieldT;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant PRICE = 0.1 ether;
    uint256 constant DAY = 86400;

    function setUp() public {
        vm.warp(1_000_000);
        treasury = new OrionTreasury(owner);
        nft = new OrionTestNFT(owner, payable(address(treasury)), PRICE, 50, 5);
        yieldT = new OrionYieldTreasury(owner);
        staking = new OrionStaking(address(nft), DAY, address(yieldT));
        rental = new OrionRental(owner, address(nft), address(treasury), DAY);

        vm.startPrank(owner);
        treasury.setNftContract(address(nft));
        treasury.setDonationSink(payable(owner));
        treasury.setRentalModule(address(rental));
        yieldT.setStaking(address(staking));
        vm.stopPrank();

        address[4] memory who = [alice, bob, carol, owner];
        for (uint256 i = 0; i < 4; i++) {
            vm.deal(who[i], 100 ether);
            vm.prank(who[i]);
            nft.mint{value: PRICE * 3}(3);       // alice 1-3, bob 4-6, carol 7-9, owner 10-12
        }
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _stake(address who, uint256[] memory ids) internal {
        vm.startPrank(who);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(ids);
        vm.stopPrank();
    }

    function _unstake(address who, uint256[] memory ids) internal {
        vm.prank(who);
        staking.unstake(ids);
    }

    function _profit(uint256 amount) internal {
        vm.deal(address(yieldT), address(yieldT).balance + amount);
        vm.prank(owner);
        yieldT.distributeProfit(amount);
    }

    // ===================================================================
    // Staking points: whole days only
    // ===================================================================

    function test_nothingForTheFirstDayThenExactlyOneHundred() public {
        _stake(alice, _ids(1));
        assertEq(staking.pointsOf(alice), 0);
        skip(1);
        assertEq(staking.pointsOf(alice), 0);
        skip(DAY - 2);                                    // 1 second short of 24h
        assertEq(staking.pointsOf(alice), 0);
        skip(1);                                          // exactly 24h
        assertEq(staking.pointsOf(alice), 100e18);
    }

    function test_pointsDoNotTickBetweenDays() public {
        _stake(alice, _ids(1));
        skip(DAY);
        uint256 atOneDay = staking.pointsOf(alice);
        for (uint256 i = 0; i < 10; i++) {
            skip(DAY / 11);                               // ten more samples inside the same day
            assertEq(staking.pointsOf(alice), atOneDay);
        }
        skip(DAY);                                        // well past 2 days now
        assertEq(staking.pointsOf(alice), 200e18);
    }

    function test_oneHundredPerOrionPerDay() public {
        _stake(alice, _ids(1, 2));
        skip(3 * DAY + DAY / 2);
        assertEq(staking.pointsOf(alice), 600e18);        // 2 Orions x 3 whole days x 100
    }

    function test_theLastWholeDayCountsAtTheSecond() public {
        _stake(alice, _ids(1));
        skip(7 * DAY - 1);
        assertEq(staking.pointsOf(alice), 600e18);
        skip(1);
        assertEq(staking.pointsOf(alice), 700e18);
    }

    function test_unstakingClaimsTheWholeDaysAndDropsThePartialOne() public {
        _stake(alice, _ids(1));
        skip(2 * DAY + DAY / 2);
        _unstake(alice, _ids(1));
        assertEq(staking.pointsClaimed(alice), 200e18);   // two whole days claimed, the half day dropped
        assertEq(staking.pointsOf(alice), 0);
        skip(5 * DAY);
        assertEq(staking.pointsOf(alice), 0);             // not staking, so nothing grows
    }

    function test_unstakingJustBeforeTheDayEndsEarnsNothingForIt() public {
        _stake(alice, _ids(1));
        skip(DAY - 1);
        _unstake(alice, _ids(1));
        assertEq(staking.pointsOf(alice), 0);
    }

    function test_addingAnOrionBanksWholeDaysAndRestartsTheDay() public {
        _stake(alice, _ids(1));
        skip(DAY + DAY / 2);                              // 1.5 days: one day banked
        _stake(alice, _ids(2));
        assertEq(staking.pointsOf(alice), 100e18);
        skip(DAY - 1);
        assertEq(staking.pointsOf(alice), 100e18);        // the new Orion has not done a day yet
        skip(1);
        assertEq(staking.pointsOf(alice), 100e18 + 200e18);
    }

    function test_neverMorePointsThanOneHundredPerOrionPerElapsedDay() public {
        // however stake and unstake are interleaved, credit never beats the raw clock
        uint256 start = block.timestamp;
        for (uint256 i = 0; i < 30; i++) {
            _stake(alice, _ids(1));
            skip(DAY / 3 + i * 17);
            _stake(alice, _ids(2));
            skip(DAY / 2 + i * 31);
            _unstake(alice, _ids(1));
            skip(DAY / 5);
            _unstake(alice, _ids(2));
            skip(DAY / 7);
            assertLe(staking.pointsOf(alice), 2 * ((block.timestamp - start) / DAY) * 100e18);
        }
    }

    function test_restakingStartsFromZeroAndTheClaimedPointsAreRemembered() public {
        _stake(alice, _ids(1));
        skip(2 * DAY);
        _unstake(alice, _ids(1));
        skip(10 * DAY);
        _stake(alice, _ids(1));
        assertEq(staking.pointsOf(alice), 0);
        skip(DAY);
        assertEq(staking.pointsOf(alice), 100e18);
        skip(2 * DAY);
        _unstake(alice, _ids(1));
        assertEq(staking.pointsClaimed(alice), 200e18 + 300e18);   // both stints, added up
    }

    // ===================================================================
    // Rewards follow the whole-day points, and never over-pay
    // ===================================================================

    function test_rewardsAreSharedByWholeDayPoints() public {
        _stake(alice, _ids(1));                           // staked since t0
        skip(2 * DAY);
        _stake(bob, _ids(4));
        skip(DAY + DAY / 2);                              // alice 3 days (300), bob 1 day (100, half a day dropped)
        _profit(4 ether);
        assertEq(staking.pointsOf(alice), 300e18);
        assertEq(staking.pointsOf(bob), 100e18);
        assertEq(staking.pendingRewards(alice), 3 ether);
        assertEq(staking.pendingRewards(bob), 1 ether);
    }

    function test_someoneWithNoCompletedDayGetsNothingAndTheRestIsNotLost() public {
        _stake(alice, _ids(1));
        skip(2 * DAY);
        _stake(bob, _ids(4));
        skip(DAY / 2);
        _profit(1 ether);
        assertEq(staking.pendingRewards(bob), 0);
        assertEq(staking.pendingRewards(alice), 1 ether);   // all of it: she is the only one with points
    }

    function test_distributingWithNoPointsAtAllIsRefused() public {
        _stake(alice, _ids(1));
        skip(DAY / 2);
        vm.deal(address(yieldT), 1 ether);
        vm.prank(owner);
        vm.expectRevert("no points yet");
        yieldT.distributeProfit(1 ether);
    }

    function test_payoutsAddUpToWhatWasPutInAcrossMessyTiming() public {
        address[3] memory who = [alice, bob, carol];
        uint256[3] memory start = [alice.balance, bob.balance, carol.balance];
        _stake(alice, _ids(1, 2));
        skip(3 * DAY + 5000);
        _stake(bob, _ids(4));
        skip(2 * DAY + 77);
        _stake(carol, _ids(7, 8));
        skip(DAY + DAY / 3);
        _profit(7 ether + 13);
        skip(2 * DAY + 11);
        _unstake(alice, _ids(1));
        skip(DAY);
        _profit(3 ether + 1);
        uint256 total;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(who[i]);
            try staking.claim(100) {} catch {}                // alice may have nothing left: unstaking paid her
            total += who[i].balance - start[i];               // everything received, including on unstake
        }
        assertLe(total, 10 ether + 14);
        assertGe(total, 10 ether + 14 - 100);
    }

    function test_theStakerListTracksJoinsAndExits() public {
        assertEq(staking.stakerCount(), 0);
        _stake(alice, _ids(1));
        _stake(bob, _ids(4));
        _stake(carol, _ids(7));
        _stake(alice, _ids(2));                           // already in the list: no second entry
        assertEq(staking.stakerCount(), 3);
        _unstake(alice, _ids(1));                         // still staking one
        assertEq(staking.stakerCount(), 3);
        _unstake(alice, _ids(2));                         // gone
        assertEq(staking.stakerCount(), 2);
        _unstake(carol, _ids(7));
        assertEq(staking.stakerCount(), 1);
        skip(DAY);
        assertEq(staking.eligiblePoints(), staking.pointsOf(bob));
        _unstake(bob, _ids(4));
        assertEq(staking.stakerCount(), 0);
        assertEq(staking.eligiblePoints(), 0);
    }

    // ===================================================================
    // Renting earns no points
    // ===================================================================

    function _listAndRent(address renter, uint256 id, uint256 term) internal {
        vm.prank(owner);
        nft.closeMint();
        vm.startPrank(owner);
        nft.setApprovalForAll(address(rental), true);
        rental.list(id);
        vm.stopPrank();
        uint256 cost = rental.rentCost(term);
        vm.prank(renter);
        rental.rent{value: cost}(id, term);
    }

    function test_rentingEarnsNoPointsAtAll() public {
        _listAndRent(alice, 10, 30);
        skip(10 * DAY);
        assertEq(staking.pointsOf(alice), 0);
        assertEq(staking.eligiblePoints(), 0);
        skip(30 * DAY);
        assertEq(staking.pointsOf(alice), 0);
        assertEq(rental.rentalsBy(alice), 1);
    }

    function test_theRentTermIsRealDays() public {
        _listAndRent(alice, 10, 30);
        (, , uint256 start, uint256 until) = rental.slots(10);
        assertEq(until - start, 30 * DAY);
        assertEq(until - start, 2_592_000);
        assertTrue(rental.isActive(10));
        skip(30 * DAY - 1);
        assertTrue(rental.isActive(10));
        skip(1);
        assertFalse(rental.isActive(10));
    }

    // ===================================================================
    // The public testnet: 2 Orions
    // ===================================================================

    function test_twoOrionsThenItIsSoldOut() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), 0.001 ether, 2, 2);
        vm.prank(owner);
        t2.setNftContract(address(n2));
        assertEq(n2.MAX_SUPPLY(), 2);
        assertEq(n2.MAX_PER_WALLET(), 2);
        assertFalse(n2.mintClosed());

        vm.prank(alice);
        n2.mint{value: 0.001 ether}(1);
        assertEq(n2.remainingSupply(), 1);
        assertFalse(n2.mintClosed());

        vm.prank(bob);
        n2.mint{value: 0.001 ether}(1);
        assertEq(n2.remainingSupply(), 0);
        assertTrue(n2.mintClosed());                      // minted out closes the mint by itself
        assertEq(n2.ownerOf(1), alice);
        assertEq(n2.ownerOf(2), bob);

        vm.prank(carol);
        vm.expectRevert("not enough left");
        n2.mint{value: 0.001 ether}(1);
    }

    function test_oneWalletCanTakeBothButNotThree() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), 0.001 ether, 2, 2);
        vm.prank(owner);
        t2.setNftContract(address(n2));
        vm.prank(alice);
        vm.expectRevert("wallet limit reached");
        n2.mint{value: 0.003 ether}(3);
        vm.prank(alice);
        n2.mint{value: 0.002 ether}(2);
        assertTrue(n2.mintClosed());
        assertEq(address(t2).balance, 0.002 ether);
    }

    function test_zeroLimitsAreRefused() public {
        vm.expectRevert("bad limits");
        new OrionTestNFT(owner, payable(address(treasury)), PRICE, 0, 2);
        vm.expectRevert("bad limits");
        new OrionTestNFT(owner, payable(address(treasury)), PRICE, 2, 0);
    }
}
