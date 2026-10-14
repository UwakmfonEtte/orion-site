// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DayGuard} from "./DayGuard.sol";

/**
 * @title OrionStaking
 * @notice Stake an Orion, earn 100 points a day for it. No minimum period, no
 *         cool-down, no lock: unstake whenever you like and the token comes
 *         straight back.
 *
 * POINTS are the time-weighting, and they move in whole days: 100 for each
 * Orion for every full 24 hours it has been staked, and nothing in between.
 * Rewards are NOT paid per second staked; they are paid by points, so the
 * people with more points get more.
 *
 * UNSTAKING CLAIMS. In the same transaction that returns your Orion, your
 * waiting rewards are paid to you and the points of the Orions that left are
 * cashed in (they go to zero, and are added to `pointsClaimed`, a running record).
 * Points therefore cannot outlive the staking that earned them: nobody can
 * leave, keep a pile of points, and snipe later payouts with one token. If you
 * unstake only some of your Orions, the points of the ones still staked stay.
 * If a payout to you fails (a contract that cannot receive ETH), the unstake
 * still goes through and the ETH stays claimable with claim().
 *
 * One clock per wallet. Staking or unstaking banks the whole days earned so far
 * and starts a fresh day for whatever is still staked, so the unfinished part
 * of a day is dropped. That can only ever under-credit, never over-credit, so
 * stake your Orions together.
 *
 * REWARDS are the realized profits of the Yield Treasury. When the distributor
 * (the Yield Treasury) pushes profit in, it becomes an epoch, and each CURRENT
 * staker's share of it is their points divided by the total points of everyone
 * currently staking, measured at that moment. Someone who is not staking when a
 * distribution lands gets nothing from it; their points are kept and count again
 * the next time they stake.
 *
 * Each user's rewards are settled lazily, when they claim, stake or unstake. A
 * user's position is constant between their own actions, so their points at any
 * past epoch are computable exactly. Only distribute() walks the list of
 * current stakers (at most one per staked token), to total their points.
 *
 * The staked token sits here, so it cannot be redeemed, lent against or sold
 * until unstaked. It still counts toward circulating supply, so staking never
 * changes anyone's backing.
 *
 * Tokens move with transferFrom, never safeTransferFrom, so neither stake nor
 * unstake hands control to the other side's code mid-call. The receiver hook
 * refuses every unsolicited safe transfer.
 *
 * `DAY` is a constructor argument so a testnet can run time fast; DayGuard
 * refuses a non-86400 value anywhere but a known test network.
 */
