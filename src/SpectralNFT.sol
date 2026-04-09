// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./ArtosphereConstants.sol";
import "./PhiMath.sol";
import "./SpectralRenderer.sol";

/// @title SpectralNFT — Dynamic ERC-721 "Living Particle" NFTs
/// @author F.B. Sapronov
/// @notice Each Spectral NFT represents a living particle whose visual appearance and
///         staking multiplier evolve as experimental data converges toward an Artosphere
///         prediction. The KEY INNOVATION from TRIZ analysis: we store a FORMULA, not a
///         snapshot. Confidence c(t) is computed at read time from on-chain parameters via
///         c(t) = cInf - (cInf - c0) * phi^{-floor((t-t0)/tau)}, requiring ZERO update
///         transactions as time passes. Only oracle data (cInf, tau) triggers a write.
///
/// @dev ERC-721 + ERC-721Enumerable + ERC-2981 (2.13% = 1/phi^8 royalty to scientist).
///      On-chain SVG via SpectralRenderer. Minted by DiscoveryStaking (MINTER_ROLE).
///      Confidence parameters updated by DiscoveryOracle (ORACLE_ROLE).
contract SpectralNFT is
    ERC721,
    ERC721Enumerable,
    ERC2981,
    AccessControl,
    ReentrancyGuard
{
    using Strings for uint256;

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Minter role — granted to DiscoveryStaking or a dedicated minter contract
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Oracle role — granted to DiscoveryOracle, can update confidence parameters
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Default tau: 1 week (604800 seconds) — confidence epoch duration
    /// @dev τ = 7 days. Each epoch, confidence converges toward cInf by factor 1/φ.
    uint256 public constant DEFAULT_TAU = 7 days;

    /// @notice WAD unit (1e18) for fixed-point arithmetic
    uint256 private constant WAD = 1e18;

    /// @notice Confidence thresholds for the 5 spectral stages (in WAD)
    /// @dev HYPOTHESIS [0, 0.2), SIGNAL [0.2, 0.5), CONVERGENCE [0.5, 0.75),
    ///      CONFIRMATION [0.75, 0.95), DISCOVERY [0.95, 1.0]
    uint256 private constant STAGE_THRESHOLD_1 = 0.2e18;   // 20%
    uint256 private constant STAGE_THRESHOLD_2 = 0.5e18;   // 50%
    uint256 private constant STAGE_THRESHOLD_3 = 0.75e18;  // 75%
    uint256 private constant STAGE_THRESHOLD_4 = 0.95e18;  // 95%

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice On-chain state of a Spectral NFT — stores the formula, not a value
    /// @dev Confidence is computed at read time: c(t) = cInf - (cInf - c0) * phi^{-n}
    ///      where n = floor((block.timestamp - t0) / tau)
    struct SpectralState {
        uint256 discoveryId;  // Links to ArtosphereDiscovery tokenId
        uint256 c0;           // Initial confidence (WAD, typically 0)
        uint256 cInf;         // Target confidence (WAD, set by oracle, 0-1e18)
        uint256 tau;          // Decay period in seconds (Fibonacci: 5/8/13/21 days)
        uint256 t0;           // Start timestamp
        uint256 mintAmount;   // ARTS paid to mint (WAD)
        string title;         // Cached discovery title
        string formula;       // Cached formula
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Spectral state indexed by token ID
    mapping(uint256 => SpectralState) public spectralStates;

    /// @notice Next token ID to mint
    uint256 public nextTokenId;

    /// @notice Scientist address (receives ERC-2981 royalties)
    address public immutable scientist;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new Spectral NFT is minted
    event SpectralMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint256 indexed discoveryId
    );

    /// @notice Emitted when the oracle updates confidence parameters
    event SpectralUpdate(
        uint256 indexed tokenId,
        uint256 newCInf,
        uint256 newTau
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    error TokenDoesNotExist(uint256 tokenId);
    error CInfExceedsWAD(uint256 cInf);
    error TauIsZero();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Deploy the Spectral NFT contract
    /// @param _scientist Scientist address — receives ERC-2981 royalties (1/phi^8 ~ 2.13%)
    /// @param admin Admin address — manages roles (DEFAULT_ADMIN_ROLE)
    constructor(address _scientist, address admin)
        ERC721("Artosphere Spectral", "ARTS-S")
    {
        scientist = _scientist;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // ERC-2981: 2.13% royalty (= 1/phi^8 = BURN_RATE_BPS) to scientist
        _setDefaultRoyalty(_scientist, uint96(ArtosphereConstants.BURN_RATE_BPS));
    }

    // ========================================================================
    // MINTING (called by DiscoveryStaking or dedicated minter)
    // ========================================================================

    /// @notice Mint a Spectral NFT representing a living particle tied to a discovery
    /// @param to Recipient address
    /// @param discoveryId The ArtosphereDiscovery tokenId this particle tracks
    /// @param title Cached discovery title for rendering
    /// @param formula Cached formula for rendering
    /// @param mintAmount ARTS paid to mint (WAD)
    /// @return tokenId The minted token ID
    function mint(
        address to,
        uint256 discoveryId,
        string calldata title,
        string calldata formula,
        uint256 mintAmount
    ) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256 tokenId) {
        tokenId = nextTokenId;
        unchecked { ++nextTokenId; }

        spectralStates[tokenId] = SpectralState({
            discoveryId: discoveryId,
            c0: 0,
            cInf: 0,
            tau: DEFAULT_TAU,
            t0: block.timestamp,
            mintAmount: mintAmount,
            title: title,
            formula: formula
        });

        _safeMint(to, tokenId);

        emit SpectralMinted(tokenId, to, discoveryId);
    }

    // ========================================================================
    // ORACLE UPDATE
    // ========================================================================

    /// @notice Update confidence target when new experimental data arrives
    /// @dev Called by DiscoveryOracle (ORACLE_ROLE). Snapshots current confidence as
    ///      the new c0, resets t0 to now, and sets the new asymptotic target cInf.
    ///      This preserves continuity: the particle's confidence doesn't jump.
    /// @param tokenId The Spectral NFT to update
    /// @param newCInf New target confidence (0 to WAD = 0% to 100%)
    /// @param newTau New decay period in seconds (Fibonacci: 5/8/13/21 days)
    function updateConfidenceTarget(
        uint256 tokenId,
        uint256 newCInf,
        uint256 newTau
    ) external onlyRole(ORACLE_ROLE) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        if (newCInf > WAD) revert CInfExceedsWAD(newCInf);
        if (newTau == 0) revert TauIsZero();

        SpectralState storage state = spectralStates[tokenId];

        // Snapshot current computed confidence as the new starting point
        // This ensures continuity: no discontinuous jump in confidence
        uint256 currentConfidence = _computeConfidence(state);

        state.c0 = currentConfidence;
        state.cInf = newCInf;
        state.tau = newTau;
        state.t0 = block.timestamp;

        emit SpectralUpdate(tokenId, newCInf, newTau);
    }

    // ========================================================================
    // VIEW FUNCTIONS: The Key Innovation — Zero-Write Computation
    // ========================================================================

    /// @notice Compute the current confidence of a Spectral NFT
    /// @dev THE KEY FUNCTION: confidence is computed at read time from on-chain parameters.
    ///      Formula: c(t) = cInf - (cInf - c0) * phi^{-floor((t - t0) / tau)}
    ///      Uses PhiMath.phiInvPow() for the golden ratio decay.
    ///      No storage writes — the "living particle" evolves for free.
    /// @param tokenId The Spectral NFT to query
    /// @return confidence Current confidence in WAD [0, WAD]
    function getConfidence(uint256 tokenId) external view returns (uint256 confidence) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        confidence = _computeConfidence(spectralStates[tokenId]);
    }

    /// @notice Get the staking multiplier derived from current confidence
    /// @dev Range: [1.0, phi^2] = [1.0, 2.618] in WAD
    ///      Formula: multiplier = 1 + (phi^2 - 1) * confidence / WAD
    ///      At confidence=0: multiplier=1.0 (no boost)
    ///      At confidence=WAD: multiplier=phi^2=2.618 (maximum boost)
    /// @param tokenId The Spectral NFT to query
    /// @return multiplier Staking multiplier in WAD [WAD, PHI_SQUARED]
    function getStakingMultiplier(uint256 tokenId) external view returns (uint256 multiplier) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        uint256 confidence = _computeConfidence(spectralStates[tokenId]);

        // multiplier = WAD + (PHI_SQUARED - WAD) * confidence / WAD
        // (PHI_SQUARED - WAD) = PHI - which is the fractional boost range
        unchecked {
            multiplier = WAD + PhiMath.wadMul(PhiMath.PHI_SQUARED - WAD, confidence);
        }
    }

    /// @notice Get the spectral stage and associated color based on current confidence
    /// @dev Maps confidence to 5 stages:
    ///      HYPOTHESIS (0-20%), SIGNAL (20-40%), CONVERGENCE (40-60%),
    ///      CONFIRMATION (60-80%), DISCOVERY (80-100%)
    /// @param tokenId The Spectral NFT to query
    /// @return stage Human-readable stage name
    /// @return color Hex color for rendering
    function getStage(uint256 tokenId)
        external
        view
        returns (string memory stage, string memory color)
    {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        uint256 confidence = _computeConfidence(spectralStates[tokenId]);
        (stage, color) = _resolveStage(confidence);
    }

    /// @notice Check if a token exists (has not been burned)
    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Get all token IDs owned by an address
    /// @dev Uses ERC721Enumerable for efficient on-chain enumeration
    function tokensOfOwner(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokens = new uint256[](balance);
        for (uint256 i = 0; i < balance;) {
            tokens[i] = tokenOfOwnerByIndex(owner, i);
            unchecked { ++i; }
        }
        return tokens;
    }

    // ========================================================================
    // METADATA: Fully on-chain SVG + JSON (OpenSea/Blur compatible)
    // ========================================================================

    /// @notice Returns fully on-chain metadata with dynamic SVG
    /// @dev Builds SpectralRenderer.SpectralParams from current state, renders SVG,
    ///      and returns data:application/json;base64 with name, description, image,
    ///      and attributes reflecting the current spectral stage.
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        _requireOwned(tokenId);
        SpectralState memory state = spectralStates[tokenId];

        uint256 confidence = _computeConfidence(state);
        uint256 multiplier;
        unchecked {
            multiplier = WAD + PhiMath.wadMul(PhiMath.PHI_SQUARED - WAD, confidence);
        }
        (string memory stage,) = _resolveStage(confidence);

        // Confidence percentage for display (integer 0-100)
        uint256 confPct = confidence / 1e16; // WAD/1e16 = 100 at max

        // Time held since mint
        uint256 timeHeld = block.timestamp > state.t0 ? block.timestamp - state.t0 : 0;

        // Build renderer params — matches SpectralRenderer.SpectralParams struct
        SpectralRenderer.SpectralParams memory params = SpectralRenderer.SpectralParams({
            tokenId: tokenId,
            title: state.title,
            formula: state.formula,
            confidence: confPct,
            stakingMultiplier: multiplier,
            status: stage,
            discoveryId: state.discoveryId,
            stakedAmount: state.mintAmount,
            timeHeldSeconds: timeHeld
        });

        string memory svg = SpectralRenderer.renderSpectralSVG(params);

        // Build JSON metadata (OpenSea-compatible)
        string memory json = string(abi.encodePacked(
            '{"name":"Artosphere Spectral #', tokenId.toString(),
            '","description":"A living particle tracking Discovery #',
            state.discoveryId.toString(),
            '. Confidence evolves in real-time via golden ratio decay. Stage: ',
            stage, ' (', confPct.toString(), '%).',
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","attributes":[', _jsonAttributes(tokenId, state, confidence, multiplier, stage),
            ']}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    // ========================================================================
    // INTERNAL: Confidence Computation
    // ========================================================================

    /// @notice Core confidence formula: c(t) = cInf - (cInf - c0) * phi^{-n}
    /// @dev n = floor((block.timestamp - t0) / tau). Uses PhiMath.phiInvPow for decay.
    ///      As n -> infinity, phi^{-n} -> 0, so c(t) -> cInf (asymptotic convergence).
    ///      At n=0 (t < t0 + tau), c(t) = cInf - (cInf - c0) * 1 = c0.
    function _computeConfidence(SpectralState memory state) internal view returns (uint256) {
        // If no target set, confidence stays at c0
        if (state.cInf == state.c0) return state.c0;
        // Safety: tau should never be 0 but guard anyway
        if (state.tau == 0) return state.c0;

        // Number of complete decay periods elapsed
        uint256 elapsed = block.timestamp - state.t0;
        uint256 n = elapsed / state.tau;

        // phi^{-n}: golden ratio decay factor
        uint256 decay = PhiMath.phiInvPow(n);

        // gap = cInf - c0 (unsigned because cInf >= c0 after oracle update,
        // but handle both directions for safety)
        if (state.cInf >= state.c0) {
            uint256 gap = state.cInf - state.c0;
            uint256 remaining = PhiMath.wadMul(gap, decay);
            return state.cInf - remaining;
        } else {
            // Decreasing confidence (oracle lowered target)
            uint256 gap = state.c0 - state.cInf;
            uint256 remaining = PhiMath.wadMul(gap, decay);
            return state.cInf + remaining;
        }
    }

    /// @notice Map confidence value to one of 5 spectral stages
    /// @dev Matches SpectralRenderer.getStage() thresholds: 20/50/75/95%
    function _resolveStage(uint256 confidence)
        internal
        pure
        returns (string memory stage, string memory color)
    {
        if (confidence < STAGE_THRESHOLD_1) {
            return ("HYPOTHESIS", "#4466ff");      // Blue — nascent idea
        } else if (confidence < STAGE_THRESHOLD_2) {
            return ("SIGNAL", "#00ccff");           // Cyan — early data
        } else if (confidence < STAGE_THRESHOLD_3) {
            return ("CONVERGENCE", "#00ff88");      // Green — sources align
        } else if (confidence < STAGE_THRESHOLD_4) {
            return ("CONFIRMATION", "#ffd700");     // Gold — experiment confirms
        } else {
            return ("DISCOVERY", "#ffffff");         // White+glow — fully validated
        }
    }

    // ========================================================================
    // INTERNAL: JSON Attributes
    // ========================================================================

    function _jsonAttributes(
        uint256,
        SpectralState memory state,
        uint256 confidence,
        uint256 multiplier,
        string memory stage
    ) internal pure returns (string memory) {
        // Confidence and multiplier as display integers
        uint256 confPct = confidence / 1e16;
        // Multiplier: 1.000 to 2.618 — show as x1000 integer for precision
        uint256 multX1000 = multiplier / 1e15;

        return string(abi.encodePacked(
            '{"trait_type":"Discovery","display_type":"number","value":', state.discoveryId.toString(), '},',
            '{"trait_type":"Stage","value":"', stage, '"},',
            '{"trait_type":"Confidence %","display_type":"number","value":', confPct.toString(), '},',
            '{"trait_type":"Multiplier x1000","display_type":"number","value":', multX1000.toString(), '},',
            '{"trait_type":"Mint Amount ARTS","display_type":"number","value":', (state.mintAmount / 1e18).toString(), '},',
            '{"trait_type":"Formula","value":"', state.formula, '"},',
            '{"trait_type":"Minted At","display_type":"date","value":', state.t0.toString(), '}'
        ));
    }

    // ========================================================================
    // OVERRIDES: ERC-721 + ERC-721Enumerable + ERC-2981 + AccessControl
    // ========================================================================

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC2981, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
