// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ResearcherRegistry — On-Chain Researcher Identity & Reputation
/// @author F.B. Sapronov
/// @notice Bridges traditional academic identity (ORCID) with on-chain reputation.
///         Researchers register their ORCID, build reputation through correct predictions,
///         and can earn Oracle validator status at the highest tier.
///
///         Reputation tiers (Fibonacci-indexed):
///           0 — Novice    (0 correct predictions)
///           1 — Scholar   (F(3) = 2+  correct)
///           2 — Expert    (F(5) = 5+  correct)
///           3 — Oracle    (F(7) = 13+ correct) — eligible for validator role
///
/// @dev This contract is read by DiscoveryStaking and DiscoveryOracle for
///      researcher metadata. ORCID verification is done off-chain (OAuth)
///      and attested on-chain by an ATTESTOR_ROLE.
contract ResearcherRegistry is AccessControl {

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Can attest ORCID verification (off-chain OAuth result)
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");

    /// @notice Can update reputation scores (called by DiscoveryStaking on resolution)
    bytes32 public constant STAKING_ROLE = keccak256("STAKING_ROLE");

    // ========================================================================
    // CONSTANTS — Fibonacci tier thresholds
    // ========================================================================

    uint256 public constant TIER_SCHOLAR = 2;   // F(3)
    uint256 public constant TIER_EXPERT = 5;    // F(5)
    uint256 public constant TIER_ORACLE = 13;   // F(7)

    // ========================================================================
    // STRUCTS
    // ========================================================================

    struct Researcher {
        string orcid;               // ORCID iD (e.g., "0000-0002-1234-5678")
        string name;                // Display name (optional)
        string institution;         // Affiliation (optional)
        bool orcidVerified;         // Attested by ATTESTOR_ROLE
        uint256 correctPredictions; // Times on winning side of a resolution
        uint256 totalPredictions;   // Total resolutions participated in
        uint256 totalStaked;        // Cumulative ARTS staked (WAD)
        uint256 totalEarned;        // Cumulative ARTS earned from wins (WAD)
        uint256 registeredAt;       // Block timestamp
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Address => Researcher profile
    mapping(address => Researcher) public researchers;

    /// @notice ORCID => address (reverse lookup, prevents duplicate ORCID)
    mapping(string => address) public orcidToAddress;

    /// @notice Total registered researchers
    uint256 public totalResearchers;

    // ========================================================================
    // EVENTS
    // ========================================================================

    event ResearcherRegistered(address indexed researcher, string orcid, string name);
    event OrcidVerified(address indexed researcher, string orcid);
    event ProfileUpdated(address indexed researcher, string name, string institution);
    event ReputationUpdated(
        address indexed researcher,
        uint256 correctPredictions,
        uint256 totalPredictions,
        uint256 newTier
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    error AlreadyRegistered();
    error OrcidAlreadyClaimed(string orcid);
    error NotRegistered();
    error InvalidOrcid();
    error EmptyOrcid();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ========================================================================
    // REGISTRATION
    // ========================================================================

    /// @notice Register as a researcher with ORCID
    /// @param orcid Your ORCID iD (e.g., "0000-0002-1234-5678")
    /// @param name Display name (can be empty)
    /// @param institution Affiliation (can be empty)
    function register(
        string calldata orcid,
        string calldata name,
        string calldata institution
    ) external {
        if (researchers[msg.sender].registeredAt != 0) revert AlreadyRegistered();
        if (bytes(orcid).length == 0) revert EmptyOrcid();
        if (bytes(orcid).length != 19) revert InvalidOrcid(); // ORCID format: XXXX-XXXX-XXXX-XXXX
        if (orcidToAddress[orcid] != address(0)) revert OrcidAlreadyClaimed(orcid);

        researchers[msg.sender] = Researcher({
            orcid: orcid,
            name: name,
            institution: institution,
            orcidVerified: false,
            correctPredictions: 0,
            totalPredictions: 0,
            totalStaked: 0,
            totalEarned: 0,
            registeredAt: block.timestamp
        });

        orcidToAddress[orcid] = msg.sender;
        totalResearchers++;

        emit ResearcherRegistered(msg.sender, orcid, name);
    }

    /// @notice Update profile information
    function updateProfile(string calldata name, string calldata institution) external {
        if (researchers[msg.sender].registeredAt == 0) revert NotRegistered();
        researchers[msg.sender].name = name;
        researchers[msg.sender].institution = institution;
        emit ProfileUpdated(msg.sender, name, institution);
    }

    /// @notice Attest ORCID verification (called after off-chain OAuth)
    function verifyOrcid(address researcher) external onlyRole(ATTESTOR_ROLE) {
        if (researchers[researcher].registeredAt == 0) revert NotRegistered();
        researchers[researcher].orcidVerified = true;
        emit OrcidVerified(researcher, researchers[researcher].orcid);
    }

    // ========================================================================
    // REPUTATION (called by DiscoveryStaking)
    // ========================================================================

    /// @notice Record a prediction outcome for a researcher
    /// @param researcher The researcher's address
    /// @param won Whether they were on the winning side
    /// @param stakeAmount Amount staked (WAD)
    /// @param earnedAmount Amount earned — 0 if lost (WAD)
    function recordPrediction(
        address researcher,
        bool won,
        uint256 stakeAmount,
        uint256 earnedAmount
    ) external onlyRole(STAKING_ROLE) {
        Researcher storage r = researchers[researcher];
        if (r.registeredAt == 0) return; // Not registered — skip silently

        r.totalPredictions++;
        r.totalStaked += stakeAmount;

        if (won) {
            r.correctPredictions++;
            r.totalEarned += earnedAmount;
        }

        emit ReputationUpdated(
            researcher,
            r.correctPredictions,
            r.totalPredictions,
            getTier(researcher)
        );
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get researcher's reputation tier
    /// @return 0=Novice, 1=Scholar, 2=Expert, 3=Oracle
    function getTier(address researcher) public view returns (uint256) {
        uint256 correct = researchers[researcher].correctPredictions;
        if (correct >= TIER_ORACLE) return 3;
        if (correct >= TIER_EXPERT) return 2;
        if (correct >= TIER_SCHOLAR) return 1;
        return 0;
    }

    /// @notice Get tier name as string
    function getTierName(address researcher) external view returns (string memory) {
        uint256 tier = getTier(researcher);
        if (tier == 3) return "Oracle";
        if (tier == 2) return "Expert";
        if (tier == 1) return "Scholar";
        return "Novice";
    }

    /// @notice Get full researcher profile
    function getResearcher(address addr) external view returns (Researcher memory) {
        return researchers[addr];
    }

    /// @notice Check if address is registered
    function isRegistered(address addr) external view returns (bool) {
        return researchers[addr].registeredAt != 0;
    }

    /// @notice Win rate in basis points (0-10000)
    function winRate(address researcher) external view returns (uint256) {
        Researcher storage r = researchers[researcher];
        if (r.totalPredictions == 0) return 0;
        return (r.correctPredictions * 10000) / r.totalPredictions;
    }

    /// @notice Look up address by ORCID
    function getAddressByOrcid(string calldata orcid) external view returns (address) {
        return orcidToAddress[orcid];
    }
}
