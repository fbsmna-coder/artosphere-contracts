// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./ArtosphereConstants.sol";
import "./ArtosphereDiscovery.sol";

/// @title DiscoveryOracle — Multisig Resolution Oracle for Discovery Staking
/// @author F.B. Sapronov
/// @notice Resolves scientific discoveries via validator voting with:
///         - 21-day cooldown (F(8)) between proposal and execution
///         - 30.9% quorum (sin²θ₁₂) for confirmation
///         - Challenge period with VETO_ROLE
///         - Staking freeze on proposal (prevents front-running)
///         - Validators cannot stake (prevents insider trading)
/// @dev Integrates with DiscoveryStaking (resolve) and ArtosphereDiscovery (updateStatus)
contract DiscoveryOracle is AccessControl {

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Validator role — can propose and vote on resolutions
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    /// @notice Veto role — can block proposals during cooldown (emergency safety)
    bytes32 public constant VETO_ROLE = keccak256("VETO_ROLE");

    // ========================================================================
    // ENUMS
    // ========================================================================

    enum Outcome { NONE, CONFIRMED, REFUTED }
    enum ProposalState { NONE, PROPOSED, VETOED, RESOLVED }

    // ========================================================================
    // STRUCTS
    // ========================================================================

    struct Proposal {
        Outcome outcome;
        ProposalState state;
        address proposer;
        uint256 proposedAt;
        uint256 votesFor;
        uint256 votesAgainst;
        string evidenceDOI;         // DOI of the experiment/paper that confirms/refutes
        string evidenceNote;        // Brief explanation of the evidence
        mapping(address => bool) hasVoted;
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Reference to the DiscoveryStaking contract
    address public stakingContract;

    /// @notice Reference to ArtosphereDiscovery NFT contract
    ArtosphereDiscovery public discoveryNFT;

    /// @notice Total number of validators (for quorum calculation)
    uint256 public validatorCount;

    /// @notice Active proposals by discovery ID
    mapping(uint256 => Proposal) public proposals;

    /// @notice Tracks whether an address is a validator (for staking ban)
    mapping(address => bool) public isValidator;

    /// @notice Minimum ARTS staked to nominate a validator: 1000 ARTS
    uint256 public constant NOMINATION_MIN_STAKE = 1000 * 1e18;

    /// @notice Tracks pending validator nominations (candidate => nominator)
    mapping(address => address) public nominations;

    /// @notice Tracks staked amount at nomination time
    mapping(address => uint256) public nominationStake;

    // ========================================================================
    // EVENTS
    // ========================================================================

    event ProposalCreated(uint256 indexed discoveryId, Outcome outcome, address indexed proposer, uint256 cooldownEnd, string evidenceDOI);
    event VoteCast(uint256 indexed discoveryId, address indexed voter, bool inFavor);
    event ProposalVetoed(uint256 indexed discoveryId, address indexed vetoer);
    event ProposalResolved(uint256 indexed discoveryId, Outcome outcome);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ValidatorNominated(address indexed candidate, address indexed nominator, uint256 stakedAmount);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error ProposalAlreadyExists(uint256 discoveryId);
    error NoActiveProposal(uint256 discoveryId);
    error CooldownNotExpired(uint256 discoveryId, uint256 cooldownEnd);
    error QuorumNotReached(uint256 votesFor, uint256 required);
    error AlreadyVoted(address voter);
    error ProposalNotActive(uint256 discoveryId);
    error InvalidOutcome();
    error StakingContractNotSet();
    error InvalidDiscovery(uint256 discoveryId);
    error InsufficientStake(uint256 actual, uint256 required);
    error AlreadyNominated(address candidate);

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    constructor(address _discoveryNFT, address admin) {
        discoveryNFT = ArtosphereDiscovery(_discoveryNFT);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VETO_ROLE, admin);
    }

    // ========================================================================
    // ADMIN
    // ========================================================================

    /// @notice Set the DiscoveryStaking contract address
    function setStakingContract(address _staking) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingContract = _staking;
    }

    /// @notice Add a validator
    function addValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(VALIDATOR_ROLE, validator);
        if (!isValidator[validator]) {
            isValidator[validator] = true;
            validatorCount++;
            emit ValidatorAdded(validator);
        }
    }

    /// @notice Remove a validator
    function removeValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(VALIDATOR_ROLE, validator);
        if (isValidator[validator]) {
            isValidator[validator] = false;
            validatorCount--;
            emit ValidatorRemoved(validator);
        }
    }

    // ========================================================================
    // VALIDATOR NOMINATION (H6 — decentralized validator election)
    // ========================================================================
    //
    // Architecture note: Full permissionless validator election (e.g. stake-weighted
    // voting, rotation, slashing) is deferred to v2. This intermediate step makes
    // nominations on-chain and transparent while admin retains approval authority.
    // Migration path: replace approveNomination with a DAO vote once governance
    // contract is deployed.
    //

    /// @notice Nominate a candidate for validator role.
    ///         Any ARTS holder with >= 1000 ARTS staked can nominate.
    /// @param candidate Address to nominate as validator
    /// @dev Caller must have sufficient stake in the DiscoveryStaking contract.
    ///      Admin still approves via approveNomination() (or rejects via rejectNomination()).
    function proposeValidator(address candidate) external {
        if (stakingContract == address(0)) revert StakingContractNotSet();
        if (nominations[candidate] != address(0)) revert AlreadyNominated(candidate);

        uint256 stakedAmount = IStakingBalance(stakingContract).stakedBalance(msg.sender);
        if (stakedAmount < NOMINATION_MIN_STAKE) revert InsufficientStake(stakedAmount, NOMINATION_MIN_STAKE);

        nominations[candidate] = msg.sender;
        nominationStake[candidate] = stakedAmount;

        emit ValidatorNominated(candidate, msg.sender, stakedAmount);
    }

    /// @notice Admin approves a pending nomination — adds candidate as validator
    function approveNomination(address candidate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nominations[candidate] == address(0)) revert AlreadyNominated(candidate); // no pending nomination
        delete nominations[candidate];
        delete nominationStake[candidate];

        _grantRole(VALIDATOR_ROLE, candidate);
        if (!isValidator[candidate]) {
            isValidator[candidate] = true;
            validatorCount++;
            emit ValidatorAdded(candidate);
        }
    }

    /// @notice Admin rejects a pending nomination
    function rejectNomination(address candidate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete nominations[candidate];
        delete nominationStake[candidate];
    }

    // ========================================================================
    // PROPOSAL FLOW
    // ========================================================================

    /// @notice Propose a resolution outcome for a discovery
    /// @param discoveryId The ID of the discovery NFT
    /// @param outcome CONFIRMED or REFUTED
    /// @dev Triggers staking freeze in DiscoveryStaking
    /// @notice Propose a resolution outcome with scientific evidence
    /// @param discoveryId The ID of the discovery NFT
    /// @param outcome CONFIRMED or REFUTED
    /// @param evidenceDOI DOI of the confirming/refuting experiment (e.g., "10.1038/s41586-025-12345-6")
    /// @param evidenceNote Brief explanation of how the evidence supports the outcome
    function propose(
        uint256 discoveryId,
        Outcome outcome,
        string calldata evidenceDOI,
        string calldata evidenceNote
    ) external onlyRole(VALIDATOR_ROLE) {
        if (outcome == Outcome.NONE) revert InvalidOutcome();
        if (discoveryId >= discoveryNFT.totalDiscoveries()) revert InvalidDiscovery(discoveryId);

        Proposal storage p = proposals[discoveryId];
        if (p.state == ProposalState.PROPOSED) revert ProposalAlreadyExists(discoveryId);

        p.outcome = outcome;
        p.state = ProposalState.PROPOSED;
        p.proposer = msg.sender;
        p.proposedAt = block.timestamp;
        p.votesFor = 1; // proposer votes in favor
        p.votesAgainst = 0;
        p.evidenceDOI = evidenceDOI;
        p.evidenceNote = evidenceNote;
        p.hasVoted[msg.sender] = true;

        // Notify staking contract to freeze new stakes
        if (stakingContract != address(0)) {
            IDiscoveryStakingFreeze(stakingContract).freezeStaking(discoveryId);
        }

        emit ProposalCreated(discoveryId, outcome, msg.sender, block.timestamp + ArtosphereConstants.DS_ORACLE_COOLDOWN, evidenceDOI);
    }

    /// @notice Vote on an active proposal
    /// @param discoveryId The discovery ID
    /// @param inFavor True = agree with proposed outcome, false = disagree
    function vote(uint256 discoveryId, bool inFavor) external onlyRole(VALIDATOR_ROLE) {
        Proposal storage p = proposals[discoveryId];
        if (p.state != ProposalState.PROPOSED) revert ProposalNotActive(discoveryId);
        if (p.hasVoted[msg.sender]) revert AlreadyVoted(msg.sender);

        p.hasVoted[msg.sender] = true;

        if (inFavor) {
            p.votesFor++;
        } else {
            p.votesAgainst++;
        }

        emit VoteCast(discoveryId, msg.sender, inFavor);
    }

    /// @notice Veto a proposal during the cooldown period (emergency safety)
    function veto(uint256 discoveryId) external onlyRole(VETO_ROLE) {
        Proposal storage p = proposals[discoveryId];
        if (p.state != ProposalState.PROPOSED) revert ProposalNotActive(discoveryId);

        p.state = ProposalState.VETOED;

        // Unfreeze staking
        if (stakingContract != address(0)) {
            IDiscoveryStakingFreeze(stakingContract).unfreezeStaking(discoveryId);
        }

        emit ProposalVetoed(discoveryId, msg.sender);
    }

    /// @notice Execute a proposal after cooldown and quorum
    /// @dev Anyone can call this once conditions are met
    function resolve(uint256 discoveryId) external {
        Proposal storage p = proposals[discoveryId];
        if (p.state != ProposalState.PROPOSED) revert ProposalNotActive(discoveryId);

        // Check cooldown
        uint256 cooldownEnd = p.proposedAt + ArtosphereConstants.DS_ORACLE_COOLDOWN;
        if (block.timestamp < cooldownEnd) revert CooldownNotExpired(discoveryId, cooldownEnd);

        // Check quorum: votesFor >= 30.9% of validators
        uint256 quorumRequired = (validatorCount * ArtosphereConstants.QUORUM_BPS + 9999) / 10000; // ceil
        if (p.votesFor < quorumRequired) revert QuorumNotReached(p.votesFor, quorumRequired);

        p.state = ProposalState.RESOLVED;

        // Update discovery NFT status
        string memory statusStr = p.outcome == Outcome.CONFIRMED ? "CONFIRMED" : "REFUTED";
        discoveryNFT.updateStatus(discoveryId, statusStr);

        // Resolve staking pools
        if (stakingContract != address(0)) {
            IDiscoveryStakingResolve(stakingContract).resolveDiscovery(
                discoveryId,
                p.outcome == Outcome.CONFIRMED ? uint8(1) : uint8(2)
            );
        }

        emit ProposalResolved(discoveryId, p.outcome);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get proposal state
    function getProposal(uint256 discoveryId)
        external
        view
        returns (
            Outcome outcome,
            ProposalState state,
            address proposer,
            uint256 proposedAt,
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 cooldownEnd,
            uint256 quorumRequired
        )
    {
        Proposal storage p = proposals[discoveryId];
        outcome = p.outcome;
        state = p.state;
        proposer = p.proposer;
        proposedAt = p.proposedAt;
        votesFor = p.votesFor;
        votesAgainst = p.votesAgainst;
        cooldownEnd = p.proposedAt + ArtosphereConstants.DS_ORACLE_COOLDOWN;
        quorumRequired = (validatorCount * ArtosphereConstants.QUORUM_BPS + 9999) / 10000;
    }

    /// @notice Get the DOI evidence for a proposal
    function getEvidence(uint256 discoveryId)
        external
        view
        returns (string memory evidenceDOI, string memory evidenceNote)
    {
        Proposal storage p = proposals[discoveryId];
        return (p.evidenceDOI, p.evidenceNote);
    }

    /// @notice Check if a validator has voted on a proposal
    function hasVoted(uint256 discoveryId, address voter) external view returns (bool) {
        return proposals[discoveryId].hasVoted[voter];
    }

    /// @notice Check if quorum is reached
    function quorumReached(uint256 discoveryId) external view returns (bool) {
        uint256 quorumRequired = (validatorCount * ArtosphereConstants.QUORUM_BPS + 9999) / 10000;
        return proposals[discoveryId].votesFor >= quorumRequired;
    }
}

// ========================================================================
// INTERFACES for DiscoveryStaking callbacks
// ========================================================================

interface IDiscoveryStakingFreeze {
    function freezeStaking(uint256 discoveryId) external;
    function unfreezeStaking(uint256 discoveryId) external;
}

interface IDiscoveryStakingResolve {
    function resolveDiscovery(uint256 discoveryId, uint8 outcome) external;
}

interface IStakingBalance {
    function stakedBalance(address account) external view returns (uint256);
}
