// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

/// @title ArtosphereDiscovery — Soulbound Scientific Priority NFTs
/// @author F.B. Sapronov
/// @notice On-chain proof of scientific priority for the Artosphere framework.
///         Each NFT is SOULBOUND (non-transferable) and contains:
///         - The discovery title and formula
///         - The Zenodo DOI (CERN-archived)
///         - The keccak256 hash of the discovery content
///         - An immutable blockchain timestamp
///         This creates a legally verifiable, independent proof of priority
///         that exists on-chain even if Zenodo goes down.
/// @dev Implements ERC-5192 (Soulbound) by overriding transfer functions.
///      All metadata is stored fully on-chain (no IPFS dependency).
///      Uses AccessControl for multi-role permission (owner + oracle).
contract ArtosphereDiscovery is ERC721, ERC721URIStorage, AccessControl {
    using Strings for uint256;

    // ========================================================================
    // ROLES
    // ========================================================================

    /// @notice Admin role — can register discoveries and manage roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Oracle role — can update discovery status on resolution
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ========================================================================
    // STRUCTS
    // ========================================================================

    struct Discovery {
        string title;           // Discovery name
        string formula;         // Key formula (LaTeX-compatible)
        string doi;             // Zenodo DOI
        string category;        // "D" = Derived, "S" = Semi-derived, "P" = Prediction
        string status;          // "PROVEN" | "CONFIRMED" | "PREDICTED" | "OPEN" | "REFUTED"
        uint256 timestamp;      // Block timestamp at mint
        bytes32 contentHash;    // keccak256 of the full discovery text
        uint256 accuracy;       // Deviation in basis points (100 = 1%)
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice All discoveries indexed by token ID
    mapping(uint256 => Discovery) public discoveries;

    /// @notice Total discoveries minted
    uint256 public totalDiscoveries;

    /// @notice The scientist's address (soulbound target)
    address public immutable scientist;

    /// @notice Locked flag for ERC-5192 compliance
    bool public constant LOCKED = true;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice ERC-5192: Emitted when a token is locked (soulbound)
    event Locked(uint256 indexed tokenId);

    /// @notice Emitted when a new discovery is registered on-chain
    event DiscoveryRegistered(
        uint256 indexed tokenId,
        string title,
        string doi,
        bytes32 contentHash,
        uint256 timestamp
    );

    /// @notice Emitted when a discovery status is updated (e.g., PREDICTED -> CONFIRMED)
    event StatusUpdated(uint256 indexed tokenId, string oldStatus, string newStatus);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error Soulbound();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    constructor(address _scientist)
        ERC721("Artosphere Discovery", "ARTD")
    {
        scientist = _scientist;

        // Scientist gets admin role (can register discoveries, manage roles)
        _grantRole(DEFAULT_ADMIN_ROLE, _scientist);
        _grantRole(ADMIN_ROLE, _scientist);
    }

    // ========================================================================
    // SOULBOUND: Override transfers to prevent any movement
    // ========================================================================

    /// @dev All transfers are blocked. These are soulbound tokens.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        // Allow minting (from == address(0)) but block all transfers
        if (from != address(0) && to != address(0)) {
            revert Soulbound();
        }
        return super._update(to, tokenId, auth);
    }

    /// @notice ERC-5192: Check if token is locked (always true for soulbound)
    function locked(uint256) external pure returns (bool) {
        return true;
    }

    // ========================================================================
    // CORE: Register a discovery on-chain
    // ========================================================================

    /// @notice Register a new scientific discovery as a soulbound NFT
    function registerDiscovery(
        string calldata title,
        string calldata formula,
        string calldata doi,
        string calldata category,
        string calldata status,
        bytes32 contentHash,
        uint256 accuracy
    ) external onlyRole(ADMIN_ROLE) returns (uint256 tokenId) {
        tokenId = totalDiscoveries;
        totalDiscoveries++;

        discoveries[tokenId] = Discovery({
            title: title,
            formula: formula,
            doi: doi,
            category: category,
            status: status,
            timestamp: block.timestamp,
            contentHash: contentHash,
            accuracy: accuracy
        });

        _safeMint(scientist, tokenId);
        emit Locked(tokenId);
        emit DiscoveryRegistered(tokenId, title, doi, contentHash, block.timestamp);
    }

    /// @notice Update the status of a discovery (admin or oracle)
    /// @dev Oracle calls this on resolution (CONFIRMED/REFUTED)
    function updateStatus(uint256 tokenId, string calldata newStatus) external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(ORACLE_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, ORACLE_ROLE);
        }
        string memory oldStatus = discoveries[tokenId].status;
        discoveries[tokenId].status = newStatus;
        emit StatusUpdated(tokenId, oldStatus, newStatus);
    }

    /// @notice Update accuracy when new experimental data arrives
    function updateAccuracy(uint256 tokenId, uint256 newAccuracy) external onlyRole(ADMIN_ROLE) {
        discoveries[tokenId].accuracy = newAccuracy;
    }

    // ========================================================================
    // METADATA: Fully on-chain SVG + JSON
    // ========================================================================

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        _requireOwned(tokenId);
        Discovery memory d = discoveries[tokenId];

        // Generate SVG
        string memory svg = _generateSVG(tokenId, d);

        // Build JSON metadata
        string memory json = string(abi.encodePacked(
            '{"name":"Artosphere Discovery #', tokenId.toString(),
            '","description":"', d.title,
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","attributes":[',
            '{"trait_type":"Formula","value":"', d.formula, '"},',
            '{"trait_type":"DOI","value":"', d.doi, '"},',
            '{"trait_type":"Category","value":"', d.category, '"},',
            '{"trait_type":"Status","value":"', d.status, '"},',
            '{"trait_type":"Accuracy (bps)","value":', d.accuracy.toString(), '},',
            '{"trait_type":"Timestamp","value":', d.timestamp.toString(), '},',
            '{"trait_type":"Content Hash","value":"', _bytes32ToHex(d.contentHash), '"},',
            '{"trait_type":"Soulbound","value":"true"}',
            ']}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    function _generateSVG(uint256 tokenId, Discovery memory d)
        internal
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(
            _svgHeader(tokenId, d.status),
            _svgBody(d),
            '</svg>'
        ));
    }

    function _svgHeader(uint256 tokenId, string memory status)
        internal
        pure
        returns (string memory)
    {
        string memory color = "#888888";
        if (keccak256(bytes(status)) == keccak256("CONFIRMED")) color = "#00ff88";
        else if (keccak256(bytes(status)) == keccak256("PROVEN")) color = "#4488ff";
        else if (keccak256(bytes(status)) == keccak256("PREDICTED")) color = "#ffaa00";
        else if (keccak256(bytes(status)) == keccak256("REFUTED")) color = "#ff4444";

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="500" style="background:#0a0a1a">',
            '<rect width="400" height="500" fill="#0a0a1a" rx="20"/>',
            '<circle cx="200" cy="200" r="80" fill="none" stroke="#c8a000" stroke-width="0.5" opacity="0.3"/>',
            '<text x="200" y="40" text-anchor="middle" fill="#c8a000" font-family="serif" font-size="14" font-weight="bold">ARTOSPHERE DISCOVERY</text>',
            '<text x="200" y="60" text-anchor="middle" fill="#666" font-family="monospace" font-size="10">#', tokenId.toString(), '</text>',
            '<rect x="140" y="70" width="120" height="24" rx="12" fill="', color, '" opacity="0.2"/>',
            '<text x="200" y="87" text-anchor="middle" fill="', color, '" font-family="monospace" font-size="12">', status, '</text>'
        ));
    }

    function _svgBody(Discovery memory d)
        internal
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(
            '<text x="200" y="130" text-anchor="middle" fill="white" font-family="serif" font-size="11">', _truncate(d.title, 45), '</text>',
            '<rect x="20" y="150" width="360" height="60" rx="8" fill="#111128"/>',
            '<text x="200" y="185" text-anchor="middle" fill="#c8a000" font-family="monospace" font-size="12">', _truncate(d.formula, 40), '</text>',
            '<text x="200" y="240" text-anchor="middle" fill="#4488ff" font-family="monospace" font-size="9">DOI: ', d.doi, '</text>',
            '<text x="200" y="270" text-anchor="middle" fill="#888" font-family="monospace" font-size="10">Category: ', d.category, ' | Accuracy: ', d.accuracy.toString(), ' bps</text>',
            '<text x="200" y="465" text-anchor="middle" fill="#555" font-family="serif" font-size="9">F.B. Sapronov | Cl(9,1) | April 2026</text>',
            '<text x="200" y="485" text-anchor="middle" fill="#333" font-family="monospace" font-size="8">SOULBOUND | NON-TRANSFERABLE</text>'
        ));
    }

    function _truncate(string memory str, uint256 maxLen) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        if (b.length <= maxLen) return str;
        bytes memory result = new bytes(maxLen);
        for (uint i = 0; i < maxLen - 3; i++) {
            result[i] = b[i];
        }
        result[maxLen-3] = ".";
        result[maxLen-2] = ".";
        result[maxLen-1] = ".";
        return string(result);
    }

    function _bytes32ToHex(bytes32 data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint i = 0; i < 32; i++) {
            str[2+i*2] = alphabet[uint(uint8(data[i] >> 4))];
            str[3+i*2] = alphabet[uint(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }

    // ========================================================================
    // VIEW HELPERS
    // ========================================================================

    /// @notice Get all discovery data for a token
    function getDiscovery(uint256 tokenId) external view returns (Discovery memory) {
        return discoveries[tokenId];
    }

    /// @notice Verify a content hash matches a discovery
    function verifyContent(uint256 tokenId, string calldata content) external view returns (bool) {
        return keccak256(bytes(content)) == discoveries[tokenId].contentHash;
    }

    /// @notice Check if the contract supports ERC-5192 (soulbound) and AccessControl
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, AccessControl)
        returns (bool)
    {
        // ERC-5192 interface ID
        return interfaceId == 0xb45a3c0e || super.supportsInterface(interfaceId);
    }
}
