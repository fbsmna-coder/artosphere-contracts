// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PhiMath.sol";
import "./ArtosphereConstants.sol";
import "./ArtosphereDiscovery.sol";

/// @title FalsificationMarket — Popperian Falsification Prediction Market
/// @author F.B. Sapronov
/// @notice The only protocol where scientific falsification is economically profitable.
///         Implements Karl Popper's epistemology on-chain: hypotheses gain value by
///         surviving falsification attempts, not by accumulating confirmations.
///
///         MECHANICS:
///         - Author publishes a hypothesis linked to an ArtosphereDiscovery, stakes ARTS
///         - Falsifiers stake ARTS on specific falsification methods
///         - Oracle resolves each attempt: SURVIVED or FALSIFIED
///         - If FALSIFIED: falsifier wins author's stake via φ-Cascade + φ bonus on own stake
///         - If SURVIVED: author wins falsifier's stake via φ-Cascade, hardness score grows
///         - Hardness multiplier = φ^(survivals/5) — used by Spectral NFTs for confidence
///
///         DISTRIBUTION (φ-Cascade v2, exact: φ⁻¹ + φ⁻³ + φ⁻⁵ + φ⁻⁶ = 1):
///         - 61.80% (φ⁻¹) → Winner (falsifier if falsified, author if survived)
///         - 23.60% (φ⁻³) → BURNED (deflationary pressure)
///         -  9.02% (φ⁻⁵) → Scientist (discovery creator royalty)
///         -  5.57% (φ⁻⁶) → Treasury
///
/// @dev Pull-based rewards. AccessControl for ADMIN_ROLE and ORACLE_ROLE.
///      ReentrancyGuard on all state-mutating external functions.
///      Uses PhiMath for φ-calculations, ArtosphereConstants for distribution constants.
contract FalsificationMarket is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Admin role — can manage roles, pause, emergency actions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Oracle role — resolves falsification attempts
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ========================================================================
    // ENUMS
    // ========================================================================

    /// @notice Status of a hypothesis
    enum HypothesisStatus { ACTIVE, FALSIFIED, RETIRED }

    /// @notice Status of a falsification attempt
    enum AttemptStatus { PENDING, RESOLVED_SURVIVED, RESOLVED_FALSIFIED, EXPIRED }

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice A scientific hypothesis submitted to the falsification market
    struct Hypothesis {
        address author;              // Creator of the hypothesis
        uint256 discoveryId;         // Links to ArtosphereDiscovery NFT
        bytes32 contentHash;         // keccak256 of hypothesis content
        string title;                // Human-readable title
        uint256 authorStake;         // ARTS staked by author (WAD, after fee)
        uint256 totalFalsificationStake; // Total ARTS staked by all falsifiers
        uint256 survivals;           // Number of survived falsification attempts
        uint256 createdAt;           // Block timestamp at creation
        HypothesisStatus status;     // ACTIVE, FALSIFIED, or RETIRED
    }

    /// @notice A single falsification attempt against a hypothesis
    struct FalsificationAttempt {
        address falsifier;           // The falsifier's address
        bytes32 methodHash;          // keccak256 of falsification method description
        string method;               // Brief description of the falsification method
        uint256 stake;               // ARTS staked (WAD, after fee)
        uint256 submittedAt;         // Block timestamp at submission
        AttemptStatus status;        // PENDING, RESOLVED_SURVIVED, RESOLVED_FALSIFIED, EXPIRED
    }

    /// @notice Pending reward for pull-based claiming
    struct PendingReward {
        uint256 amount;              // ARTS claimable
        bool claimed;                // Whether already claimed
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice The ARTS ERC-20 token
    IERC20 public immutable artsToken;

    /// @notice The ArtosphereDiscovery soulbound NFT contract
    ArtosphereDiscovery public immutable discoveryNFT;

    /// @notice Scientist address (receives royalties from fees and φ-Cascade)
    address public immutable scientist;

    /// @notice Treasury address (receives protocol share)
    address public immutable treasury;

    /// @notice All hypotheses indexed by ID
    mapping(uint256 => Hypothesis) public hypotheses;

    /// @notice Next hypothesis ID
    uint256 public nextHypothesisId;

    /// @notice Falsification attempts: hypothesisId => attemptId => FalsificationAttempt
    mapping(uint256 => mapping(uint256 => FalsificationAttempt)) public attempts;

    /// @notice Next attempt ID per hypothesis
    mapping(uint256 => uint256) public nextAttemptId;

    /// @notice Count of PENDING attempts per hypothesis (for retirement check)
    mapping(uint256 => uint256) public pendingAttemptCount;

    /// @notice Pending rewards: hypothesisId => attemptId => beneficiary => PendingReward
    mapping(uint256 => mapping(uint256 => mapping(address => PendingReward))) public rewards;

    /// @notice Total value locked in the market
    uint256 public totalStaked;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new hypothesis is created
    event HypothesisCreated(
        uint256 indexed hypothesisId,
        address indexed author,
        uint256 indexed discoveryId,
        uint256 authorStake
    );

    /// @notice Emitted when a falsification attempt is submitted
    event FalsificationSubmitted(
        uint256 indexed hypothesisId,
        uint256 indexed attemptId,
        address indexed falsifier,
        uint256 stake
    );

    /// @notice Emitted when an attempt is resolved by the oracle
    event AttemptResolved(
        uint256 indexed hypothesisId,
        uint256 indexed attemptId,
        bool falsified,
        address beneficiary,
        uint256 reward
    );

    /// @notice Emitted when a hypothesis is retired by its author
    event HypothesisRetired(uint256 indexed hypothesisId, uint256 survivals);

    /// @notice Emitted when a hypothesis is falsified
    event HypothesisFalsified(
        uint256 indexed hypothesisId,
        uint256 indexed attemptId,
        address indexed falsifier
    );

    /// @notice Emitted when a reward is claimed
    event RewardClaimed(
        uint256 indexed hypothesisId,
        uint256 indexed attemptId,
        address indexed claimer,
        uint256 amount
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    error BelowMinimumStake(uint256 provided, uint256 required);
    error HypothesisNotActive(uint256 hypothesisId);
    error HypothesisNotFound(uint256 hypothesisId);
    error AttemptNotFound(uint256 hypothesisId, uint256 attemptId);
    error AttemptNotPending(uint256 hypothesisId, uint256 attemptId);
    error NotHypothesisAuthor(uint256 hypothesisId);
    error PendingAttemptsExist(uint256 hypothesisId, uint256 pendingCount);
    error NothingToClaim(uint256 hypothesisId, uint256 attemptId);
    error AlreadyClaimed(uint256 hypothesisId, uint256 attemptId);
    error InvalidDiscovery(uint256 discoveryId);
    error ZeroAddress();
    error CannotFalsifyOwnHypothesis(uint256 hypothesisId);

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the FalsificationMarket
    /// @param _artsToken Address of the ARTS ERC-20 token
    /// @param _discoveryNFT Address of the ArtosphereDiscovery NFT contract
    /// @param _scientist Address that receives scientist royalties
    /// @param _treasury Address that receives treasury share
    /// @param _admin Address that receives ADMIN_ROLE and DEFAULT_ADMIN_ROLE
    constructor(
        address _artsToken,
        address _discoveryNFT,
        address _scientist,
        address _treasury,
        address _admin
    ) {
        if (_artsToken == address(0)) revert ZeroAddress();
        if (_discoveryNFT == address(0)) revert ZeroAddress();
        if (_scientist == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        artsToken = IERC20(_artsToken);
        discoveryNFT = ArtosphereDiscovery(_discoveryNFT);
        scientist = _scientist;
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    // ========================================================================
    // CORE: Create Hypothesis
    // ========================================================================

    /// @notice Create a new hypothesis linked to an ArtosphereDiscovery, staking ARTS as conviction
    /// @param discoveryId The ID of the ArtosphereDiscovery NFT this hypothesis relates to
    /// @param contentHash keccak256 hash of the full hypothesis content (off-chain)
    /// @param title Human-readable title of the hypothesis
    /// @param stakeAmount Amount of ARTS to stake (must be >= DS_MIN_STAKE = 100 ARTS)
    /// @return hypothesisId The ID of the newly created hypothesis
    function createHypothesis(
        uint256 discoveryId,
        bytes32 contentHash,
        string calldata title,
        uint256 stakeAmount
    ) external nonReentrant returns (uint256 hypothesisId) {
        // Validate discovery exists
        if (discoveryId >= discoveryNFT.totalDiscoveries()) {
            revert InvalidDiscovery(discoveryId);
        }

        // Validate minimum stake
        if (stakeAmount < ArtosphereConstants.DS_MIN_STAKE) {
            revert BelowMinimumStake(stakeAmount, ArtosphereConstants.DS_MIN_STAKE);
        }

        // Transfer ARTS from author
        artsToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Deduct 1.18% fee to scientist (αₛ/10)
        uint256 fee = (stakeAmount * ArtosphereConstants.FEE_BPS) / 10000;
        uint256 netStake = stakeAmount - fee;

        if (fee > 0) {
            artsToken.safeTransfer(scientist, fee);
        }

        // Create hypothesis
        hypothesisId = nextHypothesisId++;

        hypotheses[hypothesisId] = Hypothesis({
            author: msg.sender,
            discoveryId: discoveryId,
            contentHash: contentHash,
            title: title,
            authorStake: netStake,
            totalFalsificationStake: 0,
            survivals: 0,
            createdAt: block.timestamp,
            status: HypothesisStatus.ACTIVE
        });

        totalStaked += netStake;

        emit HypothesisCreated(hypothesisId, msg.sender, discoveryId, netStake);
    }

    // ========================================================================
    // CORE: Submit Falsification Attempt
    // ========================================================================

    /// @notice Submit a falsification attempt against an active hypothesis
    /// @param hypothesisId The ID of the hypothesis to falsify
    /// @param methodHash keccak256 hash of the detailed falsification method (off-chain)
    /// @param method Brief human-readable description of the falsification method
    /// @param stakeAmount Amount of ARTS to stake (must be >= DS_MIN_STAKE = 100 ARTS)
    /// @return attemptId The ID of the falsification attempt within this hypothesis
    function submitFalsification(
        uint256 hypothesisId,
        bytes32 methodHash,
        string calldata method,
        uint256 stakeAmount
    ) external nonReentrant returns (uint256 attemptId) {
        // Validate hypothesis exists and is active
        if (hypothesisId >= nextHypothesisId) {
            revert HypothesisNotFound(hypothesisId);
        }
        Hypothesis storage h = hypotheses[hypothesisId];
        if (h.status != HypothesisStatus.ACTIVE) {
            revert HypothesisNotActive(hypothesisId);
        }

        // Prevent author from falsifying their own hypothesis
        if (msg.sender == h.author) {
            revert CannotFalsifyOwnHypothesis(hypothesisId);
        }

        // Validate minimum stake
        if (stakeAmount < ArtosphereConstants.DS_MIN_STAKE) {
            revert BelowMinimumStake(stakeAmount, ArtosphereConstants.DS_MIN_STAKE);
        }

        // Transfer ARTS from falsifier
        artsToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Deduct 1.18% fee to treasury
        uint256 fee = (stakeAmount * ArtosphereConstants.FEE_BPS) / 10000;
        uint256 netStake = stakeAmount - fee;

        if (fee > 0) {
            artsToken.safeTransfer(treasury, fee);
        }

        // Create falsification attempt
        attemptId = nextAttemptId[hypothesisId]++;

        attempts[hypothesisId][attemptId] = FalsificationAttempt({
            falsifier: msg.sender,
            methodHash: methodHash,
            method: method,
            stake: netStake,
            submittedAt: block.timestamp,
            status: AttemptStatus.PENDING
        });

        h.totalFalsificationStake += netStake;
        pendingAttemptCount[hypothesisId]++;
        totalStaked += netStake;

        emit FalsificationSubmitted(hypothesisId, attemptId, msg.sender, netStake);
    }

    // ========================================================================
    // ORACLE: Resolve Attempt
    // ========================================================================

    /// @notice Resolve a falsification attempt — oracle determines if the hypothesis was falsified
    /// @dev If falsified: hypothesis status → FALSIFIED, author's remaining stake distributed
    ///      via φ-Cascade to falsifier, burn, scientist, treasury. Falsifier gets own stake × φ bonus.
    ///      If survived: hypothesis survivals++, falsifier's stake distributed via φ-Cascade
    ///      to author, burn, scientist, treasury.
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The falsification attempt ID
    /// @param falsified True if the hypothesis was successfully falsified, false if it survived
    function resolveAttempt(
        uint256 hypothesisId,
        uint256 attemptId,
        bool falsified
    ) external onlyRole(ORACLE_ROLE) nonReentrant {
        // Validate
        if (hypothesisId >= nextHypothesisId) {
            revert HypothesisNotFound(hypothesisId);
        }
        Hypothesis storage h = hypotheses[hypothesisId];
        if (h.status != HypothesisStatus.ACTIVE) {
            revert HypothesisNotActive(hypothesisId);
        }
        if (attemptId >= nextAttemptId[hypothesisId]) {
            revert AttemptNotFound(hypothesisId, attemptId);
        }
        FalsificationAttempt storage a = attempts[hypothesisId][attemptId];
        if (a.status != AttemptStatus.PENDING) {
            revert AttemptNotPending(hypothesisId, attemptId);
        }

        // Decrement pending count
        pendingAttemptCount[hypothesisId]--;

        if (falsified) {
            _resolveFalsified(hypothesisId, attemptId, h, a);
        } else {
            _resolveSurvived(hypothesisId, attemptId, h, a);
        }
    }

    /// @dev Handle FALSIFIED resolution — falsifier wins
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The attempt ID
    /// @param h Storage pointer to hypothesis
    /// @param a Storage pointer to attempt
    function _resolveFalsified(
        uint256 hypothesisId,
        uint256 attemptId,
        Hypothesis storage h,
        FalsificationAttempt storage a
    ) internal {
        a.status = AttemptStatus.RESOLVED_FALSIFIED;
        h.status = HypothesisStatus.FALSIFIED;

        address falsifier = a.falsifier;
        uint256 authorStake = h.authorStake;
        uint256 falsifierStake = a.stake;

        // ---- Distribute author's remaining stake via φ-Cascade ----
        // φ⁻¹ (61.8%) to falsifier, φ⁻³ (23.6%) burned, φ⁻⁵ (9.02%) to scientist, φ⁻⁶ (5.57%) to treasury
        uint256 falsifierCut = PhiMath.wadMul(authorStake, ArtosphereConstants.DS_WINNER_WAD);
        uint256 burnCut = PhiMath.wadMul(authorStake, ArtosphereConstants.DS_BURN_WAD);
        uint256 scientistCut = PhiMath.wadMul(authorStake, ArtosphereConstants.DS_SCIENTIST_WAD);
        uint256 treasuryCut = authorStake - falsifierCut - burnCut - scientistCut; // remainder avoids dust

        // ---- BONUS: falsifier gets their own stake back × φ (1.618x) ----
        // The φ bonus is the protocol reward for finding truth.
        // Total falsifier payout = φ-Cascade share + (own stake × φ)
        uint256 falsifierBonus = PhiMath.wadMul(falsifierStake, PhiMath.PHI);
        uint256 totalFalsifierReward = falsifierCut + falsifierBonus;

        // Execute burn and distributions
        if (burnCut > 0) {
            artsToken.safeTransfer(address(0xdead), burnCut);
        }
        if (scientistCut > 0) {
            artsToken.safeTransfer(scientist, scientistCut);
        }
        if (treasuryCut > 0) {
            artsToken.safeTransfer(treasury, treasuryCut);
        }

        // Store falsifier reward for pull-based claim
        rewards[hypothesisId][attemptId][falsifier] = PendingReward({
            amount: totalFalsifierReward,
            claimed: false
        });

        // Update accounting: author stake is fully distributed, falsifier stake used for bonus
        // The extra φ-bonus above the falsifier's original stake comes from the contract's pool.
        // Net: authorStake is gone, falsifierStake transforms into falsifierBonus.
        // Difference (falsifierBonus - falsifierStake) is protocol subsidy from accumulated fees.
        h.authorStake = 0;
        totalStaked -= authorStake; // Author's stake leaves the pool (distributed)
        // Falsifier's stake remains locked until claimed (in totalStaked)

        // Expire all other PENDING attempts on this hypothesis — return stakes
        _expireRemainingAttempts(hypothesisId, attemptId);

        emit AttemptResolved(hypothesisId, attemptId, true, falsifier, totalFalsifierReward);
        emit HypothesisFalsified(hypothesisId, attemptId, falsifier);
    }

    /// @dev Handle SURVIVED resolution — author wins
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The attempt ID
    /// @param h Storage pointer to hypothesis
    /// @param a Storage pointer to attempt
    function _resolveSurvived(
        uint256 hypothesisId,
        uint256 attemptId,
        Hypothesis storage h,
        FalsificationAttempt storage a
    ) internal {
        a.status = AttemptStatus.RESOLVED_SURVIVED;

        // Increment survivals — the hypothesis grows stronger
        h.survivals++;

        address author = h.author;
        uint256 falsifierStake = a.stake;

        // ---- Distribute falsifier's stake via φ-Cascade ----
        // φ⁻¹ (61.8%) to author, φ⁻³ (23.6%) burned, φ⁻⁵ (9.02%) to scientist, φ⁻⁶ (5.57%) to treasury
        uint256 authorCut = PhiMath.wadMul(falsifierStake, ArtosphereConstants.DS_WINNER_WAD);
        uint256 burnCut = PhiMath.wadMul(falsifierStake, ArtosphereConstants.DS_BURN_WAD);
        uint256 scientistCut = PhiMath.wadMul(falsifierStake, ArtosphereConstants.DS_SCIENTIST_WAD);
        uint256 treasuryCut = falsifierStake - authorCut - burnCut - scientistCut; // remainder avoids dust

        // Execute burn and distributions
        if (burnCut > 0) {
            artsToken.safeTransfer(address(0xdead), burnCut);
        }
        if (scientistCut > 0) {
            artsToken.safeTransfer(scientist, scientistCut);
        }
        if (treasuryCut > 0) {
            artsToken.safeTransfer(treasury, treasuryCut);
        }

        // Store author reward for pull-based claim
        rewards[hypothesisId][attemptId][author] = PendingReward({
            amount: authorCut,
            claimed: false
        });

        // Update accounting
        h.totalFalsificationStake -= falsifierStake;
        totalStaked -= falsifierStake; // Falsifier's stake leaves the pool

        emit AttemptResolved(hypothesisId, attemptId, false, author, authorCut);
    }

    /// @dev Expire all remaining PENDING attempts when a hypothesis is falsified.
    ///      Returns stakes to the respective falsifiers via pending rewards.
    /// @param hypothesisId The hypothesis ID
    /// @param excludeAttemptId The winning attempt ID (already resolved, skip it)
    function _expireRemainingAttempts(uint256 hypothesisId, uint256 excludeAttemptId) internal {
        uint256 totalAttempts = nextAttemptId[hypothesisId];

        for (uint256 i = 0; i < totalAttempts;) {
            if (i != excludeAttemptId) {
                FalsificationAttempt storage a = attempts[hypothesisId][i];
                if (a.status == AttemptStatus.PENDING) {
                    a.status = AttemptStatus.EXPIRED;

                    // Return full stake to the expired falsifier
                    rewards[hypothesisId][i][a.falsifier] = PendingReward({
                        amount: a.stake,
                        claimed: false
                    });

                    pendingAttemptCount[hypothesisId]--;
                }
            }
            unchecked { ++i; }
        }
    }

    // ========================================================================
    // USER: Claim Reward (pull-based)
    // ========================================================================

    /// @notice Claim pending reward from a resolved or expired falsification attempt
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The falsification attempt ID
    function claimReward(uint256 hypothesisId, uint256 attemptId) external nonReentrant {
        PendingReward storage r = rewards[hypothesisId][attemptId][msg.sender];

        if (r.amount == 0) {
            revert NothingToClaim(hypothesisId, attemptId);
        }
        if (r.claimed) {
            revert AlreadyClaimed(hypothesisId, attemptId);
        }

        r.claimed = true;
        uint256 amount = r.amount;

        // Reduce totalStaked for claimed amounts (the stake is leaving the contract)
        totalStaked -= amount;

        artsToken.safeTransfer(msg.sender, amount);

        emit RewardClaimed(hypothesisId, attemptId, msg.sender, amount);
    }

    // ========================================================================
    // AUTHOR: Retire Hypothesis
    // ========================================================================

    /// @notice Retire an active hypothesis and reclaim remaining author stake
    /// @dev Only the hypothesis author can retire. No PENDING attempts may exist.
    ///      A 5.57% (φ⁻⁶) treasury fee is deducted from the returned stake.
    /// @param hypothesisId The hypothesis ID to retire
    function retireHypothesis(uint256 hypothesisId) external nonReentrant {
        if (hypothesisId >= nextHypothesisId) {
            revert HypothesisNotFound(hypothesisId);
        }
        Hypothesis storage h = hypotheses[hypothesisId];

        if (msg.sender != h.author) {
            revert NotHypothesisAuthor(hypothesisId);
        }
        if (h.status != HypothesisStatus.ACTIVE) {
            revert HypothesisNotActive(hypothesisId);
        }
        if (pendingAttemptCount[hypothesisId] > 0) {
            revert PendingAttemptsExist(hypothesisId, pendingAttemptCount[hypothesisId]);
        }

        h.status = HypothesisStatus.RETIRED;

        uint256 stake = h.authorStake;
        h.authorStake = 0;

        // Deduct φ⁻⁶ (5.57%) treasury fee
        uint256 treasuryFee = PhiMath.wadMul(stake, ArtosphereConstants.DS_TREASURY_WAD);
        uint256 returnAmount = stake - treasuryFee;

        totalStaked -= stake;

        if (treasuryFee > 0) {
            artsToken.safeTransfer(treasury, treasuryFee);
        }
        if (returnAmount > 0) {
            artsToken.safeTransfer(h.author, returnAmount);
        }

        emit HypothesisRetired(hypothesisId, h.survivals);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the hardness multiplier for a hypothesis: φ^(survivals/5) in WAD
    /// @dev 0 survivals → 1.0x, 5 survivals → φ ≈ 1.618x, 10 → φ² ≈ 2.618x, etc.
    ///      Uses integer division for the exponent: floor(survivals/5).
    ///      The fractional part (survivals % 5) is interpolated linearly between
    ///      φ^floor and φ^(floor+1) for smooth progression.
    /// @param hypothesisId The hypothesis ID
    /// @return multiplier The hardness multiplier in WAD
    function getHardnessMultiplier(uint256 hypothesisId) external view returns (uint256 multiplier) {
        if (hypothesisId >= nextHypothesisId) {
            revert HypothesisNotFound(hypothesisId);
        }
        uint256 survivals = hypotheses[hypothesisId].survivals;
        return _computeHardnessMultiplier(survivals);
    }

    /// @notice Get full hypothesis data
    /// @param hypothesisId The hypothesis ID
    /// @return h The Hypothesis struct
    function getHypothesis(uint256 hypothesisId) external view returns (Hypothesis memory h) {
        if (hypothesisId >= nextHypothesisId) {
            revert HypothesisNotFound(hypothesisId);
        }
        return hypotheses[hypothesisId];
    }

    /// @notice Get a falsification attempt
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The attempt ID
    /// @return a The FalsificationAttempt struct
    function getAttempt(
        uint256 hypothesisId,
        uint256 attemptId
    ) external view returns (FalsificationAttempt memory a) {
        if (hypothesisId >= nextHypothesisId) {
            revert HypothesisNotFound(hypothesisId);
        }
        if (attemptId >= nextAttemptId[hypothesisId]) {
            revert AttemptNotFound(hypothesisId, attemptId);
        }
        return attempts[hypothesisId][attemptId];
    }

    /// @notice Get pending reward for an address on a specific attempt
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The attempt ID
    /// @param account The address to check
    /// @return amount The pending reward amount
    /// @return claimed Whether the reward has been claimed
    function getReward(
        uint256 hypothesisId,
        uint256 attemptId,
        address account
    ) external view returns (uint256 amount, bool claimed) {
        PendingReward storage r = rewards[hypothesisId][attemptId][account];
        return (r.amount, r.claimed);
    }

    /// @notice Get the total number of falsification attempts for a hypothesis
    /// @param hypothesisId The hypothesis ID
    /// @return count Total attempts (all statuses)
    function getAttemptCount(uint256 hypothesisId) external view returns (uint256 count) {
        return nextAttemptId[hypothesisId];
    }

    /// @notice Estimate author reward if a specific attempt survives
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The attempt ID
    /// @return authorReward The φ⁻¹ share of the falsifier's stake
    function estimateSurvivalReward(
        uint256 hypothesisId,
        uint256 attemptId
    ) external view returns (uint256 authorReward) {
        FalsificationAttempt storage a = attempts[hypothesisId][attemptId];
        if (a.status != AttemptStatus.PENDING) return 0;
        return PhiMath.wadMul(a.stake, ArtosphereConstants.DS_WINNER_WAD);
    }

    /// @notice Estimate falsifier reward if a specific attempt succeeds in falsifying
    /// @param hypothesisId The hypothesis ID
    /// @param attemptId The attempt ID
    /// @return falsifierReward The φ⁻¹ share of author's stake + own stake × φ
    function estimateFalsificationReward(
        uint256 hypothesisId,
        uint256 attemptId
    ) external view returns (uint256 falsifierReward) {
        Hypothesis storage h = hypotheses[hypothesisId];
        FalsificationAttempt storage a = attempts[hypothesisId][attemptId];
        if (a.status != AttemptStatus.PENDING) return 0;

        uint256 cascadeCut = PhiMath.wadMul(h.authorStake, ArtosphereConstants.DS_WINNER_WAD);
        uint256 bonus = PhiMath.wadMul(a.stake, PhiMath.PHI);
        return cascadeCut + bonus;
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    /// @dev Compute φ^(survivals/5) with linear interpolation for fractional parts.
    ///      floor(survivals/5) gives the base exponent.
    ///      Fractional part survivals%5 is interpolated: base + (next - base) × frac/5
    /// @param survivals Number of survived falsification attempts
    /// @return multiplier φ^(survivals/5) in WAD
    function _computeHardnessMultiplier(uint256 survivals) internal pure returns (uint256 multiplier) {
        if (survivals == 0) return PhiMath.WAD; // 1.0x

        uint256 baseExp = survivals / 5;
        uint256 remainder = survivals % 5;

        uint256 basePhi = PhiMath.phiPow(baseExp);

        if (remainder == 0) {
            return basePhi;
        }

        // Linear interpolation between φ^baseExp and φ^(baseExp+1)
        uint256 nextPhi = PhiMath.phiPow(baseExp + 1);
        // interpolated = basePhi + (nextPhi - basePhi) × remainder / 5
        uint256 delta = nextPhi - basePhi;
        uint256 interpolation = (delta * remainder) / 5;

        return basePhi + interpolation;
    }
}
