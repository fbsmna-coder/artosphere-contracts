// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./PhiMath.sol";

/// @title PhiCertificate — Soulbound NFT Certificates
/// @notice Non-transferable achievement certificates generated from φ-Hash-inspired math
/// @dev Minted by authorized contracts (quest, staking, governance, LP) to track contributions
contract PhiCertificate is ERC721, Ownable {
    uint256 private _nextTokenId;

    struct Certificate {
        address recipient;
        uint256 actionType;    // 0=quest, 1=stake, 2=vote, 3=LP
        uint256 actionValue;   // amount/duration involved
        uint256 timestamp;
        uint256 phiHash;       // on-chain phi-inspired hash
        uint256 fibonacciRank; // nearest Fibonacci rank of cumulative contributions
    }

    mapping(uint256 => Certificate) public certificates;
    mapping(address => uint256) public contributionCount;
    mapping(address => uint256[]) public userCertificates;

    /// @notice Authorized minters (quest contract, staking contract, etc.)
    mapping(address => bool) public authorizedMinters;

    event CertificateMinted(address indexed to, uint256 indexed tokenId, uint256 actionType, uint256 phiHash);

    constructor() ERC721("Artosphere Certificate", "ARTS-CERT") Ownable(msg.sender) {}

    /// @notice Set or revoke an authorized minter
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        authorizedMinters[minter] = authorized;
    }

    /// @notice Mint a soulbound certificate to a user
    /// @param to The recipient address
    /// @param actionType The type of action (0=quest, 1=stake, 2=vote, 3=LP)
    /// @param actionValue The value/amount involved in the action
    /// @return tokenId The newly minted token ID
    function mintCertificate(
        address to,
        uint256 actionType,
        uint256 actionValue
    ) external returns (uint256) {
        require(authorizedMinters[msg.sender], "Not authorized");

        uint256 tokenId = _nextTokenId++;
        contributionCount[to]++;

        // Generate phi-inspired hash from action data
        uint256 phiHash = _generatePhiHash(to, actionType, actionValue, block.timestamp);
        uint256 fibRank = _nearestFibonacciRank(contributionCount[to]);

        certificates[tokenId] = Certificate({
            recipient: to,
            actionType: actionType,
            actionValue: actionValue,
            timestamp: block.timestamp,
            phiHash: phiHash,
            fibonacciRank: fibRank
        });

        userCertificates[to].push(tokenId);
        _safeMint(to, tokenId);

        emit CertificateMinted(to, tokenId, actionType, phiHash);
        return tokenId;
    }

    /// @notice Soulbound: prevent transfers (except mint and burn)
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        require(from == address(0) || to == address(0), "Soulbound: non-transferable");
        return super._update(to, tokenId, auth);
    }

    /// @notice Get the number of certificates a user holds
    function getUserCertificateCount(address user) external view returns (uint256) {
        return userCertificates[user].length;
    }

    /// @notice Generate a phi-inspired hash on-chain
    /// @dev Mixes keccak256 of inputs with golden ratio constants
    function _generatePhiHash(
        address user,
        uint256 actionType,
        uint256 value,
        uint256 ts
    ) internal pure returns (uint256) {
        // Mix inputs with keccak256
        uint256 hash = uint256(keccak256(abi.encodePacked(user, actionType, value, ts)));
        // Reduce to WAD range and apply golden ratio mixing
        uint256 reduced = hash % PhiMath.WAD;
        uint256 phiMixed = PhiMath.wadMul(reduced, PhiMath.PHI);
        // XOR with a Fibonacci number (use reduced modulo to pick a safe index 1-40)
        uint256 fibIndex = (reduced % 40) + 1; // 1-40, avoids 0 which returns 0
        uint256 fibVal = PhiMath.fibonacci(fibIndex);
        return phiMixed ^ fibVal;
    }

    /// @notice Find nearest Fibonacci number rank for a given count
    /// @dev Returns the index k such that F(k) is the smallest Fibonacci number >= n
    function _nearestFibonacciRank(uint256 n) internal pure returns (uint256) {
        if (n == 0) return 0;
        uint256 a = 0;
        uint256 b = 1;
        uint256 rank = 1;
        while (b < n) {
            uint256 temp = a + b;
            a = b;
            b = temp;
            rank++;
            if (rank > 93) break;
        }
        return rank;
    }
}
