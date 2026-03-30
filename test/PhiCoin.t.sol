// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/PhiMath.sol";

/**
 * @title PhiCoinTest
 * @notice Comprehensive test suite for the PhiCoin ERC-20 token with Fibonacci emission.
 * @dev Tests cover deployment, metadata, role-based minting, emission decay,
 *      supply cap enforcement, and token burning.
 */
contract PhiCoinTest is Test {
    PhiCoin public implementation;
    PhiCoin public phiCoin;
    ERC1967Proxy public proxy;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /// @notice Deploys the PhiCoin implementation behind a UUPS proxy and grants roles.
    function setUp() public {
        // Deploy implementation
        implementation = new PhiCoin();

        // Deploy proxy pointing to implementation, calling initialize(admin)
        bytes memory initData = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        proxy = new ERC1967Proxy(address(implementation), initData);

        // Wrap proxy as PhiCoin
        phiCoin = PhiCoin(address(proxy));

        // Admin grants MINTER_ROLE to the minter address
        bytes32 minterRole = phiCoin.MINTER_ROLE();
        vm.prank(admin);
        phiCoin.grantRole(minterRole, minter);
    }

    // =========================================================================
    // Deployment & Metadata
    // =========================================================================

    /// @notice Verifies the token name is "PhiCoin".
    function test_Name() public view {
        assertEq(phiCoin.name(), "PhiCoin");
    }

    /// @notice Verifies the token symbol is "PHI".
    function test_Symbol() public view {
        assertEq(phiCoin.symbol(), "PHI");
    }

    /// @notice Verifies the token uses 18 decimals.
    function test_Decimals() public view {
        assertEq(phiCoin.decimals(), 18);
    }

    /// @notice Verifies the hard supply cap equals phi * 10^9 tokens.
    function test_MaxSupply() public view {
        assertEq(phiCoin.MAX_SUPPLY(), 1_618_033_988 * 1e18);
    }

    /// @notice Verifies initial total supply is zero (no pre-mine).
    function test_InitialSupplyIsZero() public view {
        assertEq(phiCoin.totalSupply(), 0);
    }

    /// @notice Verifies the genesis block is set to the deployment block.
    function test_GenesisBlock() public view {
        assertEq(phiCoin.genesisBlock(), block.number);
    }

    /// @notice Verifies the admin has DEFAULT_ADMIN_ROLE.
    function test_AdminHasRole() public view {
        assertTrue(phiCoin.hasRole(phiCoin.DEFAULT_ADMIN_ROLE(), admin));
    }

    /// @notice Verifies the admin has UPGRADER_ROLE.
    function test_AdminHasUpgraderRole() public view {
        assertTrue(phiCoin.hasRole(phiCoin.UPGRADER_ROLE(), admin));
    }

    /// @notice Verifies the minter has MINTER_ROLE.
    function test_MinterHasRole() public view {
        assertTrue(phiCoin.hasRole(phiCoin.MINTER_ROLE(), minter));
    }

    // =========================================================================
    // Minting with correct role
    // =========================================================================

    /// @notice MINTER_ROLE can mint epoch emissions successfully.
    function test_MintWithRole() public {
        // Advance past epoch 0 so there is emission to claim
        vm.roll(block.number + 100);

        vm.prank(minter);
        phiCoin.mint();

        assertTrue(phiCoin.totalSupply() > 0, "Supply should increase after mint");
        assertTrue(phiCoin.hasEverMinted(), "hasEverMinted should be true");
    }

    /// @notice mintTo correctly mints a specific amount to a recipient.
    function test_MintTo() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, amount);

        assertEq(phiCoin.balanceOf(alice), amount);
        assertEq(phiCoin.totalSupply(), amount);
    }

    /// @notice Minting for the same epoch twice reverts with NoEmissionAvailable.
    function test_MintSameEpochReverts() public {
        vm.roll(block.number + 100);

        vm.prank(minter);
        phiCoin.mint();

        vm.prank(minter);
        vm.expectRevert(PhiCoin.NoEmissionAvailable.selector);
        phiCoin.mint();
    }

    // =========================================================================
    // Minting fails without role
    // =========================================================================

    /// @notice Calling mint() without MINTER_ROLE reverts.
    function test_MintWithoutRoleReverts() public {
        vm.roll(block.number + 100);

        vm.prank(alice);
        vm.expectRevert();
        phiCoin.mint();
    }

    /// @notice Calling mintTo() without MINTER_ROLE reverts.
    function test_MintToWithoutRoleReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        phiCoin.mintTo(bob, 100 * 1e18);
    }

    // =========================================================================
    // Emission decreases each epoch
    // =========================================================================

    /// @notice Emission for epoch 1 is greater than epoch 0 (F(0)=0, F(1)=1).
    function test_EmissionEpoch1GreaterThanEpoch0() public view {
        uint256 e0 = phiCoin.emissionForEpoch(0);
        uint256 e1 = phiCoin.emissionForEpoch(1);

        // F(0) = 0, F(1) = 1 * WAD, so e0 = 0, e1 > 0
        assertEq(e0, 0, "Epoch 0 emission should be 0 (F(0)=0)");
        assertTrue(e1 > 0, "Epoch 1 emission should be > 0");
    }

    /// @notice Emissions in the second cycle (epochs 100+) are smaller than first cycle.
    /// @dev Due to the phi^{-(epoch/100)} decay factor.
    function test_EmissionDecayAcrossCycles() public view {
        // Compare emission at epoch 5 vs epoch 105 (same Fibonacci index, different decay)
        uint256 e5 = phiCoin.emissionForEpoch(5);
        uint256 e105 = phiCoin.emissionForEpoch(105);

        assertTrue(e105 < e5, "Emission at epoch 105 should be less than epoch 5 due to decay");
    }

    /// @notice Emission at epoch 205 is even smaller than epoch 105.
    function test_EmissionDecayThirdCycle() public view {
        uint256 e105 = phiCoin.emissionForEpoch(105);
        uint256 e205 = phiCoin.emissionForEpoch(205);

        assertTrue(e205 < e105, "Epoch 205 emission should be less than epoch 105");
    }

    /// @notice Fibonacci growth within a cycle: F(10) > F(5).
    function test_EmissionFibonacciGrowthWithinCycle() public view {
        uint256 e5 = phiCoin.emissionForEpoch(5);
        uint256 e10 = phiCoin.emissionForEpoch(10);

        assertTrue(e10 > e5, "F(10) > F(5) so emission at epoch 10 > epoch 5");
    }

    // =========================================================================
    // Total supply never exceeds cap
    // =========================================================================

    /// @notice mintTo respects the hard cap and reverts on overflow.
    function test_MintToExceedsCapReverts() public {
        // Mint close to cap first
        vm.startPrank(minter);
        phiCoin.mintTo(alice, phiCoin.MAX_SUPPLY() - 100);

        // Try to mint more than remaining
        vm.expectRevert(
            abi.encodeWithSelector(PhiCoin.ExceedsMaxSupply.selector, 200, 100)
        );
        phiCoin.mintTo(bob, 200);
        vm.stopPrank();
    }

    /// @notice After minting to cap, no more tokens can be minted.
    function test_MintToExactCap() public {
        uint256 maxSupply = phiCoin.MAX_SUPPLY();
        vm.prank(minter);
        phiCoin.mintTo(alice, maxSupply);

        assertEq(phiCoin.totalSupply(), phiCoin.MAX_SUPPLY());
        assertEq(phiCoin.remainingSupply(), 0);

        // Further mintTo should revert
        vm.prank(minter);
        vm.expectRevert();
        phiCoin.mintTo(bob, 1);
    }

    /// @notice remainingSupply decreases correctly after minting.
    function test_RemainingSupply() public {
        uint256 amount = 1_000_000 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, amount);

        assertEq(phiCoin.remainingSupply(), phiCoin.MAX_SUPPLY() - amount);
    }

    // =========================================================================
    // Burn
    // =========================================================================

    /// @notice Users can burn their own tokens.
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

    /// @notice Burning more than balance reverts with InsufficientBalance.
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

    /// @notice Burning with zero balance reverts.
    function test_BurnZeroBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PhiCoin.InsufficientBalance.selector, 1, 0)
        );
        phiCoin.burn(1);
    }

    /// @notice Burn emits TokensBurned event.
    function test_BurnEmitsEvent() public {
        uint256 amount = 500 * 1e18;

        vm.prank(minter);
        phiCoin.mintTo(alice, amount);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PhiCoin.TokensBurned(alice, amount);
        phiCoin.burn(amount);
    }

    /// @notice After burn, remainingSupply reflects the burned tokens (cap is on totalSupply).
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

    /// @notice emissionForEpoch(0) returns 0 since F(0) = 0.
    function test_EmissionEpochZero() public view {
        assertEq(phiCoin.emissionForEpoch(0), 0);
    }

    /// @notice currentEpoch starts at 0.
    function test_CurrentEpochStartsAtZero() public view {
        assertEq(phiCoin.currentEpoch(), 0);
    }

    /// @notice currentEpoch advances after BLOCKS_PER_EPOCH blocks.
    function test_CurrentEpochAdvances() public {
        vm.roll(block.number + 100);
        assertEq(phiCoin.currentEpoch(), 1);

        vm.roll(block.number + 100);
        assertEq(phiCoin.currentEpoch(), 2);
    }
}
