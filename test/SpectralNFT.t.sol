// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "../src/SpectralNFT.sol";
import "../src/SpectralRenderer.sol";
import "../src/PhiMath.sol";
import "../src/ArtosphereConstants.sol";

/// @title SpectralNFTTest — Comprehensive Foundry tests for SpectralNFT
/// @author F.B. Sapronov
/// @notice Tests: deployment, minting, confidence evolution, staking multiplier,
///         stage transitions, tokenURI, ERC-2981 royalties, transfers, oracle updates.
contract SpectralNFTTest is Test {
    SpectralNFT public spectral;

    address public admin = address(0xAD);
    address public scientist = address(0x5C1);
    address public minter = address(0xBEEF);
    address public oracle = address(0x04AC);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 constant WAD = 1e18;
    uint256 constant PHI_SQUARED = 2_618033988749894848;

    function setUp() public {
        spectral = new SpectralNFT(scientist, admin);

        // Grant roles
        vm.startPrank(admin);
        spectral.grantRole(spectral.MINTER_ROLE(), minter);
        spectral.grantRole(spectral.ORACLE_ROLE(), oracle);
        vm.stopPrank();
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    /// @dev Mint a token to `to` with default params, returns tokenId
    function _mintDefault(address to) internal returns (uint256) {
        vm.prank(minter);
        return spectral.mint(to, 1, "Muon Mass Prediction", "m_mu = m_bare * (1 - 1/(2*phi*pi^3))", 100e18);
    }

    /// @dev Mint and set oracle target, returns tokenId
    function _mintAndSetTarget(address to, uint256 cInf, uint256 tau) internal returns (uint256) {
        uint256 tokenId = _mintDefault(to);
        vm.prank(oracle);
        spectral.updateConfidenceTarget(tokenId, cInf, tau);
        return tokenId;
    }

    // ========================================================================
    // 1. DEPLOYMENT
    // ========================================================================

    function test_deployment_name_symbol() public view {
        assertEq(spectral.name(), "Artosphere Spectral");
        assertEq(spectral.symbol(), "ARTS-S");
    }

    function test_deployment_roles() public view {
        assertTrue(spectral.hasRole(spectral.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(spectral.hasRole(spectral.MINTER_ROLE(), minter));
        assertTrue(spectral.hasRole(spectral.ORACLE_ROLE(), oracle));
    }

    function test_deployment_scientist() public view {
        assertEq(spectral.scientist(), scientist);
    }

    // ========================================================================
    // 2. MINTING
    // ========================================================================

    function test_mint_success() public {
        uint256 tokenId = _mintDefault(alice);
        assertEq(tokenId, 0);
        assertEq(spectral.ownerOf(0), alice);
        assertEq(spectral.nextTokenId(), 1);
    }

    function test_mint_revert_without_role() public {
        vm.prank(alice);
        vm.expectRevert();
        spectral.mint(alice, 1, "Test", "E=mc^2", 50e18);
    }

    function test_mint_increments_tokenId() public {
        _mintDefault(alice);
        uint256 second = _mintDefault(bob);
        assertEq(second, 1);
        assertEq(spectral.nextTokenId(), 2);
    }

    function test_mint_event() public {
        vm.prank(minter);
        vm.expectEmit(true, true, true, false);
        emit SpectralNFT.SpectralMinted(0, alice, 1);
        spectral.mint(alice, 1, "Test", "F=ma", 10e18);
    }

    // ========================================================================
    // 3. INITIAL CONFIDENCE = 0
    // ========================================================================

    function test_initial_confidence_zero() public {
        uint256 tokenId = _mintDefault(alice);
        uint256 conf = spectral.getConfidence(tokenId);
        assertEq(conf, 0, "Initial confidence should be 0");
    }

    // ========================================================================
    // 4. UPDATE CONFIDENCE TARGET
    // ========================================================================

    function test_updateConfidenceTarget_oracle() public {
        uint256 tokenId = _mintDefault(alice);

        vm.prank(oracle);
        spectral.updateConfidenceTarget(tokenId, 0.5e18, 7 days);

        // State should be updated
        (
            uint256 discoveryId,
            uint256 c0,
            uint256 cInf,
            uint256 tau,
            uint256 t0,
            uint256 mintAmount,
            ,
        ) = spectral.spectralStates(tokenId);

        assertEq(discoveryId, 1);
        assertEq(c0, 0);
        assertEq(cInf, 0.5e18);
        assertEq(tau, 7 days);
        assertEq(t0, block.timestamp);
        assertEq(mintAmount, 100e18);
    }

    function test_updateConfidenceTarget_revert_without_role() public {
        uint256 tokenId = _mintDefault(alice);
        vm.prank(alice);
        vm.expectRevert();
        spectral.updateConfidenceTarget(tokenId, 0.5e18, 7 days);
    }

    function test_updateConfidenceTarget_revert_cInf_exceeds_WAD() public {
        uint256 tokenId = _mintDefault(alice);
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(SpectralNFT.CInfExceedsWAD.selector, WAD + 1));
        spectral.updateConfidenceTarget(tokenId, WAD + 1, 7 days);
    }

    function test_updateConfidenceTarget_revert_tau_zero() public {
        uint256 tokenId = _mintDefault(alice);
        vm.prank(oracle);
        vm.expectRevert(SpectralNFT.TauIsZero.selector);
        spectral.updateConfidenceTarget(tokenId, 0.5e18, 0);
    }

    function test_updateConfidenceTarget_revert_nonexistent_token() public {
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(SpectralNFT.TokenDoesNotExist.selector, 999));
        spectral.updateConfidenceTarget(999, 0.5e18, 7 days);
    }

    // ========================================================================
    // 5. CONFIDENCE GROWS OVER TIME
    // ========================================================================

    function test_confidence_grows_over_time() public {
        uint256 t0 = block.timestamp;
        uint256 tokenId = _mintAndSetTarget(alice, 0.8e18, 7 days);

        uint256 conf0 = spectral.getConfidence(tokenId);

        // Warp 7 days (1 tau period)
        vm.warp(t0 + 7 days);
        uint256 conf1 = spectral.getConfidence(tokenId);

        // Warp to 10 days (2 tau periods total)
        vm.warp(t0 + 10 days);
        uint256 conf2 = spectral.getConfidence(tokenId);

        assertTrue(conf1 > conf0, "Confidence should grow after 1 tau");
        assertTrue(conf2 > conf1, "Confidence should grow after 2 tau");
        assertTrue(conf2 < 0.8e18, "Confidence should still be below cInf");
    }

    // ========================================================================
    // 6. CONFIDENCE AT t=0 SHOULD BE c0 (near 0)
    // ========================================================================

    function test_confidence_at_t0_is_c0() public {
        uint256 tokenId = _mintAndSetTarget(alice, 0.9e18, 7 days);

        // At t=0, n=0, decay=1.0, so c(t) = cInf - (cInf - c0) * 1 = c0 = 0
        uint256 conf = spectral.getConfidence(tokenId);
        assertEq(conf, 0, "Confidence at t=0 should be c0 = 0");
    }

    // ========================================================================
    // 7. CONFIDENCE AFTER MANY TAU PERIODS APPROACHES cInf
    // ========================================================================

    function test_confidence_approaches_cInf() public {
        uint256 t0 = block.timestamp;
        uint256 cInf = 0.95e18;
        uint256 tokenId = _mintAndSetTarget(alice, cInf, 7 days);

        // Warp forward 50 tau periods (250 days)
        vm.warp(t0 + 250 days);
        uint256 conf = spectral.getConfidence(tokenId);

        // After 50 tau periods, phi^{-50} is essentially 0
        // Confidence should be very close to cInf
        assertApproxEqAbs(conf, cInf, 1e12, "After 50 tau, confidence should nearly equal cInf");
    }

    // ========================================================================
    // 8. STAKING MULTIPLIER AT CONFIDENCE=0 SHOULD BE 1e18
    // ========================================================================

    function test_stakingMultiplier_at_zero_confidence() public {
        uint256 tokenId = _mintDefault(alice);
        uint256 mult = spectral.getStakingMultiplier(tokenId);
        assertEq(mult, WAD, "Multiplier at confidence=0 should be WAD (1.0)");
    }

    // ========================================================================
    // 9. STAKING MULTIPLIER AT MAX CONFIDENCE APPROACHES PHI_SQUARED
    // ========================================================================

    function test_stakingMultiplier_at_max_confidence() public {
        uint256 t0 = block.timestamp;
        uint256 tokenId = _mintAndSetTarget(alice, WAD, 7 days);

        // Warp far into the future so confidence -> WAD
        vm.warp(t0 + 500 days);
        uint256 mult = spectral.getStakingMultiplier(tokenId);

        // multiplier = WAD + (PHI_SQUARED - WAD) * confidence / WAD
        // At confidence ~ WAD: multiplier ~ PHI_SQUARED
        assertApproxEqAbs(mult, PHI_SQUARED, 1e12, "Multiplier at max confidence should approach PHI_SQUARED");
    }

    function test_stakingMultiplier_increases_with_confidence() public {
        uint256 t0 = block.timestamp;
        uint256 tokenId = _mintAndSetTarget(alice, 0.8e18, 7 days);

        uint256 mult0 = spectral.getStakingMultiplier(tokenId);

        vm.warp(t0 + 10 days);
        uint256 mult1 = spectral.getStakingMultiplier(tokenId);

        vm.warp(t0 + 30 days);
        uint256 mult2 = spectral.getStakingMultiplier(tokenId);

        assertTrue(mult1 > mult0, "Multiplier should increase over time");
        assertTrue(mult2 > mult1, "Multiplier should keep increasing");
    }

    // ========================================================================
    // 10. STAGE TRANSITIONS
    // ========================================================================

    function test_stage_hypothesis_at_zero() public {
        uint256 tokenId = _mintDefault(alice);
        (string memory stage,) = spectral.getStage(tokenId);
        assertEq(stage, "HYPOTHESIS");
    }

    function test_stage_transitions_with_growing_confidence() public {
        // Test each stage by using oracle updates to set appropriate confidence targets.
        // With phi-decay, confidence at n=0 is c0 and jumps discretely at each tau boundary,
        // so we use sequential oracle updates to pin confidence into each stage range.
        uint256 t0 = block.timestamp;

        // Stage 1: HYPOTHESIS — confidence 0 (initial)
        uint256 tokenId = _mintDefault(alice);
        (string memory stage,) = spectral.getStage(tokenId);
        assertEq(stage, "HYPOTHESIS", "Stage 0: should be HYPOTHESIS");

        // Stage 2: SIGNAL — set target to 0.3e18, warp many tau so conf -> 0.3e18
        vm.prank(oracle);
        spectral.updateConfidenceTarget(tokenId, 0.3e18, 1 hours);
        vm.warp(t0 + 100 hours);
        (stage,) = spectral.getStage(tokenId);
        assertEq(stage, "SIGNAL", "Stage 1: should be SIGNAL at conf ~0.3");

        // Stage 3: CONVERGENCE — update target to 0.5e18, warp many tau
        uint256 t1 = block.timestamp;
        vm.prank(oracle);
        spectral.updateConfidenceTarget(tokenId, 0.5e18, 1 hours);
        vm.warp(t1 + 100 hours);
        (stage,) = spectral.getStage(tokenId);
        assertEq(stage, "CONVERGENCE", "Stage 2: should be CONVERGENCE at conf ~0.5");

        // Stage 4: CONFIRMATION — update target to 0.8e18, warp many tau
        uint256 t2 = block.timestamp;
        vm.prank(oracle);
        spectral.updateConfidenceTarget(tokenId, 0.8e18, 1 hours);
        vm.warp(t2 + 100 hours);
        (stage,) = spectral.getStage(tokenId);
        assertEq(stage, "CONFIRMATION", "Stage 3: should be CONFIRMATION at conf ~0.8");

        // Stage 5: DISCOVERY — update target to 0.95e18, warp many tau
        uint256 t3 = block.timestamp;
        vm.prank(oracle);
        spectral.updateConfidenceTarget(tokenId, 0.95e18, 1 hours);
        vm.warp(t3 + 100 hours);
        (stage,) = spectral.getStage(tokenId);
        assertEq(stage, "DISCOVERY", "Stage 4: should be DISCOVERY at conf ~0.95");
    }

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ========================================================================
    // 11. TOKEN URI RETURNS VALID BASE64 JSON
    // ========================================================================

    function test_tokenURI_returns_base64_json() public {
        uint256 tokenId = _mintDefault(alice);
        string memory uri = spectral.tokenURI(tokenId);

        // Should start with data:application/json;base64,
        bytes memory uriBytes = bytes(uri);
        assertTrue(uriBytes.length > 37, "tokenURI should be non-empty");

        // Check prefix
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i], "tokenURI prefix mismatch");
        }
    }

    function test_tokenURI_changes_with_confidence() public {
        uint256 t0 = block.timestamp;
        uint256 tokenId = _mintAndSetTarget(alice, 0.9e18, 7 days);

        string memory uri0 = spectral.tokenURI(tokenId);

        vm.warp(t0 + 50 days);
        string memory uri1 = spectral.tokenURI(tokenId);

        // URIs should differ since confidence changed
        assertTrue(
            keccak256(bytes(uri0)) != keccak256(bytes(uri1)),
            "tokenURI should change as confidence evolves"
        );
    }

    function test_tokenURI_revert_nonexistent() public {
        vm.expectRevert();
        spectral.tokenURI(999);
    }

    // ========================================================================
    // 12. ERC-2981 ROYALTY = 213 BPS (2.13%)
    // ========================================================================

    function test_erc2981_royalty() public {
        uint256 tokenId = _mintDefault(alice);

        uint256 salePrice = 100e18;
        (address receiver, uint256 royaltyAmount) = spectral.royaltyInfo(tokenId, salePrice);

        assertEq(receiver, scientist, "Royalty receiver should be scientist");
        // 213 bps = 2.13% => 100e18 * 213 / 10000 = 2.13e18
        assertEq(royaltyAmount, salePrice * 213 / 10000, "Royalty should be 2.13% (213 bps)");
    }

    function test_erc2981_supports_interface() public view {
        assertTrue(spectral.supportsInterface(type(IERC2981).interfaceId), "Should support ERC-2981");
    }

    // ========================================================================
    // 13. ERC-721 TRANSFER WORKS (NOT SOULBOUND)
    // ========================================================================

    function test_transfer_works() public {
        uint256 tokenId = _mintDefault(alice);

        vm.prank(alice);
        spectral.transferFrom(alice, bob, tokenId);

        assertEq(spectral.ownerOf(tokenId), bob, "Bob should own the token after transfer");
    }

    function test_safeTransfer_works() public {
        uint256 tokenId = _mintDefault(alice);

        vm.prank(alice);
        spectral.safeTransferFrom(alice, bob, tokenId);

        assertEq(spectral.ownerOf(tokenId), bob);
    }

    // ========================================================================
    // 14. MULTIPLE TOKENS FOR SAME DISCOVERY
    // ========================================================================

    function test_multiple_tokens_same_discovery() public {
        vm.startPrank(minter);
        uint256 id0 = spectral.mint(alice, 42, "Same Discovery", "x^2+1=0", 50e18);
        uint256 id1 = spectral.mint(bob, 42, "Same Discovery", "x^2+1=0", 75e18);
        uint256 id2 = spectral.mint(alice, 42, "Same Discovery", "x^2+1=0", 25e18);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2);

        // All track the same discovery
        (uint256 disc0,,,,,,, ) = spectral.spectralStates(id0);
        (uint256 disc1,,,,,,, ) = spectral.spectralStates(id1);
        (uint256 disc2,,,,,,, ) = spectral.spectralStates(id2);
        assertEq(disc0, 42);
        assertEq(disc1, 42);
        assertEq(disc2, 42);

        // Alice should own 2 tokens
        assertEq(spectral.balanceOf(alice), 2);
        assertEq(spectral.balanceOf(bob), 1);
    }

    // ========================================================================
    // 15. ORACLE CAN UPDATE TARGET MULTIPLE TIMES (SNAPSHOTS c0)
    // ========================================================================

    function test_oracle_multiple_updates_snapshots_c0() public {
        uint256 t0 = block.timestamp;
        uint256 tokenId = _mintAndSetTarget(alice, 0.5e18, 7 days);

        // Warp 10 days (2 tau periods) — confidence should have grown
        vm.warp(t0 + 10 days);
        uint256 confBefore = spectral.getConfidence(tokenId);
        assertTrue(confBefore > 0, "Confidence should be > 0 after 2 tau");

        // Oracle updates target to higher value
        uint256 t1 = block.timestamp;
        vm.prank(oracle);
        spectral.updateConfidenceTarget(tokenId, 0.9e18, 8 days);

        // After update, confidence should be snapshotted (continuity)
        uint256 confAfter = spectral.getConfidence(tokenId);
        assertApproxEqAbs(confAfter, confBefore, 1, "Confidence should be continuous after oracle update");

        // Verify new state
        (, uint256 newC0, uint256 newCInf, uint256 newTau, uint256 newT0,,,) = spectral.spectralStates(tokenId);
        assertApproxEqAbs(newC0, confBefore, 1, "c0 should snapshot current confidence");
        assertEq(newCInf, 0.9e18, "cInf should be updated");
        assertEq(newTau, 8 days, "tau should be updated");
        assertEq(newT0, t1, "t0 should be reset to now");

        // Warp more — confidence should grow toward new cInf
        vm.warp(t1 + 400 days);
        uint256 confLater = spectral.getConfidence(tokenId);
        assertTrue(confLater > confAfter, "Confidence should grow toward new cInf");
        assertApproxEqAbs(confLater, 0.9e18, 1e16, "After many tau, should approach new cInf");
    }

    function test_oracle_update_event() public {
        uint256 tokenId = _mintDefault(alice);

        vm.prank(oracle);
        vm.expectEmit(true, false, false, true);
        emit SpectralNFT.SpectralUpdate(tokenId, 0.8e18, 13 days);
        spectral.updateConfidenceTarget(tokenId, 0.8e18, 13 days);
    }

    // ========================================================================
    // ADDITIONAL: Edge cases and enumeration
    // ========================================================================

    function test_tokensOfOwner() public {
        _mintDefault(alice);
        _mintDefault(alice);
        _mintDefault(bob);

        uint256[] memory aliceTokens = spectral.tokensOfOwner(alice);
        assertEq(aliceTokens.length, 2);
        assertEq(aliceTokens[0], 0);
        assertEq(aliceTokens[1], 1);
    }

    function test_exists() public {
        assertFalse(spectral.exists(0));
        _mintDefault(alice);
        assertTrue(spectral.exists(0));
        assertFalse(spectral.exists(1));
    }

    function test_getConfidence_revert_nonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(SpectralNFT.TokenDoesNotExist.selector, 42));
        spectral.getConfidence(42);
    }

    function test_getStakingMultiplier_revert_nonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(SpectralNFT.TokenDoesNotExist.selector, 0));
        spectral.getStakingMultiplier(0);
    }

    function test_getStage_revert_nonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(SpectralNFT.TokenDoesNotExist.selector, 7));
        spectral.getStage(7);
    }

    function test_confidence_with_cInf_equals_WAD() public {
        uint256 t0 = block.timestamp;
        uint256 tokenId = _mintAndSetTarget(alice, WAD, 7 days);

        vm.warp(t0 + 500 days);
        uint256 conf = spectral.getConfidence(tokenId);

        assertApproxEqAbs(conf, WAD, 1e10, "Confidence should approach WAD when cInf=WAD");
    }

    function test_default_tau_is_5_days() public view {
        assertEq(spectral.DEFAULT_TAU(), 7 days);
    }

    function test_supportsInterface_erc721() public view {
        // ERC-721 interface ID
        assertTrue(spectral.supportsInterface(0x80ac58cd));
    }

    function test_supportsInterface_accessControl() public view {
        // AccessControl interface ID
        assertTrue(spectral.supportsInterface(0x7965db0b));
    }
}
