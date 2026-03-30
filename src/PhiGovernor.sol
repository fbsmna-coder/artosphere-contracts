// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {PhiMath} from "./PhiMath.sol";

/// @title PhiGovernor — Golden-Ratio Weighted Governance for PhiCoin
/// @author IBG Technologies
/// @notice On-chain governance where:
///   - Voting power = staked PHI x phi^{lock_tier}  (longer stakers have more weight)
///   - Proposal threshold  = supply / phi^8  (~0.2% of supply)
///   - Quorum              = supply / phi^4  (~14.6% of supply)
///   - Voting period       = F(13) = 233 blocks
///   - Execution delay     = F(8) = 21 blocks  (timelock)
///   - phi-Supermajority   = yes/(yes+no) > 1/phi ≈ 61.8%  (not the usual 50%)
/// @dev Extends OpenZeppelin 5.x Governor with custom counting logic for phi-weighting
///      and golden-ratio supermajority. Requires an IVotes token (e.g. a staking wrapper
///      around PhiCoin that implements ERC20Votes).
contract PhiGovernor is
    Governor,
    GovernorSettings,
    GovernorVotes,
    GovernorTimelockControl
{
    // ---------------------------------------------------------------
    // Constants  (Fibonacci & Golden Ratio)
    // ---------------------------------------------------------------

    /// @notice Voting period in blocks: F(13) = 233
    uint32 public constant VOTING_PERIOD = 233;

    /// @notice Voting delay in blocks (1 block — minimal delay)
    uint48 public constant VOTING_DELAY = 1;

    /// @notice Exponent for proposal threshold divisor: supply / phi^8 ≈ 0.213%
    uint256 public constant PROPOSAL_THRESHOLD_EXP = 8;

    /// @notice Exponent for quorum divisor: supply / phi^4 ≈ 14.59%
    uint256 public constant QUORUM_EXP = 4;

    /// @notice 1/phi in WAD = 0.618033988749894848e18 — the supermajority threshold
    ///         A proposal passes iff: forVotes * WAD > (forVotes + againstVotes) * PHI_INV
    uint256 public constant SUPERMAJORITY_THRESHOLD = PhiMath.PHI_INV; // ~61.8%

    /// @notice Max supply of PHI token (matches PhiCoin.MAX_SUPPLY)
    uint256 public constant MAX_SUPPLY = 1_618_033_988 * 1e18;

    // ---------------------------------------------------------------
    // phi-weighted staking tiers
    // ---------------------------------------------------------------

    /// @notice Maximum lock tier (0 = no bonus, 5 = maximum phi^5 multiplier)
    uint256 public constant MAX_LOCK_TIER = 5;

    /// @dev user => lock tier
    mapping(address => uint256) public lockTier;

    // ---------------------------------------------------------------
    // Custom vote counting (replaces GovernorCountingSimple)
    // ---------------------------------------------------------------

    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
    }

    mapping(uint256 => ProposalVote) private _proposalVotes;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event LockTierSet(address indexed account, uint256 tier);

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error TierExceedsMax(uint256 tier, uint256 max);
    error AlreadyVoted(uint256 proposalId, address account);
    error InvalidVoteType(uint8 support);

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    /// @param token_ An IVotes token (ERC20Votes wrapper around PhiCoin)
    /// @param timelock_ TimelockController with F(8)=21 block delay
    constructor(
        IVotes token_,
        TimelockController timelock_
    )
        Governor("PhiGovernor")
        GovernorSettings(VOTING_DELAY, VOTING_PERIOD, 0) // threshold overridden below
        GovernorVotes(token_)
        GovernorTimelockControl(timelock_)
    {}

    // ---------------------------------------------------------------
    // Lock tier management
    // ---------------------------------------------------------------

    /// @notice Set your lock tier (0-5). Higher tier = more voting weight.
    /// @dev In production, this would be enforced by the staking contract.
    ///      Here it is self-declared for flexibility and testability.
    function setLockTier(uint256 tier) external {
        if (tier > MAX_LOCK_TIER) revert TierExceedsMax(tier, MAX_LOCK_TIER);
        lockTier[msg.sender] = tier;
        emit LockTierSet(msg.sender, tier);
    }

    // ---------------------------------------------------------------
    // Proposal threshold  (supply / phi^8)
    // ---------------------------------------------------------------

    function proposalThreshold()
        public
        pure
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        // MAX_SUPPLY * phi^(-8) = MAX_SUPPLY / phi^8
        return PhiMath.wadMul(MAX_SUPPLY, PhiMath.phiInvPow(PROPOSAL_THRESHOLD_EXP));
    }

    // ---------------------------------------------------------------
    // Quorum  (supply / phi^4)
    // ---------------------------------------------------------------

    function quorum(uint256 /* blockNumber */)
        public
        pure
        override(Governor)
        returns (uint256)
    {
        return PhiMath.wadMul(MAX_SUPPLY, PhiMath.phiInvPow(QUORUM_EXP));
    }

    // ---------------------------------------------------------------
    // Vote counting — phi-weighted + 61.8% supermajority
    // ---------------------------------------------------------------

    function COUNTING_MODE() public pure override returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
    }

    /// @notice Returns (againstVotes, forVotes, abstainVotes) for a proposal
    function proposalVotes(uint256 proposalId)
        public
        view
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        ProposalVote storage pv = _proposalVotes[proposalId];
        return (pv.againstVotes, pv.forVotes, pv.abstainVotes);
    }

    function _quorumReached(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage pv = _proposalVotes[proposalId];
        return (pv.forVotes + pv.abstainVotes) >= quorum(0);
    }

    /// @notice phi-supermajority: forVotes / (forVotes + againstVotes) > 1/phi ≈ 61.8%
    function _voteSucceeded(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage pv = _proposalVotes[proposalId];
        uint256 total = pv.forVotes + pv.againstVotes;
        if (total == 0) return false;
        // forVotes * WAD > total * PHI_INV  iff  forVotes/total > 1/phi
        return pv.forVotes * PhiMath.WAD > total * SUPERMAJORITY_THRESHOLD;
    }

    /// @notice Record a vote with phi-weighted power: baseWeight * phi^{lockTier}
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 totalWeight,
        bytes memory /* params */
    ) internal override returns (uint256) {
        ProposalVote storage pv = _proposalVotes[proposalId];
        if (pv.hasVoted[account]) revert AlreadyVoted(proposalId, account);
        pv.hasVoted[account] = true;

        // Apply phi-weighting: weight * phi^tier
        uint256 tier = lockTier[account];
        uint256 weightedVotes;
        if (tier > 0) {
            // totalWeight is in token units (WAD-scaled tokens).
            // phiPow(tier) is in WAD. We want: totalWeight * phiPow(tier) / WAD
            weightedVotes = PhiMath.wadMul(totalWeight, PhiMath.phiPow(tier));
        } else {
            weightedVotes = totalWeight;
        }

        if (support == 0) {
            pv.againstVotes += weightedVotes;
        } else if (support == 1) {
            pv.forVotes += weightedVotes;
        } else if (support == 2) {
            pv.abstainVotes += weightedVotes;
        } else {
            revert InvalidVoteType(support);
        }

        return weightedVotes;
    }

    // ---------------------------------------------------------------
    // Required overrides (OZ Governor diamond resolution)
    // ---------------------------------------------------------------

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }
}
