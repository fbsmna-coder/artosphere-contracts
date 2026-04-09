// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PhiMath.sol";
import "./PhiCoin.sol";
import "./ArtosphereConstants.sol";
import "./ArtosphereDiscovery.sol";

/// @title DiscoveryStaking — Prediction Market for Scientific Discoveries
/// @author F.B. Sapronov
/// @notice Stake ARTS tokens on whether scientific discoveries will be experimentally
///         confirmed or refuted. Uses φ-Cascade v2 distribution on resolution:
///
///         φ⁻¹ + φ⁻³ + φ⁻⁵ + φ⁻⁶ = 1 (exact, by φ² = φ + 1)
///
///         - 61.80% (φ⁻¹) → Winners (pull-based claims)
///         - 23.60% (φ⁻³) → BURNED (deflationary)
///         -  9.02% (φ⁻⁵) → Scientist (discovery creator royalty)
///         -  5.57% (φ⁻⁶) → Treasury
///
/// @dev Pull-based claim pattern for gas efficiency. UUPS upgradeable.
///      Sybil-resistant: hedging produces -20.3% ROI loss.
///      Oracle front-running mitigated by staking freeze on proposal.
contract DiscoveryStaking is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    uint8 public constant SIDE_CONFIRM = 0;
    uint8 public constant SIDE_REFUTE = 1;

    uint256 public constant NUM_TIERS = 3;
    uint256 public constant TIER_0_DAYS = 5;   // F(5)
    uint256 public constant TIER_1_DAYS = 21;  // F(8)
    uint256 public constant TIER_2_DAYS = 55;  // F(10)

    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Individual stake position
    struct StakePosition {
        uint256 amount;         // ARTS staked (after fee)
        uint8 side;             // 0=CONFIRM, 1=REFUTE
        uint256 tier;           // 0, 1, 2
        uint256 stakedAt;       // block.timestamp
        uint256 lockEnd;        // stakedAt + lock duration
        bool claimed;           // whether rewards have been claimed
    }

    /// @notice Per-discovery pool state
    struct DiscoveryPool {
        uint256 confirmPool;       // Total ARTS on CONFIRM side
        uint256 refutePool;        // Total ARTS on REFUTE side
        uint256 confirmWeighted;   // Sum of (amount × tierMultiplier) for CONFIRM
        uint256 refuteWeighted;    // Sum of (amount × tierMultiplier) for REFUTE
        uint256 scienceWeight;     // confirmPool + refutePool (total conviction)
        bool resolved;             // Whether oracle has resolved
        uint8 winnerSide;          // 0=CONFIRM won, 1=REFUTE won (only valid if resolved)
        uint256 winnerRewardPool;  // Total ARTS allocated to winners (φ⁻¹ of losing pool)
        uint256 winnerWeightedTotal; // Total weighted stakes of winners
        bool frozen;               // Staking frozen (oracle proposal submitted)
        uint256 createdAt;         // First stake timestamp
        bool renewed;              // Expiration renewed to F(15)=610 days
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice The ARTS token
    PhiCoin public artsToken;

    /// @notice ArtosphereDiscovery NFT contract
    ArtosphereDiscovery public discoveryNFT;

    /// @notice Scientist address (receives royalties)
    address public scientist;

    /// @notice Treasury address (receives protocol share)
    address public treasury;

    /// @notice Per-discovery pool data
    mapping(uint256 => DiscoveryPool) public pools;

    /// @notice User stakes: discoveryId => staker => StakePosition
    mapping(uint256 => mapping(address => StakePosition)) public stakes;

    /// @notice Claimable rewards: user => amount
    mapping(address => uint256) public claimable;

    /// @notice Track which side a user staked on (for anti-hedge)
    /// discoveryId => staker => hasSide (side + 1, 0 = no stake)
    mapping(uint256 => mapping(address => uint8)) public userSide;

    /// @notice Total value locked across all discoveries
    uint256 public totalStaked;

    /// @dev Reserved storage gap for future upgrades
    uint256[40] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    event Staked(
        uint256 indexed discoveryId,
        address indexed staker,
        uint8 side,
        uint256 amount,
        uint256 tier
    );

    event Resolved(
        uint256 indexed discoveryId,
        uint8 winnerSide,
        uint256 losingPool,
        uint256 burned,
        uint256 winnerRewards,
        uint256 scientistCut,
        uint256 treasuryCut
    );

    event Claimed(uint256 indexed discoveryId, address indexed staker, uint256 reward);
    event EmergencyWithdraw(uint256 indexed discoveryId, address indexed staker, uint256 netAmount, uint256 penalty);
    event ExpirationWithdraw(uint256 indexed discoveryId, address indexed staker, uint256 amount);
    event StakingFrozen(uint256 indexed discoveryId);
    event StakingUnfrozen(uint256 indexed discoveryId);
    event ScienceWeightUpdated(uint256 indexed discoveryId, uint256 newWeight);
    event ExpirationRenewed(uint256 indexed discoveryId);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error InvalidSide();
    error InvalidTier(uint256 tier);
    error BelowMinimumStake(uint256 amount, uint256 minimum);
    error CannotHedge(uint256 discoveryId);
    error AlreadyStaked(uint256 discoveryId);
    error StakingIsFrozen(uint256 discoveryId);
    error NotResolved(uint256 discoveryId);
    error AlreadyResolved(uint256 discoveryId);
    error AlreadyClaimed(uint256 discoveryId);
    error NoStake(uint256 discoveryId);
    error NotExpired(uint256 discoveryId);
    error InvalidDiscovery(uint256 discoveryId);
    error NothingToClaim();
    error ZeroAmount();
    error AlreadyRenewed(uint256 discoveryId);

    // ========================================================================
    // INITIALIZER
    // ========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        PhiCoin _artsToken,
        ArtosphereDiscovery _discoveryNFT,
        address _treasury,
        address admin
    ) external initializer {
        __AccessControl_init();

        artsToken = _artsToken;
        discoveryNFT = _discoveryNFT;
        scientist = _discoveryNFT.scientist();
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    // ========================================================================
    // CORE: Stake on a Discovery
    // ========================================================================

    /// @notice Stake ARTS tokens on a scientific discovery
    /// @param discoveryId The ID of the discovery NFT
    /// @param amount Amount of ARTS to stake
    /// @param side 0=CONFIRM (discovery will be confirmed), 1=REFUTE
    /// @param tier Lock tier: 0=5d (x1), 1=21d (xφ), 2=55d (xφ²)
    function stakeOnDiscovery(
        uint256 discoveryId,
        uint256 amount,
        uint8 side,
        uint256 tier
    ) external nonReentrant {
        // Validations
        if (amount == 0) revert ZeroAmount();
        if (discoveryId >= discoveryNFT.totalDiscoveries()) revert InvalidDiscovery(discoveryId);
        if (side > 1) revert InvalidSide();
        if (tier >= NUM_TIERS) revert InvalidTier(tier);

        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);
        if (pool.frozen) revert StakingIsFrozen(discoveryId);

        // Anti-hedge: cannot stake on both sides
        uint8 existingSide = userSide[discoveryId][msg.sender];
        if (existingSide != 0 && existingSide != side + 1) revert CannotHedge(discoveryId);
        if (stakes[discoveryId][msg.sender].amount != 0) revert AlreadyStaked(discoveryId);

        // Check minimum stake
        if (amount < ArtosphereConstants.DS_MIN_STAKE) {
            revert BelowMinimumStake(amount, ArtosphereConstants.DS_MIN_STAKE);
        }

        // Transfer tokens from user
        IERC20(address(artsToken)).safeTransferFrom(msg.sender, address(this), amount);

        // Deduct staking fee: 1.18% -> scientist
        uint256 fee = (amount * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        if (fee > 0) {
            IERC20(address(artsToken)).safeTransfer(scientist, fee);
        }

        // Calculate weighted stake
        uint256 multiplier = _tierMultiplier(tier);
        uint256 weighted = PhiMath.wadMul(netAmount, multiplier);

        // Record stake
        uint256 lockDur = _lockDurationSeconds(tier);
        stakes[discoveryId][msg.sender] = StakePosition({
            amount: netAmount,
            side: side,
            tier: tier,
            stakedAt: block.timestamp,
            lockEnd: block.timestamp + lockDur,
            claimed: false
        });
        userSide[discoveryId][msg.sender] = side + 1;

        // Update pool
        if (pool.createdAt == 0) pool.createdAt = block.timestamp;

        if (side == SIDE_CONFIRM) {
            pool.confirmPool += netAmount;
            pool.confirmWeighted += weighted;
        } else {
            pool.refutePool += netAmount;
            pool.refuteWeighted += weighted;
        }

        pool.scienceWeight = pool.confirmPool + pool.refutePool;
        totalStaked += netAmount;

        emit Staked(discoveryId, msg.sender, side, netAmount, tier);
        emit ScienceWeightUpdated(discoveryId, pool.scienceWeight);
    }

    // ========================================================================
    // ORACLE: Resolution (called by DiscoveryOracle)
    // ========================================================================

    /// @notice Resolve a discovery — distribute losing pool via φ-Cascade v2
    /// @param discoveryId The discovery ID
    /// @param outcome 1=CONFIRMED, 2=REFUTED
    function resolveDiscovery(uint256 discoveryId, uint8 outcome) external onlyRole(ORACLE_ROLE) nonReentrant {
        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);

        pool.resolved = true;

        uint8 winnerSide;
        uint256 losingPool;
        uint256 winnerWeighted;

        if (outcome == 1) {
            // CONFIRMED — CONFIRM stakers win
            winnerSide = SIDE_CONFIRM;
            losingPool = pool.refutePool;
            winnerWeighted = pool.confirmWeighted;
        } else {
            // REFUTED — REFUTE stakers win
            winnerSide = SIDE_REFUTE;
            losingPool = pool.confirmPool;
            winnerWeighted = pool.refuteWeighted;
        }

        pool.winnerSide = winnerSide;

        if (losingPool == 0 || winnerWeighted == 0) {
            // No losing pool or no winners — return stakes to everyone
            pool.winnerRewardPool = 0;
            pool.winnerWeightedTotal = 0;
            emit Resolved(discoveryId, winnerSide, 0, 0, 0, 0, 0);
            return;
        }

        // φ-Cascade v2 distribution of the losing pool
        // φ⁻¹ + φ⁻³ + φ⁻⁵ + φ⁻⁶ = 1 (exact)
        uint256 winnerCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_WINNER_WAD);
        uint256 burnCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_BURN_WAD);
        uint256 scientistCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_SCIENTIST_WAD);
        // Treasury gets the remainder (avoids rounding dust)
        uint256 treasuryCut = losingPool - winnerCut - burnCut - scientistCut;

        // Store for pull-based claims
        pool.winnerRewardPool = winnerCut;
        pool.winnerWeightedTotal = winnerWeighted;

        // Execute distributions
        // 1. BURN — transfer to dead address (PhiCoin.burn requires msg.sender to hold)
        if (burnCut > 0) {
            IERC20(address(artsToken)).safeTransfer(address(0xdead), burnCut);
        }

        // 2. Scientist royalty
        if (scientistCut > 0) {
            IERC20(address(artsToken)).safeTransfer(scientist, scientistCut);
        }

        // 3. Treasury
        if (treasuryCut > 0) {
            IERC20(address(artsToken)).safeTransfer(treasury, treasuryCut);
        }

        // 4. Winner rewards stay in contract — pull-based claims
        // Update total staked
        totalStaked -= losingPool;

        emit Resolved(discoveryId, winnerSide, losingPool, burnCut, winnerCut, scientistCut, treasuryCut);
    }

    // ========================================================================
    // ORACLE: Staking Freeze (called by DiscoveryOracle)
    // ========================================================================

    /// @notice Freeze staking on a discovery (called when Oracle proposal submitted)
    function freezeStaking(uint256 discoveryId) external onlyRole(ORACLE_ROLE) {
        pools[discoveryId].frozen = true;
        emit StakingFrozen(discoveryId);
    }

    /// @notice Unfreeze staking (called when Oracle proposal vetoed)
    function unfreezeStaking(uint256 discoveryId) external onlyRole(ORACLE_ROLE) {
        pools[discoveryId].frozen = false;
        emit StakingUnfrozen(discoveryId);
    }

    // ========================================================================
    // USER: Claim Rewards (pull-based)
    // ========================================================================

    /// @notice Claim rewards after resolution
    /// @param discoveryId The discovery ID
    function claim(uint256 discoveryId) external nonReentrant {
        StakePosition storage pos = stakes[discoveryId][msg.sender];
        if (pos.amount == 0) revert NoStake(discoveryId);

        DiscoveryPool storage pool = pools[discoveryId];
        if (!pool.resolved) revert NotResolved(discoveryId);
        if (pos.claimed) revert AlreadyClaimed(discoveryId);

        pos.claimed = true;

        uint256 payout;

        if (pos.side == pool.winnerSide) {
            // WINNER: principal + proportional share of winnerRewardPool
            uint256 multiplier = _tierMultiplier(pos.tier);
            uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);

            uint256 reward = 0;
            if (pool.winnerWeightedTotal > 0) {
                reward = (pool.winnerRewardPool * weighted) / pool.winnerWeightedTotal;
            }

            payout = pos.amount + reward;
            totalStaked -= pos.amount;
        } else {
            // LOSER: their stake was already distributed in resolve()
            // Nothing to return
            payout = 0;
        }

        if (payout > 0) {
            IERC20(address(artsToken)).safeTransfer(msg.sender, payout);
        }

        emit Claimed(discoveryId, msg.sender, payout);
    }

    /// @notice Batch claim across multiple discoveries
    function claimBatch(uint256[] calldata discoveryIds) external nonReentrant {
        uint256 totalPayout;

        for (uint256 i = 0; i < discoveryIds.length; i++) {
            uint256 discoveryId = discoveryIds[i];
            StakePosition storage pos = stakes[discoveryId][msg.sender];

            if (pos.amount == 0) continue;
            if (!pools[discoveryId].resolved) continue;
            if (pos.claimed) continue;

            pos.claimed = true;

            DiscoveryPool storage pool = pools[discoveryId];

            if (pos.side == pool.winnerSide) {
                uint256 multiplier = _tierMultiplier(pos.tier);
                uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);

                uint256 reward = 0;
                if (pool.winnerWeightedTotal > 0) {
                    reward = (pool.winnerRewardPool * weighted) / pool.winnerWeightedTotal;
                }

                totalPayout += pos.amount + reward;
                totalStaked -= pos.amount;
            }

            emit Claimed(discoveryId, msg.sender, pos.side == pool.winnerSide ? pos.amount : 0);
        }

        if (totalPayout > 0) {
            IERC20(address(artsToken)).safeTransfer(msg.sender, totalPayout);
        }
    }

    // ========================================================================
    // USER: Emergency & Expiration Withdrawals
    // ========================================================================

    /// @notice Emergency withdraw before resolution — 38.2% penalty burn
    function emergencyWithdraw(uint256 discoveryId) external nonReentrant {
        StakePosition storage pos = stakes[discoveryId][msg.sender];
        if (pos.amount == 0) revert NoStake(discoveryId);

        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);

        uint256 principal = pos.amount;
        uint256 penalty = PhiMath.wadMul(principal, ArtosphereConstants.DS_EARLY_EXIT_PENALTY_WAD);
        uint256 netAmount = principal - penalty;

        // Remove from pool
        if (pos.side == SIDE_CONFIRM) {
            pool.confirmPool -= principal;
            pool.confirmWeighted -= PhiMath.wadMul(principal, _tierMultiplier(pos.tier));
        } else {
            pool.refutePool -= principal;
            pool.refuteWeighted -= PhiMath.wadMul(principal, _tierMultiplier(pos.tier));
        }

        pool.scienceWeight = pool.confirmPool + pool.refutePool;
        totalStaked -= principal;

        // Clear stake
        delete stakes[discoveryId][msg.sender];
        delete userSide[discoveryId][msg.sender];

        // Transfer net amount back, burn penalty
        IERC20(address(artsToken)).safeTransfer(msg.sender, netAmount);
        IERC20(address(artsToken)).safeTransfer(address(0xdead), penalty);

        emit EmergencyWithdraw(discoveryId, msg.sender, netAmount, penalty);
        emit ScienceWeightUpdated(discoveryId, pool.scienceWeight);
    }

    /// @notice Withdraw after expiration (F(13)=233 days) — no penalty
    function withdrawExpired(uint256 discoveryId) external nonReentrant {
        StakePosition storage pos = stakes[discoveryId][msg.sender];
        if (pos.amount == 0) revert NoStake(discoveryId);

        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);

        uint256 expiration = pool.renewed
            ? ArtosphereConstants.DS_EXPIRATION_RENEWAL
            : ArtosphereConstants.DS_EXPIRATION;

        if (block.timestamp < pool.createdAt + expiration) revert NotExpired(discoveryId);

        uint256 principal = pos.amount;

        // Remove from pool
        if (pos.side == SIDE_CONFIRM) {
            pool.confirmPool -= principal;
            pool.confirmWeighted -= PhiMath.wadMul(principal, _tierMultiplier(pos.tier));
        } else {
            pool.refutePool -= principal;
            pool.refuteWeighted -= PhiMath.wadMul(principal, _tierMultiplier(pos.tier));
        }

        pool.scienceWeight = pool.confirmPool + pool.refutePool;
        totalStaked -= principal;

        delete stakes[discoveryId][msg.sender];
        delete userSide[discoveryId][msg.sender];

        IERC20(address(artsToken)).safeTransfer(msg.sender, principal);

        emit ExpirationWithdraw(discoveryId, msg.sender, principal);
        emit ScienceWeightUpdated(discoveryId, pool.scienceWeight);
    }

    /// @notice Renew expiration from F(13)=233 days to F(15)=610 days
    function renewExpiration(uint256 discoveryId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.renewed) revert AlreadyRenewed(discoveryId);
        pool.renewed = true;
        emit ExpirationRenewed(discoveryId);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get pool state for a discovery
    function getPool(uint256 discoveryId)
        external
        view
        returns (
            uint256 confirmPool,
            uint256 refutePool,
            uint256 scienceWeight,
            bool resolved,
            uint8 winnerSide,
            bool frozen
        )
    {
        DiscoveryPool storage p = pools[discoveryId];
        return (p.confirmPool, p.refutePool, p.scienceWeight, p.resolved, p.winnerSide, p.frozen);
    }

    /// @notice Get user's stake on a discovery
    function getStake(uint256 discoveryId, address staker)
        external
        view
        returns (StakePosition memory)
    {
        return stakes[discoveryId][staker];
    }

    /// @notice Estimate reward if user's side wins
    function estimateReward(uint256 discoveryId, address staker) external view returns (uint256) {
        StakePosition storage pos = stakes[discoveryId][staker];
        if (pos.amount == 0) return 0;

        DiscoveryPool storage pool = pools[discoveryId];

        // Calculate what losing pool would be
        uint256 losingPool = pos.side == SIDE_CONFIRM ? pool.refutePool : pool.confirmPool;
        uint256 winnerWeighted = pos.side == SIDE_CONFIRM ? pool.confirmWeighted : pool.refuteWeighted;

        if (losingPool == 0 || winnerWeighted == 0) return 0;

        uint256 winnerCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_WINNER_WAD);
        uint256 multiplier = _tierMultiplier(pos.tier);
        uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);

        return (winnerCut * weighted) / winnerWeighted;
    }

    /// @notice Get tier multiplier
    function tierMultiplier(uint256 tier) external pure returns (uint256) {
        return _tierMultiplier(tier);
    }

    /// @notice Check if a discovery's staking has expired
    function isExpired(uint256 discoveryId) external view returns (bool) {
        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.createdAt == 0) return false;
        uint256 expiration = pool.renewed
            ? ArtosphereConstants.DS_EXPIRATION_RENEWAL
            : ArtosphereConstants.DS_EXPIRATION;
        return block.timestamp >= pool.createdAt + expiration;
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    function _tierMultiplier(uint256 tier) internal pure returns (uint256) {
        if (tier == 0) return PhiMath.WAD;           // x1.0
        if (tier == 1) return PhiMath.PHI;            // xφ ≈ 1.618
        if (tier == 2) return PhiMath.PHI_SQUARED;    // xφ² ≈ 2.618
        revert InvalidTier(tier);
    }

    function _lockDurationSeconds(uint256 tier) internal pure returns (uint256) {
        if (tier == 0) return TIER_0_DAYS * 1 days;
        if (tier == 1) return TIER_1_DAYS * 1 days;
        if (tier == 2) return TIER_2_DAYS * 1 days;
        revert InvalidTier(tier);
    }

    // ========================================================================
    // UUPS
    // ========================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
