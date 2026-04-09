// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {PhiMath} from "./PhiMath.sol";
import {ArtosphereConstants} from "./ArtosphereConstants.sol";

/// @notice Minimal interface to read a user's staking tier from PhiStaking.
interface IPhiStaking {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 startTimestamp;
        uint256 lockEnd;
        uint256 rewardDebt;
        uint256 earned;
    }
    function getStake(address user) external view returns (Stake memory);
}

/// @title PhiGovernor -- Golden-Ratio Weighted Governance for PhiCoin
contract PhiGovernor is Governor, GovernorSettings, GovernorVotes, GovernorTimelockControl {
    uint32 public constant VOTING_PERIOD = 233;
    uint48 public constant VOTING_DELAY = 1;
    uint256 public constant PROPOSAL_THRESHOLD_EXP = 8;
    uint256 public constant QUORUM_EXP = 4;
    uint256 public constant SUPERMAJORITY_THRESHOLD = PhiMath.PHI_INV;
    uint256 public constant MAX_SUPPLY = ArtosphereConstants.TOTAL_SUPPLY; // 987_000_000 * 1e18
    uint256 public constant MAX_LOCK_TIER = 5;

    IPhiStaking public stakingContract;

    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
    }
    mapping(uint256 => ProposalVote) private _proposalVotes;

    event StakingContractSet(address indexed stakingContract);
    error AlreadyVoted(uint256 proposalId, address account);
    error InvalidVoteType(uint8 support);

    constructor(IVotes token_, TimelockController timelock_)
        Governor("PhiGovernor")
        GovernorSettings(VOTING_DELAY, VOTING_PERIOD, 0)
        GovernorVotes(token_)
        GovernorTimelockControl(timelock_)
    {}

    function setStakingContract(address _stakingContract) external {
        require(msg.sender == _executor(), "PhiGovernor: only executor");
        stakingContract = IPhiStaking(_stakingContract);
        emit StakingContractSet(_stakingContract);
    }

    function _getEffectiveTier(address account) internal view returns (uint256) {
        if (address(stakingContract) == address(0)) return 0;
        try stakingContract.getStake(account) returns (IPhiStaking.Stake memory s) {
            if (s.amount == 0) return 0;
            return s.tier > MAX_LOCK_TIER ? MAX_LOCK_TIER : s.tier;
        } catch {
            return 0;
        }
    }

    function proposalThreshold()
        public view override(Governor, GovernorSettings) returns (uint256)
    {
        uint256 supply = token().getPastTotalSupply(clock() - 1);
        return PhiMath.wadMul(supply, PhiMath.phiInvPow(PROPOSAL_THRESHOLD_EXP));
    }

    function quorum(uint256 blockNumber)
        public view override(Governor) returns (uint256)
    {
        uint256 timepoint = blockNumber == 0 ? clock() - 1 : blockNumber;
        uint256 supply = token().getPastTotalSupply(timepoint);
        return PhiMath.wadMul(supply, PhiMath.phiInvPow(QUORUM_EXP));
    }

    function COUNTING_MODE() public pure override returns (string memory) {
        return "support=bravo&quorum=for,abstain";
    }

    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return _proposalVotes[proposalId].hasVoted[account];
    }

    function proposalVotes(uint256 proposalId)
        public view returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        ProposalVote storage pv = _proposalVotes[proposalId];
        return (pv.againstVotes, pv.forVotes, pv.abstainVotes);
    }

    function _quorumReached(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage pv = _proposalVotes[proposalId];
        return (pv.forVotes + pv.abstainVotes) >= quorum(0);
    }

    function _voteSucceeded(uint256 proposalId) internal view override returns (bool) {
        ProposalVote storage pv = _proposalVotes[proposalId];
        uint256 total = pv.forVotes + pv.againstVotes;
        if (total == 0) return false;
        return pv.forVotes * PhiMath.WAD > total * SUPERMAJORITY_THRESHOLD;
    }

    function _countVote(
        uint256 proposalId, address account, uint8 support,
        uint256 totalWeight, bytes memory /* params */
    ) internal override returns (uint256) {
        ProposalVote storage pv = _proposalVotes[proposalId];
        if (pv.hasVoted[account]) revert AlreadyVoted(proposalId, account);
        pv.hasVoted[account] = true;

        uint256 tier = _getEffectiveTier(account);
        uint256 weightedVotes;
        if (tier > 0) {
            weightedVotes = PhiMath.wadMul(totalWeight, PhiMath.phiPow(tier));
        } else {
            weightedVotes = totalWeight;
        }

        if (support == 0) pv.againstVotes += weightedVotes;
        else if (support == 1) pv.forVotes += weightedVotes;
        else if (support == 2) pv.abstainVotes += weightedVotes;
        else revert InvalidVoteType(support);

        return weightedVotes;
    }

    // Required overrides
    function _cancel(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        internal override(Governor, GovernorTimelockControl) returns (uint256)
    { return super._cancel(targets, values, calldatas, descriptionHash); }

    function _executeOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        internal override(Governor, GovernorTimelockControl)
    { super._executeOperations(proposalId, targets, values, calldatas, descriptionHash); }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address)
    { return super._executor(); }

    function _queueOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        internal override(Governor, GovernorTimelockControl) returns (uint48)
    { return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash); }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (bool)
    { return super.proposalNeedsQueuing(proposalId); }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState)
    { return super.state(proposalId); }
}
