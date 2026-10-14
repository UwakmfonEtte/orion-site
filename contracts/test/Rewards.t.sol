// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionTestNFT} from "../src/OrionTestNFT.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";
import {OrionStaking} from "../src/OrionStaking.sol";
import {OrionYieldTreasury} from "../src/OrionYieldTreasury.sol";
import {OrionRoyaltySplitter} from "../src/OrionRoyaltySplitter.sol";

/// @dev A staker that tries to re-enter claim or unstake while its reward is being paid.
contract HostileClaimer {
    OrionStaking public staking;
    OrionTestNFT public nft;
    uint256 public id;
    uint8 public mode;   // 1 = claim again, 2 = unstake

    constructor(OrionStaking s, OrionTestNFT n) {
        staking = s;
        nft = n;
    }

    function stakeIt(uint256 tokenId) external {
        id = tokenId;
        nft.setApprovalForAll(address(staking), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        staking.stake(ids);
    }

    function attack(uint8 m) external {
        mode = m;
        staking.claim(10);
    }

    receive() external payable {
        if (mode == 1) staking.claim(10);
        if (mode == 2) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = id;
            staking.unstake(ids);
        }
    }
}

/// A staker that cannot receive ETH: unstaking must still return its Orion.
contract EthRefuser {
    function stakeIt(OrionStaking st, OrionTestNFT n, uint256 id) external {
        n.setApprovalForAll(address(st), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        st.stake(ids);
    }

    function unstakeIt(OrionStaking st, uint256 id) external {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        st.unstake(ids);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract RewardsTest is Test {
    OrionTestNFT nft;
    OrionTreasury treasury;
    OrionStaking staking;
    OrionYieldTreasury yieldT;
    OrionRoyaltySplitter splitter;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    uint256 constant PRICE = 0.1 ether;
    uint256 constant DAY = 1 days;

    function setUp() public {
        treasury = new OrionTreasury(owner);
        nft = new OrionTestNFT(owner, payable(address(treasury)), PRICE, 50, 5);
        yieldT = new OrionYieldTreasury(owner);
        staking = new OrionStaking(address(nft), DAY, address(yieldT));
        splitter = new OrionRoyaltySplitter(address(treasury), address(yieldT), address(nft));

        vm.startPrank(owner);
        treasury.setNftContract(address(nft));
        treasury.setDonationSink(payable(owner));
        treasury.setRoyaltySplitter(address(splitter));
        yieldT.setStaking(address(staking));
        nft.setRoyaltyReceiver(address(splitter));
        vm.stopPrank();

        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(who[i], 100 ether);
            vm.prank(who[i]);
            nft.mint{value: PRICE * 5}(5);
        }
        vm.deal(stranger, 100 ether);
        vm.deal(owner, 100 ether);
    }

    // ---- helpers -----------------------------------------------------------

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
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

    function _stake(address who, uint256 id) internal {
        vm.startPrank(who);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(id));
        vm.stopPrank();
    }

    function _unstake(address who, uint256 id) internal {
        vm.prank(who);
        staking.unstake(_ids(id));
    }

    function _profit(uint256 amount) internal {
        vm.deal(address(yieldT), address(yieldT).balance + amount);
        vm.prank(owner);
        yieldT.distributeProfit(amount);
    }

    function _share(uint256 amount, uint256 mine, uint256 total) internal pure returns (uint256) {
        return (amount * mine) / total;
    }

    function _claim(address who) internal returns (uint256 got) {
        uint256 before = who.balance;
        vm.prank(who);
        staking.claim(1000);
        got = who.balance - before;
    }

    // ===================================================================
    // Rewards are shared by points
    // ===================================================================

    function test_profitIsSharedByPointsAmongCurrentStakers() public {
        _stake(alice, 1);                      // staking since t0
        vm.warp(block.timestamp + 1 days);
        _stake(bob, 6);                        // joins a day later
        vm.warp(block.timestamp + 1 days);
        _profit(3 ether);                      // alice 200 points, bob 100 points

        assertEq(staking.pendingRewards(alice), 2 ether);
        assertEq(staking.pendingRewards(bob), 1 ether);
        assertEq(_claim(alice), 2 ether);
        assertEq(_claim(bob), 1 ether);
    }

    function test_moreTokensStakedMeansMorePointsMeansMoreReward() public {
        _stake(alice, 1);
        _stake(alice, 2);                      // alice stakes two
        _stake(bob, 6);                        // bob stakes one
        vm.warp(block.timestamp + 3 days);
        _profit(3 ether);
        assertEq(staking.pendingRewards(alice), 2 ether);
        assertEq(staking.pendingRewards(bob), 1 ether);
    }

    function test_theRewardFollowsPointsNotTimeStakedSinceTheLastEvent() public {
        // alice stakes 10 days (1000 points) and unstakes: that claims them. Bob has
        // been staking longer than she has since she came back.
        _stake(alice, 1);
        vm.warp(block.timestamp + 10 days);
        _unstake(alice, 1);
        assertEq(staking.pointsClaimed(alice), 1000e18);
        _stake(bob, 6);
        vm.warp(block.timestamp + 1 days);
        _stake(alice, 1);                      // alice is back, from zero
        vm.warp(block.timestamp + 1 days);
        _profit(10 ether);
        // alice: 100;  bob: 200
        assertEq(staking.pendingRewards(alice), _share(10 ether, 100, 300));
        assertEq(staking.pendingRewards(bob), _share(10 ether, 200, 300));
    }

    function test_someoneNotStakingWhenProfitLandsGetsNothingFromIt() public {
        _stake(carol, 11);
        vm.warp(block.timestamp + 2 days);
        _unstake(carol, 11);                   // carol has 200 points but is not staking
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        _profit(5 ether);
        assertEq(staking.pendingRewards(carol), 0);
        assertEq(staking.pendingRewards(alice), 5 ether);
        assertEq(staking.pointsOf(carol), 0);                // unstaking cashed them in
        assertEq(staking.pointsClaimed(carol), 200e18);
    }

    function test_comingBackStartsFromZeroPoints() public {
        _stake(carol, 11);
        vm.warp(block.timestamp + 2 days);
        _unstake(carol, 11);                   // her 200 points are claimed and gone
        _stake(alice, 1);
        vm.warp(block.timestamp + 5 days);
        _stake(carol, 11);                     // back, from zero
        vm.warp(block.timestamp + 1 days);
        _profit(10 ether);
        // carol: 100, alice: 600
        assertEq(staking.pendingRewards(alice), _share(10 ether, 600, 700));
        assertEq(staking.pendingRewards(carol), _share(10 ether, 100, 700));
    }

    function test_aLateJoinerDoesNotShareInEarlierProfit() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        _profit(4 ether);
        _stake(bob, 6);
        assertEq(staking.pendingRewards(bob), 0);
        assertEq(staking.pendingRewards(alice), 4 ether);
    }

    function test_unstakingPaysOutWhatYouEarnedInTheSameTransaction() public {
        _stake(alice, 1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 1 days);
        _profit(2 ether);
        uint256 before = alice.balance;
        _unstake(alice, 1);                    // leaves after the profit landed
        assertEq(alice.balance - before, 1 ether);           // paid in the same flow
        assertEq(staking.pendingRewards(alice), 0);
        assertEq(staking.pointsOf(alice), 0);
        assertEq(staking.pointsClaimed(alice), 100e18);
        assertEq(nft.ownerOf(1), alice);
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        staking.claim(10);
    }

    function test_unstakingOneOfTwoPaysEverythingAndKeepsTheRemainingPoints() public {
        _stake(alice, _ids2(1, 2));
        _stake(bob, 6);
        vm.warp(block.timestamp + 2 days);                   // alice 2 tokens x 2 days = 400, bob 200
        _profit(6 ether);                                    // alice 4, bob 2
        uint256 before = alice.balance;
        _unstake(alice, 1);
        assertEq(alice.balance - before, 4 ether);           // all her rewards, not just a part
        assertEq(staking.pointsClaimed(alice), 200e18);      // half of her 400
        assertEq(staking.pointsOf(alice), 200e18);           // the other half stays with the staked one
        assertEq(staking.stakedCount(alice), 1);
    }

    function test_theSnipingPlayFromTheReviewNowPaysNothing() public {
        // round 3, SEC-3-2: a wallet banks points, leaves, then hops in one second
        // before every payout. Leaving now claims the points, so it has none to hop with.
        _stake(alice, 1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 30 days);
        _unstake(alice, 1);                                  // alice cashes in 3,000 points
        assertEq(staking.pointsClaimed(alice), 3000e18);
        uint256 aliceEth = alice.balance;
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 days - 1);
            _stake(alice, 1);                                // one second before the payout
            vm.warp(block.timestamp + 1);
            _profit(1 ether);
            _unstake(alice, 1);
        }
        assertEq(alice.balance, aliceEth);                   // she earned nothing from any of them
        assertEq(staking.pendingRewards(bob), 5 ether);      // bob, who stayed, got all of it
    }

    function test_aContractThatCannotReceiveEthStillGetsItsOrionBack() public {
        EthRefuser r = new EthRefuser();
        vm.prank(alice);
        nft.transferFrom(alice, address(r), 1);
        r.stakeIt(staking, nft, 1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 1 days);
        _profit(2 ether);
        r.unstakeIt(staking, 1);                             // must not revert even though the ETH bounces
        assertEq(nft.ownerOf(1), address(r));
        assertEq(staking.rewardsOwed(address(r)), 1 ether);  // still owed, still claimable later
    }

    function test_severalEpochsAddUp() public {
        _stake(alice, 1);
        _stake(bob, 6);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 1 days);
            _profit(2 ether);
        }
        assertEq(staking.epochCount(), 4);
        assertEq(staking.pendingRewards(alice), 4 ether);   // identical positions, half each time
        assertEq(staking.pendingRewards(bob), 4 ether);
    }

    function test_claimingInChunksPaysTheSameAsClaimingAtOnce() public {
        _stake(alice, 1);
        _stake(bob, 6);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 days);
            _profit(2 ether);
        }
        uint256 all = staking.pendingRewards(alice);
        uint256 before = alice.balance;
        vm.startPrank(alice);
        staking.claim(2);
        staking.claim(2);
        staking.claim(2);
        vm.stopPrank();
        assertEq(alice.balance - before, all);
        assertEq(staking.pendingRewards(alice), 0);
    }

    function test_whatIsPaidOutNeverExceedsWhatWasPutIn() public {
        _stake(alice, 1);
        _stake(alice, 2);
        _stake(bob, 6);
        vm.warp(block.timestamp + 3 days + 17 minutes);
        _stake(carol, 11);
        vm.warp(block.timestamp + 2 days + 333);
        _profit(7 ether + 13);
        vm.warp(block.timestamp + 1 days + 7);
        _profit(3 ether + 1);
        uint256 paid = _claim(alice) + _claim(bob) + _claim(carol);
        assertLe(paid, 10 ether + 14);
        assertGe(paid, 10 ether + 14 - 100);                 // and only wei of rounding is lost
    }

    // ===================================================================
    // Who can push profit in, and when
    // ===================================================================

    function test_onlyTheYieldTreasuryCanDistribute() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        vm.expectRevert("only the yield treasury");
        staking.distribute{value: 1 ether}();
        vm.prank(owner);                                     // not even the owner, directly
        vm.expectRevert("only the yield treasury");
        staking.distribute{value: 1 ether}();
    }

    function test_distributionsHaveToBeADayApart() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        _profit(1 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.deal(address(yieldT), 1 ether);
        vm.prank(owner);
        vm.expectRevert("too soon");
        yieldT.distributeProfit(1 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(owner);
        yieldT.distributeProfit(1 ether);
        assertEq(staking.epochCount(), 2);
    }

    function test_cannotDistributeWhenNobodyIsStaking() public {
        vm.deal(address(yieldT), 1 ether);
        vm.prank(owner);
        vm.expectRevert("nobody is staking");
        yieldT.distributeProfit(1 ether);
    }

    function test_nothingToClaimWhenNothingIsOwed() public {
        _stake(alice, 1);
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        staking.claim(10);
    }

    function test_distributeNeedsSomethingSent() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert("insufficient balance");
        yieldT.distributeProfit(0);
    }

    // ===================================================================
    // Nobody can be trapped
    // ===================================================================

    function test_unstakeAlwaysWorksEvenRightAfterADistribution() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        _profit(1 ether);
        _unstake(alice, 1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_stakingAndUnstakingManyTimesNeverBricksTheLastExit() public {
        for (uint256 i = 0; i < 40; i++) {
            _stake(alice, 1);
            vm.warp(block.timestamp + 37 + i);
            _stake(bob, 6);
            vm.warp(block.timestamp + 91);
            _unstake(alice, 1);
            vm.warp(block.timestamp + 13);
            _unstake(bob, 6);
        }
        _stake(alice, 1);
        _unstake(alice, 1);                                  // the very last exit still works
        assertEq(nft.ownerOf(1), alice);
        assertEq(staking.totalStaked(), 0);
    }

    function test_aStakerWhoNeverClaimsCanStillUnstakeAfterManyEpochsOnceTheyClaimInChunks() public {
        _stake(alice, 1);
        _stake(bob, 6);
        vm.deal(address(yieldT), 1000 ether);
        for (uint256 i = 0; i < 210; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(owner);
            yieldT.distributeProfit(1 ether);
        }
        vm.prank(alice);
        vm.expectRevert("claim first");
        staking.unstake(_ids(1));

        uint256 before = alice.balance;
        vm.startPrank(alice);
        staking.claim(100);
        staking.unstake(_ids(1));                            // 110 left, under the limit: settles and pays them
        vm.stopPrank();
        assertEq(nft.ownerOf(1), alice);
        // the reward for all 210 epochs reached her, half of each, between the two calls
        assertEq(alice.balance - before, 105 ether);
        assertEq(staking.pendingRewards(alice), 0);
    }

    // ===================================================================
    // Attacks
    // ===================================================================

    function test_attack_reenteringClaimWhileBeingPaidFails() public {
        HostileClaimer h = new HostileClaimer(staking, nft);
        vm.prank(alice);
        nft.transferFrom(alice, address(h), 1);
        h.stakeIt(1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 1 days);
        _profit(2 ether);
        vm.expectRevert("ETH transfer failed");
        h.attack(1);
        assertEq(staking.pendingRewards(address(h)), 1 ether);   // nothing lost, nothing double-paid
    }

    function test_attack_unstakingWhileBeingPaidFails() public {
        HostileClaimer h = new HostileClaimer(staking, nft);
        vm.prank(alice);
        nft.transferFrom(alice, address(h), 1);
        h.stakeIt(1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 1 days);
        _profit(2 ether);
        vm.expectRevert("ETH transfer failed");
        h.attack(2);
        assertEq(nft.ownerOf(1), address(staking));
    }

    function test_attack_stakingRightBeforeADistributionIsPaidByPointsNotByTimingAlone() public {
        // alice banked 1000 points earlier and left. bob has staked all along (200 points).
        // alice hops back one second before the profit lands: she is paid by her
        // POINTS, which she really did earn - this documents that the design allows it.
        _stake(alice, 1);
        vm.warp(block.timestamp + 10 days);
        _unstake(alice, 1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 2 days);
        _stake(alice, 1);
        vm.warp(block.timestamp + 1);
        _profit(10 ether);
        // alice left and claimed her 1000 points, so coming back one second before the
        // payout gives her nothing: bob, who has been staking, takes it all.
        assertEq(staking.pendingRewards(alice), 0);
        assertEq(staking.pendingRewards(bob), 10 ether);
    }

    function test_attack_aPointsFarmerWithNothingStakedGetsNothing() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        _profit(5 ether);
        // stranger holds nothing and stakes nothing
        assertEq(staking.pendingRewards(stranger), 0);
        uint256 before = stranger.balance;
        vm.prank(stranger);
        staking.claim(10);                                   // walks past the epoch, pays nothing
        assertEq(stranger.balance, before);
        vm.prank(stranger);
        vm.expectRevert("nothing to claim");                 // and now there is no progress left to make
        staking.claim(10);
    }

    // ---- round 3: the 200-epoch lockout ------------------------------------

    function _manyEpochs(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.warp(block.timestamp + 1 days);
            _profit(0.01 ether);
        }
    }

    function test_aNewWalletCanStakeEvenAfterMoreThanTwoHundredEpochs() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        _manyEpochs(205);
        assertEq(staking.epochCount(), 205);
        _stake(bob, 6);                                      // used to revert with "claim first"
        assertEq(staking.stakedCount(bob), 1);
        assertEq(staking.pendingRewards(bob), 0);            // nothing from epochs before he joined
        vm.warp(block.timestamp + 2 days);
        _profit(1 ether);
        assertGt(staking.pendingRewards(bob), 0);            // but he shares from now on
    }

    function test_aReturningWalletCanStakeAgainAfterManyEpochs() public {
        _stake(alice, 1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 1 days);
        _profit(1 ether);
        _unstake(bob, 6);                                    // pays his share of the profit on the way out
        _manyEpochs(205);
        _stake(bob, 6);
        assertEq(staking.stakedCount(bob), 1);
        assertEq(nft.ownerOf(6), address(staking));
    }

    function test_aStakerWithAHugeBacklogCanWorkThroughItInChunks() public {
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        _manyEpochs(450);
        vm.prank(alice);
        vm.expectRevert("claim first");
        staking.unstake(_ids(1));                            // too far behind to settle in one call
        uint256 total;
        for (uint256 i = 0; i < 3; i++) {
            uint256 b = alice.balance;
            vm.prank(alice);
            staking.claim(200);
            total += alice.balance - b;
        }
        assertEq(staking.pendingRewards(alice), 0);
        assertGe(total, 450 * 0.01 ether - 450);             // everything, less wei of rounding
        _unstake(alice, 1);
        assertEq(nft.ownerOf(1), alice);
    }

    // ---- round 3: wiring checks ------------------------------------------------

    function test_theNftRefusesARoyaltyReceiverTheTreasuryDoesNotKnow() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 5);
        OrionRoyaltySplitter sp2 = new OrionRoyaltySplitter(address(t2), address(yieldT), address(n2));
        vm.startPrank(owner);
        t2.setNftContract(address(n2));
        vm.expectRevert("treasury has a different splitter");
        n2.setRoyaltyReceiver(address(sp2));                 // treasury has no splitter wired yet
        t2.setRoyaltySplitter(address(sp2));
        n2.setRoyaltyReceiver(address(sp2));                 // now they agree
        vm.expectRevert("treasury has a different splitter");
        n2.setRoyaltyReceiver(stranger);
        vm.stopPrank();
    }

    function test_theYieldTreasuryRefusesAStakingContractThatNamesSomeoneElse() public {
        OrionYieldTreasury y2 = new OrionYieldTreasury(owner);
        vm.prank(owner);
        vm.expectRevert("staking names another distributor");
        y2.setStaking(address(staking));                     // staking's distributor is yieldT, not y2
    }

    // ===================================================================
    // The yield treasury
    // ===================================================================

    function test_onlyTheOwnerRunsTheYieldTreasury() public {
        vm.deal(address(yieldT), 1 ether);
        vm.startPrank(stranger);
        vm.expectRevert();
        yieldT.withdraw(payable(stranger), 1 ether);
        vm.expectRevert();
        yieldT.distributeProfit(1 ether);
        vm.expectRevert();
        yieldT.setStaking(address(staking));
        vm.stopPrank();
    }

    function test_theOwnerCanSendCapitalOutToRunAStrategyAndBringProfitHome() public {
        vm.deal(address(yieldT), 1 ether);
        vm.prank(owner);
        yieldT.withdraw(payable(owner), 1 ether);
        assertEq(address(yieldT).balance, 0);
        _stake(alice, 1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        (bool ok, ) = address(yieldT).call{value: 1.4 ether}("");   // the strategy came back with 40% more
        assertTrue(ok);
        vm.prank(owner);
        yieldT.distributeProfit(0.4 ether);
        assertEq(staking.pendingRewards(alice), 0.4 ether);
    }

    function test_stakingCanOnlyBeSetOnce() public {
        vm.prank(owner);
        vm.expectRevert("staking already set");
        yieldT.setStaking(address(staking));
    }

    function test_theYieldTreasuryCannotTouchTheBacking() public {
        // nothing in OrionYieldTreasury calls the backing treasury, and the
        // backing treasury would reject the call anyway: it is not a module.
        uint256 before = address(treasury).balance;
        vm.deal(address(yieldT), 5 ether);
        vm.prank(owner);
        yieldT.withdraw(payable(owner), 5 ether);
        assertEq(address(treasury).balance, before);
    }

    // ===================================================================
    // Royalties
    // ===================================================================

    function test_theNftNamesTheSplitterAsReceiverOfTenPercent() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(splitter));
        assertEq(amount, 0.1 ether);
        assertTrue(nft.supportsInterface(0x2a55205a));        // ERC-2981
        assertTrue(nft.supportsInterface(0x80ac58cd));        // still an ERC-721
    }

    function test_theRoyaltyReceiverCanOnlyBeChangedByTheOwnerAndOnlyBeforeTheMintCloses() public {
        vm.prank(stranger);
        vm.expectRevert();
        nft.setRoyaltyReceiver(stranger);
        vm.startPrank(owner);
        nft.closeMint();
        vm.expectRevert("mint is closed");
        nft.setRoyaltyReceiver(stranger);
        vm.stopPrank();
    }

    function test_royaltiesWaitInTheSplitterWhileTheMintIsOpen() public {
        vm.prank(stranger);
        (bool ok, ) = address(splitter).call{value: 1 ether}("");   // a marketplace pays a royalty
        assertTrue(ok);
        vm.expectRevert("mint still open");
        splitter.release();
        assertEq(address(splitter).balance, 1 ether);
    }

    function test_releaseSplitsEightyTwentyAndAnyoneCanCallIt() public {
        vm.prank(stranger);
        (bool ok, ) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(owner);
        nft.closeMint();
        uint256 assetsBefore = treasury.totalAssets();
        uint256 yieldBefore = address(yieldT).balance;
        vm.prank(stranger);
        splitter.release();
        assertEq(treasury.totalAssets() - assetsBefore, 0.8 ether);
        assertEq(address(yieldT).balance - yieldBefore, 0.2 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_theBackingShareOfRoyaltiesRaisesBackingForEveryHolder() public {
        vm.prank(owner);
        nft.closeMint();
        uint256 before = treasury.backingPerToken();
        vm.prank(stranger);
        (bool ok, ) = address(splitter).call{value: 1.5 ether}("");
        assertTrue(ok);
        splitter.release();
        assertGt(treasury.backingPerToken(), before);
        assertEq(treasury.backingPerToken(), treasury.totalAssets() / 15);
    }

    function test_releaseWithNothingToReleaseReverts() public {
        vm.prank(owner);
        nft.closeMint();
        vm.expectRevert("nothing to release");
        splitter.release();
    }

    function test_royaltyMoneyNeverGoesToTheDonationSink() public {
        vm.prank(owner);
        nft.closeMint();
        vm.prank(stranger);
        (bool ok, ) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 sinkBefore = owner.balance;
        splitter.release();
        assertEq(owner.balance, sinkBefore);                  // the splitter is a known depositor
    }

    // ---- wiring the splitter ---------------------------------------------

    function test_aSplitterForAnotherNftIsRefused() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT mine = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 5);
        OrionTestNFT fake = new OrionTestNFT(stranger, payable(address(t2)), PRICE, 50, 5);
        OrionRoyaltySplitter bad = new OrionRoyaltySplitter(address(t2), address(yieldT), address(fake));
        vm.startPrank(owner);
        t2.setNftContract(address(mine));
        vm.expectRevert("module is for another nft");
        t2.setRoyaltySplitter(address(bad));
        vm.stopPrank();
    }

    function test_theSplitterCannotBeWiredAfterTheMintClosesOrTwice() public {
        vm.startPrank(owner);
        vm.expectRevert("splitter already set");
        treasury.setRoyaltySplitter(address(splitter));
        vm.stopPrank();

        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 5);
        OrionRoyaltySplitter s2 = new OrionRoyaltySplitter(address(t2), address(yieldT), address(n2));
        vm.startPrank(owner);
        t2.setNftContract(address(n2));
        n2.closeMint();
        vm.expectRevert("wire modules before the mint closes");
        t2.setRoyaltySplitter(address(s2));
        vm.stopPrank();
    }

    function test_anUnwiredSplitterCannotPushMoneyIntoTheBacking() public {
        OrionRoyaltySplitter loose = new OrionRoyaltySplitter(address(treasury), address(yieldT), address(nft));
        vm.prank(owner);
        nft.closeMint();
        vm.prank(stranger);
        (bool ok, ) = address(loose).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 assetsBefore = treasury.totalAssets();
        uint256 sinkBefore = owner.balance;
        loose.release();                                      // treasury sees a stranger -> donation sink
        assertEq(treasury.totalAssets(), assetsBefore);
        assertEq(owner.balance - sinkBefore, 0.8 ether);
    }

    // ===================================================================
    // The whole chain
    // ===================================================================

    function test_royaltyToYieldToStakers() public {
        _stake(alice, 1);
        _stake(bob, 6);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        nft.closeMint();

        // a marketplace pays 1 ETH of royalties
        vm.prank(stranger);
        (bool ok, ) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        splitter.release();
        assertEq(address(yieldT).balance, 0.2 ether);

        // the yield treasury "made a profit": it sends its 0.2 plus 0.1 earned
        vm.deal(address(yieldT), 0.3 ether);
        vm.prank(owner);
        yieldT.distributeProfit(0.3 ether);
        assertEq(staking.pendingRewards(alice), 0.15 ether);
        assertEq(staking.pendingRewards(bob), 0.15 ether);
        assertEq(_claim(alice), 0.15 ether);
    }
}
