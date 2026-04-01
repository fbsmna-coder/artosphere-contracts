// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GoldenMirror} from "../src/GoldenMirror.sol";
import {PhiMath} from "../src/PhiMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockARTS is ERC20 {
    constructor(address holder, uint256 amount) ERC20("Artosphere", "ARTS") {
        _mint(holder, amount);
    }
}

contract GoldenMirrorTest is Test {
    GoldenMirror public mirror;
    MockARTS public arts;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant STAKE_AMOUNT = 100e18;

    function setUp() public {
        arts = new MockARTS(alice, 1_000_000e18);
        mirror = new GoldenMirror(address(arts));

        vm.prank(alice);
        arts.transfer(bob, 10_000e18);
    }

    function test_mirrorStake() public {
        vm.startPrank(alice);
        arts.approve(address(mirror), STAKE_AMOUNT);
        mirror.mirrorStake(STAKE_AMOUNT);
        vm.stopPrank();

        // phi * 100e18 ~ 161.8e18
        uint256 expectedGArts = PhiMath.wadMul(STAKE_AMOUNT, PhiMath.PHI);
        assertEq(mirror.balanceOf(alice), expectedGArts, "gARTS minted should be phi * amount");
        assertGt(expectedGArts, 161e18, "Should be > 161 gARTS");
        assertLt(expectedGArts, 162e18, "Should be < 162 gARTS");
        assertEq(mirror.totalArtsLocked(), STAKE_AMOUNT, "Total locked mismatch");

        (uint256 deposited, uint256 minted, uint256 ts, bool active) = mirror.mirrorStakes(alice);
        assertEq(deposited, STAKE_AMOUNT);
        assertEq(minted, expectedGArts);
        assertTrue(active);
    }

    function test_mirrorUnstake() public {
        vm.startPrank(alice);
        arts.approve(address(mirror), STAKE_AMOUNT);
        mirror.mirrorStake(STAKE_AMOUNT);

        uint256 artsBefore = arts.balanceOf(alice);
        mirror.mirrorUnstake();
        vm.stopPrank();

        assertEq(arts.balanceOf(alice), artsBefore + STAKE_AMOUNT, "Should get ARTS back");
        assertEq(mirror.balanceOf(alice), 0, "gARTS should be burned");
        assertEq(mirror.totalArtsLocked(), 0, "Nothing should be locked");
    }

    function test_gArtsValue_increases() public {
        vm.startPrank(alice);
        arts.approve(address(mirror), STAKE_AMOUNT);
        mirror.mirrorStake(STAKE_AMOUNT);
        vm.stopPrank();

        uint256 valueDay1 = mirror.gArtsValue(alice);

        // Warp 8 weeks forward (fibonacci bonus kicks in after week 1)
        vm.warp(block.timestamp + 8 weeks);
        uint256 valueWeek8 = mirror.gArtsValue(alice);

        assertGt(valueWeek8, valueDay1, "Value should increase over time with fibonacci bonus");
    }

    function test_gArtsTransferable() public {
        vm.startPrank(alice);
        arts.approve(address(mirror), STAKE_AMOUNT);
        mirror.mirrorStake(STAKE_AMOUNT);

        uint256 gArtsBalance = mirror.balanceOf(alice);
        uint256 transferAmount = gArtsBalance / 2;

        mirror.transfer(bob, transferAmount);
        vm.stopPrank();

        assertEq(mirror.balanceOf(bob), transferAmount, "Bob should receive gARTS");
        assertEq(mirror.balanceOf(alice), gArtsBalance - transferAmount, "Alice balance reduced");
    }

    function test_insufficientGArts_reverts() public {
        vm.startPrank(alice);
        arts.approve(address(mirror), STAKE_AMOUNT);
        mirror.mirrorStake(STAKE_AMOUNT);

        // Transfer all gARTS away
        mirror.transfer(bob, mirror.balanceOf(alice));

        // Try to unstake without gARTS
        vm.expectRevert("Insufficient gARTS balance");
        mirror.mirrorUnstake();
        vm.stopPrank();
    }

    function test_doubleStake_reverts() public {
        vm.startPrank(alice);
        arts.approve(address(mirror), STAKE_AMOUNT * 2);
        mirror.mirrorStake(STAKE_AMOUNT);

        vm.expectRevert("Already staked");
        mirror.mirrorStake(STAKE_AMOUNT);
        vm.stopPrank();
    }
}
