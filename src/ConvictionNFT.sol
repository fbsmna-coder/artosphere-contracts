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

/// @title ConvictionNFT — Transferable ERC-721 Staking Position Receipts
/// @author F.B. Sapronov
/// @notice Each NFT represents a staking position in Discovery Staking.
///         Unlike soulbound ArtosphereDiscovery NFTs, these are TRANSFERABLE —
///         whoever holds the NFT can claim the staking rewards. This creates
///         a secondary market for conviction: buy an existing CONFIRM position NFT
///         if you believe a discovery will be confirmed.
///
///         Key innovation: claim() is callable by the current NFT holder,
///         not the original staker. The NFT is BURNED on claim.
///
/// @dev ERC-721 + ERC-2981 (2.13% = 1/φ⁸ royalty to scientist).
///      On-chain SVG metadata. Minted exclusively by DiscoveryStaking (MINTER_ROLE).
///      Burns on claim to prevent double-claiming.
contract ConvictionNFT is
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

    /// @notice Minter role — exclusively granted to DiscoveryStaking contract
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Claimer role — contract authorized to execute claim/burn logic
    /// @dev Set to the DiscoveryStaking contract so it can process reward payouts
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice On-chain representation of a staking position
    struct ConvictionPosition {
        uint256 discoveryId;    // Which discovery this bet is on
        uint8 side;             // 0 = CONFIRM, 1 = REFUTE
        uint256 amount;         // ARTS staked (after fee)
        uint8 tier;             // 0, 1, 2 (Fibonacci lock tiers)
        uint256 stakedAt;       // Timestamp of original stake
        bool claimed;           // Whether rewards have been claimed (NFT burned)
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Position data indexed by token ID
    mapping(uint256 => ConvictionPosition) public positions;

    /// @notice Next token ID to mint
    uint256 public nextTokenId;

    /// @notice Scientist address (receives ERC-2981 royalties)
    address public immutable scientist;

    /// @notice Discovery title cache for SVG rendering
    /// @dev Set at mint time to avoid cross-contract calls during tokenURI
    mapping(uint256 => string) private _discoveryTitles;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new conviction position NFT is minted
    event ConvictionMinted(
        uint256 indexed tokenId,
        address indexed staker,
        uint256 indexed discoveryId,
        uint8 side,
        uint256 amount,
        uint8 tier
    );

    /// @notice Emitted when a conviction NFT is claimed and burned
    event ConvictionClaimed(
        uint256 indexed tokenId,
        address indexed claimer,
        uint256 indexed discoveryId
    );

    /// @notice Emitted when a conviction NFT is burned (emergency withdraw)
    event ConvictionBurned(
        uint256 indexed tokenId,
        uint256 indexed discoveryId
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    error InvalidSide();
    error InvalidTier(uint8 tier);
    error AlreadyClaimed(uint256 tokenId);
    error NotTokenHolder(uint256 tokenId);
    error ZeroAmount();
    error TokenDoesNotExist(uint256 tokenId);

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @param _scientist Scientist address — receives ERC-2981 royalties (1/φ⁸ ≈ 2.13%)
    /// @param admin Admin address — manages roles
    constructor(address _scientist, address admin)
        ERC721("Artosphere Conviction", "ARTC")
    {
        scientist = _scientist;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // ERC-2981: 2.13% royalty (= 1/φ⁸ = BURN_RATE_BPS) to scientist
        _setDefaultRoyalty(_scientist, uint96(ArtosphereConstants.BURN_RATE_BPS));
    }

    // ========================================================================
    // MINTING (called by DiscoveryStaking)
    // ========================================================================

    /// @notice Mint a conviction NFT representing a staking position
    /// @param to The staker's address
    /// @param discoveryId The discovery being staked on
    /// @param side 0 = CONFIRM, 1 = REFUTE
    /// @param amount ARTS staked (after fee)
    /// @param tier Fibonacci lock tier (0, 1, 2)
    /// @param discoveryTitle Title for SVG rendering (cached on-chain)
    /// @return tokenId The minted token ID
    function mint(
        address to,
        uint256 discoveryId,
        uint8 side,
        uint256 amount,
        uint8 tier,
        string calldata discoveryTitle
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (side > 1) revert InvalidSide();
        if (tier > 2) revert InvalidTier(tier);
        if (amount == 0) revert ZeroAmount();

        tokenId = nextTokenId;
        unchecked { ++nextTokenId; }

        positions[tokenId] = ConvictionPosition({
            discoveryId: discoveryId,
            side: side,
            amount: amount,
            tier: tier,
            stakedAt: block.timestamp,
            claimed: false
        });

        _discoveryTitles[tokenId] = discoveryTitle;

        _safeMint(to, tokenId);

        emit ConvictionMinted(tokenId, to, discoveryId, side, amount, tier);
    }

    // ========================================================================
    // CLAIM & BURN
    // ========================================================================

    /// @notice Mark a conviction NFT as claimed and burn it
    /// @dev Called by DiscoveryStaking (CLAIMER_ROLE) after processing rewards.
    ///      The DiscoveryStaking contract verifies the caller is the NFT holder
    ///      and handles the actual ARTS token transfer.
    /// @param tokenId The conviction NFT to claim
    /// @param caller The address initiating the claim (must be current token holder)
    function markClaimed(uint256 tokenId, address caller) external onlyRole(CLAIMER_ROLE) nonReentrant {
        _requireOwned(tokenId);

        ConvictionPosition storage pos = positions[tokenId];
        if (pos.claimed) revert AlreadyClaimed(tokenId);
        if (ownerOf(tokenId) != caller) revert NotTokenHolder(tokenId);

        pos.claimed = true;

        _burn(tokenId);

        emit ConvictionClaimed(tokenId, caller, pos.discoveryId);
    }

    /// @notice Burn a conviction NFT without claiming (emergency withdraw)
    /// @dev Called by DiscoveryStaking (CLAIMER_ROLE) on emergency/expiration withdraw
    /// @param tokenId The token to burn
    function burn(uint256 tokenId) external onlyRole(CLAIMER_ROLE) {
        _requireOwned(tokenId);
        uint256 discoveryId = positions[tokenId].discoveryId;
        _burn(tokenId);
        emit ConvictionBurned(tokenId, discoveryId);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get full position data for a token
    function getPosition(uint256 tokenId) external view returns (ConvictionPosition memory) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        return positions[tokenId];
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
        for (uint256 i = 0; i < balance; i++) {
            tokens[i] = tokenOfOwnerByIndex(owner, i);
        }
        return tokens;
    }

    /// @notice Get the cached discovery title for SVG rendering
    function getDiscoveryTitle(uint256 tokenId) external view returns (string memory) {
        return _discoveryTitles[tokenId];
    }

    // ========================================================================
    // METADATA: Fully on-chain SVG + JSON (OpenSea/Blur compatible)
    // ========================================================================

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        _requireOwned(tokenId);
        ConvictionPosition memory pos = positions[tokenId];

        string memory svg = _generateSVG(tokenId, pos);

        string memory sideStr = pos.side == 0 ? "CONFIRM" : "REFUTE";
        string memory tierStr = _tierName(pos.tier);

        // Build JSON metadata (OpenSea-compatible)
        string memory json = string(abi.encodePacked(
            '{"name":"Artosphere Conviction #', tokenId.toString(),
            '","description":"Staking position on Discovery #', pos.discoveryId.toString(),
            ' (', sideStr, '). Whoever holds this NFT can claim the staking rewards.',
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","attributes":[',
            _jsonAttributes(pos, sideStr, tierStr),
            ']}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    function _jsonAttributes(
        ConvictionPosition memory pos,
        string memory sideStr,
        string memory tierStr
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '{"trait_type":"Discovery","display_type":"number","value":', pos.discoveryId.toString(), '},',
            '{"trait_type":"Side","value":"', sideStr, '"},',
            '{"trait_type":"Amount ARTS","display_type":"number","value":', (pos.amount / 1e18).toString(), '},',
            '{"trait_type":"Tier","value":"', tierStr, '"},',
            '{"trait_type":"Staked At","display_type":"date","value":', pos.stakedAt.toString(), '},',
            '{"trait_type":"Transferable","value":"Yes"}'
        ));
    }

    // ========================================================================
    // SVG GENERATION — On-chain visual identity
    // ========================================================================

    function _generateSVG(uint256 tokenId, ConvictionPosition memory pos)
        internal
        view
        returns (string memory)
    {
        return string(abi.encodePacked(
            _svgHeader(tokenId, pos),
            _svgBody(tokenId, pos),
            _svgFooter(pos),
            '</svg>'
        ));
    }

    function _svgHeader(uint256 tokenId, ConvictionPosition memory pos)
        internal
        pure
        returns (string memory)
    {
        // CONFIRM = green (#00ff88), REFUTE = red (#ff4444)
        string memory sideColor = pos.side == 0 ? "#00ff88" : "#ff4444";
        string memory sideLabel = pos.side == 0 ? "CONFIRM" : "REFUTE";

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="500" style="background:#0a0a1a">',
            '<defs>',
            '<linearGradient id="glow" x1="0" y1="0" x2="0" y2="1">',
            '<stop offset="0%" stop-color="', sideColor, '" stop-opacity="0.1"/>',
            '<stop offset="100%" stop-color="#0a0a1a" stop-opacity="0"/>',
            '</linearGradient>',
            '</defs>',
            '<rect width="400" height="500" fill="#0a0a1a" rx="20"/>',
            '<rect width="400" height="150" fill="url(#glow)" rx="20"/>',
            // Golden spiral decorative circles (phi-proportioned radii)
            '<circle cx="200" cy="230" r="100" fill="none" stroke="#c8a000" stroke-width="0.5" opacity="0.2"/>',
            '<circle cx="200" cy="230" r="61.8" fill="none" stroke="#c8a000" stroke-width="0.5" opacity="0.15"/>',
            '<circle cx="200" cy="230" r="38.2" fill="none" stroke="#c8a000" stroke-width="0.5" opacity="0.1"/>',
            // Title
            '<text x="200" y="35" text-anchor="middle" fill="#c8a000" font-family="serif" font-size="14" font-weight="bold">ARTOSPHERE CONVICTION</text>',
            '<text x="200" y="55" text-anchor="middle" fill="#666" font-family="monospace" font-size="10">#', tokenId.toString(), '</text>',
            // Side badge
            '<rect x="140" y="65" width="120" height="24" rx="12" fill="', sideColor, '" opacity="0.2"/>',
            '<text x="200" y="82" text-anchor="middle" fill="', sideColor, '" font-family="monospace" font-size="12" font-weight="bold">', sideLabel, '</text>'
        ));
    }

    function _svgBody(uint256 tokenId, ConvictionPosition memory pos)
        internal
        view
        returns (string memory)
    {
        string memory title = _discoveryTitles[tokenId];
        if (bytes(title).length == 0) title = "Unknown Discovery";

        string memory tierMultiplier = pos.tier == 0 ? "x1.0" : (pos.tier == 1 ? "x1.618" : "x2.618");
        string memory tierLabel = _tierName(pos.tier);

        // Amount in whole ARTS (integer division for display)
        uint256 artsWhole = pos.amount / 1e18;

        return string(abi.encodePacked(
            // Discovery info box
            '<rect x="20" y="100" width="360" height="50" rx="8" fill="#111128"/>',
            '<text x="200" y="120" text-anchor="middle" fill="#888" font-family="monospace" font-size="9">DISCOVERY #', pos.discoveryId.toString(), '</text>',
            '<text x="200" y="138" text-anchor="middle" fill="white" font-family="serif" font-size="11">', _truncate(title, 40), '</text>',
            // Amount display (large, centered, golden)
            '<text x="200" y="210" text-anchor="middle" fill="#c8a000" font-family="monospace" font-size="32" font-weight="bold">', artsWhole.toString(), '</text>',
            '<text x="200" y="230" text-anchor="middle" fill="#888" font-family="monospace" font-size="10">ARTS STAKED</text>',
            // Tier info box
            '<rect x="120" y="250" width="160" height="30" rx="8" fill="#111128"/>',
            '<text x="200" y="270" text-anchor="middle" fill="#4488ff" font-family="monospace" font-size="11">', tierLabel, ' (', tierMultiplier, ')</text>'
        ));
    }

    function _svgFooter(ConvictionPosition memory pos)
        internal
        pure
        returns (string memory)
    {
        // Active position — green status
        string memory statusColor = "#00ff88";
        string memory statusLabel = "ACTIVE";

        return string(abi.encodePacked(
            // Status badge
            '<rect x="150" y="300" width="100" height="22" rx="11" fill="', statusColor, '" opacity="0.15"/>',
            '<text x="200" y="315" text-anchor="middle" fill="', statusColor, '" font-family="monospace" font-size="10">', statusLabel, '</text>',
            // Staked timestamp
            '<text x="200" y="350" text-anchor="middle" fill="#555" font-family="monospace" font-size="9">Staked: ', pos.stakedAt.toString(), '</text>',
            // Phi decorative element
            '<text x="200" y="410" text-anchor="middle" fill="#c8a000" font-family="serif" font-size="28" opacity="0.25">', unicode"\u03C6", '</text>',
            // Footer
            '<text x="200" y="455" text-anchor="middle" fill="#555" font-family="serif" font-size="9">F.B. Sapronov | Cl(9,1) | Artosphere</text>',
            '<text x="200" y="475" text-anchor="middle" fill="#444" font-family="monospace" font-size="8">TRANSFERABLE | ERC-721 | ERC-2981</text>',
            '<text x="200" y="490" text-anchor="middle" fill="#333" font-family="monospace" font-size="7">Royalty: 2.13% (1/', unicode"\u03C6", unicode"\u2078", ') to Scientist</text>'
        ));
    }

    // ========================================================================
    // INTERNAL HELPERS
    // ========================================================================

    /// @notice Human-readable tier name for SVG and metadata
    function _tierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 0) return "Tier 0 (F5=5d)";
        if (tier == 1) return "Tier 1 (F8=21d)";
        return "Tier 2 (F10=55d)";
    }

    /// @notice Truncate a string with "..." suffix if too long
    function _truncate(string memory str, uint256 maxLen) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        if (b.length <= maxLen) return str;
        bytes memory result = new bytes(maxLen);
        for (uint256 i = 0; i < maxLen - 3; i++) {
            result[i] = b[i];
        }
        result[maxLen - 3] = ".";
        result[maxLen - 2] = ".";
        result[maxLen - 1] = ".";
        return string(result);
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
