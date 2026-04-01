// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {NashFee} from "../src/NashFee.sol";
import {PhiMath} from "../src/PhiMath.sol";

contract NashFeeTest is Test {
    NashFee public nashFee;
    address public owner = makeAddr("owner");

    uint256 constant WAD = 1e18;
    uint256 constant EQUILIBRIUM = 6180339887498948;

    function setUp() public {
        vm.prank(owner);
        nashFee = new NashFee();
    }

    function test_initialFee_isEquilibrium() public view {
        assertEq(nashFee.currentFee(), EQUILIBRIUM, "Initial fee should be 0.618%");
        assertEq(nashFee.getFee(), EQUILIBRIUM, "getFee should return equilibrium");
    }

    function test_holderPressure_increasesFee() public {
        // Set holder signal > trader signal
        vm.prank(owner);
        nashFee.updateSignals(100, 10, 0);

        // Advance time past update interval
        vm.warp(block.timestamp + 1 hours + 1);
        nashFee.rebalanceFee();

        // Fee should have increased from equilibrium (then pulled back by mean reversion)
        // But net effect of holderPressure > traderPressure should push fee up initially
        // After mean reversion it may come back. Let's just check the mechanics work.
        // With holder > trader and no LP damping, fee increases by ADJUSTMENT_RATE,
        // then mean reversion pulls it back. Since we started at equilibrium,
        // after adding ADJUSTMENT_RATE and reverting ~38.2% of deviation, net should be above equilibrium.
        uint256 fee = nashFee.currentFee();
        assertGt(fee, EQUILIBRIUM, "Fee should increase with holder pressure");
    }

    function test_traderPressure_decreasesFee() public {
        // Set trader signal > holder signal
        vm.prank(owner);
        nashFee.updateSignals(10, 100, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        nashFee.rebalanceFee();

        uint256 fee = nashFee.currentFee();
        assertLt(fee, EQUILIBRIUM, "Fee should decrease with trader pressure");
    }

    function test_meanReversion() public {
        // Push fee high first: set holder pressure for several rounds
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(owner);
            nashFee.updateSignals(1000, 0, 0);
            vm.warp(block.timestamp + 1 hours + 1);
            nashFee.rebalanceFee();
        }

        uint256 highFee = nashFee.currentFee();
        assertGt(highFee, EQUILIBRIUM, "Fee should be above equilibrium");

        // Now set balanced signals and let mean reversion pull back
        vm.prank(owner);
        nashFee.updateSignals(50, 50, 0);
        vm.warp(block.timestamp + 1 hours + 1);
        nashFee.rebalanceFee();

        uint256 afterReversion = nashFee.currentFee();
        assertLt(afterReversion, highFee, "Mean reversion should pull fee down toward equilibrium");
    }

    function test_feeClamp() public {
        // Push fee very high
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(owner);
            nashFee.updateSignals(1e18, 0, 0);
            vm.warp(block.timestamp + 1 hours + 1);
            nashFee.rebalanceFee();
        }

        uint256 fee = nashFee.currentFee();
        assertLe(fee, nashFee.MAX_FEE(), "Fee should not exceed MAX_FEE");

        // Push fee very low
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(owner);
            nashFee.updateSignals(0, 1e18, 0);
            vm.warp(block.timestamp + 1 hours + 1);
            nashFee.rebalanceFee();
        }

        fee = nashFee.currentFee();
        assertGe(fee, nashFee.MIN_FEE(), "Fee should not go below MIN_FEE");
    }

    function test_updateTooSoon_reverts() public {
        vm.expectRevert("Too soon");
        nashFee.rebalanceFee();
    }
}
