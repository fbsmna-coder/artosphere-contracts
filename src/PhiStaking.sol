// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PhiCoin.sol";
import "./PhiMath.sol";

/**
 * @title PhiStaking
 * @author IBG Technologies
 * @notice Stake PHI tokens and earn golden-ratio-decay rewards.
 *
 * @dev **APY schedule:**
 *      APY starts at 1/phi ~ 61.8% and decreases by factor 1/phi each epoch:
 *          APY(epoch) = phi^{-(epoch+1)}
 *
 *      **Lock tiers (Fibonacci periods):**
 *        - Tier 0: F(5)  =  5 days  -- multiplier x1.0
 *        - Tier 1: F(8)  = 21 days  -- multiplier x phi   (~1.618)
 *        - Tier 2: F(10) = 55 days  -- multiplier x phi^2 (~2.618)
 *
 *      Longer lock periods earn proportionally higher rewards, scaled by phi
 *      for each successive Fibonacci tier.
 *
 *      **Compound rewards:** stakers may compound accrued rewards back into
 *      their stake without resetting the lock timer.
 *
 *      **Emergency withdraw:** stakers may withdraw before the lock expires,
 *      but incur a penalty of 1/phi^2 (~38.2%) of the staked principal.
 *      Penalty tokens are burned (deflationary).
 *
 *      **Upgradeability:** UUPS proxy pattern (OpenZeppelin 5.x).
 */
