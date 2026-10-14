// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStakingDistribute {
    function distribute() external payable;
    function DISTRIBUTOR() external view returns (address);
}

/**
 * @title OrionYieldTreasury
 * @notice The second treasury. It receives 20% of royalties and is put to work -
 *         farming yield, buying NFTs and other assets, selling them - by the
 *         multisig that owns it. What that work realizes as profit is pushed to
 *         stakers, weighted by their points (see OrionStaking).
 *
 * THIS IS A DIFFERENT TRUST MODEL FROM THE LIQUID BACKING TREASURY, ON PURPOSE.
 * The backing treasury is locked to the rules holders can rely on: no owner
 * withdraw once it is live. This one has to trade, so the owner can move its
 * ETH out to strategies (`withdraw`) and decides when and how much realized
 * profit to distribute. Holders are trusting the multisig with this 20%, and
 * nothing on-chain can check that the profit pushed in is honest. It never
 * touches the backing: the two treasuries are separate contracts and nothing here
 * can call into the backing treasury.
 *
 * The owner is meant to be the same multisig, moved in two steps.
 */
contract OrionYieldTreasury is Ownable2Step, ReentrancyGuard {
    address public staking;

    event StakingSet(address indexed staking);
    event Funded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event ProfitDistributed(uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @dev Accepts anything: royalties, and strategy proceeds coming home.
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice One-time. The staking contract must name this treasury as its
    ///         distributor, or nothing it sends would be accepted.
    function setStaking(address stakingAddress) external onlyOwner {
        require(staking == address(0), "staking already set");
        require(stakingAddress != address(0) && stakingAddress.code.length > 0, "not a contract");
        require(IStakingDistribute(stakingAddress).DISTRIBUTOR() == address(this), "staking names another distributor");
        staking = stakingAddress;
        emit StakingSet(stakingAddress);
    }

    /// @notice Move ETH out to run a strategy.
    function withdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        require(amount <= address(this).balance, "insufficient balance");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit Withdrawn(to, amount);
    }

    /// @notice Pay realized profit to stakers. ETH attached to the call counts
    ///         too, so profits can be sent straight through.
    function distributeProfit(uint256 amount) external payable onlyOwner nonReentrant {
        require(staking != address(0), "staking not set");
        require(amount > 0 && amount <= address(this).balance, "insufficient balance");
        IStakingDistribute(staking).distribute{value: amount}();
        emit ProfitDistributed(amount);
    }

    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }
}
