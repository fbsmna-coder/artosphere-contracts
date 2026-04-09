// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PhiMath} from "../src/PhiMath.sol";

/// @title PhiMathTest — Comprehensive tests for the PhiMath library
/// @dev Uses a wrapper contract to expose internal library functions for testing
contract PhiMathWrapper {
    using PhiMath for *;

    function WAD() external pure returns (uint256) { return PhiMath.WAD; }
    function PHI() external pure returns (uint256) { return PhiMath.PHI; }
    function PHI_SQUARED() external pure returns (uint256) { return PhiMath.PHI_SQUARED; }
    function PHI_INV() external pure returns (uint256) { return PhiMath.PHI_INV; }
    function GOLDEN_ANGLE() external pure returns (uint256) { return PhiMath.GOLDEN_ANGLE; }

    function wadMul(uint256 a, uint256 b) external pure returns (uint256) { return PhiMath.wadMul(a, b); }
    function wadDiv(uint256 a, uint256 b) external pure returns (uint256) { return PhiMath.wadDiv(a, b); }
    function fibonacci(uint256 n) external pure returns (uint256) { return PhiMath.fibonacci(n); }
    function phiPow(uint256 n) external pure returns (uint256) { return PhiMath.phiPow(n); }
    function phiInvPow(uint256 n) external pure returns (uint256) { return PhiMath.phiInvPow(n); }
    function fibEmission(uint256 epoch) external pure returns (uint256) { return PhiMath.fibEmission(epoch); }
    function fibStakingAPY(uint256 epoch) external pure returns (uint256) { return PhiMath.fibStakingAPY(epoch); }
    function zeckendorf(uint256 n) external pure returns (uint256[] memory) { return PhiMath.zeckendorf(n); }
    function goldenFee(uint256 amount, uint256 phiLevel) external pure returns (uint256) {
        return PhiMath.goldenFee(amount, phiLevel);
    }
    // Paper VI-VII functions
    function sin2Theta13() external pure returns (uint256) { return PhiMath.sin2Theta13(); }
    function higgsCorrection() external pure returns (uint256) { return PhiMath.higgsCorrection(); }
    function higgsQuarticCoupling(uint256 piWad) external pure returns (uint256) { return PhiMath.higgsQuarticCoupling(piWad); }
    function mzNormFactor() external pure returns (uint256) { return PhiMath.mzNormFactor(); }
}

