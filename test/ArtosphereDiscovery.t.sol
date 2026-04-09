// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ArtosphereDiscovery.sol";

/// @title ArtosphereDiscoveryTest — Foundry tests for ArtosphereDiscovery (Soulbound NFTs)
/// @author F.B. Sapronov
contract ArtosphereDiscoveryTest is Test {
    ArtosphereDiscovery public discovery;

    address public scientist = makeAddr("scientist");
    address public oracle = makeAddr("oracle");
    address public alice = makeAddr("alice");

    bytes32 public constant CONTENT_HASH = keccak256("alpha_s = 1/(2*phi^3)");

    function setUp() public {
        discovery = new ArtosphereDiscovery(scientist);

        // Grant oracle role — use startPrank to avoid prank being consumed by view call
        vm.startPrank(scientist);
        discovery.grantRole(discovery.ORACLE_ROLE(), oracle);
        vm.stopPrank();
    }

    // ========================================================================
    // 1. test_RegisterDiscovery — scientist can register a discovery
    // ========================================================================

    function test_RegisterDiscovery() public {
        vm.prank(scientist);
        uint256 tokenId = discovery.registerDiscovery(
            "Strong Coupling from Phi",
            "alpha_s = 1/(2*phi^3)",
            "10.5281/zenodo.19464050",
            "D", "PREDICTED",
            CONTENT_HASH, 2
        );

        assertEq(tokenId, 0);
        assertEq(discovery.totalDiscoveries(), 1);
        assertEq(discovery.ownerOf(tokenId), scientist);

        (string memory title,,string memory doi,,string memory status,,,uint256 accuracy) =
            discovery.discoveries(tokenId);
        assertEq(title, "Strong Coupling from Phi");
        assertEq(doi, "10.5281/zenodo.19464050");
        assertEq(status, "PREDICTED");
        assertEq(accuracy, 2);
    }

    // ========================================================================
    // 2. test_RegisterDiscovery_UnauthorizedReverts
    // ========================================================================

    function test_RegisterDiscovery_UnauthorizedReverts() public {
        vm.expectRevert();
        vm.prank(alice);
        discovery.registerDiscovery(
            "Fake", "x=1", "doi", "D", "OPEN",
            keccak256("fake"), 0
        );
    }

    // ========================================================================
    // 3. test_UpdateStatus — admin and oracle can update status
    // ========================================================================

    function test_UpdateStatus() public {
        vm.prank(scientist);
        discovery.registerDiscovery(
            "Test Discovery", "f=phi", "doi:test",
            "D", "PREDICTED", CONTENT_HASH, 5
        );

        // Oracle updates status
        vm.prank(oracle);
        discovery.updateStatus(0, "CONFIRMED");

        (,,,, string memory status,,,) = discovery.discoveries(0);
        assertEq(status, "CONFIRMED");

        // Scientist (admin) can also update
        vm.prank(scientist);
        discovery.updateStatus(0, "PROVEN");

        (,,,, string memory status2,,,) = discovery.discoveries(0);
        assertEq(status2, "PROVEN");
    }

    // ========================================================================
    // 4. test_UpdateStatus_UnauthorizedReverts
    // ========================================================================

    function test_UpdateStatus_UnauthorizedReverts() public {
        vm.prank(scientist);
        discovery.registerDiscovery(
            "Test", "f=1", "doi", "D", "OPEN",
            CONTENT_HASH, 0
        );

        vm.expectRevert();
        vm.prank(alice);
        discovery.updateStatus(0, "HACKED");
    }

    // ========================================================================
    // 5. test_Soulbound_TransferReverts — transfers are blocked
    // ========================================================================

    function test_Soulbound_TransferReverts() public {
        vm.prank(scientist);
        discovery.registerDiscovery(
            "Soulbound Test", "f=phi", "doi:sb",
            "D", "PREDICTED", CONTENT_HASH, 1
        );

        vm.expectRevert(ArtosphereDiscovery.Soulbound.selector);
        vm.prank(scientist);
        discovery.transferFrom(scientist, alice, 0);
    }

    // ========================================================================
    // 6. test_TokenURI — returns valid base64 JSON metadata
    // ========================================================================

    function test_TokenURI() public {
        vm.prank(scientist);
        discovery.registerDiscovery(
            "Higgs Mass", "M_H = v*sqrt(2*lambda)",
            "10.5281/zenodo.19480973",
            "D", "CONFIRMED", CONTENT_HASH, 1
        );

        string memory uri = discovery.tokenURI(0);
        bytes memory uriBytes = bytes(uri);

        // Must start with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        assertGt(uriBytes.length, prefix.length, "URI too short");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uint8(uriBytes[i]), uint8(prefix[i]), "URI prefix mismatch");
        }
    }

    // ========================================================================
    // 7. test_VerifyContent — content hash verification
    // ========================================================================

    function test_VerifyContent() public {
        vm.prank(scientist);
        discovery.registerDiscovery(
            "Hash Test", "f=1", "doi:hash",
            "D", "OPEN",
            keccak256("secret content"), 0
        );

        assertTrue(discovery.verifyContent(0, "secret content"));
        assertFalse(discovery.verifyContent(0, "wrong content"));
    }
}
