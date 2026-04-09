// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PhiMath.sol";
import "./ArtosphereConstants.sol";

/// @title ReviewRewards — phi-Cascade Distribution for Peer Reviewers
/// @author F.B. Sapronov
/// @notice Distributes ARTS rewards to reviewers after paper acceptance.
///
///         phi-Cascade distribution of review fees:
///           phi^-1 (61.80%) — top reviewer (by stake weight)
///           phi^-3 (23.60%) — second reviewer
///           phi^-5 + phi^-6 (14.59%) — remaining reviewers split evenly
///
///         Kill Condition bonus: reviewer who identifies a fatal flaw
///         receives phi^-5 x pool as an additional bonus from treasury.
///
///         Tracks reviewer reputation as a 5-dimensional vector:
///           [theory, experiment, math, computation, review]
///
/// @dev Called by PeerReviewDAO after paper acceptance. Uses AccessControl
///      with DAO_ROLE restricted to the PeerReviewDAO contract.
contract ReviewRewards is AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Only PeerReviewDAO can distribute rewards
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Kill Condition bonus: phi^-5 ~ 9.02% of pool
    uint256 public constant KILL_BONUS_WAD = 90169943749474241; // phi^-5 in WAD

    /// @notice Reputation dimensions
    uint8 public constant DIM_THEORY = 0;
    uint8 public constant DIM_EXPERIMENT = 1;
    uint8 public constant DIM_MATH = 2;
    uint8 public constant DIM_COMPUTATION = 3;
    uint8 public constant DIM_REVIEW = 4;
    uint8 public constant NUM_DIMENSIONS = 5;

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice 5-dimensional reputation vector for a reviewer
    struct ReputationVector {
        uint256 theory;
        uint256 experiment;
        uint256 math;
        uint256 computation;
        uint256 review;         // Incremented on every completed review
    }

    /// @notice Claimable reward record
    struct RewardRecord {
        uint256 amount;
        bool claimed;
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice ARTS ERC-20 token
    IERC20 public immutable artsToken;

    /// @notice Treasury for Kill Condition bonus funding
    address public immutable treasury;

    /// @notice Reviewer reputation vectors
    mapping(address => ReputationVector) public reputation;

    /// @notice Claimable rewards: reviewer => paperId => RewardRecord
    mapping(address => mapping(uint256 => RewardRecord)) public rewards;

    /// @notice Total rewards distributed (lifetime)
    uint256 public totalDistributed;

    /// @notice Total Kill Condition bonuses paid
    uint256 public totalKillBonuses;

    // ========================================================================
    // EVENTS
    // ========================================================================

    event RewardsDistributed(uint256 indexed paperId, uint256 pool, uint256 reviewerCount);
    event RewardAllocated(uint256 indexed paperId, address indexed reviewer, uint256 amount);
    event KillConditionBonus(uint256 indexed paperId, address indexed reviewer, uint256 bonus);
    event RewardClaimed(address indexed reviewer, uint256 indexed paperId, uint256 amount);
    event ReputationUpdated(address indexed reviewer, uint8 dimension, uint256 newValue);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error InvalidZeroAddress();
    error NoReviewers();
    error NoRewardToClaim();
    error AlreadyClaimed();
    error ZeroPool();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @param _artsToken ARTS ERC-20 address
    /// @param _treasury Treasury address (funds Kill Condition bonuses)
    /// @param admin Admin address (DEFAULT_ADMIN_ROLE)
    constructor(address _artsToken, address _treasury, address admin) {
        if (_artsToken == address(0) || _treasury == address(0) || admin == address(0)) {
            revert InvalidZeroAddress();
        }

        artsToken = IERC20(_artsToken);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ========================================================================
    // REWARD DISTRIBUTION (called by PeerReviewDAO)
    // ========================================================================

    /// @notice Distribute review rewards via phi-Cascade
    /// @param paperId The accepted paper ID
    /// @param pool Total ARTS to distribute (must already be transferred to this contract)
    /// @param reviewers Array of honest reviewer addresses (ordered by stake weight)
    /// @param killFlags Parallel array: true if reviewer flagged a Kill Condition
    /// @dev phi-Cascade allocation:
    ///        Reviewer 0 (top):    phi^-1 = 61.80%
    ///        Reviewer 1 (second): phi^-3 = 23.60%
    ///        Remaining:           phi^-5 + phi^-6 = 14.59% split evenly
    ///      Kill Condition: reviewer who flags fatal flaw gets phi^-5 x pool bonus
    function distributeRewards(
        uint256 paperId,
        uint256 pool,
        address[] calldata reviewers,
        bool[] calldata killFlags
    ) external onlyRole(DAO_ROLE) nonReentrant {
        if (pool == 0) revert ZeroPool();
        uint256 count = reviewers.length;
        if (count == 0) revert NoReviewers();

        uint256 distributed;

        if (count == 1) {
            // Single reviewer gets entire pool
            rewards[reviewers[0]][paperId].amount = pool;
            distributed = pool;
            emit RewardAllocated(paperId, reviewers[0], pool);
        } else if (count == 2) {
            // Two reviewers: phi^-1 and phi^-3 (renormalized)
            // phi^-1 + phi^-3 = 0.618 + 0.236 = 0.854 -> scale to 100%
            uint256 topShare = PhiMath.wadMul(pool, ArtosphereConstants.DS_WINNER_WAD);
            uint256 secondShare = pool - topShare;

            rewards[reviewers[0]][paperId].amount = topShare;
            rewards[reviewers[1]][paperId].amount = secondShare;
            distributed = pool;

            emit RewardAllocated(paperId, reviewers[0], topShare);
            emit RewardAllocated(paperId, reviewers[1], secondShare);
        } else {
            // 3+ reviewers: full phi-Cascade
            uint256 topShare = PhiMath.wadMul(pool, ArtosphereConstants.DS_WINNER_WAD);   // phi^-1
            uint256 secondShare = PhiMath.wadMul(pool, ArtosphereConstants.DS_BURN_WAD);  // phi^-3
            uint256 remainder = pool - topShare - secondShare;                             // phi^-5 + phi^-6
            uint256 perRemaining = remainder / (count - 2);

            rewards[reviewers[0]][paperId].amount = topShare;
            distributed += topShare;
            emit RewardAllocated(paperId, reviewers[0], topShare);

            rewards[reviewers[1]][paperId].amount = secondShare;
            distributed += secondShare;
            emit RewardAllocated(paperId, reviewers[1], secondShare);

            for (uint256 i = 2; i < count;) {
                uint256 share = (i == count - 1) ? (pool - distributed) : perRemaining;
                rewards[reviewers[i]][paperId].amount = share;
                distributed += share;
                emit RewardAllocated(paperId, reviewers[i], share);
                unchecked { ++i; }
            }
        }

        // Process Kill Condition bonuses
        for (uint256 i; i < count;) {
            if (killFlags[i]) {
                uint256 bonus = PhiMath.wadMul(pool, KILL_BONUS_WAD);
                rewards[reviewers[i]][paperId].amount += bonus;
                totalKillBonuses += bonus;
                emit KillConditionBonus(paperId, reviewers[i], bonus);
            }
            unchecked { ++i; }
        }

        // Update reputation: increment review dimension for all
        for (uint256 i; i < count;) {
            reputation[reviewers[i]].review++;
            emit ReputationUpdated(reviewers[i], DIM_REVIEW, reputation[reviewers[i]].review);
            unchecked { ++i; }
        }

        totalDistributed += pool;
        emit RewardsDistributed(paperId, pool, count);
    }

    // ========================================================================
    // REWARD CLAIMS (pull-based)
    // ========================================================================

    /// @notice Claim accumulated rewards for a specific paper
    /// @param paperId Paper ID
    function claimReward(uint256 paperId) external nonReentrant {
        RewardRecord storage record = rewards[msg.sender][paperId];
        if (record.amount == 0) revert NoRewardToClaim();
        if (record.claimed) revert AlreadyClaimed();

        record.claimed = true;
        uint256 amount = record.amount;

        artsToken.safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, paperId, amount);
    }

    // ========================================================================
    // REPUTATION MANAGEMENT
    // ========================================================================

    /// @notice Update a specific reputation dimension (admin or DAO)
    /// @param reviewer Reviewer address
    /// @param dimension Reputation dimension (0-4)
    /// @param value New value
    function updateReputation(
        address reviewer,
        uint8 dimension,
        uint256 value
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDimension(reviewer, dimension, value);
        emit ReputationUpdated(reviewer, dimension, value);
    }

    /// @notice Batch update reputation dimensions
    /// @param reviewer Reviewer address
    /// @param values Array of 5 values [theory, experiment, math, computation, review]
    function setReputationVector(
        address reviewer,
        uint256[5] calldata values
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        reputation[reviewer] = ReputationVector({
            theory: values[0],
            experiment: values[1],
            math: values[2],
            computation: values[3],
            review: values[4]
        });

        for (uint8 i; i < NUM_DIMENSIONS;) {
            emit ReputationUpdated(reviewer, i, values[i]);
            unchecked { ++i; }
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get full reputation vector for a reviewer
    function getReputation(address reviewer) external view returns (ReputationVector memory) {
        return reputation[reviewer];
    }

    /// @notice Get total reputation score (sum of all dimensions)
    function totalReputation(address reviewer) external view returns (uint256 total) {
        ReputationVector storage r = reputation[reviewer];
        total = r.theory + r.experiment + r.math + r.computation + r.review;
    }

    /// @notice Get reward info for a reviewer on a specific paper
    function getReward(address reviewer, uint256 paperId) external view returns (uint256 amount, bool claimed) {
        RewardRecord storage record = rewards[reviewer][paperId];
        return (record.amount, record.claimed);
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    function _setDimension(address reviewer, uint8 dim, uint256 value) internal {
        if (dim == DIM_THEORY) reputation[reviewer].theory = value;
        else if (dim == DIM_EXPERIMENT) reputation[reviewer].experiment = value;
        else if (dim == DIM_MATH) reputation[reviewer].math = value;
        else if (dim == DIM_COMPUTATION) reputation[reviewer].computation = value;
        else if (dim == DIM_REVIEW) reputation[reviewer].review = value;
    }
}
