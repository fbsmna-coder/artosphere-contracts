// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title KillSwitch — On-Chain Kill Conditions & Graceful Shutdown
/// @author F.B. Sapronov
/// @notice Implements the whitepaper's Kill Conditions: 6 falsifiable predictions
///         with deadlines. When 3+ conditions are triggered (experiment refutes
///         prediction), graceful shutdown activates and token holders can claim
///         pro-rata treasury distribution.
/// @dev Threshold of 3 = N_gen (3 generations from Cl(6)), ensuring shutdown
///      requires a pattern of failure, not a single anomaly.
contract KillSwitch is AccessControl {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant TRIGGER_ROLE = keccak256("TRIGGER_ROLE");

    // --- Constants ---
    uint256 public constant SHUTDOWN_THRESHOLD = 3;
    uint256 public constant MAX_CONDITIONS = 6;

    // --- Structs ---
    struct KillCondition {
        uint256 id;
        string description;       // e.g. "chi-boson not found at 58+-5 GeV by DARWIN"
        uint256 threshold;        // numeric threshold (encoded, condition-specific)
        string experimentName;    // e.g. "DARWIN/XLZD", "HL-LHC Run 4"
        uint256 deadline;         // unix timestamp — expires unfalsified after this
        bool triggered;
        string evidence;          // DOI or description of refuting evidence
        uint256 triggeredAt;
    }

    // --- State ---
    IERC20 public immutable artsToken;
    address public treasury;     // ZeckendorfTreasury — source of shutdown funds

    mapping(uint256 => KillCondition) public conditions;
    uint256 public conditionCount;
    uint256 public triggeredCount;

    bool public shutdownActivated;
    uint256 public shutdownSupplySnapshot;
    uint256 public shutdownTreasurySnapshot;
    mapping(address => bool) public hasClaimed;

    // --- Events ---
    event KillConditionAdded(uint256 indexed conditionId, string description, string experimentName, uint256 deadline);
    event KillConditionTriggered(uint256 indexed conditionId, string evidence, address indexed triggeredBy);
    event ShutdownActivated(uint256 triggeredCount, uint256 treasuryBalance, uint256 timestamp);
    event ShutdownClaimed(address indexed claimer, uint256 amount);

    // --- Errors ---
    error MaxConditionsReached();
    error InvalidConditionId(uint256 conditionId);
    error ConditionAlreadyTriggered(uint256 conditionId);
    error ConditionExpired(uint256 conditionId, uint256 deadline);
    error ShutdownNotActive();
    error ShutdownAlreadyActive();
    error AlreadyClaimed(address claimer);
    error ZeroBalance();

    // --- Constructor ---
    /// @param _artsToken ARTS ERC-20 token
    /// @param _treasury  ZeckendorfTreasury address (fund source for shutdown)
    /// @param admin      Admin address (later replaced by multisig)
    constructor(address _artsToken, address _treasury, address admin) {
        artsToken = IERC20(_artsToken);
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TRIGGER_ROLE, admin);
    }

    // --- Admin ---

    /// @notice Add a new kill condition (admin only, max 6)
    function addCondition(
        string calldata description,
        uint256 threshold,
        string calldata experimentName,
        uint256 deadline
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (conditionCount >= MAX_CONDITIONS) revert MaxConditionsReached();
        if (shutdownActivated) revert ShutdownAlreadyActive();

        uint256 id = conditionCount;
        KillCondition storage c = conditions[id];
        c.id = id;
        c.description = description;
        c.threshold = threshold;
        c.experimentName = experimentName;
        c.deadline = deadline;
        conditionCount++;

        emit KillConditionAdded(id, description, experimentName, deadline);
    }

    /// @notice Update treasury address (e.g. after multisig migration)
    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        treasury = _treasury;
    }

    // --- Trigger ---

    /// @notice Trigger a kill condition when an experiment refutes a prediction
    /// @param conditionId Which condition was falsified
    /// @param evidence    DOI or description of the refuting experimental result
    function triggerKillCondition(
        uint256 conditionId,
        string calldata evidence
    ) external onlyRole(TRIGGER_ROLE) {
        if (conditionId >= conditionCount) revert InvalidConditionId(conditionId);
        if (shutdownActivated) revert ShutdownAlreadyActive();

        KillCondition storage c = conditions[conditionId];
        if (c.triggered) revert ConditionAlreadyTriggered(conditionId);
        if (block.timestamp > c.deadline) revert ConditionExpired(conditionId, c.deadline);

        c.triggered = true;
        c.evidence = evidence;
        c.triggeredAt = block.timestamp;
        triggeredCount++;

        emit KillConditionTriggered(conditionId, evidence, msg.sender);

        if (triggeredCount >= SHUTDOWN_THRESHOLD) {
            _activateShutdown();
        }
    }

    // --- Shutdown ---

    function _activateShutdown() internal {
        shutdownActivated = true;
        shutdownSupplySnapshot = artsToken.totalSupply();
        shutdownTreasurySnapshot = artsToken.balanceOf(treasury);
        emit ShutdownActivated(triggeredCount, shutdownTreasurySnapshot, block.timestamp);
    }

    /// @notice Check whether shutdown has been triggered
    function isShutdownTriggered() external view returns (bool) {
        return shutdownActivated;
    }

    /// @notice Claim pro-rata share of treasury after shutdown.
    ///         share = (caller_balance / total_supply) * treasury_snapshot
    function claimShutdownShare() external {
        if (!shutdownActivated) revert ShutdownNotActive();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed(msg.sender);

        uint256 balance = artsToken.balanceOf(msg.sender);
        if (balance == 0) revert ZeroBalance();

        hasClaimed[msg.sender] = true;
        uint256 share = (balance * shutdownTreasurySnapshot) / shutdownSupplySnapshot;

        // Treasury must have approved this contract for spending
        artsToken.safeTransferFrom(treasury, msg.sender, share);
        emit ShutdownClaimed(msg.sender, share);
    }

    // --- Views ---

    /// @notice Get full details of a kill condition
    function getCondition(uint256 conditionId)
        external view
        returns (
            string memory description, uint256 threshold,
            string memory experimentName, uint256 deadline,
            bool triggered, string memory evidence, uint256 triggeredAt
        )
    {
        if (conditionId >= conditionCount) revert InvalidConditionId(conditionId);
        KillCondition storage c = conditions[conditionId];
        return (c.description, c.threshold, c.experimentName, c.deadline, c.triggered, c.evidence, c.triggeredAt);
    }

    /// @notice How many more conditions must trigger before shutdown
    function conditionsUntilShutdown() external view returns (uint256) {
        if (triggeredCount >= SHUTDOWN_THRESHOLD) return 0;
        return SHUTDOWN_THRESHOLD - triggeredCount;
    }
}
