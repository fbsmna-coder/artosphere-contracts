// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/FibonacciFusion.sol";
import "../src/PhiCoin.sol";
import "../src/ArtosphereConstants.sol";

/// @title FibonacciFusionTest — Foundry tests for FibonacciFusion (τ⊗τ = 1⊕τ)
/// @author F.B. Sapronov
contract FibonacciFusionTest is Test {
    FibonacciFusion public fusion;

    PhiCoin public phiCoinImpl;
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant FUSE_AMOUNT = 1_000 * 1e18;

    function setUp() public {
        // Deploy PhiCoin (UUPS proxy)
        phiCoinImpl = new PhiCoin();
        bytes memory coinInit = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        coinProxy = new ERC1967Proxy(address(phiCoinImpl), coinInit);
        phiCoin = PhiCoin(address(coinProxy));

        // Deploy FibonacciFusion
        fusion = new FibonacciFusion(address(phiCoin), admin);

        // Fund users
        vm.startPrank(admin);
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        phiCoin.mintTo(alice, 1_000_000 * 1e18);
        phiCoin.mintTo(bob, 1_000_000 * 1e18);
        // Fund the fusion contract so it can return tokens on survival
        phiCoin.mintTo(address(fusion), 100_000 * 1e18);
        vm.stopPrank();

        // Approve fusion contract
        vm.prank(alice);
        phiCoin.approve(address(fusion), type(uint256).max);
        vm.prank(bob);
        phiCoin.approve(address(fusion), type(uint256).max);
    }

    // ========================================================================
    // 1. test_FuseExecutes — fuse completes and updates stats
    // ========================================================================

    function test_FuseExecutes() public {
        vm.prank(alice);
        (uint256 burned, uint256 survived) = fusion.fuse(FUSE_AMOUNT);

        // One of the two must be the full amount
        assertTrue(
            (burned == FUSE_AMOUNT && survived == 0) ||
            (burned == 0 && survived == FUSE_AMOUNT),
            "Invalid fusion outcome"
        );

        (uint256 burns, uint256 fusions,) = fusion.stats();
        assertEq(fusions, 1, "Should record 1 fusion");
        assertEq(burns, burned, "Burns should match");
    }

    // ========================================================================
    // 2. test_FuseZeroAmount_Reverts
    // ========================================================================

    function test_FuseZeroAmount_Reverts() public {
        vm.expectRevert(FibonacciFusion.ZeroAmount.selector);
        vm.prank(alice);
        fusion.fuse(0);
    }

    // ========================================================================
    // 3. test_FuseBelowMinimum_Reverts
    // ========================================================================

    function test_FuseBelowMinimum_Reverts() public {
        uint256 belowMin = 50 * 1e18; // default min is 100 ARTS
        vm.expectRevert(
            abi.encodeWithSelector(FibonacciFusion.AmountBelowMinimum.selector, belowMin, 100 * 1e18)
        );
        vm.prank(alice);
        fusion.fuse(belowMin);
    }

    // ========================================================================
    // 4. test_Cooldown_Reverts — second fuse within cooldown reverts
    // ========================================================================

    function test_Cooldown_Reverts() public {
        vm.prank(alice);
        fusion.fuse(FUSE_AMOUNT);

        // Try again immediately — should revert with CooldownActive
        vm.expectRevert();
        vm.prank(alice);
        fusion.fuse(FUSE_AMOUNT);
    }

    // ========================================================================
    // 5. test_CooldownExpires — fuse works after cooldown passes
    // ========================================================================

    function test_CooldownExpires() public {
        vm.prank(alice);
        fusion.fuse(FUSE_AMOUNT);

        // Warp past cooldown (1200 seconds)
        vm.warp(block.timestamp + 1201);

        vm.prank(alice);
        (uint256 burned, uint256 survived) = fusion.fuse(FUSE_AMOUNT);

        assertTrue(burned > 0 || survived > 0, "Second fuse should work");

        (, uint256 fusions,) = fusion.stats();
        assertEq(fusions, 2, "Should record 2 fusions");
    }

    // ========================================================================
    // 6. test_SetMinFusionAmount — operator can change minimum
    // ========================================================================

    function test_SetMinFusionAmount() public {
        vm.prank(admin);
        fusion.setMinFusionAmount(500 * 1e18);

        assertEq(fusion.minFusionAmount(), 500 * 1e18);

        // Now 200 ARTS should fail (below new minimum)
        vm.expectRevert();
        vm.prank(alice);
        fusion.fuse(200 * 1e18);
    }

    // ========================================================================
    // 7. test_RescueTokens — admin can rescue stuck tokens
    // ========================================================================

    function test_RescueTokens() public {
        // Send some tokens directly to fusion contract (simulating stuck tokens)
        vm.prank(alice);
        phiCoin.transfer(address(fusion), 5_000 * 1e18);

        uint256 bobBefore = phiCoin.balanceOf(bob);

        vm.prank(admin);
        fusion.rescueTokens(address(phiCoin), bob, 5_000 * 1e18);

        assertEq(phiCoin.balanceOf(bob) - bobBefore, 5_000 * 1e18, "Bob should receive rescued tokens");
    }

    // ========================================================================
    // 8. test_RescueTokens_UnauthorizedReverts
    // ========================================================================

    function test_RescueTokens_UnauthorizedReverts() public {
        vm.expectRevert();
        vm.prank(alice);
        fusion.rescueTokens(address(phiCoin), alice, 1_000 * 1e18);
    }
}