contract OrionStaking is ReentrancyGuard {
    IERC721 public immutable NFT;
    uint256 public immutable DAY;
    /// @notice Only this address can push profit in (the Yield Treasury).
    address public immutable DISTRIBUTOR;

    uint256 public constant POINTS_PER_DAY = 100e18;   // 18-decimal fixed point
    uint256 public constant MAX_BATCH = 25;
    /// @notice Distributions are at least this many days apart, so the epoch
    ///         list - and the work to settle it - grows slowly.
    uint256 public constant MIN_EPOCH_GAP_DAYS = 1;
    /// @notice Stake and unstake settle up to this many pending epochs
    ///         themselves. Past that, claim() first (it can be done in chunks).
    uint256 public constant MAX_AUTO_SETTLE = 200;

    mapping(uint256 => address) public stakerOf;
    mapping(address => uint256) public stakedCount;
    uint256 public totalStaked;

    mapping(address => uint256) private _banked;       // points already settled
    mapping(address => uint256) private _lastTouch;    // when this wallet's current day started

    address[] private _stakers;                        // wallets with something staked right now
    mapping(address => uint256) private _stakerIndex;  // position + 1

    // ---- rewards -------------------------------------------------------
    struct Epoch {
        uint256 time;
        uint256 amount;          // ETH distributed
        uint256 totalPoints;     // points of everyone staking at that moment
    }
    Epoch[] public epochs;
    mapping(address => uint256) public nextEpoch;      // first epoch not yet settled for this user
    mapping(address => uint256) public rewardsOwed;    // settled and unclaimed
    uint256 public totalDistributed;
    /// @notice Points each wallet has cashed in by unstaking, over its lifetime. A memory aid.
    mapping(address => uint256) public pointsClaimed;

    event Staked(address indexed staker, uint256 indexed tokenId);
    event Unstaked(address indexed staker, uint256 indexed tokenId);
    event Distributed(uint256 indexed epoch, uint256 amount, uint256 totalPoints);
    event Claimed(address indexed staker, uint256 amount);
    event PointsClaimed(address indexed staker, uint256 points);

    constructor(address nftAddress, uint256 daySeconds, address distributor) {
        require(nftAddress != address(0) && nftAddress.code.length > 0, "not a contract");
        require(distributor != address(0), "no distributor");
        DayGuard.check(daySeconds);
        NFT = IERC721(nftAddress);
        DAY = daySeconds;
        DISTRIBUTOR = distributor;
    }

    // ------------------------------------------------------------------
    // Points
    // ------------------------------------------------------------------

    /// @dev `staked` tokens held since `since`, valued at time `t`: 100 per
    ///      token per COMPLETED day.
    function _livePoints(uint256 staked, uint256 since, uint256 t) internal view returns (uint256) {
        return staked * ((t - since) / DAY) * POINTS_PER_DAY;
    }

    function pointsOf(address user) public view returns (uint256) {
        return _banked[user] + _livePoints(stakedCount[user], _lastTouch[user], block.timestamp);
    }

    function _settlePoints(address user) internal {
        _banked[user] = pointsOf(user);
        _lastTouch[user] = block.timestamp;
    }

    /// @notice Total points of everyone staking right now.
    function eligiblePoints() public view returns (uint256 total) {
        for (uint256 i = 0; i < _stakers.length; i++) total += pointsOf(_stakers[i]);
    }

    function stakerCount() external view returns (uint256) {
        return _stakers.length;
    }

    function _addStaker(address user) internal {
        _stakers.push(user);
        _stakerIndex[user] = _stakers.length;
    }

    function _removeStaker(address user) internal {
        uint256 i = _stakerIndex[user] - 1;
        address last = _stakers[_stakers.length - 1];
        _stakers[i] = last;
        _stakerIndex[last] = i + 1;
        _stakers.pop();
        delete _stakerIndex[user];
    }

    // ------------------------------------------------------------------
    // Rewards
    // ------------------------------------------------------------------

    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    /// @notice Push realized profit to stakers. Only the Yield Treasury can.
    function distribute() external payable nonReentrant {
        require(msg.sender == DISTRIBUTOR, "only the yield treasury");
        require(msg.value > 0, "nothing sent");
        require(totalStaked > 0, "nobody is staking");
        uint256 n = epochs.length;
        if (n > 0) {
            require(block.timestamp >= epochs[n - 1].time + MIN_EPOCH_GAP_DAYS * DAY, "too soon");
        }
        uint256 tp = eligiblePoints();
        require(tp > 0, "no points yet");
        epochs.push(Epoch(block.timestamp, msg.value, tp));
        totalDistributed += msg.value;
        emit Distributed(n, msg.value, tp);
    }

    /// @dev What `user` earns from epochs [from, to). Their position has been
    ///      constant since `_lastTouch`, and every epoch from `nextEpoch` on
    ///      happened after it, so their points at each epoch are exact.
    function _earned(address user, uint256 from, uint256 to) internal view returns (uint256 acc) {
        uint256 staked = stakedCount[user];
        if (staked == 0) return 0;
        uint256 base = _banked[user];
        uint256 last = _lastTouch[user];
        for (uint256 e = from; e < to; e++) {
            Epoch memory ep = epochs[e];
            uint256 pts = base + _livePoints(staked, last, ep.time);
            acc += (ep.amount * pts) / ep.totalPoints;
        }
    }

    function _settleRewards(address user, uint256 maxEpochs) internal {
        uint256 from = nextEpoch[user];
        uint256 to = epochs.length;
        if (to - from > maxEpochs) to = from + maxEpochs;
        rewardsOwed[user] += _earned(user, from, to);
        nextEpoch[user] = to;
    }

    /// @notice Rewards waiting for `user`: settled plus not yet settled.
    function pendingRewards(address user) external view returns (uint256) {
        return rewardsOwed[user] + _earned(user, nextEpoch[user], epochs.length);
    }

    /// @notice Collect your rewards. `maxEpochs` lets someone who has not
    ///         claimed in a long time catch up in chunks.
    function claim(uint256 maxEpochs) external nonReentrant {
        uint256 before = nextEpoch[msg.sender];
        _settleRewards(msg.sender, maxEpochs);
        uint256 amount = rewardsOwed[msg.sender];
        if (amount > address(this).balance) amount = address(this).balance;   // a few wei of rounding at most
        if (amount == 0) {
            // A chunk of epochs that pays nothing still counts as progress: keep it,
            // so a long backlog can always be worked through.
            require(nextEpoch[msg.sender] > before, "nothing to claim");
            return;
        }
        rewardsOwed[msg.sender] -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit Claimed(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------

    function _beforeChange(address user) internal {
        if (stakedCount[user] == 0) {
            // Nothing staked means nothing earned from any epoch so far (_earned is
            // zero for them), so skip straight to the latest one. Without this, a
            // wallet that is not staking could never join once 200 epochs piled up.
            nextEpoch[user] = epochs.length;
        } else {
            require(epochs.length - nextEpoch[user] <= MAX_AUTO_SETTLE, "claim first");
            _settleRewards(user, MAX_AUTO_SETTLE);
        }
        _settlePoints(user);
    }

    function stake(uint256[] calldata ids) external nonReentrant {
        require(ids.length > 0 && ids.length <= MAX_BATCH, "bad batch");
        _beforeChange(msg.sender);
        if (stakedCount[msg.sender] == 0) _addStaker(msg.sender);
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            require(NFT.ownerOf(id) == msg.sender, "not your token");
            stakerOf[id] = msg.sender;
            NFT.transferFrom(msg.sender, address(this), id);
            emit Staked(msg.sender, id);
        }
        stakedCount[msg.sender] += ids.length;
        totalStaked += ids.length;
    }

    function unstake(uint256[] calldata ids) external nonReentrant {
        require(ids.length > 0 && ids.length <= MAX_BATCH, "bad batch");
        _beforeChange(msg.sender);
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            require(stakerOf[id] == msg.sender, "not staked by you");
            delete stakerOf[id];
            NFT.transferFrom(address(this), msg.sender, id);
            emit Unstaked(msg.sender, id);
        }
        uint256 before = stakedCount[msg.sender];
        stakedCount[msg.sender] = before - ids.length;
        totalStaked -= ids.length;

        // Cash in the points of the Orions that left: the share belonging to the
        // ones still staked stays, the rest is claimed. A full exit zeroes it.
        uint256 banked = _banked[msg.sender];
        uint256 kept = (banked * stakedCount[msg.sender]) / before;
        _banked[msg.sender] = kept;
        pointsClaimed[msg.sender] += banked - kept;
        emit PointsClaimed(msg.sender, banked - kept);

        if (stakedCount[msg.sender] == 0) _removeStaker(msg.sender);
        _payOut(msg.sender);
    }

    /// @dev Pay whatever is owed, best effort: a failed transfer is put back so
    ///      the exit it rides on can never be blocked by the receiver.
    function _payOut(address user) internal {
        uint256 amount = rewardsOwed[user];
        if (amount > address(this).balance) amount = address(this).balance;
        if (amount == 0) return;
        rewardsOwed[user] -= amount;
        (bool ok, ) = user.call{value: amount}("");
        if (!ok) {
            rewardsOwed[user] += amount;
        } else {
            emit Claimed(user, amount);
        }
    }

    /// @dev Always refuses. stake() uses transferFrom, so it never lands here.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("use stake()");
    }
}
