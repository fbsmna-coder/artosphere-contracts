// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PhiMath.sol";
import "./ArtosphereConstants.sol";
import "./ResearcherRegistry.sol";
import "./ReviewRewards.sol";

/// @title PeerReviewDAO — Fibonacci-Timed Peer Review with Golden Quorum
/// @author F.B. Sapronov
/// @notice Manages multi-round review for papers submitted to Artosphere Scholar.
///
///         Review rounds follow Fibonacci durations: 5, 8, 13, 21 days.
///         Golden Quorum: ceil(N/phi) ~ 61.8% of assigned reviewers must vote.
///         Reviewers stake ARTS (skin in the game).
///         Dishonest reviewers (voted against final consensus) are slashed 1/phi^2 ~ 38.2%.
///         Honest reviewers are rewarded from the slashed pool.
///
/// @dev Integrates with ResearcherRegistry (tier >= Expert to review) and
///      ReviewRewards (phi-Cascade reward distribution + Kill Condition bonus).
///      Non-upgradeable. Uses AccessControl for SUBMIT_ROLE and REVIEW_ROLE.
contract PeerReviewDAO is AccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Authors who may submit papers
    bytes32 public constant SUBMIT_ROLE = keccak256("SUBMIT_ROLE");

    /// @notice Qualified researchers who may review
    bytes32 public constant REVIEW_ROLE = keccak256("REVIEW_ROLE");

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Fibonacci review round durations
    uint256 public constant ROUND_0_DURATION = 5 days;   // F(5)
    uint256 public constant ROUND_1_DURATION = 8 days;   // F(6)
    uint256 public constant ROUND_2_DURATION = 13 days;  // F(7)
    uint256 public constant ROUND_3_DURATION = 21 days;  // F(8)

    /// @notice Maximum review rounds before forced decision
    uint256 public constant MAX_ROUNDS = 4;

    /// @notice Minimum reviewer stake: 100 ARTS
    uint256 public constant MIN_REVIEWER_STAKE = 100e18;

    /// @notice Minimum publication fee: 50 ARTS
    uint256 public constant MIN_PUBLICATION_FEE = 50e18;

    /// @notice Slash rate for dishonest reviews: 1/phi^2 ~ 38.20%
    uint256 public constant SLASH_WAD = 381966011250105152; // 1/phi^2 in WAD

    /// @notice Minimum researcher tier to review: Expert (tier 2)
    uint256 public constant MIN_REVIEW_TIER = 2;

    /// @notice Acceptance threshold: 100/phi ~ 61.8 -> 62
    uint256 public constant ACCEPT_THRESHOLD = 62;

    /// @notice Rejection threshold: 100/phi^2 ~ 38.2 -> 38
    uint256 public constant REJECT_THRESHOLD = 38;

    // ========================================================================
    // ENUMS
    // ========================================================================

    enum PaperStatus {
        Submitted,      // Awaiting reviewer assignment
        UnderReview,    // Active review round (commit-reveal)
        Revision,       // Author revising after inconclusive round
        Accepted,       // Paper accepted by consensus
        Rejected,       // Paper rejected by consensus
        Withdrawn       // Author withdrew
    }

    // ========================================================================
    // STRUCTS
    // ========================================================================

    struct Paper {
        address author;
        bytes32 contentHash;         // keccak256 of IPFS CID
        string title;
        string doi;                  // Optional Zenodo DOI
        PaperStatus status;
        uint256 currentRound;        // 0..3
        uint256 roundStartedAt;      // Timestamp when current round began
        uint256 publicationFee;      // ARTS deposited by author
        uint256 totalSlashed;        // Accumulated slashed ARTS across all rounds
        uint256 submittedAt;
    }

    struct ReviewCommit {
        address reviewer;
        bytes32 commitHash;          // keccak256(abi.encodePacked(score, comment, salt))
        uint8 score;                 // 0-100 (set on reveal)
        string comment;              // IPFS hash of review text (set on reveal)
        bool revealed;
        uint256 stakeAmount;         // ARTS staked
        bool slashed;
        uint256 rewardAmount;        // Claimable after resolution
        bool claimed;
        bool killCondition;          // Flagged fatal flaw
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice ARTS ERC-20 token
    IERC20 public immutable artsToken;

    /// @notice ResearcherRegistry for tier checks
    ResearcherRegistry public immutable registry;

    /// @notice ReviewRewards for phi-Cascade distribution
    ReviewRewards public immutable rewardsContract;

    /// @notice Treasury address
    address public immutable treasury;

    /// @notice Auto-incrementing paper ID
    uint256 public nextPaperId;

    /// @notice paperId => Paper
    mapping(uint256 => Paper) public papers;

    /// @notice paperId => round => ReviewCommit[]
    mapping(uint256 => mapping(uint256 => ReviewCommit[])) internal _roundReviews;

    /// @notice paperId => round => reviewer => index+1 (0 = not committed)
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public reviewerIndex;

    /// @notice paperId => round => assigned reviewer addresses
    mapping(uint256 => mapping(uint256 => address[])) internal _assignedReviewers;

    /// @notice paperId => round => reviewer => assigned flag
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public isAssigned;

    // ========================================================================
    // EVENTS
    // ========================================================================

    event PaperSubmitted(uint256 indexed paperId, address indexed author, bytes32 contentHash, string title);
    event ReviewRoundStarted(uint256 indexed paperId, uint256 round, uint256 duration, uint256 assignedCount);
    event ReviewerAssigned(uint256 indexed paperId, uint256 round, address indexed reviewer);
    event ReviewCommitted(uint256 indexed paperId, uint256 round, address indexed reviewer, bytes32 commitHash);
    event ReviewRevealed(uint256 indexed paperId, uint256 round, address indexed reviewer, uint8 score, bool killCondition);
    event RoundFinalized(uint256 indexed paperId, uint256 round, uint256 weightedScore, uint256 slashedTotal);
    event ReviewerSlashed(uint256 indexed paperId, uint256 round, address indexed reviewer, uint256 slashAmount);
    event PaperAccepted(uint256 indexed paperId, uint256 finalRound);
    event PaperRejected(uint256 indexed paperId, uint256 finalRound);
    event PaperWithdrawn(uint256 indexed paperId);
    event RewardClaimed(uint256 indexed paperId, uint256 round, address indexed reviewer, uint256 amount);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error InvalidZeroAddress();
    error PaperNotFound(uint256 paperId);
    error InvalidStatus(uint256 paperId, PaperStatus current);
    error MaxRoundsReached(uint256 paperId);
    error NotAuthor(uint256 paperId);
    error ReviewWindowExpired(uint256 paperId);
    error RevealWindowNotStarted(uint256 paperId);
    error RevealWindowExpired(uint256 paperId);
    error RoundNotExpired(uint256 paperId);
    error QuorumNotReached(uint256 revealed, uint256 required);
    error NotAssignedReviewer(uint256 paperId, address reviewer);
    error AlreadyCommitted(uint256 paperId, address reviewer);
    error ReviewNotCommitted(uint256 paperId, address reviewer);
    error AlreadyRevealed(uint256 paperId, address reviewer);
    error CommitHashMismatch();
    error ScoreOutOfRange(uint8 score);
    error InsufficientStake(uint256 sent, uint256 required);
    error InsufficientFee(uint256 sent, uint256 required);
    error TierTooLow(address reviewer, uint256 tier);
    error AuthorCannotReview();
    error AlreadyAssigned(uint256 paperId, address reviewer);
    error NoRewardToClaim();
    error AlreadyClaimed();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @param _artsToken ARTS ERC-20 address
    /// @param _registry ResearcherRegistry address
    /// @param _rewardsContract ReviewRewards address
    /// @param _treasury Treasury address
    /// @param admin Admin (DEFAULT_ADMIN_ROLE)
    constructor(
        address _artsToken,
        address _registry,
        address _rewardsContract,
        address _treasury,
        address admin
    ) {
        if (_artsToken == address(0) || _registry == address(0) ||
            _rewardsContract == address(0) || _treasury == address(0) ||
            admin == address(0)) {
            revert InvalidZeroAddress();
        }

        artsToken = IERC20(_artsToken);
        registry = ResearcherRegistry(_registry);
        rewardsContract = ReviewRewards(_rewardsContract);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ========================================================================
    // PAPER SUBMISSION
    // ========================================================================

    /// @notice Submit a paper for peer review
    /// @param contentHash keccak256 of the paper (IPFS CID)
    /// @param title Paper title
    /// @param doi Optional Zenodo DOI
    /// @param publicationFee ARTS to deposit (>= MIN_PUBLICATION_FEE)
    /// @return paperId Assigned paper ID
    function submitPaper(
        bytes32 contentHash,
        string calldata title,
        string calldata doi,
        uint256 publicationFee
    ) external onlyRole(SUBMIT_ROLE) nonReentrant returns (uint256 paperId) {
        if (publicationFee < MIN_PUBLICATION_FEE) revert InsufficientFee(publicationFee, MIN_PUBLICATION_FEE);

        artsToken.safeTransferFrom(msg.sender, address(this), publicationFee);

        // Burn phi^-3 ~ 23.6% of the fee
        uint256 burnAmount = PhiMath.wadMul(publicationFee, ArtosphereConstants.DS_BURN_WAD);
        if (burnAmount > 0) {
            artsToken.safeTransfer(address(0xdead), burnAmount);
        }

        paperId = nextPaperId++;

        papers[paperId] = Paper({
            author: msg.sender,
            contentHash: contentHash,
            title: title,
            doi: doi,
            status: PaperStatus.Submitted,
            currentRound: 0,
            roundStartedAt: 0,
            publicationFee: publicationFee - burnAmount,
            totalSlashed: 0,
            submittedAt: block.timestamp
        });

        emit PaperSubmitted(paperId, msg.sender, contentHash, title);
    }

    // ========================================================================
    // REVIEWER ASSIGNMENT & ROUND START
    // ========================================================================

    /// @notice Assign a reviewer to the current round
    /// @param paperId Paper ID
    /// @param reviewer Reviewer address (must have REVIEW_ROLE and tier >= Expert)
    function assignReviewer(uint256 paperId, address reviewer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Paper storage paper = papers[paperId];
        if (paper.submittedAt == 0) revert PaperNotFound(paperId);
        if (paper.status != PaperStatus.Submitted && paper.status != PaperStatus.Revision) {
            revert InvalidStatus(paperId, paper.status);
        }
        if (reviewer == paper.author) revert AuthorCannotReview();

        uint256 tier = registry.getTier(reviewer);
        if (tier < MIN_REVIEW_TIER) revert TierTooLow(reviewer, tier);

        uint256 round = paper.currentRound;
        if (isAssigned[paperId][round][reviewer]) revert AlreadyAssigned(paperId, reviewer);

        isAssigned[paperId][round][reviewer] = true;
        _assignedReviewers[paperId][round].push(reviewer);

        emit ReviewerAssigned(paperId, round, reviewer);
    }

    /// @notice Start the review round (commit phase begins)
    /// @param paperId Paper ID
    function startReviewRound(uint256 paperId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Paper storage paper = papers[paperId];
        if (paper.submittedAt == 0) revert PaperNotFound(paperId);
        if (paper.status != PaperStatus.Submitted && paper.status != PaperStatus.Revision) {
            revert InvalidStatus(paperId, paper.status);
        }
        if (paper.currentRound >= MAX_ROUNDS) revert MaxRoundsReached(paperId);

        paper.status = PaperStatus.UnderReview;
        paper.roundStartedAt = block.timestamp;

        uint256 duration = _roundDuration(paper.currentRound);
        uint256 assigned = _assignedReviewers[paperId][paper.currentRound].length;

        emit ReviewRoundStarted(paperId, paper.currentRound, duration, assigned);
    }

    // ========================================================================
    // COMMIT PHASE
    // ========================================================================

    /// @notice Commit a review hash with ARTS stake
    /// @param paperId Paper ID
    /// @param commitHash keccak256(abi.encodePacked(score, comment, salt))
    /// @param stakeAmount ARTS to stake (>= MIN_REVIEWER_STAKE)
    function commitReview(
        uint256 paperId,
        bytes32 commitHash,
        uint256 stakeAmount
    ) external onlyRole(REVIEW_ROLE) nonReentrant {
        Paper storage paper = papers[paperId];
        if (paper.status != PaperStatus.UnderReview) revert InvalidStatus(paperId, paper.status);

        uint256 round = paper.currentRound;
        uint256 duration = _roundDuration(round);
        // Commit window = first 2/3 of round duration
        uint256 commitDeadline = paper.roundStartedAt + (duration * 2) / 3;
        if (block.timestamp > commitDeadline) revert ReviewWindowExpired(paperId);

        if (msg.sender == paper.author) revert AuthorCannotReview();
        if (!isAssigned[paperId][round][msg.sender]) revert NotAssignedReviewer(paperId, msg.sender);
        if (reviewerIndex[paperId][round][msg.sender] != 0) revert AlreadyCommitted(paperId, msg.sender);
        if (stakeAmount < MIN_REVIEWER_STAKE) revert InsufficientStake(stakeAmount, MIN_REVIEWER_STAKE);

        artsToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        _roundReviews[paperId][round].push(ReviewCommit({
            reviewer: msg.sender,
            commitHash: commitHash,
            score: 0,
            comment: "",
            revealed: false,
            stakeAmount: stakeAmount,
            slashed: false,
            rewardAmount: 0,
            claimed: false,
            killCondition: false
        }));

        reviewerIndex[paperId][round][msg.sender] = _roundReviews[paperId][round].length;

        emit ReviewCommitted(paperId, round, msg.sender, commitHash);
    }

    // ========================================================================
    // REVEAL PHASE
    // ========================================================================

    /// @notice Reveal a committed review
    /// @param paperId Paper ID
    /// @param score Review score 0-100
    /// @param comment IPFS hash of review text
    /// @param salt Salt used in commit
    /// @param killCondition True if reviewer identifies a fatal flaw
    function revealReview(
        uint256 paperId,
        uint8 score,
        string calldata comment,
        bytes32 salt,
        bool killCondition
    ) external {
        Paper storage paper = papers[paperId];
        if (paper.status != PaperStatus.UnderReview) revert InvalidStatus(paperId, paper.status);

        uint256 round = paper.currentRound;
        uint256 duration = _roundDuration(round);
        uint256 commitDeadline = paper.roundStartedAt + (duration * 2) / 3;
        uint256 revealDeadline = paper.roundStartedAt + duration;

        if (block.timestamp <= commitDeadline) revert RevealWindowNotStarted(paperId);
        if (block.timestamp > revealDeadline) revert RevealWindowExpired(paperId);
        if (score > 100) revert ScoreOutOfRange(score);

        uint256 idx = reviewerIndex[paperId][round][msg.sender];
        if (idx == 0) revert ReviewNotCommitted(paperId, msg.sender);

        ReviewCommit storage rc = _roundReviews[paperId][round][idx - 1];
        if (rc.revealed) revert AlreadyRevealed(paperId, msg.sender);

        bytes32 computed = keccak256(abi.encodePacked(score, comment, salt));
        if (computed != rc.commitHash) revert CommitHashMismatch();

        rc.score = score;
        rc.comment = comment;
        rc.revealed = true;
        rc.killCondition = killCondition;

        emit ReviewRevealed(paperId, round, msg.sender, score, killCondition);
    }

    // ========================================================================
    // ROUND FINALIZATION
    // ========================================================================

    /// @notice Finalize a review round after its duration expires
    /// @param paperId Paper ID
    function finalizeRound(uint256 paperId) external nonReentrant {
        Paper storage paper = papers[paperId];
        if (paper.status != PaperStatus.UnderReview) revert InvalidStatus(paperId, paper.status);

        uint256 round = paper.currentRound;
        uint256 duration = _roundDuration(round);
        if (block.timestamp < paper.roundStartedAt + duration) revert RoundNotExpired(paperId);

        // Check Golden Quorum: ceil(N * phi^-1) of assigned reviewers must have revealed
        uint256 assignedCount = _assignedReviewers[paperId][round].length;
        uint256 quorumRequired = _goldenQuorum(assignedCount);

        ReviewCommit[] storage reviews = _roundReviews[paperId][round];
        uint256 revealedCount;
        for (uint256 i; i < reviews.length;) {
            if (reviews[i].revealed) revealedCount++;
            unchecked { ++i; }
        }
        if (revealedCount < quorumRequired) revert QuorumNotReached(revealedCount, quorumRequired);

        // Compute phi-weighted score
        (uint256 weightedScore, uint256 totalWeight) = _computeWeightedScore(paperId, round);

        // Determine consensus
        bool accepted = weightedScore >= ACCEPT_THRESHOLD;
        bool rejected = weightedScore < REJECT_THRESHOLD;

        // Slash dishonest reviewers and compute reward pools
        uint256 roundSlashed = _slashAndReward(paperId, round, accepted, rejected, totalWeight);
        paper.totalSlashed += roundSlashed;

        emit RoundFinalized(paperId, round, weightedScore, roundSlashed);

        if (accepted) {
            paper.status = PaperStatus.Accepted;
            // Distribute review fee + slashed pool via ReviewRewards
            uint256 rewardPool = paper.publicationFee + paper.totalSlashed;
            _distributeToRewards(paperId, round, rewardPool);
            emit PaperAccepted(paperId, round);
        } else if (rejected) {
            paper.status = PaperStatus.Rejected;
            // Slashed pool to treasury, review fee refunded to author
            if (paper.totalSlashed > 0) {
                artsToken.safeTransfer(treasury, paper.totalSlashed);
            }
            if (paper.publicationFee > 0) {
                artsToken.safeTransfer(paper.author, paper.publicationFee);
            }
            emit PaperRejected(paperId, round);
        } else {
            // Inconclusive: move to revision for next round
            paper.status = PaperStatus.Revision;
            paper.currentRound++;
        }
    }

    // ========================================================================
    // WITHDRAWAL
    // ========================================================================

    /// @notice Author withdraws paper (only before acceptance/rejection)
    function withdrawPaper(uint256 paperId) external {
        Paper storage paper = papers[paperId];
        if (paper.author != msg.sender) revert NotAuthor(paperId);
        if (paper.status == PaperStatus.Accepted || paper.status == PaperStatus.Rejected) {
            revert InvalidStatus(paperId, paper.status);
        }

        paper.status = PaperStatus.Withdrawn;

        // Refund publication fee minus 1.18% protocol fee
        uint256 fee = (paper.publicationFee * ArtosphereConstants.FEE_BPS) / 10000;
        uint256 refund = paper.publicationFee - fee;
        if (fee > 0) artsToken.safeTransfer(treasury, fee);
        if (refund > 0) artsToken.safeTransfer(paper.author, refund);

        emit PaperWithdrawn(paperId);
    }

    /// @notice Claim review reward (pull-based)
    /// @param paperId Paper ID
    /// @param round Review round
    function claimReward(uint256 paperId, uint256 round) external nonReentrant {
        uint256 idx = reviewerIndex[paperId][round][msg.sender];
        if (idx == 0) revert ReviewNotCommitted(paperId, msg.sender);

        ReviewCommit storage rc = _roundReviews[paperId][round][idx - 1];
        if (rc.rewardAmount == 0) revert NoRewardToClaim();
        if (rc.claimed) revert AlreadyClaimed();

        rc.claimed = true;
        uint256 amount = rc.rewardAmount;
        artsToken.safeTransfer(msg.sender, amount);

        emit RewardClaimed(paperId, round, msg.sender, amount);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get Golden Quorum: ceil(N * phi^-1) ~ 61.8% of N
    function goldenQuorum(uint256 numReviewers) external pure returns (uint256) {
        return _goldenQuorum(numReviewers);
    }

    /// @notice Get round duration by index
    function roundDuration(uint256 round) external pure returns (uint256) {
        return _roundDuration(round);
    }

    /// @notice Get reviews for a paper round
    function getRoundReviews(uint256 paperId, uint256 round) external view returns (ReviewCommit[] memory) {
        return _roundReviews[paperId][round];
    }

    /// @notice Get assigned reviewers for a paper round
    function getAssignedReviewers(uint256 paperId, uint256 round) external view returns (address[] memory) {
        return _assignedReviewers[paperId][round];
    }

    /// @notice Preview phi-weighted score for a round
    function getWeightedScore(uint256 paperId, uint256 round) external view returns (uint256 score, uint256 revealedCount) {
        ReviewCommit[] storage reviews = _roundReviews[paperId][round];
        uint256 weightedSum;
        uint256 totalWeight;
        for (uint256 i; i < reviews.length;) {
            if (reviews[i].revealed) {
                uint256 tier = registry.getTier(reviews[i].reviewer);
                uint256 weight = PhiMath.phiPow(tier);
                weightedSum += PhiMath.wadMul(uint256(reviews[i].score) * PhiMath.WAD, weight);
                totalWeight += weight;
                revealedCount++;
            }
            unchecked { ++i; }
        }
        if (revealedCount > 0 && totalWeight > 0) {
            score = PhiMath.wadDiv(weightedSum, totalWeight) / PhiMath.WAD;
        }
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    /// @notice Golden Quorum: ceil(N * phi^-1)
    function _goldenQuorum(uint256 n) internal pure returns (uint256) {
        if (n == 0) return 0;
        // ceil(N * phi^-1) where phi^-1 = 0.618033...
        uint256 product = n * ArtosphereConstants.PHI_INV_WAD;
        return (product + PhiMath.WAD - 1) / PhiMath.WAD;
    }

    function _roundDuration(uint256 round) internal pure returns (uint256) {
        if (round == 0) return ROUND_0_DURATION;
        if (round == 1) return ROUND_1_DURATION;
        if (round == 2) return ROUND_2_DURATION;
        return ROUND_3_DURATION;
    }

    /// @notice Compute phi-weighted average score for a round
    function _computeWeightedScore(
        uint256 paperId,
        uint256 round
    ) internal view returns (uint256 score, uint256 totalWeight) {
        ReviewCommit[] storage reviews = _roundReviews[paperId][round];
        uint256 weightedSum;

        for (uint256 i; i < reviews.length;) {
            if (reviews[i].revealed) {
                uint256 tier = registry.getTier(reviews[i].reviewer);
                uint256 weight = PhiMath.phiPow(tier);
                weightedSum += PhiMath.wadMul(uint256(reviews[i].score) * PhiMath.WAD, weight);
                totalWeight += weight;
            }
            unchecked { ++i; }
        }

        if (totalWeight > 0) {
            score = PhiMath.wadDiv(weightedSum, totalWeight) / PhiMath.WAD;
        }
    }

    /// @notice Slash dishonest reviewers and set up rewards for honest ones
    /// @return totalSlashed Total ARTS slashed this round
    function _slashAndReward(
        uint256 paperId,
        uint256 round,
        bool accepted,
        bool rejected,
        uint256 totalWeight
    ) internal returns (uint256 totalSlashed) {
        ReviewCommit[] storage reviews = _roundReviews[paperId][round];

        uint256 totalLoserStake;
        uint256 winnerWeightSum;

        // First pass: identify losers, slash them
        for (uint256 i; i < reviews.length;) {
            ReviewCommit storage rc = reviews[i];

            if (!rc.revealed) {
                // Unrevealed: slash full stake
                rc.slashed = true;
                totalLoserStake += rc.stakeAmount;
                emit ReviewerSlashed(paperId, round, rc.reviewer, rc.stakeAmount);
            } else {
                bool aligned;
                if (accepted) {
                    aligned = rc.score >= 50; // High score = aligned with acceptance
                } else if (rejected) {
                    aligned = rc.score < 50; // Low score = aligned with rejection
                } else {
                    aligned = true; // Inconclusive: no slashing
                }

                if (!aligned) {
                    // Slash 1/phi^2 ~ 38.2% of stake
                    uint256 slashAmount = PhiMath.wadMul(rc.stakeAmount, SLASH_WAD);
                    rc.slashed = true;
                    totalLoserStake += slashAmount;
                    // Return remaining stake
                    rc.rewardAmount = rc.stakeAmount - slashAmount;
                    emit ReviewerSlashed(paperId, round, rc.reviewer, slashAmount);
                } else {
                    uint256 tier = registry.getTier(rc.reviewer);
                    winnerWeightSum += PhiMath.phiPow(tier);
                }
            }

            unchecked { ++i; }
        }

        totalSlashed = totalLoserStake;

        // Second pass: distribute loser stakes to winners via phi-cascade
        if (totalLoserStake > 0 && winnerWeightSum > 0) {
            uint256 winnerShare = PhiMath.wadMul(totalLoserStake, ArtosphereConstants.DS_WINNER_WAD);
            uint256 burnShare = PhiMath.wadMul(totalLoserStake, ArtosphereConstants.DS_BURN_WAD);
            uint256 treasuryShare = totalLoserStake - winnerShare - burnShare;

            // Burn
            if (burnShare > 0) {
                artsToken.safeTransfer(address(0xdead), burnShare);
            }
            // Treasury
            if (treasuryShare > 0) {
                artsToken.safeTransfer(treasury, treasuryShare);
            }

            // Distribute winner share proportionally by phi^tier weight
            for (uint256 i; i < reviews.length;) {
                ReviewCommit storage rc = reviews[i];
                if (rc.revealed && !rc.slashed) {
                    uint256 tier = registry.getTier(rc.reviewer);
                    uint256 weight = PhiMath.phiPow(tier);
                    uint256 reward = (winnerShare * weight) / winnerWeightSum;
                    rc.rewardAmount = rc.stakeAmount + reward;
                }
                unchecked { ++i; }
            }
        } else {
            // No losers: return stakes to all honest reviewers
            for (uint256 i; i < reviews.length;) {
                ReviewCommit storage rc = reviews[i];
                if (rc.revealed && !rc.slashed) {
                    rc.rewardAmount = rc.stakeAmount;
                }
                unchecked { ++i; }
            }
        }
    }

    /// @notice Transfer reward pool to ReviewRewards for phi-Cascade distribution
    function _distributeToRewards(uint256 paperId, uint256 round, uint256 pool) internal {
        if (pool == 0) return;

        // Collect reviewer addresses and kill condition flags for this round
        ReviewCommit[] storage reviews = _roundReviews[paperId][round];
        address[] memory reviewers = new address[](reviews.length);
        bool[] memory killFlags = new bool[](reviews.length);
        uint256 count;

        for (uint256 i; i < reviews.length;) {
            if (reviews[i].revealed && !reviews[i].slashed) {
                reviewers[count] = reviews[i].reviewer;
                killFlags[count] = reviews[i].killCondition;
                count++;
            }
            unchecked { ++i; }
        }

        // Trim arrays
        assembly {
            mstore(reviewers, count)
            mstore(killFlags, count)
        }

        artsToken.safeTransfer(address(rewardsContract), pool);
        rewardsContract.distributeRewards(paperId, pool, reviewers, killFlags);
    }
}
