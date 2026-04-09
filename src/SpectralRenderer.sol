// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./PhiMath.sol";
import "./ConvictionNFT.sol";

/// @title SpectralRenderer — On-chain SVG Rendering for Spectral Dynamic NFTs
/// @author F.B. Sapronov
/// @notice Pure library that generates fully on-chain SVG images for Spectral Dynamic NFTs.
///         Each NFT visualizes a scientific discovery's journey through 5 spectral stages:
///           1. HYPOTHESIS  (blue, <20%)   — initial stake, nascent idea
///           2. SIGNAL      (cyan, 20-50%) — early data suggests match
///           3. CONVERGENCE (green, 50-75%) — multiple sources align
///           4. CONFIRMATION (gold, 75-95%) — experiment confirms
///           5. DISCOVERY   (white+glow, 95%+) — fully validated
///         Features an animated golden spiral (CSS keyframe animations in SVG), confidence bar,
///         discovery title, ARTS staked, and time held.
///
/// @dev All rendering is deterministic and gas-optimized. SVG output is kept under 24KB.
///      Visual style matches ArtosphereDiscovery.sol and ConvictionNFT.sol:
///      dark background (#0a0a1a), gold accents (#c8a000), monospace/serif fonts,
///      phi-proportioned golden spiral circles with CSS rotation animation.
library SpectralRenderer {
    using Strings for uint256;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Fixed-point unit (1.0 = 1e18)
    uint256 internal constant WAD = 1e18;

    /// @notice phi^2 = phi + 1 in WAD (maximum staking multiplier at 100% confidence)
    uint256 internal constant PHI_SQUARED = 2_618033988749894848;

    // ========================================================================
    // ENUMS
    // ========================================================================

    /// @notice The 5 spectral stages of a discovery's lifecycle
    enum Stage {
        Hypothesis,     // 0 — blue (#4466ff), confidence < 20%
        Signal,         // 1 — cyan (#00ccff), 20% <= confidence < 50%
        Convergence,    // 2 — green (#00ff88), 50% <= confidence < 75%
        Confirmation,   // 3 — gold (#ffd700), 75% <= confidence < 95%
        Discovery       // 4 — white+glow (#ffffff), confidence >= 95%
    }

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice Parameters for rendering a Spectral Dynamic NFT
    /// @param tokenId          The NFT token ID
    /// @param title            Discovery title (human-readable)
    /// @param formula          Key formula (LaTeX-compatible string)
    /// @param confidence       Confidence percentage, 0-100 (NOT WAD-scaled)
    /// @param stakingMultiplier Staking multiplier in WAD (1e18 = x1.0)
    /// @param status           Stage label: "HYPOTHESIS"|"SIGNAL"|"CONVERGENCE"|"CONFIRMATION"|"DISCOVERY"
    /// @param discoveryId      Reference token ID in ArtosphereDiscovery
    /// @param stakedAmount     Total ARTS staked on this discovery (WAD-scaled)
    /// @param timeHeldSeconds  Time the current holder has held this NFT (seconds)
    struct SpectralParams {
        uint256 tokenId;
        string title;
        string formula;
        uint256 confidence;
        uint256 stakingMultiplier;
        string status;
        uint256 discoveryId;
        uint256 stakedAmount;
        uint256 timeHeldSeconds;
    }

    // ========================================================================
    // PUBLIC FUNCTIONS
    // ========================================================================

    /// @notice Determine the Stage enum for a given confidence percentage
    /// @dev Thresholds: [0,20) HYPOTHESIS, [20,50) SIGNAL, [50,75) CONVERGENCE,
    ///      [75,95) CONFIRMATION, [95,100] DISCOVERY
    /// @param confidence The confidence percentage (0-100)
    /// @return The Stage enum value
    function getStage(uint256 confidence) internal pure returns (Stage) {
        if (confidence < 20) return Stage.Hypothesis;
        if (confidence < 50) return Stage.Signal;
        if (confidence < 75) return Stage.Convergence;
        if (confidence < 95) return Stage.Confirmation;
        return Stage.Discovery;
    }

    /// @notice Render a full SVG for a ConvictionPosition with spectral styling
    /// @dev Primary entry point for ConvictionNFT.tokenURI(). Generates on-chain SVG
    ///      with golden spiral animation, confidence display, and spectral glow.
    /// @param position The ConvictionPosition from ConvictionNFT
    /// @param confidence Current confidence percentage (0-100)
    /// @param title Discovery title string
    /// @return svg The complete SVG markup
    function renderSVG(
        ConvictionNFT.ConvictionPosition memory position,
        uint256 confidence,
        string memory title
    ) internal pure returns (string memory svg) {
        uint256 conf = confidence > 100 ? 100 : confidence;
        Stage stage = getStage(conf);
        string memory color = _stageColor(stage);
        string memory stageName = _stageName(stage);

        // Time held: compute days from stakedAt to now (passed as timeHeld in params)
        // For pure function we derive from position.stakedAt difference
        uint256 artsWhole = position.amount / WAD;

        svg = string(abi.encodePacked(
            _svgOpen(color, conf, stage),
            _svgGoldenSpiralAnimated(color, stage),
            _svgTitleBlock(position.discoveryId, title),
            _svgStageBadge(stageName, color),
            _svgConfidenceDisplay(conf, color),
            _svgStakeInfo(artsWhole, position.tier, position.stakedAt),
            _svgFooter(stage),
            '</svg>'
        ));
    }

    /// @notice Generate a complete SVG string for a Spectral Dynamic NFT (extended params)
    /// @dev Alternative entry point using SpectralParams struct for full control.
    /// @param params The rendering parameters (see SpectralParams)
    /// @return svg The complete SVG markup as a string
    function renderSpectralSVG(SpectralParams memory params)
        internal
        pure
        returns (string memory svg)
    {
        uint256 conf = params.confidence > 100 ? 100 : params.confidence;
        Stage stage = getStage(conf);
        string memory color = _stageColor(stage);
        string memory stageName = _stageName(stage);

        svg = string(abi.encodePacked(
            _svgOpen(color, conf, stage),
            _svgGoldenSpiralAnimated(color, stage),
            _svgTitleBlock(params.discoveryId, params.title),
            _svgStageBadge(stageName, color),
            _svgConfidenceDisplay(conf, color),
            _svgExtendedInfo(params, stage),
            _svgFooter(stage),
            '</svg>'
        ));
    }

    /// @notice Determine the stage name and hex color for a given confidence percentage
    /// @dev Thresholds: [0,20) HYPOTHESIS (blue), [20,50) SIGNAL (cyan),
    ///      [50,75) CONVERGENCE (green), [75,95) CONFIRMATION (gold), [95,100] DISCOVERY (white).
    /// @param confidence The confidence percentage (0-100)
    /// @return stage The human-readable stage name
    /// @return color The hex color string
    function getStageFromConfidence(uint256 confidence)
        internal
        pure
        returns (string memory stage, string memory color)
    {
        Stage s = getStage(confidence);
        return (_stageName(s), _stageColor(s));
    }

    /// @notice Compute the staking multiplier for a given confidence level
    /// @dev Linearly interpolates from WAD (1.0) at confidence=0 to PHI_SQUARED (2.618) at confidence=100.
    ///      Formula: WAD + (PHI_SQUARED - WAD) * confidence / 100
    /// @param confidence The confidence percentage (0-100)
    /// @return multiplier The staking multiplier in WAD
    function computeStakingMultiplier(uint256 confidence)
        internal
        pure
        returns (uint256 multiplier)
    {
        uint256 conf = confidence > 100 ? 100 : confidence;
        unchecked {
            multiplier = WAD + (PHI_SQUARED - WAD) * conf / 100;
        }
    }

    // ========================================================================
    // STAGE HELPERS
    // ========================================================================

    /// @dev Returns the hex color for a given stage
    function _stageColor(Stage stage) private pure returns (string memory) {
        if (stage == Stage.Hypothesis)    return "#4466ff";  // Blue
        if (stage == Stage.Signal)        return "#00ccff";  // Cyan
        if (stage == Stage.Convergence)   return "#00ff88";  // Green
        if (stage == Stage.Confirmation)  return "#ffd700";  // Gold
        return "#ffffff";                                     // White (Discovery)
    }

    /// @dev Returns the human-readable name for a given stage
    function _stageName(Stage stage) private pure returns (string memory) {
        if (stage == Stage.Hypothesis)    return "HYPOTHESIS";
        if (stage == Stage.Signal)        return "SIGNAL";
        if (stage == Stage.Convergence)   return "CONVERGENCE";
        if (stage == Stage.Confirmation)  return "CONFIRMATION";
        return "DISCOVERY";
    }

    // ========================================================================
    // INTERNAL SVG BUILDERS
    // ========================================================================

    /// @dev SVG opening tag with CSS keyframes for golden spiral rotation and Discovery glow
    function _svgOpen(string memory glowColor, uint256 confidence, Stage stage)
        private
        pure
        returns (string memory)
    {
        // Rotation speed: faster at higher confidence (20s -> 5s)
        uint256 rotDur = 20 - (confidence * 15) / 100; // 20s at 0%, 5s at 100%
        if (rotDur < 5) rotDur = 5;

        string memory discoveryGlow = "";
        if (stage == Stage.Discovery) {
            // White radial glow pulse for Discovery stage
            discoveryGlow = string(abi.encodePacked(
                '@keyframes discoveryPulse{0%,100%{opacity:0.3;transform:scale(1)}50%{opacity:0.8;transform:scale(1.05)}}',
                '.discovery-glow{animation:discoveryPulse 2s ease-in-out infinite;transform-origin:200px 220px;}'
            ));
        }

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="500" style="background:#0a0a1a">',
            '<style>',
            '@keyframes spiralRotate{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}',
            '.spiral{animation:spiralRotate ', rotDur.toString(), 's linear infinite;transform-origin:200px 220px;}',
            '@keyframes glowPulse{0%,100%{opacity:0.4}50%{opacity:0.8}}',
            '.glow-ring{animation:glowPulse 3s ease-in-out infinite;}',
            discoveryGlow,
            '</style>',
            '<defs>',
            '<radialGradient id="spectralGlow" cx="50%" cy="44%" r="25%">',
            '<stop offset="0%" stop-color="', glowColor, '" stop-opacity="0.6"/>',
            '<stop offset="60%" stop-color="', glowColor, '" stop-opacity="0.15"/>',
            '<stop offset="100%" stop-color="#0a0a1a" stop-opacity="0"/>',
            '</radialGradient>',
            '<linearGradient id="topGlow" x1="0" y1="0" x2="0" y2="1">',
            '<stop offset="0%" stop-color="', glowColor, '" stop-opacity="0.08"/>',
            '<stop offset="100%" stop-color="#0a0a1a" stop-opacity="0"/>',
            '</linearGradient>',
            '</defs>',
            '<rect width="400" height="500" fill="#0a0a1a" rx="20"/>',
            '<rect width="400" height="120" fill="url(#topGlow)" rx="20"/>'
        ));
    }

    /// @dev Animated golden spiral — phi-proportioned circles that rotate via CSS animation.
    ///      The spiral is built from 5 arcs at radii 100, 61.8, 38.2, 23.6, 14.6 (each r/phi)
    ///      with a connecting phi-spiral path approximation.
    function _svgGoldenSpiralAnimated(string memory color, Stage stage)
        private
        pure
        returns (string memory)
    {
        string memory discoveryClass = stage == Stage.Discovery ? " discovery-glow" : "";

        // Opacity increases with stage
        string memory baseOp = stage == Stage.Discovery ? "0.5" : "0.2";

        return string(abi.encodePacked(
            '<g class="spiral', discoveryClass, '">',
            // Golden spiral path (approximation using quarter-circle arcs at phi ratios)
            '<path d="M200,220 '
            'a100,100 0 0,1 100,0 '       // r=100 quarter arc
            'a61.8,61.8 0 0,1 0,61.8 '    // r=61.8 quarter arc
            'a38.2,38.2 0 0,1 -38.2,0 '   // r=38.2 quarter arc
            'a23.6,23.6 0 0,1 0,-23.6 '   // r=23.6 quarter arc
            'a14.6,14.6 0 0,1 14.6,0'     // r=14.6 quarter arc
            '" fill="none" stroke="', color, '" stroke-width="1" opacity="', baseOp, '"/>',
            // Phi-proportioned concentric circles
            '<circle cx="200" cy="220" r="100" fill="none" stroke="#c8a000" stroke-width="0.5" opacity="0.15"/>',
            '<circle cx="200" cy="220" r="61.8" fill="none" stroke="#c8a000" stroke-width="0.5" opacity="0.12"/>',
            '<circle cx="200" cy="220" r="38.2" fill="none" stroke="#c8a000" stroke-width="0.5" opacity="0.09"/>',
            '<circle cx="200" cy="220" r="23.6" fill="none" stroke="#c8a000" stroke-width="0.4" opacity="0.06"/>',
            '<circle cx="200" cy="220" r="14.6" fill="none" stroke="#c8a000" stroke-width="0.4" opacity="0.04"/>',
            '</g>',
            // Spectral glow orb (static, behind the spiral)
            _svgSpectralGlow(color, stage)
        ));
    }

    /// @dev Spectral glow circle — the central visual element whose brightness scales with stage
    function _svgSpectralGlow(string memory glowColor, Stage stage)
        private
        pure
        returns (string memory)
    {
        uint256 glowRadius = 40;
        string memory opStr = "0.2";

        if (stage == Stage.Signal)        { glowRadius = 50; opStr = "0.4"; }
        else if (stage == Stage.Convergence)   { glowRadius = 60; opStr = "0.5"; }
        else if (stage == Stage.Confirmation)  { glowRadius = 70; opStr = "0.7"; }
        else if (stage == Stage.Discovery)     { glowRadius = 80; opStr = "0.9"; }

        string memory glowClass = stage == Stage.Discovery ? " class=\"discovery-glow\"" : "";

        return string(abi.encodePacked(
            '<g', glowClass, '>',
            '<circle cx="200" cy="220" r="', glowRadius.toString(),
            '" fill="url(#spectralGlow)" opacity="', opStr, '"/>',
            '<circle cx="200" cy="220" r="', glowRadius.toString(),
            '" fill="none" stroke="', glowColor, '" stroke-width="1.5" opacity="', opStr,
            '" class="glow-ring"/>',
            '</g>'
        ));
    }

    /// @dev Title block: "ARTOSPHERE SPECTRAL", discovery reference
    function _svgTitleBlock(uint256 discoveryId, string memory title)
        private
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(
            '<text x="200" y="35" text-anchor="middle" fill="#c8a000" font-family="serif" font-size="14" font-weight="bold">ARTOSPHERE SPECTRAL</text>',
            '<text x="200" y="55" text-anchor="middle" fill="#666" font-family="monospace" font-size="10">Discovery #',
            discoveryId.toString(), '</text>',
            // Discovery title
            '<rect x="20" y="62" width="360" height="30" rx="8" fill="#111128"/>',
            '<text x="200" y="82" text-anchor="middle" fill="white" font-family="serif" font-size="11">',
            _truncate(title, 42), '</text>'
        ));
    }

    /// @dev Stage badge with colored background pill
    function _svgStageBadge(string memory stageName, string memory color)
        private
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(
            '<rect x="130" y="96" width="140" height="24" rx="12" fill="', color, '" opacity="0.2"/>',
            '<text x="200" y="113" text-anchor="middle" fill="', color,
            '" font-family="monospace" font-size="12" font-weight="bold">', stageName, '</text>'
        ));
    }

    /// @dev Large confidence percentage display with progress bar
    function _svgConfidenceDisplay(uint256 confidence, string memory color)
        private
        pure
        returns (string memory)
    {
        uint256 barWidth;
        unchecked { barWidth = (confidence * 280) / 100; }
        if (confidence > 0 && barWidth < 4) barWidth = 4;

        return string(abi.encodePacked(
            '<text x="200" y="330" text-anchor="middle" fill="', color,
            '" font-family="monospace" font-size="42" font-weight="bold">',
            confidence.toString(), '%</text>',
            '<text x="200" y="348" text-anchor="middle" fill="#888" font-family="monospace" font-size="10">CONFIDENCE</text>',
            '<rect x="60" y="358" width="280" height="6" rx="3" fill="#1a1a2e"/>',
            '<rect x="60" y="358" width="', barWidth.toString(), '" height="6" rx="3" fill="', color, '" opacity="0.8"/>'
        ));
    }

    /// @dev Stake info: ARTS staked, tier, time held (for ConvictionPosition-based rendering)
    function _svgStakeInfo(uint256 artsWhole, uint8 tier, uint256 stakedAt)
        private
        pure
        returns (string memory)
    {
        string memory tierLabel = tier == 0 ? "Tier 0 (5d)" : (tier == 1 ? "Tier 1 (21d)" : "Tier 2 (55d)");

        return string(abi.encodePacked(
            // ARTS staked
            '<rect x="60" y="375" width="280" height="40" rx="8" fill="#111128"/>',
            '<text x="200" y="392" text-anchor="middle" fill="#c8a000" font-family="monospace" font-size="18" font-weight="bold">',
            artsWhole.toString(), ' ARTS</text>',
            '<text x="200" y="408" text-anchor="middle" fill="#888" font-family="monospace" font-size="8">STAKED | ',
            tierLabel, '</text>',
            // Staked timestamp
            '<text x="200" y="432" text-anchor="middle" fill="#555" font-family="monospace" font-size="9">Staked: ',
            stakedAt.toString(), '</text>'
        ));
    }

    /// @dev Extended info block for SpectralParams rendering (multiplier, stake, time held)
    function _svgExtendedInfo(SpectralParams memory params, Stage stage)
        private
        pure
        returns (string memory)
    {
        uint256 artsWhole;
        unchecked { artsWhole = params.stakedAmount / WAD; }

        // Format multiplier: integer.decimal
        uint256 intPart;
        uint256 decPart;
        unchecked {
            intPart = params.stakingMultiplier / WAD;
            decPart = (params.stakingMultiplier % WAD) / 1e17;
        }

        // Time held in days
        uint256 daysHeld;
        unchecked { daysHeld = params.timeHeldSeconds / 86400; }

        // Discovery stage: show special "VALIDATED" tag
        string memory validTag = "";
        if (stage == Stage.Discovery) {
            validTag = string(abi.encodePacked(
                '<rect x="150" y="428" width="100" height="18" rx="9" fill="#ffffff" opacity="0.15"/>',
                '<text x="200" y="441" text-anchor="middle" fill="#ffffff" font-family="monospace" font-size="9" font-weight="bold">VALIDATED</text>'
            ));
        }

        return string(abi.encodePacked(
            '<rect x="60" y="375" width="280" height="40" rx="8" fill="#111128"/>',
            '<text x="140" y="392" text-anchor="middle" fill="#c8a000" font-family="monospace" font-size="14" font-weight="bold">',
            artsWhole.toString(), ' ARTS</text>',
            '<text x="280" y="392" text-anchor="middle" fill="#c8a000" font-family="monospace" font-size="14" font-weight="bold">x',
            intPart.toString(), '.', decPart.toString(), '</text>',
            '<text x="140" y="408" text-anchor="middle" fill="#888" font-family="monospace" font-size="8">STAKED</text>',
            '<text x="280" y="408" text-anchor="middle" fill="#888" font-family="monospace" font-size="8">MULTIPLIER</text>',
            '<text x="200" y="432" text-anchor="middle" fill="#666" font-family="monospace" font-size="9">Held: ',
            daysHeld.toString(), ' days</text>',
            validTag
        ));
    }

    /// @dev Footer with author, phi symbol, and protocol info
    function _svgFooter(Stage stage) private pure returns (string memory) {
        string memory stageIndicator = "";
        if (stage == Stage.Discovery) {
            // Pulsing white border for Discovery stage
            stageIndicator = '<rect x="5" y="5" width="390" height="490" rx="18" fill="none" stroke="#ffffff" stroke-width="2" opacity="0.3" class="glow-ring"/>';
        }

        return string(abi.encodePacked(
            stageIndicator,
            '<text x="200" y="462" text-anchor="middle" fill="#c8a000" font-family="serif" font-size="20" opacity="0.2">',
            unicode"\u03C6", unicode"\u00B2", ' = ', unicode"\u03C6", ' + 1</text>',
            '<text x="200" y="480" text-anchor="middle" fill="#555" font-family="serif" font-size="9">F.B. Sapronov | Cl(9,1) | DYNAMIC</text>',
            '<text x="200" y="493" text-anchor="middle" fill="#333" font-family="monospace" font-size="7">SPECTRAL NFT | ARTOSPHERE PROTOCOL</text>'
        ));
    }

    // ========================================================================
    // UTILITY HELPERS
    // ========================================================================

    /// @dev Truncate a string to maxLen characters, appending "..." if truncated
    function _truncate(string memory str, uint256 maxLen) private pure returns (string memory) {
        bytes memory b = bytes(str);
        if (b.length <= maxLen) return str;

        bytes memory result = new bytes(maxLen);
        unchecked {
            for (uint256 i = 0; i < maxLen - 3; ++i) {
                result[i] = b[i];
            }
        }
        result[maxLen - 3] = ".";
        result[maxLen - 2] = ".";
        result[maxLen - 1] = ".";
        return string(result);
    }
}