contract PhiStaking is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Role for addresses permitted to upgrade the proxy.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Number of blocks per staking epoch (matches PhiCoin emission epoch).
    uint256 public constant BLOCKS_PER_EPOCH = 100;

    /// @notice Seconds in one day (used for lock period calculation).
    uint256 public constant SECONDS_PER_DAY = 86_400;

    /// @notice Number of lock tiers.
    uint256 public constant NUM_TIERS = 3;

    /// @notice Lock durations in days for each tier: F(5)=5, F(8)=21, F(10)=55.
    uint256 public constant TIER_0_DAYS = 5;
    uint256 public constant TIER_1_DAYS = 21;
    uint256 public constant TIER_2_DAYS = 55;

    /// @notice Emergency withdraw penalty: 1/phi^2 ~ 0.381966 in WAD.
    /// @dev Calculated as PhiMath.WAD - PhiMath.PHI_INV = 1e18 - 618033988749894848
    ///      which equals 381966011250105152, equivalent to 1/phi^2.
    uint256 public constant EMERGENCY_PENALTY_WAD = 381966011250105152;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Represents a single staking position.
    /// @param amount     Staked principal (WAD).
    /// @param tier       Lock tier (0, 1, or 2).
    /// @param startBlock Block at which the stake was created.
    /// @param startTime  Timestamp at which the stake was created.
    /// @param lockEnd    Timestamp at which the lock expires.
    /// @param rewardDebt Accumulated reward debt for correct reward accounting.
    /// @param earned     Rewards accumulated but not yet claimed or compounded.
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 startBlock;
        uint256 startTime;
        uint256 lockEnd;
        uint256 rewardDebt;
        uint256 earned;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice The PHI token contract.
    PhiCoin public phiCoin;

    /// @notice Genesis block (mirrors PhiCoin genesis for epoch alignment).
    uint256 public genesisBlock;

    /// @notice Total amount of PHI currently staked across all users.
    uint256 public totalStaked;

    /// @notice Mapping from user address to their active stake.
    mapping(address => Stake) public stakes;

    /// @dev Reserved storage gap for future upgrades.
    uint256[45] private __gap;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a user stakes PHI tokens.
    /// @param user   The staker's address.
    /// @param amount Amount of PHI staked (WAD).
    /// @param tier   The selected lock tier (0, 1, or 2).
    event Staked(address indexed user, uint256 amount, uint256 tier);

    /// @notice Emitted when a user unstakes after the lock period.
    /// @param user   The staker's address.
    /// @param amount Principal returned (WAD).
    /// @param reward Rewards distributed (WAD).
    event Unstaked(address indexed user, uint256 amount, uint256 reward);

    /// @notice Emitted when a user compounds rewards into their stake.
    /// @param user   The staker's address.
    /// @param reward Amount of rewards compounded (WAD).
    event Compounded(address indexed user, uint256 reward);

    /// @notice Emitted when a user performs an emergency withdraw.
    /// @param user    The staker's address.
    /// @param amount  Net amount returned after penalty (WAD).
    /// @param penalty Amount burned as penalty (WAD).
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 penalty);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice User has no active stake.
    error NoActiveStake();

    /// @notice Lock period has not yet expired.
    /// @param lockEnd   Timestamp when the lock expires.
    /// @param currentTs Current block timestamp.
    error LockNotExpired(uint256 lockEnd, uint256 currentTs);

    /// @notice Invalid lock tier provided.
    /// @param tier The invalid tier value.
    error InvalidTier(uint256 tier);

    /// @notice Zero amount is not allowed.
    error ZeroAmount();

    /// @notice User already has an active stake.
    error AlreadyStaking();

    /// @notice No rewards available to compound.
    error NoRewardsToCompound();

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises the staking contract behind a UUPS proxy.
     * @param _phiCoin Address of the PhiCoin token proxy.
     * @param admin    Address that receives DEFAULT_ADMIN_ROLE and UPGRADER_ROLE.
     */
    function initialize(PhiCoin _phiCoin, address admin) external initializer {
        __AccessControl_init();
        // UUPSUpgradeable in OZ 5.x has no __init function
        // ReentrancyGuard (non-upgradeable) is initialized via constructor, no init needed

        phiCoin = _phiCoin;
        genesisBlock = block.number;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Core staking operations
    // -------------------------------------------------------------------------

    /**
     * @notice Stake PHI tokens with a chosen lock tier.
     * @dev Transfers `amount` of PHI from the caller to this contract.
     *      The caller must have approved this contract for at least `amount`.
     *      Only one active stake per address is allowed.
     * @param amount Amount of PHI to stake (WAD, 18 decimals).
     * @param tier   Lock tier: 0 = 5 days, 1 = 21 days, 2 = 55 days.
     */
    function stake(uint256 amount, uint256 tier) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (tier >= NUM_TIERS) revert InvalidTier(tier);
        if (stakes[msg.sender].amount != 0) revert AlreadyStaking();

        uint256 lockDur = _lockDurationSeconds(tier);

        stakes[msg.sender] = Stake({
            amount: amount,
            tier: tier,
            startBlock: block.number,
            startTime: block.timestamp,
            lockEnd: block.timestamp + lockDur,
            rewardDebt: 0,
            earned: 0
        });

        totalStaked += amount;

        IERC20(address(phiCoin)).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, tier);
    }

    /**
     * @notice Unstake after the lock period has expired, claiming all rewards.
     * @dev Returns the full principal plus accrued rewards (minted by PhiCoin).
     *      Reverts if the lock has not yet expired.
     */
    function unstake() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoActiveStake();
        if (block.timestamp < s.lockEnd) revert LockNotExpired(s.lockEnd, block.timestamp);

        uint256 reward = _calculateReward(msg.sender);
        uint256 principal = s.amount;

        totalStaked -= principal;
        delete stakes[msg.sender];

        // Return principal
        IERC20(address(phiCoin)).safeTransfer(msg.sender, principal);

        // Mint and transfer rewards (this contract must hold MINTER_ROLE on PhiCoin)
        if (reward > 0) {
            phiCoin.mintTo(msg.sender, reward);
        }

        emit Unstaked(msg.sender, principal, reward);
    }

    /**
     * @notice Compound accrued rewards back into the stake without resetting the lock.
     * @dev Mints reward tokens and adds them to the staked principal.
     *      Does NOT reset the lock timer.
     */
    function compound() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoActiveStake();

        uint256 reward = _calculateReward(msg.sender);
        if (reward == 0) revert NoRewardsToCompound();

        // Reset reward tracking
        s.rewardDebt += reward;

        // Mint rewards to this contract and add to stake
        phiCoin.mintTo(address(this), reward);
        s.amount += reward;
        totalStaked += reward;

        emit Compounded(msg.sender, reward);
    }

    /**
     * @notice Emergency withdraw before the lock expires (with penalty).
     * @dev Returns principal minus penalty. Penalty = 1/phi^2 (~38.2%) of principal.
     *      The penalty tokens are burned (deflationary).
     *      No rewards are paid.
     */
    function emergencyWithdraw() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoActiveStake();

        uint256 principal = s.amount;
        uint256 penalty = PhiMath.wadMul(principal, EMERGENCY_PENALTY_WAD);
        uint256 netAmount = principal - penalty;

        totalStaked -= principal;
        delete stakes[msg.sender];

        // Return net amount to user
        IERC20(address(phiCoin)).safeTransfer(msg.sender, netAmount);

        // Burn penalty tokens (deflationary)
        // Transfer penalty to this contract's balance is implicit (already held).
        // Approve and burn via PhiCoin.
        IERC20(address(phiCoin)).safeTransfer(address(0xdead), penalty);

        emit EmergencyWithdraw(msg.sender, netAmount, penalty);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the current staking epoch (aligned with PhiCoin epochs).
     * @return epoch The zero-indexed epoch number.
     */
    function currentEpoch() public view returns (uint256 epoch) {
        if (block.number < genesisBlock) return 0;
        epoch = (block.number - genesisBlock) / BLOCKS_PER_EPOCH;
    }

    /**
     * @notice Returns the current APY in WAD for the given epoch.
     * @dev APY(epoch) = phi^{-(epoch+1)}, delegated to PhiMath.fibStakingAPY.
     * @param epoch The epoch number.
     * @return apy The APY as a WAD fraction (e.g. 0.618 * 1e18 = 61.8%).
     */
    function apyForEpoch(uint256 epoch) public pure returns (uint256 apy) {
        apy = PhiMath.fibStakingAPY(epoch);
    }

    /**
     * @notice Returns the tier multiplier in WAD.
     * @dev Tier 0: 1.0 (WAD), Tier 1: phi, Tier 2: phi^2.
     * @param tier The lock tier (0, 1, or 2).
     * @return multiplier The multiplier in WAD.
     */
    function tierMultiplier(uint256 tier) public pure returns (uint256 multiplier) {
        if (tier == 0) return PhiMath.WAD;
        if (tier == 1) return PhiMath.PHI;
        if (tier == 2) return PhiMath.PHI_SQUARED;
        revert InvalidTier(tier);
    }

    /**
     * @notice Returns the pending (unclaimed) reward for a staker.
     * @param user Address of the staker.
     * @return reward The pending reward in WAD.
     */
    function pendingReward(address user) external view returns (uint256 reward) {
        reward = _calculateReward(user);
    }

    /**
     * @notice Returns the stake details for a user.
     * @param user Address of the staker.
     * @return The Stake struct.
     */
    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    /**
     * @notice Returns the lock duration in seconds for a given tier.
     * @param tier The lock tier (0, 1, or 2).
     * @return duration Lock duration in seconds.
     */
    function lockDuration(uint256 tier) external pure returns (uint256 duration) {
        duration = _lockDurationSeconds(tier);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Calculates the pending reward for a staker.
     *
     *      reward = sum over elapsed epochs of:
     *          (staked_amount * APY(epoch) * tierMultiplier / EPOCHS_PER_YEAR) - rewardDebt
     *
     *      For simplicity and gas efficiency, we compute a simplified version:
     *          reward = staked * avgAPY * elapsedEpochs * tierMul / epochsPerYear - debt
     *
     *      where avgAPY is approximated using the geometric mean over the epoch range.
     *      In practice we use a per-epoch summation capped at 200 epochs to bound gas.
     *
     * @param user Address of the staker.
     * @return reward The pending reward in WAD.
     */
    function _calculateReward(address user) internal view returns (uint256 reward) {
        Stake storage s = stakes[user];
        if (s.amount == 0) return 0;

        uint256 stakeEpoch = (s.startBlock - genesisBlock) / BLOCKS_PER_EPOCH;
        uint256 curEpoch = currentEpoch();

        if (curEpoch <= stakeEpoch) return 0;

        uint256 epochs = curEpoch - stakeEpoch;

        // Cap iteration to prevent excessive gas usage
        uint256 maxIter = epochs > 200 ? 200 : epochs;

        uint256 mul = tierMultiplier(s.tier);

        // Approximate annual epochs: ~365.25 days * 86400s / (100 blocks * 12s/block) ~ 26,280
        // For simplicity we use 26_280 epochs per year.
        uint256 epochsPerYear = 26_280;

        uint256 accumulatedReward;

        for (uint256 i = 0; i < maxIter; i++) {
            uint256 epochIdx = stakeEpoch + i;
            uint256 apy = PhiMath.fibStakingAPY(epochIdx);

            // reward_per_epoch = staked * apy * multiplier / epochsPerYear
            uint256 epochReward = PhiMath.wadMul(s.amount, apy);
            epochReward = PhiMath.wadMul(epochReward, mul);
            epochReward = epochReward / epochsPerYear;

            accumulatedReward += epochReward;
        }

        // Subtract already-accounted rewards (from compounding)
        reward = accumulatedReward > s.rewardDebt ? accumulatedReward - s.rewardDebt : 0;
    }

    /**
     * @dev Returns the lock duration in seconds for a given tier.
     * @param tier The lock tier (0, 1, or 2).
     * @return Lock duration in seconds.
     */
    function _lockDurationSeconds(uint256 tier) internal pure returns (uint256) {
        if (tier == 0) return TIER_0_DAYS * SECONDS_PER_DAY;
        if (tier == 1) return TIER_1_DAYS * SECONDS_PER_DAY;
        if (tier == 2) return TIER_2_DAYS * SECONDS_PER_DAY;
        revert InvalidTier(tier);
    }

    // -------------------------------------------------------------------------
    // UUPS authorization
    // -------------------------------------------------------------------------

    /**
     * @dev Only UPGRADER_ROLE may authorise an implementation upgrade.
     * @param newImplementation Address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
