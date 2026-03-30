// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/PhiStaking.sol";
import "../src/PhiMath.sol";

/**
 * @title PhiStakingTest
 * @notice Comprehensive test suite for PhiStaking: stake/unstake, rewards,
 *         lock periods, emergency withdraw penalty, and APY decay.
 */
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

    /// @notice Deploys PhiCoin and PhiStaking behind UUPS proxies, grants roles,
    ///         and funds Alice with PHI tokens for testing.
    function setUp() public {
        // ----- Deploy PhiCoin proxy -----
        phiCoinImpl = new PhiCoin();
        bytes memory coinInit = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        coinProxy = new ERC1967Proxy(address(phiCoinImpl), coinInit);
        phiCoin = PhiCoin(address(coinProxy));

        // ----- Deploy PhiStaking proxy -----
        stakingImpl = new PhiStaking();
        bytes memory stakingInit = abi.encodeWithSelector(
            PhiStaking.initialize.selector, address(phiCoin), admin
        );
        stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInit);
        staking = PhiStaking(address(stakingProxy));

        // ----- Grant roles -----
        vm.startPrank(admin);
        // Staking contract needs MINTER_ROLE to mint rewards
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), address(staking));
        // Admin also gets MINTER_ROLE to seed tokens
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        vm.stopPrank();

        // ----- Fund Alice -----
        vm.prank(admin);
        phiCoin.mintTo(alice, STAKE_AMOUNT * 10);

        // ----- Alice approves staking contract -----
        vm.prank(alice);
        phiCoin.approve(address(staking), type(uint256).max);
    }

    // =========================================================================
    // Stake and unstake
    // =========================================================================

    /// @notice Alice can stake PHI tokens successfully (tier 0 = 5 days).
    function test_Stake() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        PhiStaking.Stake memory s = staking.getStake(alice);
        assertEq(s.amount, STAKE_AMOUNT, "Staked amount should match");
        assertEq(s.tier, 0, "Tier should be 0");
        assertEq(staking.totalStaked(), STAKE_AMOUNT, "Total staked should match");
        assertEq(
            phiCoin.balanceOf(address(staking)),
            STAKE_AMOUNT,
            "Staking contract should hold the tokens"
        );
    }

    /// @notice Alice can unstake after the lock period and receive principal + reward.
    function test_Unstake() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        // Advance time past tier 0 lock (5 days) and some blocks for reward accrual
        vm.warp(block.timestamp + 6 days);
        vm.roll(block.number + 200); // 2 epochs for some reward

        uint256 balanceBefore = phiCoin.balanceOf(alice);

        vm.prank(alice);
        staking.unstake();

        uint256 balanceAfter = phiCoin.balanceOf(alice);

        // Should get back at least the principal
        assertTrue(balanceAfter >= balanceBefore + STAKE_AMOUNT, "Should receive at least principal");
        assertEq(staking.totalStaked(), 0, "Total staked should be 0 after unstake");
    }

    /// @notice Staking with zero amount reverts.
    function test_StakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(PhiStaking.ZeroAmount.selector);
        staking.stake(0, 0);
    }

    /// @notice Staking with invalid tier reverts.
    function test_StakeInvalidTierReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PhiStaking.InvalidTier.selector, 3));
        staking.stake(STAKE_AMOUNT, 3);
    }

    /// @notice Double staking reverts with AlreadyStaking.
    function test_DoubleStakeReverts() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        vm.expectRevert(PhiStaking.AlreadyStaking.selector);
        staking.stake(STAKE_AMOUNT, 1);
        vm.stopPrank();
    }

    /// @notice Unstaking without a stake reverts with NoActiveStake.
    function test_UnstakeWithoutStakeReverts() public {
        vm.prank(bob);
        vm.expectRevert(PhiStaking.NoActiveStake.selector);
        staking.unstake();
    }

    // =========================================================================
    // Rewards calculation
    // =========================================================================

    /// @notice Pending reward is zero immediately after staking.
    function test_PendingRewardZeroAtStart() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        uint256 reward = staking.pendingReward(alice);
        assertEq(reward, 0, "Reward should be 0 at stake block");
    }

    /// @notice Pending reward increases as blocks pass.
    function test_PendingRewardIncreasesOverTime() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        // Advance 1 epoch (100 blocks)
        vm.roll(block.number + 100);
        uint256 reward1 = staking.pendingReward(alice);

        // Advance another epoch
        vm.roll(block.number + 100);
        uint256 reward2 = staking.pendingReward(alice);

        assertTrue(reward2 > reward1, "Reward should increase over more epochs");
    }

    /// @notice Higher lock tier yields higher rewards (phi multiplier).
    function test_HigherTierHigherRewards() public {
        // Fund Bob too
        vm.prank(admin);
        phiCoin.mintTo(bob, STAKE_AMOUNT * 10);
        vm.prank(bob);
        phiCoin.approve(address(staking), type(uint256).max);

        // Alice stakes tier 0, Bob stakes tier 2
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        vm.prank(bob);
        staking.stake(STAKE_AMOUNT, 2);

        // Advance some epochs
        vm.roll(block.number + 500);

        uint256 rewardAlice = staking.pendingReward(alice);
        uint256 rewardBob = staking.pendingReward(bob);

        assertTrue(
            rewardBob > rewardAlice,
            "Tier 2 (55 days, x phi^2) should earn more than tier 0 (5 days, x1)"
        );
    }

    /// @notice Compound adds rewards to the stake.
    function test_Compound() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        // Advance epochs for reward accrual
        vm.roll(block.number + 300);

        uint256 rewardBefore = staking.pendingReward(alice);
        assertTrue(rewardBefore > 0, "Should have pending rewards");

        vm.prank(alice);
        staking.compound();

        PhiStaking.Stake memory s = staking.getStake(alice);
        assertTrue(s.amount > STAKE_AMOUNT, "Compounded stake should be larger than original");
    }

    /// @notice Compound with no rewards reverts.
    function test_CompoundNoRewardsReverts() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);

        // No blocks advanced, no reward
        vm.prank(alice);
        vm.expectRevert(PhiStaking.NoRewardsToCompound.selector);
        staking.compound();
    }

    // =========================================================================
    // Lock period enforcement
    // =========================================================================

    /// @notice Unstake before lock expires reverts with LockNotExpired.
    function test_UnstakeBeforeLockReverts() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0); // 5-day lock

        // Advance only 2 days (lock is 5 days)
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert();
        staking.unstake();
    }

    /// @notice Unstake exactly at lock expiry succeeds.
    function test_UnstakeAtExactLockEnd() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0); // 5 days

        PhiStaking.Stake memory s = staking.getStake(alice);

        // Warp to exact lock end and advance blocks
        vm.warp(s.lockEnd);
        vm.roll(block.number + 100);

        vm.prank(alice);
        staking.unstake(); // Should succeed

        assertEq(staking.totalStaked(), 0);
    }

    /// @notice Lock durations match Fibonacci values: 5, 21, 55 days.
    function test_LockDurations() public view {
        assertEq(staking.lockDuration(0), 5 days, "Tier 0 = F(5) = 5 days");
        assertEq(staking.lockDuration(1), 21 days, "Tier 1 = F(8) = 21 days");
        assertEq(staking.lockDuration(2), 55 days, "Tier 2 = F(10) = 55 days");
    }

    /// @notice Tier 1 lock (21 days) prevents early unstake.
    function test_Tier1LockEnforcement() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 1);

        // Advance 20 days (still locked for 21-day tier)
        vm.warp(block.timestamp + 20 days);

        vm.prank(alice);
        vm.expectRevert();
        staking.unstake();

        // Advance past 21 days
        vm.warp(block.timestamp + 2 days);
        vm.roll(block.number + 100);

        vm.prank(alice);
        staking.unstake(); // Should succeed
    }

    // =========================================================================
    // Emergency withdraw penalty
    // =========================================================================

    /// @notice Emergency withdraw returns principal minus 1/phi^2 penalty.
    function test_EmergencyWithdraw() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 2); // 55-day lock

        uint256 balanceBefore = phiCoin.balanceOf(alice);

        // Withdraw immediately (before lock expires)
        vm.prank(alice);
        staking.emergencyWithdraw();

        uint256 balanceAfter = phiCoin.balanceOf(alice);
        uint256 received = balanceAfter - balanceBefore;

        // Expected penalty: STAKE_AMOUNT * 1/phi^2 ~ 38.2%
        uint256 expectedPenalty = PhiMath.wadMul(STAKE_AMOUNT, staking.EMERGENCY_PENALTY_WAD());
        uint256 expectedNet = STAKE_AMOUNT - expectedPenalty;

        assertEq(received, expectedNet, "Should receive principal minus 1/phi^2 penalty");
        assertEq(staking.totalStaked(), 0, "Total staked should be 0");
    }

    /// @notice Emergency withdraw without a stake reverts.
    function test_EmergencyWithdrawNoStakeReverts() public {
        vm.prank(bob);
        vm.expectRevert(PhiStaking.NoActiveStake.selector);
        staking.emergencyWithdraw();
    }

    /// @notice Emergency withdraw penalty is approximately 38.2%.
    function test_EmergencyPenaltyPercentage() public view {
        uint256 penalty = staking.EMERGENCY_PENALTY_WAD();
        // 1/phi^2 = 1 - 1/phi = 1 - 0.618... = 0.381966...
        // In WAD: 381966011250105152
        assertEq(penalty, 381966011250105152, "Penalty should be 1/phi^2 in WAD");
    }

    /// @notice After emergency withdraw, user can stake again.
    function test_EmergencyWithdrawThenRestake() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        staking.emergencyWithdraw();

        // Should be able to stake again
        staking.stake(STAKE_AMOUNT, 1);
        vm.stopPrank();

        PhiStaking.Stake memory s = staking.getStake(alice);
        assertEq(s.amount, STAKE_AMOUNT);
        assertEq(s.tier, 1);
    }

    // =========================================================================
    // APY decreasing over epochs
    // =========================================================================

    /// @notice APY at epoch 0 is 1/phi ~ 61.8%.
    function test_APYEpoch0() public view {
        uint256 apy0 = staking.apyForEpoch(0);
        // fibStakingAPY(0) = phiInvPow(1) = 1/phi = PHI_INV
        assertEq(apy0, PhiMath.PHI_INV, "APY at epoch 0 should be 1/phi");
    }

    /// @notice APY decreases from epoch to epoch.
    function test_APYDecreases() public view {
        uint256 apy0 = staking.apyForEpoch(0);
        uint256 apy1 = staking.apyForEpoch(1);
        uint256 apy2 = staking.apyForEpoch(2);
        uint256 apy10 = staking.apyForEpoch(10);

        assertTrue(apy0 > apy1, "APY should decrease: epoch 0 > epoch 1");
        assertTrue(apy1 > apy2, "APY should decrease: epoch 1 > epoch 2");
        assertTrue(apy2 > apy10, "APY should decrease: epoch 2 > epoch 10");
    }

    /// @notice APY ratio between consecutive epochs approximates 1/phi.
    function test_APYDecayRatio() public view {
        uint256 apy0 = staking.apyForEpoch(0);
        uint256 apy1 = staking.apyForEpoch(1);

        // apy1 / apy0 should be approximately 1/phi = 0.618...
        // ratio = apy1 * WAD / apy0
        uint256 ratio = (apy1 * 1e18) / apy0;

        // Allow 1% tolerance due to fixed-point rounding
        uint256 expected = PhiMath.PHI_INV; // ~0.618 * 1e18
        uint256 tolerance = expected / 100; // 1%

        assertTrue(
            ratio > expected - tolerance && ratio < expected + tolerance,
            "APY decay ratio should be approximately 1/phi"
        );
    }

    /// @notice APY converges toward zero at high epochs.
    function test_APYConvergesToZero() public view {
        uint256 apy50 = staking.apyForEpoch(50);
        uint256 apy100 = staking.apyForEpoch(100);

        assertTrue(apy50 < 1e15, "APY at epoch 50 should be very small");
        assertTrue(apy100 < apy50, "APY at epoch 100 should be smaller than epoch 50");
    }

    // =========================================================================
    // Tier multipliers
    // =========================================================================

    /// @notice Tier multipliers follow phi powers: 1, phi, phi^2.
    function test_TierMultipliers() public view {
        assertEq(staking.tierMultiplier(0), PhiMath.WAD, "Tier 0 multiplier = 1.0");
        assertEq(staking.tierMultiplier(1), PhiMath.PHI, "Tier 1 multiplier = phi");
        assertEq(staking.tierMultiplier(2), PhiMath.PHI_SQUARED, "Tier 2 multiplier = phi^2");
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Staking emits the Staked event.
    function test_StakeEmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PhiStaking.Staked(alice, STAKE_AMOUNT, 0);
        staking.stake(STAKE_AMOUNT, 0);
    }

    /// @notice Emergency withdraw emits the EmergencyWithdraw event.
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
