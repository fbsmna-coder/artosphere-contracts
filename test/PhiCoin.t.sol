// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/PhiMath.sol";

/**
 * @title PhiCoinTest
 * @notice Comprehensive test suite for the PhiCoin ERC-20 token with Fibonacci emission.
 */
contract PhiCoinTest is Test {
    PhiCoin public implementation;
    PhiCoin public phiCoin;
    ERC1967Proxy public proxy;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        implementation = new PhiCoin();
        bytes memory initData = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        proxy = new ERC1967Proxy(address(implementation), initData);
        phiCoin = PhiCoin(address(proxy));

        bytes32 minterRole = phiCoin.MINTER_ROLE();
        vm.prank(admin);
        phiCoin.grantRole(minterRole, minter);
    }

    // =========================================================================
    // Deployment & Metadata
    // =========================================================================

    function test_Name() public view {
        assertEq(phiCoin.name(), "PhiCoin");
    }

    function test_Symbol() public view {
        assertEq(phiCoin.symbol(), "PHI");
    }

    function test_Decimals() public view {
        assertEq(phiCoin.decimals(), 18);
    }

    function test_MaxSupply() public view {
        assertEq(phiCoin.MAX_SUPPLY(), 1_618_033_988 * 1e18);
    }

    function test_InitialSupplyIsZero() public view {
        assertEq(phiCoin.totalSupply(), 0);
    }

    function test_GenesisTimestamp() public view {
        assertEq(phiCoin.genesisTimestamp(), block.timestamp);
    }

    function test_AdminHasRole() public view {
        assertTrue(phiCoin.hasRole(phiCoin.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_AdminHasUpgraderRole() public view {
        assertTrue(phiCoin.hasRole(phiCoin.UPGRADER_ROLE(), admin));
    }

    function test_MinterHasRole() public view {
        assertTrue(phiCoin.hasRole(phiCoin.MINTER_ROLE(), minter));
    }

    // =========================================================================
    // Minting with correct role
    // =========================================================================

    function test_MintWithRole() public {
        vm.warp(block.timestamp + 1200); // advance 1 epoch

        vm.prank(minter);
        phiCoin.mint(500);

        assertTrue(phiCoin.totalSupply() > 0, "Supply should increase after mint");
        assertTrue(phiCoin.hasEverMinted(), "hasEverMinted should be true");
    }

    function test_MintTo() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, amount);

        assertEq(phiCoin.balanceOf(alice), amount);
        assertEq(phiCoin.totalSupply(), amount);
    }

    function test_MintToEmitsMintedToEvent() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(minter);
        vm.expectEmit(true, false, false, true);
        emit PhiCoin.MintedTo(alice, amount);
        phiCoin.mintTo(alice, amount);
    }

    function test_MintSameEpochReverts() public {
        vm.warp(block.timestamp + 1200);

        vm.prank(minter);
        phiCoin.mint(500);

        vm.prank(minter);
        vm.expectRevert(PhiCoin.NoEmissionAvailable.selector);
        phiCoin.mint(500);
    }

    function test_MintCapsEpochs() public {
        // Advance many epochs (100 epochs = 120000 seconds)
        vm.warp(block.timestamp + 120000);

        vm.prank(minter);
        phiCoin.mint(5); // Only process 5 epochs

        // lastMintedEpoch should be startEpoch + maxEpochs, not currentEpoch
        assertTrue(phiCoin.lastMintedEpoch() <= 5, "Should only process 5 epochs");

        // Can mint again for remaining epochs
        vm.prank(minter);
        phiCoin.mint(500);
    }

    // =========================================================================
    // Minting fails without role
    // =========================================================================

    function test_MintWithoutRoleReverts() public {
        vm.warp(block.timestamp + 1200);

        vm.prank(alice);
        vm.expectRevert();
        phiCoin.mint(500);
    }

    function test_MintToWithoutRoleReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        phiCoin.mintTo(bob, 100 * 1e18);
    }

    // =========================================================================
    // Emission decreases each epoch
    // =========================================================================

    function test_EmissionEpoch1GreaterThanEpoch0() public view {
        uint256 e0 = phiCoin.emissionForEpoch(0);
        uint256 e1 = phiCoin.emissionForEpoch(1);

        assertEq(e0, 0, "Epoch 0 emission should be 0 (F(0)=0)");
        assertTrue(e1 > 0, "Epoch 1 emission should be > 0");
    }

    function test_EmissionDecayAcrossCycles() public view {
        uint256 e5 = phiCoin.emissionForEpoch(5);
        uint256 e105 = phiCoin.emissionForEpoch(105);

        assertTrue(e105 < e5, "Emission at epoch 105 should be less than epoch 5 due to decay");
    }

    function test_EmissionDecayThirdCycle() public view {
        uint256 e105 = phiCoin.emissionForEpoch(105);
        uint256 e205 = phiCoin.emissionForEpoch(205);

        assertTrue(e205 < e105, "Epoch 205 emission should be less than epoch 105");
    }

    function test_EmissionFibonacciGrowthWithinCycle() public view {
        uint256 e5 = phiCoin.emissionForEpoch(5);
        uint256 e10 = phiCoin.emissionForEpoch(10);

        assertTrue(e10 > e5, "F(10) > F(5) so emission at epoch 10 > epoch 5");
    }

    // =========================================================================
    // Total supply never exceeds cap
    // =========================================================================

    function test_MintToExceedsCapReverts() public {
        vm.startPrank(minter);
        phiCoin.mintTo(alice, phiCoin.MAX_SUPPLY() - 100);

        vm.expectRevert(
            abi.encodeWithSelector(PhiCoin.ExceedsMaxSupply.selector, 200, 100)
        );
        phiCoin.mintTo(bob, 200);
        vm.stopPrank();
    }

    function test_MintToExactCap() public {
        uint256 maxSupply = phiCoin.MAX_SUPPLY();
        vm.prank(minter);
        phiCoin.mintTo(alice, maxSupply);

        assertEq(phiCoin.totalSupply(), phiCoin.MAX_SUPPLY());
        assertEq(phiCoin.remainingSupply(), 0);

        vm.prank(minter);
        vm.expectRevert();
        phiCoin.mintTo(bob, 1);
    }

    function test_RemainingSupply() public {
        uint256 amount = 1_000_000 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, amount);

        assertEq(phiCoin.remainingSupply(), phiCoin.MAX_SUPPLY() - amount);
    }

    // =========================================================================
    // Burn
    // =========================================================================

    function test_Burn() public {
        uint256 mintAmount = 1000 * 1e18;
        uint256 burnAmount = 400 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, mintAmount);

        vm.prank(alice);
        phiCoin.burn(burnAmount);

        assertEq(phiCoin.balanceOf(alice), mintAmount - burnAmount);
        assertEq(phiCoin.totalSupply(), mintAmount - burnAmount);
    }

    function test_BurnExceedsBalanceReverts() public {
        uint256 mintAmount = 100 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, mintAmount);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PhiCoin.InsufficientBalance.selector, mintAmount + 1, mintAmount)
        );
        phiCoin.burn(mintAmount + 1);
    }

    function test_BurnZeroBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PhiCoin.InsufficientBalance.selector, 1, 0)
        );
        phiCoin.burn(1);
    }

    function test_BurnEmitsEvent() public {
        uint256 amount = 500 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, amount);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PhiCoin.TokensBurned(alice, amount);
        phiCoin.burn(amount);
    }

    function test_BurnIncreasesRemainingSupply() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, amount);

        uint256 remainingBefore = phiCoin.remainingSupply();

        vm.prank(alice);
        phiCoin.burn(amount);

        uint256 remainingAfter = phiCoin.remainingSupply();
        assertEq(remainingAfter, remainingBefore + amount);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_EmissionEpochZero() public view {
        assertEq(phiCoin.emissionForEpoch(0), 0);
    }

    function test_CurrentEpochStartsAtZero() public view {
        assertEq(phiCoin.currentEpoch(), 0);
    }

    function test_CurrentEpochAdvances() public {
        vm.warp(block.timestamp + 1200);
        assertEq(phiCoin.currentEpoch(), 1);

        vm.warp(block.timestamp + 1200);
        assertEq(phiCoin.currentEpoch(), 2);
    }
}
