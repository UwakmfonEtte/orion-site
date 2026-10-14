// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrionTestNFT} from "../src/OrionTestNFT.sol";
import {OrionTreasury} from "../src/OrionTreasury.sol";
import {OrionStaking} from "../src/OrionStaking.sol";
import {OrionLending} from "../src/OrionLending.sol";
import {OrionRental} from "../src/OrionRental.sol";

/// @dev Borrower that tries to re-enter while the loan ETH is being paid to it.
contract HostileBorrower {
    OrionLending public lending;
    OrionTreasury public treasury;
    OrionTestNFT public nft;
    uint256 public otherId;
    uint8 public mode;   // 1 = borrow again, 2 = redeem the other token

    constructor(OrionLending l, OrionTreasury t, OrionTestNFT n) {
        lending = l; treasury = t; nft = n;
    }

    function prepare() external {
        nft.setApprovalForAll(address(lending), true);
        nft.setApprovalForAll(address(treasury), true);
    }

    function attack(uint256 first, uint256 other, uint256 amount, uint8 m) external {
        otherId = other;
        mode = m;
        lending.borrow(first, 30, amount);
    }

    receive() external payable {
        if (mode == 1) lending.borrow(otherId, 30, msg.value);
        if (mode == 2) treasury.redeem(otherId);
    }
}

/// @dev Renter that tries to re-enter while its change is being refunded.
contract HostileRenter {
    OrionRental public rental;
    uint256 public otherId;

    constructor(OrionRental r) { rental = r; }

    function attack(uint256 first, uint256 other, uint256 term) external payable {
        otherId = other;
        rental.rent{value: msg.value}(first, term);
    }

    receive() external payable {
        rental.rent{value: address(this).balance}(otherId, 7);
    }
}