contract PhiMathTest is Test {
    PhiMathWrapper public lib;

    uint256 constant WAD = 1e18;
    uint256 constant PHI = 1_618033988749894848;
    uint256 constant PHI_INV = 618033988749894848;

    function setUp() public {
        lib = new PhiMathWrapper();
    }

    // ====================================================================
    // CONSTANTS
    // ====================================================================

    function test_constants_values() public view {
        assertEq(lib.WAD(), 1e18, "WAD should be 1e18");
        assertEq(lib.PHI(), 1_618033988749894848, "PHI constant mismatch");
        assertEq(lib.PHI_SQUARED(), 2_618033988749894848, "PHI_SQUARED constant mismatch");
        assertEq(lib.PHI_INV(), 618033988749894848, "PHI_INV constant mismatch");
        assertEq(lib.GOLDEN_ANGLE(), 2_399963229728653000, "GOLDEN_ANGLE constant mismatch");
    }

    /// @notice Verify the fundamental identity: φ² = φ + 1
    function test_phi_squared_identity() public view {
        // PHI * PHI should approximately equal PHI + WAD
        uint256 phiTimePhi = lib.wadMul(PHI, PHI);
        uint256 phiPlusOne = PHI + WAD;

        // Allow 1 wei of rounding error from wadMul truncation
        assertApproxEqAbs(phiTimePhi, phiPlusOne, 1, "phi^2 should equal phi + 1");
    }

    /// @notice Verify: φ * (1/φ) = 1
    function test_phi_times_inv_phi_is_one() public view {
        uint256 product = lib.wadMul(PHI, PHI_INV);
        // PHI * PHI_INV / WAD should be very close to WAD
        assertApproxEqAbs(product, WAD, 1, "phi * (1/phi) should equal 1");
    }

    /// @notice Verify PHI_SQUARED = PHI + WAD exactly
    function test_phi_squared_exact() public view {
        assertEq(lib.PHI_SQUARED(), lib.PHI() + lib.WAD(), "PHI_SQUARED must equal PHI + WAD");
    }

    // ====================================================================
    // WAD MATH
    // ====================================================================

    function test_wadMul_basic() public view {
        assertEq(lib.wadMul(WAD, WAD), WAD, "1 * 1 = 1");
        assertEq(lib.wadMul(2 * WAD, 3 * WAD), 6 * WAD, "2 * 3 = 6");
        assertEq(lib.wadMul(0, WAD), 0, "0 * 1 = 0");
        assertEq(lib.wadMul(WAD, 0), 0, "1 * 0 = 0");
    }

    function test_wadDiv_basic() public view {
        assertEq(lib.wadDiv(WAD, WAD), WAD, "1 / 1 = 1");
        assertEq(lib.wadDiv(6 * WAD, 3 * WAD), 2 * WAD, "6 / 3 = 2");
        assertEq(lib.wadDiv(WAD, 2 * WAD), WAD / 2, "1 / 2 = 0.5");
        assertEq(lib.wadDiv(0, WAD), 0, "0 / 1 = 0");
    }

    function test_wadDiv_reverts_on_zero() public {
        vm.expectRevert(PhiMath.ZeroInput.selector);
        lib.wadDiv(WAD, 0);
    }

    function test_wadMul_overflow_reverts() public {
        vm.expectRevert(PhiMath.WadMulOverflow.selector);
        lib.wadMul(type(uint256).max, type(uint256).max);
    }

    // ====================================================================
    // FIBONACCI
    // ====================================================================

    function test_fibonacci_zero() public view {
        assertEq(lib.fibonacci(0), 0, "F(0) = 0");
    }

    function test_fibonacci_one() public view {
        assertEq(lib.fibonacci(1), WAD, "F(1) = 1 WAD");
    }

    function test_fibonacci_two() public view {
        assertEq(lib.fibonacci(2), WAD, "F(2) = 1 WAD");
    }

    function test_fibonacci_ten() public view {
        // F(10) = 55
        assertEq(lib.fibonacci(10), 55 * WAD, "F(10) = 55 WAD");
    }

    function test_fibonacci_small_sequence() public view {
        // F: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55
        uint256[11] memory expected = [uint256(0), 1, 1, 2, 3, 5, 8, 13, 21, 34, 55];
        for (uint256 i = 0; i <= 10; i++) {
            assertEq(lib.fibonacci(i), expected[i] * WAD, "Fibonacci sequence mismatch");
        }
    }

    function test_fibonacci_20() public view {
        // F(20) = 6765
        assertEq(lib.fibonacci(20), 6765 * WAD, "F(20) = 6765 WAD");
    }

    function test_fibonacci_93_max() public view {
        // F(93) = 12200160415121876738 — should not revert
        uint256 f93 = lib.fibonacci(93);
        assertEq(f93, 12200160415121876738 * WAD, "F(93) value mismatch");
    }

    function test_fibonacci_reverts_above_93() public {
        vm.expectRevert(abi.encodeWithSelector(PhiMath.FibonacciIndexTooLarge.selector, 94, 93));
        lib.fibonacci(94);
    }

    /// @notice Verify Fibonacci recurrence: F(n) = F(n-1) + F(n-2) for several values
    function test_fibonacci_recurrence() public view {
        for (uint256 n = 2; n <= 30; n++) {
            assertEq(
                lib.fibonacci(n),
                lib.fibonacci(n - 1) + lib.fibonacci(n - 2),
                "Fibonacci recurrence violated"
            );
        }
    }

    // ====================================================================
    // PHI POWER
    // ====================================================================

    function test_phiPow_zero() public view {
        assertEq(lib.phiPow(0), WAD, "phi^0 = 1");
    }

    function test_phiPow_one() public view {
        assertEq(lib.phiPow(1), PHI, "phi^1 = phi");
    }

    function test_phiPow_two() public view {
        uint256 result = lib.phiPow(2);
        assertEq(result, 2_618033988749894848, "phi^2 = phi + 1");
    }

    function test_phiPow_three() public view {
        // φ^3 = φ^2 * φ = (φ+1)*φ = φ^2 + φ = 2φ + 1 ≈ 4.236067977...
        uint256 result = lib.phiPow(3);
        uint256 expected = 4_236067977499789696; // 2*PHI + WAD
        // Allow small rounding from matrix multiplication
        assertApproxEqAbs(result, expected, 2, "phi^3 ~ 2*phi + 1");
    }

    function test_phiPow_ten() public view {
        // φ^10 ≈ 122.99186...
        uint256 result = lib.phiPow(10);
        // F(10) = 55, F(9) = 34 => phi^10 = 55*phi + 34 = 55*1.618... + 34 ≈ 122.99
        uint256 expected = 55 * PHI + 34 * WAD;
        assertApproxEqAbs(result, expected, 10, "phi^10 ~ F(10)*phi + F(9)");
    }

    /// @notice Verify φ^n * φ = φ^(n+1) for small n
    function test_phiPow_multiplicative() public view {
        for (uint256 n = 0; n <= 15; n++) {
            uint256 phiN = lib.phiPow(n);
            uint256 phiNplus1 = lib.phiPow(n + 1);
            uint256 product = lib.wadMul(phiN, PHI);
            // Rounding error grows super-linearly with n; use generous bound
            uint256 tolerance = 1 + n * n * 2;
            assertApproxEqAbs(product, phiNplus1, tolerance, "phi^n * phi should equal phi^(n+1)");
        }
    }

    // ====================================================================
    // PHI INVERSE POWER
    // ====================================================================

    function test_phiInvPow_zero() public view {
        assertEq(lib.phiInvPow(0), WAD, "phi^(-0) = 1");
    }

    function test_phiInvPow_one() public view {
        assertEq(lib.phiInvPow(1), PHI_INV, "phi^(-1) = 1/phi");
    }

    function test_phiInvPow_two() public view {
        // 1/φ^2 = 1/(φ+1) ≈ 0.381966011250105...
        uint256 result = lib.phiInvPow(2);
        uint256 expected = 381966011250105152; // 1/2.618... in WAD
        assertApproxEqAbs(result, expected, WAD / 1e12, "phi^(-2) ~ 0.382");
    }

    /// @notice φ^n * φ^(-n) ≈ 1
    function test_phiPow_times_phiInvPow_is_one() public view {
        for (uint256 n = 0; n <= 10; n++) {
            uint256 forward = lib.phiPow(n);
            uint256 inverse = lib.phiInvPow(n);
            uint256 product = lib.wadMul(forward, inverse);
            // Allow increasing tolerance for larger n due to compounding rounding
            uint256 tolerance = 1 + n * n * 10;
            assertApproxEqAbs(product, WAD, tolerance, "phi^n * phi^(-n) should equal 1");
        }
    }

    /// @notice phiInvPow values should decrease monotonically
    function test_phiInvPow_decreasing() public view {
        uint256 prev = lib.phiInvPow(0);
        for (uint256 n = 1; n <= 20; n++) {
            uint256 curr = lib.phiInvPow(n);
            assertTrue(curr < prev, "phi^(-n) should be strictly decreasing");
            prev = curr;
        }
    }

    // ====================================================================
    // FIB EMISSION
    // ====================================================================

    function test_fibEmission_epoch_zero() public view {
        // epoch 0 => fibIndex=0, F(0)=0 => emission = 0
        assertEq(lib.fibEmission(0), 0, "Emission at epoch 0 should be 0");
    }

    function test_fibEmission_epoch_one() public view {
        // epoch 1 => fibIndex=1, decayPeriod=0, F(1)*phi^0 = 1*WAD = WAD
        assertEq(lib.fibEmission(1), WAD, "Emission at epoch 1 should be WAD");
    }

    function test_fibEmission_epoch_ten() public view {
        // epoch 10 => fibIndex=10, decayPeriod=0, F(10)*1 = 55*WAD
        assertEq(lib.fibEmission(10), 55 * WAD, "Emission at epoch 10 should be 55 WAD");
    }

    /// @notice Emission at epoch 100 should be less than at epoch 10 due to decay
    function test_fibEmission_decreases_with_decay_period() public view {
        // epoch 110 => fibIndex=10, decayPeriod=1, F(10)*phi^(-1) = 55*0.618... ≈ 33.99 WAD
        uint256 emission10 = lib.fibEmission(10);     // 55 WAD, no decay
        uint256 emission110 = lib.fibEmission(110);   // 55 * phi^(-1), decayed

        assertTrue(emission110 < emission10, "Emission should decrease across decay periods");
        // More precisely: emission110 ≈ wadMul(55 * WAD, PHI_INV)
        uint256 expected = lib.wadMul(55 * WAD, PHI_INV);
        assertApproxEqAbs(emission110, expected, WAD / 1e10, "Emission at epoch 110 mismatch");
    }

    /// @notice Same fibIndex across decay periods should monotonically decrease
    function test_fibEmission_monotonic_decay() public view {
        // Compare F(10) at decay periods 0, 1, 2
        uint256 e0 = lib.fibEmission(10);    // period 0
        uint256 e1 = lib.fibEmission(110);   // period 1
        uint256 e2 = lib.fibEmission(210);   // period 2

        assertTrue(e0 > e1, "Period 0 > Period 1");
        assertTrue(e1 > e2, "Period 1 > Period 2");
    }

    // ====================================================================
    // FIB STAKING APY
    // ====================================================================

    function test_fibStakingAPY_epoch_zero() public view {
        // APY(0) = phi^(-1) = 1/phi ≈ 0.618033988749894848
        uint256 apy = lib.fibStakingAPY(0);
        assertEq(apy, PHI_INV, "APY at epoch 0 should be 1/phi (61.8%)");
    }

    function test_fibStakingAPY_epoch_zero_value() public view {
        // Explicit value check: 618033988749894848
        uint256 apy = lib.fibStakingAPY(0);
        assertEq(apy, 618033988749894848, "APY(0) = 618033988749894848");
    }

    function test_fibStakingAPY_epoch_one() public view {
        // APY(1) = phi^(-2) ≈ 0.381966...
        uint256 apy = lib.fibStakingAPY(1);
        uint256 expected = 381966011250105152;
        assertApproxEqAbs(apy, expected, WAD / 1e12, "APY at epoch 1 ~ 38.2%");
    }

    /// @notice APY should decrease every epoch (golden decay)
    function test_fibStakingAPY_decreasing() public view {
        uint256 prev = lib.fibStakingAPY(0);
        for (uint256 i = 1; i <= 20; i++) {
            uint256 curr = lib.fibStakingAPY(i);
            assertTrue(curr < prev, "APY should strictly decrease each epoch");
            prev = curr;
        }
    }

    /// @notice Each APY should be approximately previous / φ
    function test_fibStakingAPY_golden_ratio_decay() public view {
        for (uint256 i = 0; i < 10; i++) {
            uint256 apyCurr = lib.fibStakingAPY(i);
            uint256 apyNext = lib.fibStakingAPY(i + 1);
            // apyNext ≈ apyCurr / φ = wadMul(apyCurr, PHI_INV)
            uint256 expected = lib.wadMul(apyCurr, PHI_INV);
            uint256 tolerance = WAD / 1e10 + i * i * 100;
            assertApproxEqAbs(apyNext, expected, tolerance, "APY golden ratio decay");
        }
    }

    // ====================================================================
    // ZECKENDORF DECOMPOSITION
    // ====================================================================

    function test_zeckendorf_one() public view {
        uint256[] memory indices = lib.zeckendorf(1);
        assertEq(indices.length, 1, "1 = F(2)");
        assertEq(indices[0], 2, "Index should be 2 (greedy picks largest F(k)<=1, F(2)=1)");
    }

    function test_zeckendorf_two() public view {
        uint256[] memory indices = lib.zeckendorf(2);
        assertEq(indices.length, 1, "2 = F(3)");
        assertEq(indices[0], 3, "Index should be 3");
    }

    function test_zeckendorf_three() public view {
        // 3 = F(4) = 3
        uint256[] memory indices = lib.zeckendorf(3);
        assertEq(indices.length, 1, "3 = F(4)");
        assertEq(indices[0], 4, "Index should be 4");
    }

    function test_zeckendorf_four() public view {
        // 4 = 3 + 1 = F(4) + F(2) (greedy picks F(2)=1 since F(2)>=F(1))
        uint256[] memory indices = lib.zeckendorf(4);
        assertEq(indices.length, 2, "4 = F(4) + F(2)");
        assertEq(indices[0], 4, "First index should be 4");
        assertEq(indices[1], 2, "Second index should be 2");
    }

    function test_zeckendorf_ten() public view {
        // 10 = 8 + 2 = F(6) + F(3)
        uint256[] memory indices = lib.zeckendorf(10);
        assertEq(indices.length, 2, "10 = F(6) + F(3)");
        assertEq(indices[0], 6, "First index should be 6 (F(6)=8)");
        assertEq(indices[1], 3, "Second index should be 3 (F(3)=2)");
    }

    function test_zeckendorf_100() public view {
        // 100 = 89 + 8 + 3 = F(11) + F(6) + F(4)
        uint256[] memory indices = lib.zeckendorf(100);
        assertEq(indices.length, 3, "100 = F(11) + F(6) + F(4)");
        assertEq(indices[0], 11, "First: F(11)=89");
        assertEq(indices[1], 6, "Second: F(6)=8");
        assertEq(indices[2], 4, "Third: F(4)=3");
    }

    /// @notice Verify decomposition sums back to original
    function test_zeckendorf_sum_correctness() public view {
        uint256[5] memory testValues = [uint256(7), 13, 42, 99, 144];

        for (uint256 t = 0; t < 5; t++) {
            uint256 n = testValues[t];
            uint256[] memory indices = lib.zeckendorf(n);
            uint256 sum = 0;

            for (uint256 i = 0; i < indices.length; i++) {
                // Compute raw Fibonacci for the index
                uint256 fibVal = lib.fibonacci(indices[i]) / WAD;
                sum += fibVal;
            }

            assertEq(sum, n, "Zeckendorf decomposition sum should equal original");
        }
    }

    /// @notice No two consecutive Fibonacci indices in Zeckendorf decomposition
    function test_zeckendorf_no_consecutive() public view {
        uint256[3] memory testValues = [uint256(20), 50, 100];

        for (uint256 t = 0; t < 3; t++) {
            uint256[] memory indices = lib.zeckendorf(testValues[t]);

            for (uint256 i = 1; i < indices.length; i++) {
                // Indices are in decreasing order; consecutive means diff == 1
                assertTrue(
                    indices[i - 1] - indices[i] >= 2,
                    "Zeckendorf should have no consecutive Fibonacci indices"
                );
            }
        }
    }

    function test_zeckendorf_reverts_on_zero() public {
        vm.expectRevert(PhiMath.ZeckendorfZeroInput.selector);
        lib.zeckendorf(0);
    }

    /// @notice Fibonacci numbers themselves should have a single-element decomposition
    function test_zeckendorf_fibonacci_numbers() public view {
        // F(2)=1, F(3)=2, F(4)=3, F(5)=5, F(6)=8, F(7)=13
        // Note: greedy algorithm picks largest index, so 1 -> F(2) not F(1)
        uint256[6] memory fibNums = [uint256(1), 2, 3, 5, 8, 13];
        uint256[6] memory fibIdxs = [uint256(2), 3, 4, 5, 6, 7];

        for (uint256 i = 0; i < 6; i++) {
            uint256[] memory indices = lib.zeckendorf(fibNums[i]);
            assertEq(indices.length, 1, "Fibonacci number should have single Zeckendorf term");
            assertEq(indices[0], fibIdxs[i], "Zeckendorf index mismatch for Fibonacci number");
        }
    }

    // ====================================================================
    // GOLDEN FEE
    // ====================================================================

    function test_goldenFee_level_zero() public view {
        // Level 0: fee = amount / φ^0 = amount
        uint256 fee = lib.goldenFee(1000 * WAD, 0);
        assertEq(fee, 1000 * WAD, "Fee at level 0 should equal full amount");
    }

    function test_goldenFee_level_one() public view {
        // Level 1: fee = amount / φ ≈ 618 WAD
        uint256 fee = lib.goldenFee(1000 * WAD, 1);
        uint256 expected = lib.wadDiv(1000 * WAD, PHI);
        assertEq(fee, expected, "Fee at level 1 should be amount/phi");

        // ~618 WAD (more precisely 618.033988... WAD)
        uint256 approx618 = 618 * WAD;
        assertApproxEqAbs(fee, approx618, WAD, "Fee at level 1 ~ 618 WAD");
    }

    function test_goldenFee_level_two() public view {
        // Level 2: fee = amount / φ^2 ≈ 382 WAD
        uint256 fee = lib.goldenFee(1000 * WAD, 2);
        uint256 approx382 = 382 * WAD;
        assertApproxEqAbs(fee, approx382, WAD, "Fee at level 2 ~ 382 WAD");
    }

    function test_goldenFee_zero_amount() public view {
        assertEq(lib.goldenFee(0, 5), 0, "Fee on zero amount should be zero");
    }

    /// @notice Fee should decrease as phi_level increases
    function test_goldenFee_decreasing_with_level() public view {
        uint256 amount = 1000 * WAD;
        uint256 prev = lib.goldenFee(amount, 0);

        for (uint256 level = 1; level <= 10; level++) {
            uint256 curr = lib.goldenFee(amount, level);
            assertTrue(curr < prev, "Fee should decrease with higher phi_level");
            prev = curr;
        }
    }

    /// @notice Ratio between consecutive fee levels should be ~1/φ
    function test_goldenFee_ratio_is_phi() public view {
        uint256 amount = 10_000 * WAD;

        for (uint256 level = 0; level < 5; level++) {
            uint256 feeHere = lib.goldenFee(amount, level);
            uint256 feeNext = lib.goldenFee(amount, level + 1);

            // feeNext / feeHere ≈ 1/φ ≈ 0.618
            if (feeHere > 0) {
                uint256 ratio = lib.wadDiv(feeNext, feeHere);
                assertApproxEqAbs(ratio, PHI_INV, WAD / 1e8, "Fee ratio should be 1/phi");
            }
        }
    }

    // ====================================================================
    // GAS BENCHMARKS (informational, not assertions)
    // ====================================================================

    function test_gas_fibonacci_10() public view {
        uint256 gasBefore = gasleft();
        lib.fibonacci(10);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: fibonacci(10) =", gasUsed);
    }

    function test_gas_fibonacci_93() public view {
        uint256 gasBefore = gasleft();
        lib.fibonacci(93);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: fibonacci(93) =", gasUsed);
    }

    function test_gas_phiPow_10() public view {
        uint256 gasBefore = gasleft();
        lib.phiPow(10);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: phiPow(10) =", gasUsed);
    }

    function test_gas_zeckendorf_100() public view {
        uint256 gasBefore = gasleft();
        lib.zeckendorf(100);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: zeckendorf(100) =", gasUsed);
    }

    // ====================================================================
    // PAPER VI-VII: PHYSICS FUNCTIONS (2026-04-09)
    // ====================================================================

    /// @notice sin²θ₁₃ = φ⁻⁸ + φ⁻¹⁵ ≈ 0.02202 (exp: 0.02200 ± 0.00069)
    function test_sin2Theta13_value() public view {
        uint256 result = lib.sin2Theta13();
        // Expected: ~0.02202 → in WAD: ~22020000000000000
        // Allow 0.1% tolerance for fixed-point rounding
        uint256 expectedApprox = 22020000000000000; // 0.02202 WAD
        assertApproxEqAbs(result, expectedApprox, WAD / 1e4, "sin2Theta13 ~ 0.02202");
    }

    /// @notice sin²θ₁₃ should equal phiInvPow(8) + phiInvPow(15) exactly
    function test_sin2Theta13_decomposition() public view {
        uint256 result = lib.sin2Theta13();
        uint256 phi8inv = lib.phiInvPow(8);
        uint256 phi15inv = lib.phiInvPow(15);
        assertEq(result, phi8inv + phi15inv, "sin2Theta13 = phi^-8 + phi^-15");
    }

    /// @notice sin²θ₁₃ leading term φ⁻⁸ should dominate (>96%)
    function test_sin2Theta13_leading_dominates() public view {
        uint256 phi8inv = lib.phiInvPow(8);
        uint256 total = lib.sin2Theta13();
        // φ⁻⁸/total > 0.96
        uint256 ratio = lib.wadDiv(phi8inv, total);
        assertTrue(ratio > 960000000000000000, "Leading term phi^-8 should be > 96% of sin2Theta13");
    }

    /// @notice Higgs correction: Δλ_H = 1/(24φ⁸) ≈ 0.000887
    function test_higgsCorrection_value() public view {
        uint256 result = lib.higgsCorrection();
        // Expected: ~0.000887 → in WAD: ~887000000000000
        uint256 expectedApprox = 887000000000000; // 0.000887 WAD
        assertApproxEqAbs(result, expectedApprox, WAD / 1e5, "Higgs correction ~ 0.000887");
    }

    /// @notice Higgs correction = sin²θ₁₃ (leading) / 24 ≈ φ⁻⁸/24
    function test_higgsCorrection_is_sin2theta13_over_24() public view {
        uint256 correction = lib.higgsCorrection();
        uint256 phi8inv = lib.phiInvPow(8);
        uint256 phi8over24 = lib.wadDiv(phi8inv, 24 * WAD);
        // Should be equal (both computed as 1/(24φ⁸))
        assertApproxEqAbs(correction, phi8over24, 100, "Higgs correction = phi^-8 / 24");
    }

    /// @notice Higgs quartic coupling: λ_H = (π + 6φ⁹)/(24πφ⁸) ≈ 0.12905
    function test_higgsQuarticCoupling_value() public view {
        uint256 piWad = 3_141592653589793238;
        uint256 result = lib.higgsQuarticCoupling(piWad);
        // Expected: ~0.12905 → in WAD: ~129050000000000000
        uint256 expectedApprox = 129050000000000000;
        assertApproxEqAbs(result, expectedApprox, WAD / 1e3, "lambda_H ~ 0.12905");
    }

    /// @notice λ_H = tree + CP correction: φ/(4π) + 1/(24φ⁸)
    function test_higgsQuarticCoupling_decomposition() public view {
        uint256 piWad = 3_141592653589793238;
        uint256 lambdaH = lib.higgsQuarticCoupling(piWad);
        uint256 correction = lib.higgsCorrection();
        // Tree term = λ_H - correction
        uint256 tree = lambdaH - correction;
        // Tree should be φ/(4π) ≈ 0.12877
        uint256 expectedTree = lib.wadDiv(PHI, 4 * piWad);
        assertApproxEqAbs(tree, expectedTree, 10, "Tree term = phi/(4pi)");
    }

    /// @notice Higgs-Flavor Identity: J²_CP(lep) ≈ Δλ_H (ratio ~ 1.05)
    function test_higgsFlavor_identity() public view {
        uint256 correction = lib.higgsCorrection();
        // J_CP^lep ≈ 0.0305 → J² ≈ 0.000930
        uint256 jCPLep = 30500000000000000; // 0.0305 WAD
        uint256 jSquared = lib.wadMul(jCPLep, jCPLep);
        // Ratio J²/Δλ should be ~1.048 (within 10%)
        uint256 ratio = lib.wadDiv(jSquared, correction);
        assertApproxEqAbs(ratio, WAD, WAD / 10, "Higgs-Flavor Identity: J^2_CP ~ Delta_lambda_H (within 10%)");
    }

    /// @notice M_Z normalization: √(8(8φ−3)) ≈ 8.919
    function test_mzNormFactor_value() public view {
        uint256 result = lib.mzNormFactor();
        // 8φ−3 ≈ 9.9443, ×8 = 79.554, √ ≈ 8.919
        uint256 expectedApprox = 8_919000000000000000;
        assertApproxEqAbs(result, expectedApprox, WAD / 100, "M_Z norm ~ 8.919");
    }

    /// @notice M_Z norm squared should equal 8(8φ−3)
    function test_mzNormFactor_squared() public view {
        uint256 norm = lib.mzNormFactor();
        uint256 normSquared = lib.wadMul(norm, norm);
        // 8(8φ−3) = 64φ − 24 ≈ 79.554
        uint256 expected = 64 * PHI - 24 * WAD; // 64φ − 24 in WAD
        // Allow 0.1% tolerance from sqrt rounding
        assertApproxEqAbs(normSquared, expected, WAD / 100, "norm^2 = 8(8phi-3)");
    }

    // ====================================================================
    // GAS: Paper VI-VII functions
    // ====================================================================

    function test_gas_sin2Theta13() public view {
        uint256 gasBefore = gasleft();
        lib.sin2Theta13();
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: sin2Theta13() =", gasUsed);
    }

    function test_gas_higgsQuarticCoupling() public view {
        uint256 gasBefore = gasleft();
        lib.higgsQuarticCoupling(3_141592653589793238);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas: higgsQuarticCoupling() =", gasUsed);
    }
}
