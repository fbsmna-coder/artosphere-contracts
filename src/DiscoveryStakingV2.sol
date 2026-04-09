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
import "./ConvictionNFT.sol";

/// @title DiscoveryStakingV2 — NFT-Based Prediction Market for Scientific Discoveries
/// @author F.B. Sapronov
/// @notice Upgraded Discovery Staking with ConvictionNFT integration.
///         Each stake() mints a transferable ConvictionNFT that encodes the position.
///         Claims are NFT-based: the current NFT holder receives the payout, and the
///         NFT is burned. This enables a secondary market for conviction positions.
///
///         φ-Cascade v2 distribution on resolution (unchanged):
///         φ⁻¹ + φ⁻³ + φ⁻⁵ + φ⁻⁶ = 1 (exact, by φ² = φ + 1)
///
///         - 61.80% (φ⁻¹) → Winners (pull-based claims via NFT)
///         - 23.60% (φ⁻³) → BURNED (deflationary)
///         -  9.02% (φ⁻⁵) → Scientist (discovery creator royalty)
///         -  5.57% (φ⁻⁶) → Treasury
///
/// @dev UUPS upgrade from DiscoveryStaking. Storage layout preserved:
///      - All V1 state variables remain in their original slots
///      - New variables (convictionNFT, nftStakes) appended AFTER __gap
///      - __gap reduced from 40 to 37 slots to accommodate 3 new variables
///      - reinitializer(2) used for upgrade initialization
///      - Legacy `stakes` mapping preserved for backward-compatible reads
///      - New stakes use ConvictionNFT; claims accept tokenId
contract DiscoveryStakingV2 is
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

    /// @notice Individual stake position (V1 legacy — kept for storage compatibility)
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
        uint256 confirmWeighted;   // Sum of (amount * tierMultiplier) for CONFIRM
        uint256 refuteWeighted;    // Sum of (amount * tierMultiplier) for REFUTE
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
    // STATE — V1 LAYOUT (DO NOT REORDER OR REMOVE)
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

    /// @notice User stakes: discoveryId => staker => StakePosition (V1 legacy)
    mapping(uint256 => mapping(address => StakePosition)) public stakes;

    /// @notice Claimable rewards: user => amount (V1 legacy, unused in V2)
    mapping(address => uint256) public claimable;

    /// @notice Track which side a user staked on (for anti-hedge)
    /// discoveryId => staker => hasSide (side + 1, 0 = no stake)
    mapping(uint256 => mapping(address => uint8)) public userSide;

    /// @notice Total value locked across all discoveries
    uint256 public totalStaked;

    // ========================================================================
    // STATE — V2 NEW VARIABLES (carved from __gap)
    // ========================================================================

    /// @notice ConvictionNFT contract for minting/burning position NFTs
    ConvictionNFT public convictionNFT;

    /// @notice Maps NFT tokenId => true if the NFT was claimed/burned via this contract
    mapping(uint256 => bool) public nftClaimed;

    /// @notice Maps NFT tokenId => true if the NFT was created via emergency withdraw path
    /// @dev Prevents double-accounting in pool removal
    mapping(uint256 => bool) public nftWithdrawn;

    /// @dev Reserved storage gap for future upgrades (reduced from 40 to 37)
    uint256[37] private __gap;

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

    /// @notice Emitted when a V2 stake mints a ConvictionNFT
    event StakedWithNFT(
        uint256 indexed discoveryId,
        address indexed staker,
        uint256 indexed tokenId,
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

    /// @notice Emitted when a V2 NFT-based claim is executed
    event ClaimedWithNFT(
        uint256 indexed discoveryId,
        uint256 indexed tokenId,
        address indexed holder,
        uint256 reward
    );

    event EmergencyWithdraw(uint256 indexed discoveryId, address indexed staker, uint256 netAmount, uint256 penalty);

    /// @notice Emitted when NFT-based emergency withdraw is executed
    event EmergencyWithdrawNFT(
        uint256 indexed discoveryId,
        uint256 indexed tokenId,
        address indexed holder,
        uint256 netAmount,
        uint256 penalty
    );

    event ExpirationWithdraw(uint256 indexed discoveryId, address indexed staker, uint256 amount);

    /// @notice Emitted when NFT-based expiration withdraw is executed
    event ExpirationWithdrawNFT(
        uint256 indexed discoveryId,
        uint256 indexed tokenId,
        address indexed holder,
        uint256 amount
    );

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
    error NotNFTHolder(uint256 tokenId);
    error NFTAlreadyClaimed(uint256 tokenId);
    error NFTAlreadyWithdrawn(uint256 tokenId);
    error InvalidNFT(uint256 tokenId);

    // ========================================================================
    // INITIALIZER — V1 (preserved for storage layout)
    // ========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice V1 initializer — DO NOT call again after upgrade
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
    // INITIALIZER — V2 (called on upgrade)
    // ========================================================================

    /// @notice V2 upgrade initializer — sets ConvictionNFT reference
    /// @param _convictionNFT The ConvictionNFT contract (must grant MINTER_ROLE to this contract)
    function initializeV2(ConvictionNFT _convictionNFT) external reinitializer(2) {
        convictionNFT = _convictionNFT;
    }

    // ========================================================================
    // CORE: Stake on a Discovery (V2 — mints ConvictionNFT)
    // ========================================================================

    /// @notice Stake ARTS tokens on a scientific discovery, receiving a ConvictionNFT
    /// @param discoveryId The ID of the discovery NFT
    /// @param amount Amount of ARTS to stake
    /// @param side 0=CONFIRM (discovery will be confirmed), 1=REFUTE
    /// @param tier Lock tier: 0=5d (x1), 1=21d (xφ), 2=55d (xφ²)
    /// @return tokenId The minted ConvictionNFT token ID
    function stake(
        uint256 discoveryId,
        uint256 amount,
        uint8 side,
        uint256 tier
    ) external nonReentrant returns (uint256 tokenId) {
        // Validations
        if (amount == 0) revert ZeroAmount();
        if (discoveryId >= discoveryNFT.totalDiscoveries()) revert InvalidDiscovery(discoveryId);
        if (side > 1) revert InvalidSide();
        if (tier >= NUM_TIERS) revert InvalidTier(tier);

        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);
        if (pool.frozen) revert StakingIsFrozen(discoveryId);

        // Anti-hedge: cannot stake on both sides (uses original staker identity)
        uint8 existingSide = userSide[discoveryId][msg.sender];
        if (existingSide != 0 && existingSide != side + 1) revert CannotHedge(discoveryId);

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

        // Calculate lock duration
        uint256 lockDur = _lockDurationSeconds(tier);
        uint256 lockEnd = block.timestamp + lockDur;

        // Mint ConvictionNFT with position data
        string memory title = discoveryNFT.getDiscovery(discoveryId).title;
        tokenId = convictionNFT.mint(
            msg.sender,
            discoveryId,
            side,
            netAmount,
            uint8(tier),
            title
        );

        // Record anti-hedge mapping (tracks original staker, not NFT holder)
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
        emit StakedWithNFT(discoveryId, msg.sender, tokenId, side, netAmount, tier);
        emit ScienceWeightUpdated(discoveryId, pool.scienceWeight);
    }

    // ========================================================================
    // V1 LEGACY: stakeOnDiscovery (backward compatibility for existing callers)
    // ========================================================================

    /// @notice Legacy stake function — redirects to stake() and returns NFT tokenId
    /// @dev Maintained for backward compatibility with existing integrations
    function stakeOnDiscovery(
        uint256 discoveryId,
        uint256 amount,
        uint8 side,
        uint256 tier
    ) external nonReentrant returns (uint256 tokenId) {
        // Re-enter via internal path to avoid double nonReentrant
        return _stakeInternal(discoveryId, amount, side, tier);
    }

    // ========================================================================
    // ORACLE: Resolution (unchanged from V1)
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
            winnerSide = SIDE_CONFIRM;
            losingPool = pool.refutePool;
            winnerWeighted = pool.confirmWeighted;
        } else {
            winnerSide = SIDE_REFUTE;
            losingPool = pool.confirmPool;
            winnerWeighted = pool.refuteWeighted;
        }

        pool.winnerSide = winnerSide;

        if (losingPool == 0 || winnerWeighted == 0) {
            pool.winnerRewardPool = 0;
            pool.winnerWeightedTotal = 0;
            emit Resolved(discoveryId, winnerSide, 0, 0, 0, 0, 0);
            return;
        }

        // φ-Cascade v2 distribution of the losing pool
        uint256 winnerCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_WINNER_WAD);
        uint256 burnCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_BURN_WAD);
        uint256 scientistCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_SCIENTIST_WAD);
        uint256 treasuryCut = losingPool - winnerCut - burnCut - scientistCut;

        pool.winnerRewardPool = winnerCut;
        pool.winnerWeightedTotal = winnerWeighted;

        // Execute distributions
        if (burnCut > 0) {
            IERC20(address(artsToken)).safeTransfer(address(0xdead), burnCut);
        }
        if (scientistCut > 0) {
            IERC20(address(artsToken)).safeTransfer(scientist, scientistCut);
        }
        if (treasuryCut > 0) {
            IERC20(address(artsToken)).safeTransfer(treasury, treasuryCut);
        }

        totalStaked -= losingPool;

        emit Resolved(discoveryId, winnerSide, losingPool, burnCut, winnerCut, scientistCut, treasuryCut);
    }

    // ========================================================================
    // ORACLE: Staking Freeze (unchanged from V1)
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
    // USER: Claim via ConvictionNFT (V2 primary path)
    // ========================================================================

    /// @notice Claim rewards using a ConvictionNFT. Pays the current NFT holder, burns NFT.
    /// @param tokenId The ConvictionNFT token ID
    function claim(uint256 tokenId) external nonReentrant {
        _claimByNFT(tokenId, msg.sender);
    }

    /// @notice Batch claim across multiple ConvictionNFTs
    /// @param tokenIds Array of ConvictionNFT token IDs to claim
    function claimBatch(uint256[] calldata tokenIds) external nonReentrant {
        uint256 totalPayout;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            totalPayout += _claimByNFTBatch(tokenIds[i], msg.sender);
        }

        if (totalPayout > 0) {
            IERC20(address(artsToken)).safeTransfer(msg.sender, totalPayout);
        }
    }

    // ========================================================================
    // USER: Legacy Claim (V1 backward compatibility)
    // ========================================================================

    /// @notice Claim rewards for a V1 legacy stake (pre-upgrade positions)
    /// @param discoveryId The discovery ID
    function claimLegacy(uint256 discoveryId) external nonReentrant {
        StakePosition storage pos = stakes[discoveryId][msg.sender];
        if (pos.amount == 0) revert NoStake(discoveryId);

        DiscoveryPool storage pool = pools[discoveryId];
        if (!pool.resolved) revert NotResolved(discoveryId);
        if (pos.claimed) revert AlreadyClaimed(discoveryId);

        pos.claimed = true;

        uint256 payout;

        if (pos.side == pool.winnerSide) {
            uint256 multiplier = _tierMultiplier(pos.tier);
            uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);

            uint256 reward = 0;
            if (pool.winnerWeightedTotal > 0) {
                reward = (pool.winnerRewardPool * weighted) / pool.winnerWeightedTotal;
            }

            payout = pos.amount + reward;
            totalStaked -= pos.amount;
        } else {
            payout = 0;
        }

        if (payout > 0) {
            IERC20(address(artsToken)).safeTransfer(msg.sender, payout);
        }

        emit Claimed(discoveryId, msg.sender, payout);
    }

    /// @notice Legacy batch claim for V1 positions
    function claimLegacyBatch(uint256[] calldata discoveryIds) external nonReentrant {
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
    // USER: Emergency Withdraw via NFT (V2)
    // ========================================================================

    /// @notice Emergency withdraw before resolution using ConvictionNFT — 38.2% penalty burn
    /// @param tokenId The ConvictionNFT token ID
    function emergencyWithdraw(uint256 tokenId) external nonReentrant {
        // Verify caller is NFT holder
        if (!convictionNFT.exists(tokenId)) revert InvalidNFT(tokenId);
        if (convictionNFT.ownerOf(tokenId) != msg.sender) revert NotNFTHolder(tokenId);
        if (nftClaimed[tokenId]) revert NFTAlreadyClaimed(tokenId);
        if (nftWithdrawn[tokenId]) revert NFTAlreadyWithdrawn(tokenId);

        ConvictionNFT.ConvictionPosition memory pos = convictionNFT.getPosition(tokenId);
        DiscoveryPool storage pool = pools[pos.discoveryId];
        if (pool.resolved) revert AlreadyResolved(pos.discoveryId);

        uint256 principal = pos.amount;
        uint256 penalty = PhiMath.wadMul(principal, ArtosphereConstants.DS_EARLY_EXIT_PENALTY_WAD);
        uint256 netAmount = principal - penalty;

        // Remove from pool
        uint256 weighted = PhiMath.wadMul(principal, _tierMultiplier(uint256(pos.tier)));
        if (pos.side == SIDE_CONFIRM) {
            pool.confirmPool -= principal;
            pool.confirmWeighted -= weighted;
        } else {
            pool.refutePool -= principal;
            pool.refuteWeighted -= weighted;
        }

        pool.scienceWeight = pool.confirmPool + pool.refutePool;
        totalStaked -= principal;

        // Mark as withdrawn and burn NFT
        nftWithdrawn[tokenId] = true;
        convictionNFT.burn(tokenId);

        // Transfer net amount back, burn penalty
        IERC20(address(artsToken)).safeTransfer(msg.sender, netAmount);
        IERC20(address(artsToken)).safeTransfer(address(0xdead), penalty);

        emit EmergencyWithdrawNFT(pos.discoveryId, tokenId, msg.sender, netAmount, penalty);
        emit ScienceWeightUpdated(pos.discoveryId, pool.scienceWeight);
    }

    /// @notice Legacy emergency withdraw for V1 positions
    function emergencyWithdrawLegacy(uint256 discoveryId) external nonReentrant {
        StakePosition storage pos = stakes[discoveryId][msg.sender];
        if (pos.amount == 0) revert NoStake(discoveryId);

        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);

        uint256 principal = pos.amount;
        uint256 penalty = PhiMath.wadMul(principal, ArtosphereConstants.DS_EARLY_EXIT_PENALTY_WAD);
        uint256 netAmount = principal - penalty;

        uint256 weighted = PhiMath.wadMul(principal, _tierMultiplier(pos.tier));
        if (pos.side == SIDE_CONFIRM) {
            pool.confirmPool -= principal;
            pool.confirmWeighted -= weighted;
        } else {
            pool.refutePool -= principal;
            pool.refuteWeighted -= weighted;
        }

        pool.scienceWeight = pool.confirmPool + pool.refutePool;
        totalStaked -= principal;

        delete stakes[discoveryId][msg.sender];
        delete userSide[discoveryId][msg.sender];

        IERC20(address(artsToken)).safeTransfer(msg.sender, netAmount);
        IERC20(address(artsToken)).safeTransfer(address(0xdead), penalty);

        emit EmergencyWithdraw(discoveryId, msg.sender, netAmount, penalty);
        emit ScienceWeightUpdated(discoveryId, pool.scienceWeight);
    }

    // ========================================================================
    // USER: Expiration Withdraw via NFT (V2)
    // ========================================================================

    /// @notice Withdraw after expiration using ConvictionNFT — no penalty
    /// @param tokenId The ConvictionNFT token ID
    function withdrawExpired(uint256 tokenId) external nonReentrant {
        if (!convictionNFT.exists(tokenId)) revert InvalidNFT(tokenId);
        if (convictionNFT.ownerOf(tokenId) != msg.sender) revert NotNFTHolder(tokenId);
        if (nftClaimed[tokenId]) revert NFTAlreadyClaimed(tokenId);
        if (nftWithdrawn[tokenId]) revert NFTAlreadyWithdrawn(tokenId);

        ConvictionNFT.ConvictionPosition memory pos = convictionNFT.getPosition(tokenId);
        DiscoveryPool storage pool = pools[pos.discoveryId];
        if (pool.resolved) revert AlreadyResolved(pos.discoveryId);

        uint256 expiration = pool.renewed
            ? ArtosphereConstants.DS_EXPIRATION_RENEWAL
            : ArtosphereConstants.DS_EXPIRATION;

        if (block.timestamp < pool.createdAt + expiration) revert NotExpired(pos.discoveryId);

        uint256 principal = pos.amount;
        uint256 weighted = PhiMath.wadMul(principal, _tierMultiplier(uint256(pos.tier)));

        if (pos.side == SIDE_CONFIRM) {
            pool.confirmPool -= principal;
            pool.confirmWeighted -= weighted;
        } else {
            pool.refutePool -= principal;
            pool.refuteWeighted -= weighted;
        }

        pool.scienceWeight = pool.confirmPool + pool.refutePool;
        totalStaked -= principal;

        nftWithdrawn[tokenId] = true;
        convictionNFT.burn(tokenId);

        IERC20(address(artsToken)).safeTransfer(msg.sender, principal);

        emit ExpirationWithdrawNFT(pos.discoveryId, tokenId, msg.sender, principal);
        emit ScienceWeightUpdated(pos.discoveryId, pool.scienceWeight);
    }

    /// @notice Legacy withdraw after expiration for V1 positions
    function withdrawExpiredLegacy(uint256 discoveryId) external nonReentrant {
        StakePosition storage pos = stakes[discoveryId][msg.sender];
        if (pos.amount == 0) revert NoStake(discoveryId);

        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);

        uint256 expiration = pool.renewed
            ? ArtosphereConstants.DS_EXPIRATION_RENEWAL
            : ArtosphereConstants.DS_EXPIRATION;

        if (block.timestamp < pool.createdAt + expiration) revert NotExpired(discoveryId);

        uint256 principal = pos.amount;
        uint256 weighted = PhiMath.wadMul(principal, _tierMultiplier(pos.tier));

        if (pos.side == SIDE_CONFIRM) {
            pool.confirmPool -= principal;
            pool.confirmWeighted -= weighted;
        } else {
            pool.refutePool -= principal;
            pool.refuteWeighted -= weighted;
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

    /// @notice Get V1 legacy stake for a user on a discovery
    function getStake(uint256 discoveryId, address staker)
        external
        view
        returns (StakePosition memory)
    {
        return stakes[discoveryId][staker];
    }

    /// @notice Get position data from a ConvictionNFT
    function getNFTPosition(uint256 tokenId) external view returns (ConvictionNFT.ConvictionPosition memory) {
        return convictionNFT.getPosition(tokenId);
    }

    /// @notice Estimate reward for an NFT position if its side wins
    function estimateRewardNFT(uint256 tokenId) external view returns (uint256) {
        if (!convictionNFT.exists(tokenId)) return 0;

        ConvictionNFT.ConvictionPosition memory pos = convictionNFT.getPosition(tokenId);
        DiscoveryPool storage pool = pools[pos.discoveryId];

        uint256 losingPool = pos.side == SIDE_CONFIRM ? pool.refutePool : pool.confirmPool;
        uint256 winnerWeighted = pos.side == SIDE_CONFIRM ? pool.confirmWeighted : pool.refuteWeighted;

        if (losingPool == 0 || winnerWeighted == 0) return 0;

        uint256 winnerCut = PhiMath.wadMul(losingPool, ArtosphereConstants.DS_WINNER_WAD);
        uint256 multiplier = _tierMultiplier(uint256(pos.tier));
        uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);

        return (winnerCut * weighted) / winnerWeighted;
    }

    /// @notice Legacy: Estimate reward for a V1 stake
    function estimateReward(uint256 discoveryId, address staker) external view returns (uint256) {
        StakePosition storage pos = stakes[discoveryId][staker];
        if (pos.amount == 0) return 0;

        DiscoveryPool storage pool = pools[discoveryId];

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

    /// @dev Internal stake logic shared by stake() and stakeOnDiscovery()
    function _stakeInternal(
        uint256 discoveryId,
        uint256 amount,
        uint8 side,
        uint256 tier
    ) internal returns (uint256 tokenId) {
        if (amount == 0) revert ZeroAmount();
        if (discoveryId >= discoveryNFT.totalDiscoveries()) revert InvalidDiscovery(discoveryId);
        if (side > 1) revert InvalidSide();
        if (tier >= NUM_TIERS) revert InvalidTier(tier);

        DiscoveryPool storage pool = pools[discoveryId];
        if (pool.resolved) revert AlreadyResolved(discoveryId);
        if (pool.frozen) revert StakingIsFrozen(discoveryId);

        uint8 existingSide = userSide[discoveryId][msg.sender];
        if (existingSide != 0 && existingSide != side + 1) revert CannotHedge(discoveryId);

        if (amount < ArtosphereConstants.DS_MIN_STAKE) {
            revert BelowMinimumStake(amount, ArtosphereConstants.DS_MIN_STAKE);
        }

        IERC20(address(artsToken)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 fee = (amount * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        if (fee > 0) {
            IERC20(address(artsToken)).safeTransfer(scientist, fee);
        }

        uint256 multiplier = _tierMultiplier(tier);
        uint256 weighted = PhiMath.wadMul(netAmount, multiplier);

        uint256 lockDur = _lockDurationSeconds(tier);
        uint256 lockEnd = block.timestamp + lockDur;

        {
            string memory title = discoveryNFT.getDiscovery(discoveryId).title;
            tokenId = convictionNFT.mint(
                msg.sender,
                discoveryId,
                side,
                netAmount,
                uint8(tier),
                title
            );
        }

        userSide[discoveryId][msg.sender] = side + 1;

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
        emit StakedWithNFT(discoveryId, msg.sender, tokenId, side, netAmount, tier);
        emit ScienceWeightUpdated(discoveryId, pool.scienceWeight);
    }

    /// @dev Claim a single NFT — transfers payout to holder, burns NFT
    function _claimByNFT(uint256 tokenId, address holder) internal {
        if (!convictionNFT.exists(tokenId)) revert InvalidNFT(tokenId);
        if (convictionNFT.ownerOf(tokenId) != holder) revert NotNFTHolder(tokenId);
        if (nftClaimed[tokenId]) revert NFTAlreadyClaimed(tokenId);

        ConvictionNFT.ConvictionPosition memory pos = convictionNFT.getPosition(tokenId);
        DiscoveryPool storage pool = pools[pos.discoveryId];
        if (!pool.resolved) revert NotResolved(pos.discoveryId);

        nftClaimed[tokenId] = true;

        uint256 payout;

        if (pos.side == pool.winnerSide) {
            uint256 multiplier = _tierMultiplier(uint256(pos.tier));
            uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);

            uint256 reward = 0;
            if (pool.winnerWeightedTotal > 0) {
                reward = (pool.winnerRewardPool * weighted) / pool.winnerWeightedTotal;
            }

            payout = pos.amount + reward;
            totalStaked -= pos.amount;
        } else {
            payout = 0;
        }

        // Mark claimed and burn the NFT (markClaimed verifies holder + burns)
        convictionNFT.markClaimed(tokenId, holder);

        if (payout > 0) {
            IERC20(address(artsToken)).safeTransfer(holder, payout);
        }

        emit ClaimedWithNFT(pos.discoveryId, tokenId, holder, payout);
    }

    /// @dev Batch variant — returns payout amount without transferring (caller aggregates)
    function _claimByNFTBatch(uint256 tokenId, address holder) internal returns (uint256 payout) {
        if (!convictionNFT.exists(tokenId)) return 0;
        if (convictionNFT.ownerOf(tokenId) != holder) revert NotNFTHolder(tokenId);
        if (nftClaimed[tokenId]) return 0;

        ConvictionNFT.ConvictionPosition memory pos = convictionNFT.getPosition(tokenId);
        DiscoveryPool storage pool = pools[pos.discoveryId];
        if (!pool.resolved) return 0;

        nftClaimed[tokenId] = true;

        if (pos.side == pool.winnerSide) {
            uint256 multiplier = _tierMultiplier(uint256(pos.tier));
            uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);

            uint256 reward = 0;
            if (pool.winnerWeightedTotal > 0) {
                reward = (pool.winnerRewardPool * weighted) / pool.winnerWeightedTotal;
            }

            payout = pos.amount + reward;
            totalStaked -= pos.amount;
        } else {
            payout = 0;
        }

        convictionNFT.markClaimed(tokenId, holder);

        emit ClaimedWithNFT(pos.discoveryId, tokenId, holder, payout);
    }

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
