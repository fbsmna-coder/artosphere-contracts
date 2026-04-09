// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PhiCoin.sol";
import "./PhiMath.sol";

/**
 * @title PhiStaking
 * @author F.B. Sapronov
 * @notice Stake PHI tokens and earn golden-ratio-decay rewards.
 *
 * @dev **APY schedule:**
 *      APY starts at 1/phi ~ 61.8% and decreases by factor 1/phi each weekly epoch:
 *          APY(epoch) = phi^{-(epoch+1)}  (1 epoch = 1 week)
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
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Role for addresses permitted to upgrade the proxy.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Duration of a single staking epoch in seconds (1 week).
    /// APY decays by factor 1/φ each epoch, giving a meaningful ~2-year yield curve.
    uint256 public constant EPOCH_DURATION = 604_800;

    /// @notice Seconds in one day (used for lock period calculation).
    uint256 public constant SECONDS_PER_DAY = 86_400;

    /// @notice Number of lock tiers.
    uint256 public constant NUM_TIERS = 3;

    /// @notice Lock durations in days for each tier: F(5)=5, F(8)=21, F(10)=55.
    uint256 public constant TIER_0_DAYS = 5;
    uint256 public constant TIER_1_DAYS = 21;
    uint256 public constant TIER_2_DAYS = 55;

    /// @notice Emergency withdraw penalty: 1/phi^2 ~ 0.381966 in WAD.
    uint256 public constant EMERGENCY_PENALTY_WAD = 381966011250105152;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Represents a single staking position.
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 startTimestamp;
        uint256 lockEnd;
        uint256 rewardDebt;
        uint256 earned;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice The PHI token contract.
    PhiCoin public phiCoin;

    /// @notice Genesis timestamp (synced from PhiCoin for epoch alignment).
    uint256 public genesisTimestamp;

    /// @notice Total amount of PHI currently staked across all users.
    uint256 public totalStaked;

    /// @notice Mapping from user address to their active stake.
    mapping(address => Stake) public stakes;

    /// @dev Reserved storage gap for future upgrades.
    uint256[45] private __gap;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Staked(address indexed user, uint256 amount, uint256 tier);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event Compounded(address indexed user, uint256 reward);
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 penalty);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NoActiveStake();
    error LockNotExpired(uint256 lockEnd, uint256 currentTs);
    error InvalidTier(uint256 tier);
    error ZeroAmount();
    error AlreadyStaking();
    error NoRewardsToCompound();

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(PhiCoin _phiCoin, address admin) external initializer {
        __AccessControl_init();

        phiCoin = _phiCoin;
        genesisTimestamp = PhiCoin(address(_phiCoin)).genesisTimestamp();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Core staking operations
    // -------------------------------------------------------------------------

    function stake(uint256 amount, uint256 tier) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (tier >= NUM_TIERS) revert InvalidTier(tier);
        if (stakes[msg.sender].amount != 0) revert AlreadyStaking();

        uint256 lockDur = _lockDurationSeconds(tier);

        stakes[msg.sender] = Stake({
            amount: amount,
            tier: tier,
            startTimestamp: block.timestamp,
            lockEnd: block.timestamp + lockDur,
            rewardDebt: 0,
            earned: 0
        });

        totalStaked += amount;
        IERC20(address(phiCoin)).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, tier);
    }

    function unstake() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoActiveStake();
        if (block.timestamp < s.lockEnd) revert LockNotExpired(s.lockEnd, block.timestamp);

        uint256 reward = _calculateReward(msg.sender);
        uint256 principal = s.amount;

        totalStaked -= principal;
        delete stakes[msg.sender];

        IERC20(address(phiCoin)).safeTransfer(msg.sender, principal);
        if (reward > 0) {
            phiCoin.mintTo(msg.sender, reward);
        }
        emit Unstaked(msg.sender, principal, reward);
    }

    function compound() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoActiveStake();

        uint256 reward = _calculateReward(msg.sender);
        if (reward == 0) revert NoRewardsToCompound();

        s.rewardDebt += reward;
        phiCoin.mintTo(address(this), reward);
        s.amount += reward;
        totalStaked += reward;
        emit Compounded(msg.sender, reward);
    }

    function emergencyWithdraw() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoActiveStake();

        uint256 principal = s.amount;
        uint256 penalty = PhiMath.wadMul(principal, EMERGENCY_PENALTY_WAD);
        uint256 netAmount = principal - penalty;

        totalStaked -= principal;
        delete stakes[msg.sender];

        IERC20(address(phiCoin)).safeTransfer(msg.sender, netAmount);
        // Burn penalty tokens (deflationary) - PhiStaking holds the tokens
        PhiCoin(address(phiCoin)).burn(penalty);
        emit EmergencyWithdraw(msg.sender, netAmount, penalty);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function currentEpoch() public view returns (uint256 epoch) {
        if (block.timestamp < genesisTimestamp) return 0;
        epoch = (block.timestamp - genesisTimestamp) / EPOCH_DURATION;
    }

    function apyForEpoch(uint256 epoch) public pure returns (uint256 apy) {
        apy = PhiMath.fibStakingAPY(epoch);
    }

    function tierMultiplier(uint256 tier) public pure returns (uint256 multiplier) {
        if (tier == 0) return PhiMath.WAD;
        if (tier == 1) return PhiMath.PHI;
        if (tier == 2) return PhiMath.PHI_SQUARED;
        revert InvalidTier(tier);
    }

    function pendingReward(address user) external view returns (uint256 reward) {
        reward = _calculateReward(user);
    }

    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    function lockDuration(uint256 tier) external pure returns (uint256 duration) {
        duration = _lockDurationSeconds(tier);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Calculates the pending reward using a closed-form geometric series (O(1)).
     *
     *      SUM(phi^{-(k+1)} for k=a..a+n-1) = phi^{-(a+1)} * (1 - phi^{-n}) / (1 - 1/phi)
     *      where (1 - 1/phi) = 1/phi^2 = 0.381966... in WAD.
     */
    function _calculateReward(address user) internal view returns (uint256 reward) {
        Stake storage s = stakes[user];
        if (s.amount == 0) return 0;

        uint256 stakeEpoch = (s.startTimestamp - genesisTimestamp) / EPOCH_DURATION;
        uint256 curEpoch = currentEpoch();
        if (curEpoch <= stakeEpoch) return 0;

        uint256 epochs = curEpoch - stakeEpoch;
        uint256 mul = tierMultiplier(s.tier);
        uint256 epochsPerYear = 52;

        // Closed-form geometric series
        uint256 firstTerm = PhiMath.phiInvPow(stakeEpoch + 1);
        uint256 decayFactor = PhiMath.phiInvPow(epochs);
        uint256 numerator = PhiMath.WAD - decayFactor;
        uint256 denominator = PhiMath.WAD - PhiMath.PHI_INV; // 1/phi^2

        uint256 geometricSum = PhiMath.wadMul(firstTerm, PhiMath.wadDiv(numerator, denominator));

        uint256 accumulatedReward = PhiMath.wadMul(s.amount, geometricSum);
        accumulatedReward = PhiMath.wadMul(accumulatedReward, mul);
        accumulatedReward = accumulatedReward / epochsPerYear;

        reward = accumulatedReward > s.rewardDebt ? accumulatedReward - s.rewardDebt : 0;
    }

    function _lockDurationSeconds(uint256 tier) internal pure returns (uint256) {
        if (tier == 0) return TIER_0_DAYS * SECONDS_PER_DAY;
        if (tier == 1) return TIER_1_DAYS * SECONDS_PER_DAY;
        if (tier == 2) return TIER_2_DAYS * SECONDS_PER_DAY;
        revert InvalidTier(tier);
    }

    // -------------------------------------------------------------------------
    // UUPS authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
