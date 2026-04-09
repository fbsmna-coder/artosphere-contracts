// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PhiMath} from "./PhiMath.sol";

/// @title PhiCoherence — Ecosystem Cascade Coordinator
/// @author Artosphere Team (fcoin-contracts)
/// @notice Propagates parameter changes between Artosphere contracts through φ-damped cascades.
///         Uses a pull-based design: contracts query their damped effect rather than being called.
/// @dev Cascade levels (φ-damping per level distance):
///      Level 0: Token (PhiCoin) — 100% effect
///      Level 1: Staking, Governance, Treasury — 61.8% (φ⁻¹)
///      Level 2: Fusion, Oracle, NFT — 38.2% (φ⁻²)
///      Level 3: Reputation, Detector, PeerReview — 23.6% (φ⁻³)
///      Total cascade amplification bounded: Σφ⁻ⁿ(n=0..3) < φ² ≈ 2.618×
contract PhiCoherence is AccessControl {
    using PhiMath for uint256;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Admin role for contract registration
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Maximum cascade level (0-3)
    uint8 public constant MAX_LEVEL = 3;

    /// @notice Ring buffer capacity for cascade log
    uint256 public constant MAX_LOG_SIZE = 1000;

    /// @notice WAD unit for fixed-point arithmetic
    uint256 private constant WAD = PhiMath.WAD;

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice A recorded cascade event
    /// @param source Contract that initiated the change
    /// @param magnitude Effect magnitude in WAD (1e18 = 100%)
    /// @param dampedMagnitude Magnitude after φ-damping to next level
    /// @param sourceLevel Level of the source contract (0-3)
    /// @param timestamp Block timestamp when the cascade was triggered
    /// @param eventType keccak256 of the event name (e.g., "FEE_CHANGE")
    struct CascadeEvent {
        address source;
        uint256 magnitude;
        uint256 dampedMagnitude;
        uint8 sourceLevel;
        uint256 timestamp;
        bytes32 eventType;
    }

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when level exceeds MAX_LEVEL
    error InvalidLevel(uint8 level);

    /// @notice Thrown when caller is not a registered contract
    error NotRegistered(address caller);

    /// @notice Thrown when contract is already registered
    error AlreadyRegistered(address contractAddr);

    /// @notice Thrown when the event index is out of bounds
    error EventIndexOutOfBounds(uint256 index, uint256 total);

    /// @notice Thrown when the target contract is not registered
    error TargetNotRegistered(address target);

    /// @notice Thrown when magnitude is zero
    error ZeroMagnitude();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a contract is registered at a cascade level
    /// @param contractAddr The registered contract address
    /// @param level The cascade level (0-3)
    event ContractRegistered(address indexed contractAddr, uint8 level);

    /// @notice Emitted when a cascade is triggered
    /// @param source The source contract that initiated the cascade
    /// @param magnitude The original effect magnitude in WAD
    /// @param dampedNext The damped magnitude for the next level (magnitude × φ⁻¹)
    /// @param eventType The keccak256 identifier of the event type
    event CascadeTriggered(address indexed source, uint256 magnitude, uint256 dampedNext, bytes32 eventType);

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Maps contract address to its cascade level (0-3)
    mapping(address => uint8) public contractLevel;

    /// @notice Whitelist of registered contracts
    mapping(address => bool) public registeredContracts;

    /// @notice Ring buffer of cascade events
    CascadeEvent[1000] private _cascadeLog;

    /// @notice Write pointer for the ring buffer (next slot to write)
    uint256 public cascadeLogHead;

    /// @notice Total number of cascades ever recorded
    uint256 public totalCascades;

    /// @notice Contracts grouped by level (0-3)
    mapping(uint8 => address[]) public levelContracts;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Initializes the cascade coordinator
    /// @param admin Address that receives ADMIN_ROLE and DEFAULT_ADMIN_ROLE
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    /// @notice Registers a contract at a specific cascade level
    /// @dev Only callable by ADMIN_ROLE. Level must be 0-3.
    /// @param contractAddr The contract address to register
    /// @param level The cascade level (0 = Token, 1 = Staking/Gov/Treasury, 2 = Fusion/Oracle/NFT, 3 = Rep/Detect/Peer)
    function registerContract(address contractAddr, uint8 level) external onlyRole(ADMIN_ROLE) {
        if (contractAddr == address(0)) revert ZeroAddress();
        if (level > MAX_LEVEL) revert InvalidLevel(level);
        if (registeredContracts[contractAddr]) revert AlreadyRegistered(contractAddr);

        registeredContracts[contractAddr] = true;
        contractLevel[contractAddr] = level;
        levelContracts[level].push(contractAddr);

        emit ContractRegistered(contractAddr, level);
    }

    // ========================================================================
    // CORE CASCADE FUNCTIONS
    // ========================================================================

    /// @notice Records a cascade event from a registered contract
    /// @dev Called by any registered contract when a significant parameter change occurs.
    ///      Computes the damped magnitude for the next level: magnitude × φ⁻¹ ≈ 61.8%.
    ///      Does NOT call other contracts — they pull their damped effect via getDampedEffect.
    /// @param magnitude The effect magnitude in WAD (1e18 = 100%)
    /// @param eventType keccak256 identifier of the event (e.g., keccak256("FEE_CHANGE"))
    function propagate(uint256 magnitude, bytes32 eventType) external {
        if (!registeredContracts[msg.sender]) revert NotRegistered(msg.sender);
        if (magnitude == 0) revert ZeroMagnitude();

        uint8 srcLevel = contractLevel[msg.sender];

        // Damped magnitude for the next level: magnitude × φ⁻¹
        uint256 dampedNext = PhiMath.wadMul(magnitude, PhiMath.PHI_INV);

        // Write to ring buffer
        uint256 slot = cascadeLogHead;
        _cascadeLog[slot] = CascadeEvent({
            source: msg.sender,
            magnitude: magnitude,
            dampedMagnitude: dampedNext,
            sourceLevel: srcLevel,
            timestamp: block.timestamp,
            eventType: eventType
        });

        unchecked {
            cascadeLogHead = (slot + 1) % MAX_LOG_SIZE;
            ++totalCascades;
        }

        emit CascadeTriggered(msg.sender, magnitude, dampedNext, eventType);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Returns the damped effect magnitude that applies to a specific contract
    /// @dev Damping factor = φ⁻|targetLevel - sourceLevel|
    ///      Same level: 100%, 1 apart: 61.8%, 2 apart: 38.2%, 3 apart: 23.6%
    /// @param contractAddr The target contract to query the effect for
    /// @param eventIndex The cascade event index (0-based, from totalCascades history)
    /// @return dampedEffect The magnitude damped by level distance, in WAD
    function getDampedEffect(address contractAddr, uint256 eventIndex) external view returns (uint256 dampedEffect) {
        if (!registeredContracts[contractAddr]) revert TargetNotRegistered(contractAddr);
        if (eventIndex >= totalCascades) revert EventIndexOutOfBounds(eventIndex, totalCascades);

        CascadeEvent storage evt = _eventAt(eventIndex);
        uint8 targetLevel = contractLevel[contractAddr];
        uint8 srcLevel = evt.sourceLevel;

        // Level distance (absolute value)
        uint256 dist;
        unchecked {
            dist = srcLevel > targetLevel ? uint256(srcLevel - targetLevel) : uint256(targetLevel - srcLevel);
        }

        // Apply φ-damping: magnitude × φ⁻ᵈⁱˢᵗ
        if (dist == 0) {
            dampedEffect = evt.magnitude;
        } else {
            dampedEffect = PhiMath.wadMul(evt.magnitude, PhiMath.phiInvPow(dist));
        }
    }

    /// @notice Computes the total cascade effect across all 4 levels for an event
    /// @dev Sum = magnitude × Σ_{n=0}^{3} φ⁻ⁿ where n is the distance from source level.
    ///      For a Level 0 source: 1 + φ⁻¹ + φ⁻² + φ⁻³ ≈ 1 + 0.618 + 0.382 + 0.236 = 2.236
    ///      Bounded above by magnitude × φ² ≈ 2.618× (the golden stabilizer).
    /// @param eventIndex The cascade event index
    /// @return totalEffect The aggregate effect in WAD
    function getTotalCascadeEffect(uint256 eventIndex) external view returns (uint256 totalEffect) {
        if (eventIndex >= totalCascades) revert EventIndexOutOfBounds(eventIndex, totalCascades);

        CascadeEvent storage evt = _eventAt(eventIndex);
        uint8 srcLevel = evt.sourceLevel;
        uint256 mag = evt.magnitude;

        // Sum damped effects across all 4 levels (0-3)
        for (uint8 lvl = 0; lvl <= MAX_LEVEL;) {
            uint256 dist;
            unchecked {
                dist = srcLevel > lvl ? uint256(srcLevel - lvl) : uint256(lvl - srcLevel);
            }

            if (dist == 0) {
                totalEffect += mag;
            } else {
                totalEffect += PhiMath.wadMul(mag, PhiMath.phiInvPow(dist));
            }

            unchecked {
                ++lvl;
            }
        }
    }

    /// @notice Returns the most recent cascade events
    /// @dev Reads backwards from the ring buffer head. Returns fewer if total < count.
    /// @param count Number of recent events to retrieve
    /// @return events Array of CascadeEvent structs, most recent first
    function getRecentCascades(uint256 count) external view returns (CascadeEvent[] memory events) {
        uint256 total = totalCascades;
        if (count > total) {
            count = total;
        }
        if (count > MAX_LOG_SIZE) {
            count = MAX_LOG_SIZE;
        }

        events = new CascadeEvent[](count);

        if (count == 0) return events;

        uint256 readPos = cascadeLogHead;
        for (uint256 i = 0; i < count;) {
            unchecked {
                readPos = (readPos + MAX_LOG_SIZE - 1) % MAX_LOG_SIZE;
            }
            events[i] = _cascadeLog[readPos];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the total number of cascades ever recorded
    /// @return Total cascade count (may exceed MAX_LOG_SIZE due to ring buffer overwrites)
    function getCascadeCount() external view returns (uint256) {
        return totalCascades;
    }

    /// @notice Returns a specific cascade event by index
    /// @param eventIndex The global event index (0-based from first cascade)
    /// @return The CascadeEvent at that index
    function cascadeLog(uint256 eventIndex) external view returns (CascadeEvent memory) {
        if (eventIndex >= totalCascades) revert EventIndexOutOfBounds(eventIndex, totalCascades);
        return _eventAt(eventIndex);
    }

    /// @notice Returns the number of contracts registered at a given level
    /// @param level The cascade level (0-3)
    /// @return Number of contracts at that level
    function getLevelContractCount(uint8 level) external view returns (uint256) {
        return levelContracts[level].length;
    }

    /// @notice Returns all contracts registered at a given level
    /// @param level The cascade level (0-3)
    /// @return Array of contract addresses
    function getContractsAtLevel(uint8 level) external view returns (address[] memory) {
        return levelContracts[level];
    }

    // ========================================================================
    // INTERNAL HELPERS
    // ========================================================================

    /// @notice Resolves a global event index to its ring buffer slot
    /// @dev If totalCascades <= MAX_LOG_SIZE, slot = index directly.
    ///      Otherwise, oldest available = totalCascades - MAX_LOG_SIZE.
    /// @param eventIndex The global event index
    /// @return evt Storage pointer to the CascadeEvent
    function _eventAt(uint256 eventIndex) private view returns (CascadeEvent storage evt) {
        // Ensure the event hasn't been overwritten
        uint256 oldest;
        if (totalCascades > MAX_LOG_SIZE) {
            unchecked {
                oldest = totalCascades - MAX_LOG_SIZE;
            }
        }
        if (eventIndex < oldest) revert EventIndexOutOfBounds(eventIndex, totalCascades);

        uint256 slot = eventIndex % MAX_LOG_SIZE;
        evt = _cascadeLog[slot];
    }
}
