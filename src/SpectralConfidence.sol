// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./PhiMath.sol";

/// @title SpectralConfidence — Zero-Gas Confidence Oracle for Spectral Dynamic NFTs
/// @author F.B. Sapronov
/// @notice Implements the TRIZ insight: store the FORMULA, not the value. Confidence is
///         computed at read time from on-chain parameters with 0 gas cost for time evolution.
///         Only oracle/admin writes trigger storage updates (new experimental data).
///
///         Core formula (golden ratio convergence):
///           confidence(t) = c_max - (c_max - c_0) * phi^{-floor(t / tau)}
///
///         Where:
///           - c_0    = initial confidence, set by oracle when data first arrives
///           - c_max  = 1.0 (WAD) — asymptotic maximum
///           - tau    = epoch duration (default: 1 week = 604800 seconds)
///           - t      = time elapsed since c_0 was set
///           - phi    = golden ratio = (1+sqrt(5))/2
///
///         As epochs pass, confidence converges toward c_max via golden ratio decay:
///           n=0: c = c_0                    (initial)
///           n=1: c = c_0 + (1-c_0)/phi      (first epoch: +61.8% of gap)
///           n=2: c = c_0 + (1-c_0)*(1-1/phi^2) (+85.4%)
///           n->inf: c -> c_max = 1.0         (asymptotic)
///
/// @dev Uses PhiMath.phiInvPow() for the golden ratio decay factor.
///      All values in WAD (1e18 = 100%). AccessControl for oracle role management.
contract SpectralConfidence is AccessControl {

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Oracle role — can set initial confidence (c_0) for discoveries
    /// @dev Granted to the DiscoveryOracle contract or admin
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice WAD unit — fixed-point 1.0 = 1e18
    uint256 public constant WAD = 1e18;

    /// @notice c_max = 1.0 in WAD — the asymptotic maximum confidence
    /// @dev Confidence converges toward this value as time -> infinity
    uint256 public constant C_MAX = WAD;

    /// @notice tau = 1 week = 604800 seconds — the epoch duration
    /// @dev Each epoch, the remaining gap (c_max - c_current) shrinks by factor 1/phi.
    ///      After 1 epoch: confidence gains 61.8% of the gap to c_max.
    ///      After 2 epochs: 85.4%. After 5 epochs: 99.0%.
    uint256 public constant TAU = 604800; // 7 days in seconds

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice On-chain formula parameters for a discovery's confidence curve
    /// @dev Stores only (c_0, t_0). c_max and tau are global constants.
    ///      confidence(t) = C_MAX - (C_MAX - c0) * phi^{-floor((t - t0) / TAU)}
    struct ConfidenceParams {
        uint256 c0;     // Initial confidence in WAD [0, WAD]
        uint256 t0;     // Timestamp when c_0 was set (start of convergence)
        bool isSet;     // Whether this discovery has been initialized
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Confidence parameters per discoveryId
    mapping(uint256 => ConfidenceParams) public confidenceParams;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when an oracle sets/updates initial confidence for a discovery
    event ConfidenceSet(
        uint256 indexed discoveryId,
        uint256 c0,
        uint256 t0
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when c_0 exceeds c_max (= WAD)
    error C0ExceedsCMax(uint256 c0);

    /// @notice Thrown when querying confidence for an uninitialized discovery
    error DiscoveryNotInitialized(uint256 discoveryId);

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the SpectralConfidence oracle
    /// @param admin Admin address — manages roles (DEFAULT_ADMIN_ROLE + ORACLE_ROLE)
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ROLE, admin);
    }

    // ========================================================================
    // ORACLE FUNCTIONS (write)
    // ========================================================================

    /// @notice Set the initial confidence for a discovery
    /// @dev Called by the oracle when first experimental data arrives. Resets the
    ///      convergence clock (t0 = block.timestamp). If called again, snapshots
    ///      the current computed confidence as the new c0 for continuity.
    /// @param discoveryId The discovery identifier
    /// @param c0 Initial confidence in WAD (e.g., 0.1e18 = 10%)
    function setInitialConfidence(uint256 discoveryId, uint256 c0)
        external
        onlyRole(ORACLE_ROLE)
    {
        if (c0 > C_MAX) revert C0ExceedsCMax(c0);

        ConfidenceParams storage params = confidenceParams[discoveryId];

        if (params.isSet) {
            // Snapshot current confidence as new starting point for continuity
            uint256 currentConf = _computeConfidence(params);
            // Use the higher of current confidence or new c0
            // (oracle should not decrease confidence without explicit reset)
            params.c0 = currentConf > c0 ? currentConf : c0;
        } else {
            params.c0 = c0;
            params.isSet = true;
        }

        params.t0 = block.timestamp;

        emit ConfidenceSet(discoveryId, params.c0, block.timestamp);
    }

    // ========================================================================
    // VIEW FUNCTIONS (0 gas for confidence evolution)
    // ========================================================================

    /// @notice Get the current confidence of a discovery
    /// @dev THE KEY FUNCTION: computed at read time with 0 gas cost for updates.
    ///      Formula: confidence(t) = C_MAX - (C_MAX - c_0) * phi^{-floor((t - t_0) / TAU)}
    ///      As time passes, phi^{-n} -> 0, so confidence -> C_MAX asymptotically.
    /// @param discoveryId The discovery to query
    /// @return confidence Current confidence in WAD [c_0, C_MAX]
    function getConfidence(uint256 discoveryId) external view returns (uint256 confidence) {
        ConfidenceParams memory params = confidenceParams[discoveryId];
        if (!params.isSet) revert DiscoveryNotInitialized(discoveryId);

        confidence = _computeConfidence(params);
    }

    /// @notice Get the confidence as a percentage (0-100) for rendering
    /// @param discoveryId The discovery to query
    /// @return pct Confidence percentage (integer, 0-100)
    function getConfidencePercent(uint256 discoveryId) external view returns (uint256 pct) {
        ConfidenceParams memory params = confidenceParams[discoveryId];
        if (!params.isSet) revert DiscoveryNotInitialized(discoveryId);

        uint256 conf = _computeConfidence(params);
        pct = conf / 1e16; // WAD / 1e16 = 100 at max
    }

    /// @notice Get the number of complete epochs elapsed for a discovery
    /// @param discoveryId The discovery to query
    /// @return epochs Number of complete TAU periods since t0
    function getEpochsElapsed(uint256 discoveryId) external view returns (uint256 epochs) {
        ConfidenceParams memory params = confidenceParams[discoveryId];
        if (!params.isSet) revert DiscoveryNotInitialized(discoveryId);

        uint256 elapsed = block.timestamp - params.t0;
        epochs = elapsed / TAU;
    }

    /// @notice Check if a discovery has been initialized
    /// @param discoveryId The discovery to check
    /// @return True if confidence parameters have been set
    function isInitialized(uint256 discoveryId) external view returns (bool) {
        return confidenceParams[discoveryId].isSet;
    }

    // ========================================================================
    // INTERNAL: The Formula
    // ========================================================================

    /// @notice Core confidence computation
    /// @dev confidence(t) = c_max - (c_max - c_0) * phi^{-floor((t - t_0) / tau)}
    ///      Uses PhiMath.phiInvPow() which returns phi^{-n} in WAD.
    ///      For n > 86, phiInvPow returns 0, so confidence = c_max (converged).
    function _computeConfidence(ConfidenceParams memory params) internal view returns (uint256) {
        // If c0 == C_MAX, already at maximum
        if (params.c0 >= C_MAX) return C_MAX;

        // Number of complete epochs elapsed
        uint256 elapsed = block.timestamp - params.t0;
        uint256 n = elapsed / TAU;

        // phi^{-n}: the golden ratio decay factor
        // At n=0: phi^0 = 1.0 (full gap remains)
        // At n=1: phi^{-1} = 0.618 (38.2% of gap closed)
        // At n=2: phi^{-2} = 0.382 (61.8% of gap closed)
        // At n>86: phi^{-n} = 0 (fully converged)
        uint256 decay = PhiMath.phiInvPow(n);

        // gap = c_max - c_0
        uint256 gap = C_MAX - params.c0;

        // remaining = gap * decay (portion of gap still remaining)
        uint256 remaining = PhiMath.wadMul(gap, decay);

        // confidence = c_max - remaining
        return C_MAX - remaining;
    }
}
