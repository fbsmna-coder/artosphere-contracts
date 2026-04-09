// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/PhiStaking.sol";
import "../src/PhiMath.sol";

contract PhiStakingTest is Test {
    PhiCoin public phiCoinImpl;
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    PhiStaking public stakingImpl;
    PhiStaking public staking;
    ERC1967Proxy public stakingProxy;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant STAKE_AMOUNT = 10_000 * 1e18;

    function setUp() public {
        phiCoinImpl = new PhiCoin();
        bytes memory coinInit = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        coinProxy = new ERC1967Proxy(address(phiCoinImpl), coinInit);
        phiCoin = PhiCoin(address(coinProxy));

        stakingImpl = new PhiStaking();
        bytes memory stakingInit = abi.encodeWithSelector(
            PhiStaking.initialize.selector, address(phiCoin), admin
        );
        stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInit);
        staking = PhiStaking(address(stakingProxy));

        vm.startPrank(admin);
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), address(staking));
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        vm.stopPrank();

        vm.prank(admin);
        phiCoin.mintTo(alice, STAKE_AMOUNT * 10);

        vm.prank(alice);
        phiCoin.approve(address(staking), type(uint256).max);
    }

    function test_Stake() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        PhiStaking.Stake memory s = staking.getStake(alice);
        assertEq(s.amount, STAKE_AMOUNT);
        assertEq(s.tier, 0);
        assertEq(staking.totalStaked(), STAKE_AMOUNT);
        assertEq(phiCoin.balanceOf(address(staking)), STAKE_AMOUNT);
    }

    function test_Unstake() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        vm.warp(block.timestamp + 6 days);
        uint256 balanceBefore = phiCoin.balanceOf(alice);
        vm.prank(alice);
        staking.unstake();
        uint256 balanceAfter = phiCoin.balanceOf(alice);
        assertTrue(balanceAfter >= balanceBefore + STAKE_AMOUNT);
        assertEq(staking.totalStaked(), 0);
    }

    function test_StakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(PhiStaking.ZeroAmount.selector);
        staking.stake(0, 0);
    }

    function test_StakeInvalidTierReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PhiStaking.InvalidTier.selector, 3));
        staking.stake(STAKE_AMOUNT, 3);
    }

    function test_DoubleStakeReverts() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        vm.expectRevert(PhiStaking.AlreadyStaking.selector);
        staking.stake(STAKE_AMOUNT, 1);
        vm.stopPrank();
    }

    function test_UnstakeWithoutStakeReverts() public {
        vm.prank(bob);
        vm.expectRevert(PhiStaking.NoActiveStake.selector);
        staking.unstake();
    }

    function test_PendingRewardZeroAtStart() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        assertEq(staking.pendingReward(alice), 0);
    }

    function test_PendingRewardIncreasesOverTime() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        vm.warp(block.timestamp + 604800); // 1 week
        uint256 reward1 = staking.pendingReward(alice);
        vm.warp(block.timestamp + 604800 * 3); // +3 more weeks
        uint256 reward2 = staking.pendingReward(alice);
        assertTrue(reward2 > reward1, "Reward should increase over time");
    }

    function test_HigherTierHigherRewards() public {
        vm.prank(admin);
        phiCoin.mintTo(bob, STAKE_AMOUNT * 10);
        vm.prank(bob);
        phiCoin.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        vm.prank(bob);
        staking.stake(STAKE_AMOUNT, 2);
        vm.warp(block.timestamp + 604800);
        uint256 rewardAlice = staking.pendingReward(alice);
        uint256 rewardBob = staking.pendingReward(bob);
        assertTrue(rewardBob > rewardAlice);
    }

    function test_Compound() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        vm.warp(block.timestamp + 604800 * 3);
        assertTrue(staking.pendingReward(alice) > 0);
        vm.prank(alice);
        staking.compound();
        PhiStaking.Stake memory s = staking.getStake(alice);
        assertTrue(s.amount > STAKE_AMOUNT);
    }

    function test_CompoundNoRewardsReverts() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        vm.prank(alice);
        vm.expectRevert(PhiStaking.NoRewardsToCompound.selector);
        staking.compound();
    }

    function test_UnstakeBeforeLockReverts() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert();
        staking.unstake();
    }

    function test_UnstakeAtExactLockEnd() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        PhiStaking.Stake memory s = staking.getStake(alice);
        vm.warp(s.lockEnd);
        vm.prank(alice);
        staking.unstake();
        assertEq(staking.totalStaked(), 0);
    }

    function test_LockDurations() public view {
        assertEq(staking.lockDuration(0), 5 days);
        assertEq(staking.lockDuration(1), 21 days);
        assertEq(staking.lockDuration(2), 55 days);
    }

    function test_Tier1LockEnforcement() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 1);
        vm.warp(block.timestamp + 20 days);
        vm.prank(alice);
        vm.expectRevert();
        staking.unstake();
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        staking.unstake();
    }

    function test_EmergencyWithdraw() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 2);
        uint256 balanceBefore = phiCoin.balanceOf(alice);
        vm.prank(alice);
        staking.emergencyWithdraw();
        uint256 balanceAfter = phiCoin.balanceOf(alice);
        uint256 received = balanceAfter - balanceBefore;
        uint256 expectedPenalty = PhiMath.wadMul(STAKE_AMOUNT, staking.EMERGENCY_PENALTY_WAD());
        uint256 expectedNet = STAKE_AMOUNT - expectedPenalty;
        assertEq(received, expectedNet);
        assertEq(staking.totalStaked(), 0);
    }

    function test_EmergencyWithdrawBurnsPenalty() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 2);
        uint256 supplyBefore = phiCoin.totalSupply();
        vm.prank(alice);
        staking.emergencyWithdraw();
        uint256 supplyAfter = phiCoin.totalSupply();
        uint256 expectedPenalty = PhiMath.wadMul(STAKE_AMOUNT, staking.EMERGENCY_PENALTY_WAD());
        assertEq(supplyBefore - supplyAfter, expectedPenalty);
    }

    function test_EmergencyWithdrawNoStakeReverts() public {
        vm.prank(bob);
        vm.expectRevert(PhiStaking.NoActiveStake.selector);
        staking.emergencyWithdraw();
    }

    function test_EmergencyPenaltyPercentage() public view {
        assertEq(staking.EMERGENCY_PENALTY_WAD(), 381966011250105152);
    }

    function test_EmergencyWithdrawThenRestake() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        staking.emergencyWithdraw();
        staking.stake(STAKE_AMOUNT, 1);
        vm.stopPrank();
        PhiStaking.Stake memory s = staking.getStake(alice);
        assertEq(s.amount, STAKE_AMOUNT);
        assertEq(s.tier, 1);
    }

    function test_APYEpoch0() public view {
        assertEq(staking.apyForEpoch(0), PhiMath.PHI_INV);
    }

    function test_APYDecreases() public view {
        assertTrue(staking.apyForEpoch(0) > staking.apyForEpoch(1));
        assertTrue(staking.apyForEpoch(1) > staking.apyForEpoch(2));
        assertTrue(staking.apyForEpoch(2) > staking.apyForEpoch(10));
    }

    function test_APYDecayRatio() public view {
        uint256 apy0 = staking.apyForEpoch(0);
        uint256 apy1 = staking.apyForEpoch(1);
        uint256 ratio = (apy1 * 1e18) / apy0;
        uint256 expected = PhiMath.PHI_INV;
        uint256 tolerance = expected / 100;
        assertTrue(ratio > expected - tolerance && ratio < expected + tolerance);
    }

    function test_APYConvergesToZero() public view {
        assertTrue(staking.apyForEpoch(50) < 1e15);
        assertTrue(staking.apyForEpoch(100) < staking.apyForEpoch(50));
    }

    function test_TierMultipliers() public view {
        assertEq(staking.tierMultiplier(0), PhiMath.WAD);
        assertEq(staking.tierMultiplier(1), PhiMath.PHI);
        assertEq(staking.tierMultiplier(2), PhiMath.PHI_SQUARED);
    }

    function test_StakeEmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PhiStaking.Staked(alice, STAKE_AMOUNT, 0);
        staking.stake(STAKE_AMOUNT, 0);
    }

    function test_EmergencyWithdrawEmitsEvent() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        uint256 penalty = PhiMath.wadMul(STAKE_AMOUNT, staking.EMERGENCY_PENALTY_WAD());
        uint256 netAmount = STAKE_AMOUNT - penalty;
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PhiStaking.EmergencyWithdraw(alice, netAmount, penalty);
        staking.emergencyWithdraw();
    }
}
