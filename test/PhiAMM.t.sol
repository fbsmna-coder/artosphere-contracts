// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PhiAMM} from "../src/PhiAMM.sol";
import {PhiMath} from "../src/PhiMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol, address holder, uint256 amount) ERC20(name, symbol) {
        _mint(holder, amount);
    }
}

contract PhiAMMTest is Test {
    PhiAMM public amm;
    MockToken public arts;
    MockToken public paired;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant INITIAL_ARTS = 100_000e18;
    uint256 constant INITIAL_PAIRED = 100_000e18;
    uint256 constant SWAP_AMOUNT = 1_000e18;

    function setUp() public {
        arts = new MockToken("Artosphere", "ARTS", alice, INITIAL_ARTS * 10);
        paired = new MockToken("Wrapped ETH", "WETH", alice, INITIAL_PAIRED * 10);
        amm = new PhiAMM(address(arts), address(paired));

        // Give bob some tokens too
        vm.startPrank(alice);
        arts.transfer(bob, INITIAL_ARTS * 2);
        paired.transfer(bob, INITIAL_PAIRED * 2);
        vm.stopPrank();
    }

    function test_addLiquidity() public {
        vm.startPrank(alice);
        arts.approve(address(amm), INITIAL_ARTS);
        paired.approve(address(amm), INITIAL_PAIRED);

        uint256 lp = amm.addLiquidity(INITIAL_ARTS, INITIAL_PAIRED);
        vm.stopPrank();

        assertGt(lp, 0, "LP tokens should be minted");
        assertEq(amm.reserveARTS(), INITIAL_ARTS, "ARTS reserve mismatch");
        assertEq(amm.reservePaired(), INITIAL_PAIRED, "Paired reserve mismatch");
        assertEq(amm.lpBalance(alice), lp, "LP balance mismatch");
        assertEq(amm.totalLP(), lp + amm.MINIMUM_LIQUIDITY(), "Total LP mismatch");
    }

    function test_swapBuyARTS() public {
        _addLiquidity(alice, INITIAL_ARTS, INITIAL_PAIRED);

        vm.startPrank(bob);
        paired.approve(address(amm), SWAP_AMOUNT);
        uint256 artsBalBefore = arts.balanceOf(bob);
        uint256 amountOut = amm.swap(true, SWAP_AMOUNT, 0, block.timestamp + 300);
        uint256 artsBalAfter = arts.balanceOf(bob);
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive ARTS");
        assertEq(artsBalAfter - artsBalBefore, amountOut, "Balance change should match output");
    }

    function test_swapSellARTS() public {
        _addLiquidity(alice, INITIAL_ARTS, INITIAL_PAIRED);

        vm.startPrank(bob);
        arts.approve(address(amm), SWAP_AMOUNT);
        uint256 pairedBalBefore = paired.balanceOf(bob);
        uint256 amountOut = amm.swap(false, SWAP_AMOUNT, 0, block.timestamp + 300);
        uint256 pairedBalAfter = paired.balanceOf(bob);
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive paired tokens");
        assertEq(pairedBalAfter - pairedBalBefore, amountOut, "Balance change should match output");
    }

    function test_buyHasLessSlippage() public {
        _addLiquidity(alice, INITIAL_ARTS, INITIAL_PAIRED);

        // Buy ARTS with SWAP_AMOUNT paired tokens
        vm.startPrank(bob);
        paired.approve(address(amm), SWAP_AMOUNT);
        uint256 buyOutput = amm.swap(true, SWAP_AMOUNT, 0, block.timestamp + 300);
        vm.stopPrank();

        // Reset pool state by deploying fresh
        PhiAMM amm2 = new PhiAMM(address(arts), address(paired));
        vm.startPrank(alice);
        arts.approve(address(amm2), INITIAL_ARTS);
        paired.approve(address(amm2), INITIAL_PAIRED);
        amm2.addLiquidity(INITIAL_ARTS, INITIAL_PAIRED);
        vm.stopPrank();

        // Sell ARTS for SWAP_AMOUNT
        vm.startPrank(bob);
        arts.approve(address(amm2), SWAP_AMOUNT);
        uint256 sellOutput = amm2.swap(false, SWAP_AMOUNT, 0, block.timestamp + 300);
        vm.stopPrank();

        // Buying should get MORE output than selling (phi-asymmetry)
        assertGt(buyOutput, sellOutput, "Buy should have less slippage (more output) than sell");
    }

    function test_removeLiquidity() public {
        vm.startPrank(alice);
        arts.approve(address(amm), INITIAL_ARTS);
        paired.approve(address(amm), INITIAL_PAIRED);
        uint256 lp = amm.addLiquidity(INITIAL_ARTS, INITIAL_PAIRED);

        uint256 artsBefore = arts.balanceOf(alice);
        uint256 pairedBefore = paired.balanceOf(alice);

        (uint256 artsOut, uint256 pairedOut) = amm.removeLiquidity(lp);
        vm.stopPrank();

        // After MINIMUM_LIQUIDITY burn, user cannot withdraw 100% of reserves
        assertGt(artsOut, 0, "Should get ARTS back");
        assertGt(pairedOut, 0, "Should get paired back");
        assertEq(arts.balanceOf(alice), artsBefore + artsOut, "ARTS balance mismatch");
        assertEq(paired.balanceOf(alice), pairedBefore + pairedOut, "Paired balance mismatch");
        assertEq(amm.totalLP(), amm.MINIMUM_LIQUIDITY(), "Remaining LP should equal MINIMUM_LIQUIDITY");
    }

    function test_getAmountOut_view() public {
        _addLiquidity(alice, INITIAL_ARTS, INITIAL_PAIRED);

        uint256 expectedOut = amm.getAmountOut(true, SWAP_AMOUNT);

        vm.startPrank(bob);
        paired.approve(address(amm), SWAP_AMOUNT);
        uint256 actualOut = amm.swap(true, SWAP_AMOUNT, 0, block.timestamp + 300);
        vm.stopPrank();

        assertEq(expectedOut, actualOut, "View should match actual swap output");
    }

    function test_swapNoLiquidity_reverts() public {
        vm.startPrank(bob);
        paired.approve(address(amm), SWAP_AMOUNT);
        vm.expectRevert("No liquidity");
        amm.swap(true, SWAP_AMOUNT, 0, block.timestamp + 300);
        vm.stopPrank();
    }

    // --- Helpers ---

    function _addLiquidity(address user, uint256 artsAmt, uint256 pairedAmt) internal {
        vm.startPrank(user);
        arts.approve(address(amm), artsAmt);
        paired.approve(address(amm), pairedAmt);
        amm.addLiquidity(artsAmt, pairedAmt);
        vm.stopPrank();
    }
}