contract ModulesTest is Test {
    OrionTestNFT nft;
    OrionTreasury treasury;
    OrionStaking staking;
    OrionLending lending;
    OrionRental rental;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    uint256 constant PRICE = 0.1 ether;
    uint256 constant DAY = 1 days;

    // alice: 1-5, bob: 6-10, carol: 11-15, owner: 16-18  (18 minted, 1.8 ETH in)
    function setUp() public {
        treasury = new OrionTreasury(owner);
        nft = new OrionTestNFT(owner, payable(address(treasury)), PRICE, 50, 5);
        staking = new OrionStaking(address(nft), DAY, owner);
        lending = new OrionLending(address(nft), address(treasury), DAY);
        rental = new OrionRental(owner, address(nft), address(treasury), DAY);

        vm.startPrank(owner);
        treasury.setNftContract(address(nft));
        treasury.setDonationSink(payable(owner));
        treasury.setLendingModule(address(lending));
        treasury.setRentalModule(address(rental));
        vm.stopPrank();

        address[4] memory who = [alice, bob, carol, owner];
        uint256[4] memory qty = [uint256(5), 5, 5, 3];
        for (uint256 i = 0; i < 4; i++) {
            vm.deal(who[i], 100 ether);
            vm.prank(who[i]);
            nft.mint{value: PRICE * qty[i]}(qty[i]);
        }
        vm.deal(stranger, 100 ether);
        assertEq(address(treasury).balance, 1.8 ether);
    }

    function _close() internal {
        vm.prank(owner);
        nft.closeMint();
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

    // ===================================================================
    // Treasury wiring and the mint gate
    // ===================================================================

    function test_redeemIsShutWhileTheMintIsOpen() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(treasury), true);
        vm.expectRevert("mint still open");
        treasury.redeem(1);
        vm.stopPrank();
    }

    function test_redeemOpensOnceTheMintIsClosed() public {
        _close();
        vm.startPrank(alice);
        nft.setApprovalForAll(address(treasury), true);
        treasury.redeem(1);
        vm.stopPrank();
        assertEq(treasury.redeemedCount(), 1);
    }

    function test_modulesAreWiredOnceOnly() public {
        vm.startPrank(owner);
        vm.expectRevert("lending already set");
        treasury.setLendingModule(address(lending));
        vm.expectRevert("rental already set");
        treasury.setRentalModule(address(rental));
        vm.stopPrank();
    }

    function test_onlyOwnerWiresModules() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        vm.prank(stranger);
        vm.expectRevert();
        t2.setLendingModule(address(lending));
    }

    function test_moduleBuiltForAnotherTreasuryIsRejected() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        vm.startPrank(owner);
        t2.setNftContract(address(nft));
        vm.expectRevert("module is for another treasury");
        t2.setLendingModule(address(lending));   // lending points at `treasury`, not t2
        vm.expectRevert("module is for another treasury");
        t2.setRentalModule(address(rental));
        vm.stopPrank();
    }

    function test_walletsAndNonContractsCannotBeWiredAsModules() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        vm.startPrank(owner);
        t2.setNftContract(address(nft));
        vm.expectRevert("not a contract");
        t2.setLendingModule(stranger);
        vm.expectRevert("not a contract");
        t2.setRentalModule(address(0));
        vm.stopPrank();
    }

    function test_modulesNeedTheNftWiredFirst() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        vm.prank(owner);
        vm.expectRevert("wire the nft first");
        t2.setLendingModule(address(lending));
    }

    function test_nobodyButTheLenderCanTouchTheLoanBook() public {
        _close();
        vm.startPrank(stranger);
        vm.expectRevert("not the lending module");
        treasury.lend(stranger, 1 ether, 1 ether);
        vm.expectRevert("not the lending module");
        treasury.repayLoan{value: 0}(0);
        vm.expectRevert("not the lending module");
        treasury.writeOffDefault(0);
        vm.stopPrank();
        vm.prank(owner);                         // not even the owner
        vm.expectRevert("not the lending module");
        treasury.lend(owner, 1 ether, 1 ether);
    }

    // ===================================================================
    // Staking
    // ===================================================================

    function test_stakeHoldsTheTokenAndUnstakeReturnsIt() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(1, 2));
        assertEq(nft.ownerOf(1), address(staking));
        assertEq(staking.stakerOf(1), alice);
        assertEq(staking.stakedCount(alice), 2);
        staking.unstake(_ids(1));
        assertEq(nft.ownerOf(1), alice);
        assertEq(staking.stakedCount(alice), 1);
        assertEq(staking.totalStaked(), 1);
        vm.stopPrank();
    }

    function test_oneHundredPointsPerDayPerToken() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(1, 2));
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days);
        assertEq(staking.pointsOf(alice), 600e18);          // 2 tokens x 3 days x 100
        assertEq(staking.pointsOf(bob), 0);
    }

    function test_unstakingClaimsThePointsSoTheyStartFromZero() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(1));
        vm.warp(block.timestamp + 2 days);
        assertEq(staking.pointsOf(alice), 200e18);
        staking.unstake(_ids(1));
        assertEq(staking.pointsOf(alice), 0);                // cashed in
        assertEq(staking.pointsClaimed(alice), 200e18);      // and remembered
        vm.warp(block.timestamp + 10 days);
        assertEq(staking.pointsOf(alice), 0);
        vm.stopPrank();
    }

    function test_pointsKeepAccruingAcrossAddingMoreTokens() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(1));
        vm.warp(block.timestamp + 1 days);
        staking.stake(_ids(2));
        vm.warp(block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(staking.pointsOf(alice), 300e18);          // 1d x1 + 1d x2
    }

    function test_cannotStakeSomeoneElsesToken() public {
        vm.startPrank(bob);
        nft.setApprovalForAll(address(staking), true);
        vm.expectRevert("not your token");
        staking.stake(_ids(1));                              // alice's
        vm.stopPrank();
    }

    function test_cannotUnstakeSomeoneElsesToken() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(1));
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert("not staked by you");
        staking.unstake(_ids(1));
    }

    function test_duplicateIdInOneBatchReverts() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        vm.expectRevert("not your token");
        staking.stake(_ids(1, 1));
        vm.stopPrank();
    }

    function test_badBatchSizesRevert() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        vm.expectRevert("bad batch");
        staking.stake(new uint256[](0));
        vm.expectRevert("bad batch");
        staking.stake(new uint256[](26));
        vm.stopPrank();
    }

    function test_unsolicitedSafeTransferToStakingIsRefusedSoNothingGetsStuck() public {
        vm.prank(alice);
        vm.expectRevert("use stake()");
        nft.safeTransferFrom(alice, address(staking), 1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_aStakedTokenCannotBeRedeemedOrBorrowedAgainst() public {
        _close();
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        nft.setApprovalForAll(address(treasury), true);
        nft.setApprovalForAll(address(lending), true);
        staking.stake(_ids(1));
        vm.expectRevert("not the owner");
        treasury.redeem(1);
        vm.expectRevert("not your token");
        lending.borrow(1, 30, 0.01 ether);
        vm.stopPrank();
    }

    function test_stakingDoesNotChangeAnyonesBacking() public {
        uint256 before = treasury.backingPerToken();
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(_ids(1, 2));
        vm.stopPrank();
        assertEq(treasury.backingPerToken(), before);
    }

    // ===================================================================
    // Lending
    // ===================================================================

    function _approveLending(address who) internal {
        vm.prank(who);
        nft.setApprovalForAll(address(lending), true);
    }

    function test_cannotBorrowWhileTheMintIsOpen() public {
        _approveLending(alice);
        uint256 amt = 0.05 ether;
        vm.prank(alice);
        vm.expectRevert("mint still open");
        lending.borrow(1, 30, amt);
    }

    function test_borrowPaysOutHoldsTheTokenAndKeepsBackingSteady() public {
        _close();
        _approveLending(alice);
        uint256 backing = treasury.backingPerToken();
        uint256 limit = lending.maxBorrow();
        assertEq(limit, 0.095 ether);                        // 0.1 backing less the 5% fee

        uint256 interest = lending.interestFor(limit, 30);
        uint256 before = alice.balance;
        vm.prank(alice);
        lending.borrow(1, 30, limit);

        // interest is taken up front: she is paid the principal LESS it...
        assertEq(alice.balance - before, limit - interest);
        assertEq(lending.payoutFor(limit, 30), limit - interest);
        assertEq(nft.ownerOf(1), address(lending));
        // ...but the full principal is what is owed back
        assertEq(treasury.loansOutstanding(), limit);
        assertEq(lending.owed(1), limit);
        assertEq(address(treasury).balance, 1.8 ether - (limit - interest));
        // the loan is an asset and the interest is already in: backing only went up
        assertEq(treasury.totalAssets(), 1.8 ether + interest);
        assertGe(treasury.backingPerToken(), backing);
    }

    function test_cannotBorrowMoreThanTheRedeemValue() public {
        _close();
        _approveLending(alice);
        uint256 over = lending.maxBorrow() + 1;
        vm.prank(alice);
        vm.expectRevert("over the borrow limit");
        lending.borrow(1, 30, over);
        vm.prank(alice);
        vm.expectRevert("over the borrow limit");
        lending.borrow(1, 30, 0);
    }

    function test_onlyThe_30_90_180DayTermsExist() public {
        _close();
        _approveLending(alice);
        vm.startPrank(alice);
        vm.expectRevert("term must be 30, 90 or 180 days");
        lending.borrow(1, 7, 0.01 ether);
        vm.expectRevert("term must be 30, 90 or 180 days");
        lending.borrow(1, 0, 0.01 ether);
        lending.borrow(1, 90, 0.01 ether);
        lending.borrow(2, 180, 0.01 ether);
        vm.stopPrank();
    }

    function test_cannotBorrowAgainstSomeoneElsesToken() public {
        _close();
        _approveLending(alice);
        vm.prank(bob);
        vm.expectRevert("not your token");
        lending.borrow(1, 30, 0.01 ether);
    }

    function test_cannotBorrowTwiceAgainstTheSameToken() public {
        _close();
        _approveLending(alice);
        vm.startPrank(alice);
        lending.borrow(1, 30, 0.01 ether);
        vm.expectRevert("already borrowed against");
        lending.borrow(1, 30, 0.01 ether);
        vm.stopPrank();
    }

    function test_interestIsFivePercentAYearProRated() public view {
        assertEq(lending.interestFor(1 ether, 365), 0.05 ether);
        assertEq(lending.interestFor(1 ether, 30), (uint256(1 ether) * 500 * 30) / (365 * 10_000));
    }

    function test_repayIsJustThePrincipalAndBackingKeepsTheInterestFromDayOne() public {
        _close();
        _approveLending(alice);
        uint256 amt = lending.maxBorrow();
        uint256 interest = lending.interestFor(amt, 30);
        assertGt(interest, 0);
        vm.prank(alice);
        lending.borrow(1, 30, amt);
        uint256 owedNow = lending.owed(1);
        assertEq(owedNow, amt);                              // nothing on top of the principal

        uint256 backingBefore = treasury.backingPerToken();  // already includes the interest
        vm.prank(alice);
        lending.repay{value: owedNow}(1);

        assertEq(nft.ownerOf(1), alice);
        assertEq(treasury.loansOutstanding(), 0);
        assertEq(address(treasury).balance, 1.8 ether + interest);
        assertEq(treasury.backingPerToken(), backingBefore); // repaying changes nothing: interest was in
        assertEq(lending.owed(1), 0);
    }

    function test_repayRefundsOverpaymentAndShortPaymentReverts() public {
        _close();
        _approveLending(alice);
        uint256 amt = lending.maxBorrow();
        vm.prank(alice);
        lending.borrow(1, 30, amt);
        uint256 owedNow = lending.owed(1);

        vm.prank(alice);
        vm.expectRevert("pay the principal");
        lending.repay{value: owedNow - 1}(1);

        uint256 before = alice.balance;
        vm.prank(alice);
        lending.repay{value: owedNow + 1 ether}(1);
        assertEq(before - alice.balance, owedNow);
    }

    function test_anyoneCanRepayButTheTokenAlwaysGoesToTheBorrower() public {
        _close();
        _approveLending(alice);
        uint256 amt = lending.maxBorrow();
        vm.prank(alice);
        lending.borrow(1, 30, amt);
        uint256 owedNow = lending.owed(1);
        vm.prank(stranger);
        lending.repay{value: owedNow}(1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_cannotLiquidateBeforeTheDueDate() public {
        _close();
        _approveLending(alice);
        vm.prank(alice);
        lending.borrow(1, 30, 0.05 ether);
        vm.warp(block.timestamp + 30 days + 3 days);         // due plus the full grace, not past it
        vm.prank(stranger);
        vm.expectRevert("not past the grace period");
        lending.liquidate(1);
    }

    function test_liquidationBurnsTheTokenAndNeverDilutesAnyoneElse() public {
        _close();
        _approveLending(alice);
        uint256 amt = lending.maxBorrow();                   // 0.095
        uint256 kept = lending.payoutFor(amt, 30);           // what she actually walked off with
        uint256 assetsBefore = treasury.totalAssets();       // 1.8
        uint256 remainingBefore = 18;
        uint256 backingBefore = treasury.backingPerToken();  // 0.1
        vm.prank(alice);
        lending.borrow(1, 30, amt);

        vm.warp(block.timestamp + 33 days + 1);
        vm.prank(stranger);
        lending.liquidate(1);

        assertEq(nft.ownerOf(1), treasury.BURN_ADDRESS());
        assertEq(treasury.loansOutstanding(), 0);
        assertEq(treasury.defaultedCount(), 1);
        // she left with LESS than a redemption pays, so the others are better off:
        assertLt(kept, amt);
        assertEq(treasury.backingPerToken(), (assetsBefore - kept) / (remainingBefore - 1));
        assertGe(treasury.backingPerToken(), backingBefore);
    }

    function test_walkingAwayFromALoanIsNeverBetterThanRedeeming() public {
        _close();
        _approveLending(alice);
        uint256 redeemPays = treasury.redeemValue();
        assertEq(lending.maxBorrow(), redeemPays);           // the cap IS the redeem value
        vm.prank(alice);
        vm.expectRevert("over the borrow limit");
        lending.borrow(1, 30, redeemPays + 1);               // not a wei more
    }

    function test_cannotRepayOrLiquidateTwice() public {
        _close();
        _approveLending(alice);
        vm.prank(alice);
        lending.borrow(1, 30, 0.05 ether);
        vm.warp(block.timestamp + 34 days);
        lending.liquidate(1);
        vm.expectRevert("no open loan");
        lending.liquidate(1);
        vm.prank(alice);
        vm.expectRevert("no open loan");
        lending.repay{value: 1 ether}(1);
    }

    function test_repayStillWorksAfterTheDueDateUntilSomeoneLiquidates() public {
        _close();
        _approveLending(alice);
        vm.prank(alice);
        lending.borrow(1, 30, 0.05 ether);
        uint256 owedNow = lending.owed(1);
        vm.warp(block.timestamp + 45 days);
        vm.prank(alice);
        lending.repay{value: owedNow}(1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_utilizationCapKeepsHalfTheTreasuryInCash() public {
        _close();
        _approveLending(alice);
        _approveLending(bob);
        uint256 amt = lending.maxBorrow();                   // 0.095 each; 9 fit under 0.9
        for (uint256 id = 1; id <= 5; id++) {
            vm.prank(alice);
            lending.borrow(id, 30, amt);
        }
        for (uint256 id = 6; id <= 9; id++) {
            vm.prank(bob);
            lending.borrow(id, 30, amt);
        }
        assertEq(treasury.loansOutstanding(), amt * 9);
        vm.prank(bob);
        vm.expectRevert("utilization cap");
        lending.borrow(10, 30, amt);
    }

    function test_pausingStopsNewLoansButNeverRepayments() public {
        _close();
        _approveLending(alice);
        vm.prank(alice);
        lending.borrow(1, 30, 0.05 ether);
        uint256 owedNow = lending.owed(1);
        vm.prank(owner);
        treasury.pause();
        vm.prank(alice);
        vm.expectRevert();
        lending.borrow(2, 30, 0.05 ether);
        vm.prank(alice);
        lending.repay{value: owedNow}(1);                    // still works
        assertEq(nft.ownerOf(1), alice);
    }

    // ---- attacks on the loan flow -------------------------------------

    function _hostileBorrower() internal returns (HostileBorrower h) {
        h = new HostileBorrower(lending, treasury, nft);
        vm.startPrank(alice);
        nft.transferFrom(alice, address(h), 1);
        nft.transferFrom(alice, address(h), 2);
        vm.stopPrank();
        h.prepare();
    }

    function test_attack_borrowingAgainFromInsideTheLoanPaymentFails() public {
        _close();
        HostileBorrower h = _hostileBorrower();
        uint256 amt = lending.maxBorrow();
        vm.expectRevert("loan transfer failed");
        h.attack(1, 2, amt, 1);
        assertEq(nft.ownerOf(1), address(h));                // nothing moved
        assertEq(treasury.loansOutstanding(), 0);
    }

    function test_attack_redeemingFromInsideTheLoanPaymentFails() public {
        _close();
        HostileBorrower h = _hostileBorrower();
        uint256 amt = lending.maxBorrow();
        vm.expectRevert("loan transfer failed");
        h.attack(1, 2, amt, 2);
        assertEq(treasury.loansOutstanding(), 0);
        assertEq(treasury.redeemedCount(), 0);
    }

    function test_attack_redeemingACollateralTokenIsImpossible() public {
        _close();
        _approveLending(alice);
        vm.startPrank(alice);
        lending.borrow(1, 30, 0.05 ether);
        nft.setApprovalForAll(address(treasury), true);
        vm.expectRevert("not the owner");
        treasury.redeem(1);                                  // the lending contract holds it
        vm.stopPrank();
    }

    function test_attack_aBorrowerCannotWalkAwayWithMoreThanTheyWouldRedeem() public {
        _close();
        _approveLending(alice);
        uint256 beforeEth = alice.balance;
        uint256 redeemPays = treasury.redeemValue();
        uint256 amt = lending.maxBorrow();
        vm.prank(alice);
        lending.borrow(1, 30, amt);
        // keeps the loan, loses the token: strictly LESS than redeeming would pay
        assertLt(alice.balance - beforeEth, redeemPays);
        assertEq(alice.balance - beforeEth, redeemPays - lending.interestFor(redeemPays, 30));
    }

    function test_attack_redeemAndLoanTogetherNeverStrandARedeemer() public {
        _close();
        _approveLending(alice);
        _approveLending(bob);
        uint256 amt = lending.maxBorrow();
        for (uint256 id = 1; id <= 5; id++) {
            vm.prank(alice);
            lending.borrow(id, 30, amt);
        }
        // carol, who borrowed nothing, can still redeem with half the treasury lent out
        vm.startPrank(carol);
        nft.setApprovalForAll(address(treasury), true);
        uint256 before = carol.balance;
        treasury.redeem(11);
        vm.stopPrank();
        assertGt(carol.balance, before);
    }

    // ===================================================================
    // Rental
    // ===================================================================

    function _list(uint256 id) internal {
        _close();                       // renting opens with the mint closing
        vm.startPrank(owner);
        nft.setApprovalForAll(address(rental), true);
        rental.list(id);
        vm.stopPrank();
    }

    function test_onlyTheOwnerListsAndDelists() public {
        vm.prank(alice);
        nft.setApprovalForAll(address(rental), true);
        vm.prank(alice);
        vm.expectRevert();
        rental.list(1);
        _list(16);
        vm.prank(alice);
        vm.expectRevert();
        rental.delist(16);
    }

    function test_listedTokenSitsInTheRentalContract() public {
        _list(16);
        assertEq(nft.ownerOf(16), address(rental));
        assertEq(rental.listed().length, 1);
    }

    function test_rentCostIsTenPercentOfBackingPer30Days() public {
        // backing is 0.1 ETH each
        assertEq(rental.rentCost(30), 0.01 ether);
        assertEq(rental.rentCost(90), 0.03 ether);
        assertEq(rental.rentCost(7), (uint256(0.1 ether) * 1000 * 7) / (30 * 10_000));
    }

    function test_rentingPaysTheTreasuryAndRaisesBackingForEveryone() public {
        _list(16);
        uint256 backing = treasury.backingPerToken();
        uint256 cost = rental.rentCost(30);
        vm.prank(alice);
        rental.rent{value: cost}(16, 30);
        assertEq(address(treasury).balance, 1.8 ether + cost);
        assertGt(treasury.backingPerToken(), backing);
        assertTrue(rental.perksActive(alice));
    }

    function test_rentRefundsChangeAndRejectsShortPayment() public {
        _list(16);
        uint256 cost = rental.rentCost(30);
        vm.prank(alice);
        vm.expectRevert("pay the rent");
        rental.rent{value: cost - 1}(16, 30);
        uint256 before = alice.balance;
        vm.prank(alice);
        rental.rent{value: cost + 1 ether}(16, 30);
        assertEq(before - alice.balance, cost);
    }

    function test_onlyThe_7_30_90DayTermsExist() public {
        _list(16);
        vm.prank(alice);
        vm.expectRevert("term must be 7, 30 or 90 days");
        rental.rent{value: 1 ether}(16, 14);
    }

    function test_cannotRentWhatIsNotListedOrAlreadyRented() public {
        _close();
        vm.prank(alice);
        vm.expectRevert("not for rent");
        rental.rent{value: 1 ether}(1, 7);
        _list(16);
        vm.prank(alice);
        rental.rent{value: 1 ether}(16, 7);
        vm.prank(bob);
        vm.expectRevert("already rented");
        rental.rent{value: 1 ether}(16, 7);
    }

    function test_theRenterNeverHoldsTheTokenSoCannotRedeemOrBorrowIt() public {
        _close();
        _list(16);
        vm.startPrank(alice);
        rental.rent{value: 1 ether}(16, 30);
        nft.setApprovalForAll(address(treasury), true);
        nft.setApprovalForAll(address(lending), true);
        vm.expectRevert("not the owner");
        treasury.redeem(16);
        vm.expectRevert("not your token");
        lending.borrow(16, 30, 0.01 ether);
        vm.expectRevert();
        nft.transferFrom(alice, alice, 16);
        vm.stopPrank();
        assertEq(nft.ownerOf(16), address(rental));
    }

    function test_rentingEarnsNoPoints() public {
        _list(16);
        vm.prank(alice);
        rental.rent{value: 1 ether}(16, 7);
        vm.warp(block.timestamp + 3 days);
        assertEq(staking.pointsOf(alice), 0);                // she is renting, not staking
        assertTrue(rental.perksActive(alice));
        vm.warp(block.timestamp + 10 days);
        assertEq(staking.pointsOf(alice), 0);
        assertFalse(rental.perksActive(alice));
        assertEq(rental.rentalsBy(alice), 1);
    }

    function test_aFinishedRentalFreesTheOrionForTheNextRenter() public {
        _list(16);
        vm.prank(alice);
        rental.rent{value: 1 ether}(16, 7);
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        rental.rent{value: 1 ether}(16, 7);
        assertTrue(rental.perksActive(bob));
        assertFalse(rental.perksActive(alice));
        assertEq(rental.rentalsBy(alice), 1);
        assertEq(rental.rentalsBy(bob), 1);
    }

    function test_cannotDelistWhileRentedButCanAfter() public {
        _list(16);
        vm.prank(alice);
        rental.rent{value: 1 ether}(16, 7);
        vm.prank(owner);
        vm.expectRevert("rented out");
        rental.delist(16);
        vm.warp(block.timestamp + 8 days);
        vm.prank(owner);
        rental.delist(16);
        assertEq(nft.ownerOf(16), owner);
        assertEq(rental.listed().length, 0);
        assertEq(rental.rentalsBy(alice), 1);
    }

    function test_delistingOneOfSeveralKeepsTheRestListed() public {
        _list(16);
        _list(17);
        _list(18);
        vm.prank(owner);
        rental.delist(16);
        uint256[] memory left = rental.listed();
        assertEq(left.length, 2);
        assertEq(nft.ownerOf(17), address(rental));
        assertEq(nft.ownerOf(18), address(rental));
    }

    function test_unsolicitedSafeTransferToRentalIsRefused() public {
        vm.prank(alice);
        vm.expectRevert("use list()");
        nft.safeTransferFrom(alice, address(rental), 1);
    }

    function test_attack_changeRefundCannotReenterTheRental() public {
        _list(16);
        _list(17);
        HostileRenter h = new HostileRenter(rental);
        vm.deal(address(h), 0);
        uint256 cost = rental.rentCost(30);
        vm.expectRevert("refund failed");
        h.attack{value: cost + 1 ether}(16, 17, 30);
        assertFalse(rental.isActive(16));                    // nothing stuck half-rented
    }

    // ===================================================================
    // Everything together
    // ===================================================================

    function test_fullLifeStakeBorrowRepayRentRedeem() public {
        _close();
        // alice stakes one, borrows against another, bob rents one of the owner's
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        nft.setApprovalForAll(address(lending), true);
        nft.setApprovalForAll(address(treasury), true);
        staking.stake(_ids(1));
        lending.borrow(2, 30, lending.maxBorrow());
        vm.stopPrank();
        _list(16);
        vm.prank(bob);
        rental.rent{value: rental.rentCost(30)}(16, 30);

        vm.warp(block.timestamp + 10 days);
        assertEq(staking.pointsOf(alice), 1000e18);

        // she repays, unstakes, and redeems both for more than they cost at mint
        vm.startPrank(alice);
        lending.repay{value: lending.owed(2)}(2);
        staking.unstake(_ids(1));
        uint256 before = alice.balance;
        treasury.redeem(1);
        treasury.redeem(2);
        vm.stopPrank();
        assertGt(alice.balance - before, 2 * 0.095 ether);   // interest and rent raised backing
        assertEq(treasury.loansOutstanding(), 0);
    }

    // ===================================================================
    // Fixes from the red-team review
    // ===================================================================

    // SEC-2-1: modules cannot be wired once the mint is closed
    function test_modulesCannotBeWiredAfterTheMintCloses() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 5);
        OrionLending l2 = new OrionLending(address(n2), address(t2), DAY);
        OrionRental r2 = new OrionRental(owner, address(n2), address(t2), DAY);
        vm.startPrank(owner);
        t2.setNftContract(address(n2));
        n2.closeMint();
        vm.expectRevert("wire modules before the mint closes");
        t2.setLendingModule(address(l2));
        vm.expectRevert("wire modules before the mint closes");
        t2.setRentalModule(address(r2));
        vm.stopPrank();
    }

    function test_aSoldOutMintAlsoShutsTheWiringWindow() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT n2 = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 5);
        OrionLending l2 = new OrionLending(address(n2), address(t2), DAY);
        vm.prank(owner);
        t2.setNftContract(address(n2));
        for (uint160 i = 1; i <= 10; i++) {
            address w = address(i + 5000);
            vm.deal(w, 1 ether);
            vm.prank(w);
            n2.mint{value: PRICE * 5}(5);
        }
        vm.prank(owner);
        vm.expectRevert("wire modules before the mint closes");
        t2.setLendingModule(address(l2));
    }

    // SEC-2-2: a lookalike module built for a stranger's collection is refused
    function test_aModuleForAnotherNftIsRefused() public {
        OrionTreasury t2 = new OrionTreasury(owner);
        OrionTestNFT mine = new OrionTestNFT(owner, payable(address(t2)), PRICE, 50, 5);
        OrionTestNFT fake = new OrionTestNFT(stranger, payable(address(t2)), PRICE, 50, 5);
        OrionLending badLending = new OrionLending(address(fake), address(t2), DAY);
        OrionRental badRental = new OrionRental(stranger, address(fake), address(t2), DAY);
        vm.startPrank(owner);
        t2.setNftContract(address(mine));
        vm.expectRevert("module is for another nft");
        t2.setLendingModule(address(badLending));
        vm.expectRevert("module is for another nft");
        t2.setRentalModule(address(badRental));
        vm.stopPrank();
    }

    // SEC-2-4: a repayment at the deadline cannot be front-run into losing the Orion
    function test_aLateRepayInsideTheGraceWindowCannotBeFrontRun() public {
        _close();
        _approveLending(alice);
        vm.prank(alice);
        lending.borrow(1, 30, 0.05 ether);
        uint256 owedNow = lending.owed(1);
        vm.warp(block.timestamp + 30 days + 1);              // one second overdue
        vm.prank(stranger);
        vm.expectRevert("not past the grace period");
        lending.liquidate(1);                                // the front-runner fails
        vm.prank(alice);
        lending.repay{value: owedNow}(1);                    // and she still gets her Orion back
        assertEq(nft.ownerOf(1), alice);
    }

    // SEC-2-5: a fast testnet clock is refused on a real network
    function test_aFastClockIsRefusedOnMainnetButAllowedOnTestnets() public {
        vm.chainId(1);
        vm.expectRevert("fast clock is testnet only");
        new OrionStaking(address(nft), 60, owner);
        vm.expectRevert("fast clock is testnet only");
        new OrionLending(address(nft), address(treasury), 60);
        vm.expectRevert("fast clock is testnet only");
        new OrionRental(owner, address(nft), address(treasury), 60);
        new OrionStaking(address(nft), 86400, owner);               // a real day is always fine
        vm.chainId(4663);                                    // Robinhood mainnet
        vm.expectRevert("fast clock is testnet only");
        new OrionLending(address(nft), address(treasury), 60);
        vm.chainId(46630);                                   // Robinhood testnet
        new OrionLending(address(nft), address(treasury), 60);
    }

    // SEC-2-7 / 2-10: rent only works once wired, and only after the mint closes
    function test_rentIsRefusedWhileTheMintIsOpen() public {
        vm.startPrank(owner);
        nft.setApprovalForAll(address(rental), true);
        rental.list(16);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert("mint still open");
        rental.rent{value: 1 ether}(16, 7);
    }

    function test_aRentalThatIsNotTheWiredModuleCannotTakeRent() public {
        OrionRental rogue = new OrionRental(owner, address(nft), address(treasury), DAY);
        _close();
        vm.startPrank(owner);
        nft.setApprovalForAll(address(rogue), true);
        rogue.list(16);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert("rental not wired");
        rogue.rent{value: 1 ether}(16, 7);
    }

    // SEC-2-9: ownership moves in two steps, so a typo cannot strand the treasury
    function test_ownershipTransfersAreTwoStep() public {
        vm.prank(owner);
        treasury.transferOwnership(stranger);
        assertEq(treasury.owner(), owner);
        vm.prank(owner);
        rental.transferOwnership(stranger);
        assertEq(rental.owner(), owner);
        vm.prank(stranger);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), stranger);
    }

    // ===================================================================
    // Interest is taken up front
    // ===================================================================

    function test_theInterestIsInTheTreasuryTheMomentTheLoanIsMade() public {
        _close();
        _approveLending(alice);
        uint256 amt = lending.maxBorrow();
        uint256 interest = lending.interestFor(amt, 90);
        uint256 assetsBefore = treasury.totalAssets();
        vm.prank(alice);
        lending.borrow(1, 90, amt);
        assertEq(treasury.totalAssets(), assetsBefore + interest);
    }

    function test_aLongerTermCostsMoreUpFrontForTheSamePrincipal() public {
        _close();
        _approveLending(alice);
        uint256 amt = lending.maxBorrow();
        assertGt(lending.interestFor(amt, 180), lending.interestFor(amt, 90));
        assertGt(lending.interestFor(amt, 90), lending.interestFor(amt, 30));
        uint256 before = alice.balance;
        vm.prank(alice);
        lending.borrow(1, 180, amt);
        assertEq(alice.balance - before, amt - lending.interestFor(amt, 180));
        assertEq(lending.owed(1), amt);                      // owed does not depend on the term
    }

    function test_repayingEarlyDoesNotGiveTheInterestBack() public {
        _close();
        _approveLending(alice);
        uint256 amt = lending.maxBorrow();
        uint256 interest = lending.interestFor(amt, 180);
        vm.prank(alice);
        lending.borrow(1, 180, amt);
        vm.prank(alice);
        lending.repay{value: amt}(1);                        // straight away
        assertEq(address(treasury).balance, 1.8 ether + interest);
    }

    function test_theTreasuryRejectsALoanThatPaysOutMoreThanThePrincipal() public {
        _close();
        vm.prank(address(lending));
        vm.expectRevert("bad loan");
        treasury.lend(alice, 1 ether, 1 ether + 1);
    }
}
