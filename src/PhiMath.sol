// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PhiMath — Golden Ratio Mathematics Library for φCoin
/// @author φCoin Team (fcoin-contracts)
/// @notice Pure mathematical library implementing φ-based calculations in 18-decimal fixed-point (WAD)
/// @dev All values use WAD = 1e18 as the unit. φ = (1+√5)/2 ≈ 1.618033988749894848
///      This library is the mathematical heart of the φCoin protocol — every emission schedule,
///      staking reward, fee calculation, and governance weight derives from these functions.
library PhiMath {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice 1e18 — the fixed-point unit (one whole token)
    uint256 public constant WAD = 1e18;

    /// @notice φ = (1+√5)/2 in WAD representation (18 decimals)
    /// @dev 1.618033988749894848 * 1e18
    uint256 public constant PHI = 1_618033988749894848;

    /// @notice φ² = φ + 1 in WAD representation
    /// @dev By the golden ratio identity: φ² = φ + 1, so PHI_SQUARED = PHI + WAD
    uint256 public constant PHI_SQUARED = 2_618033988749894848;

    /// @notice 1/φ = φ - 1 in WAD representation
    /// @dev By the golden ratio identity: 1/φ = φ - 1 ≈ 0.618033988749894848
    uint256 public constant PHI_INV = 618033988749894848;

    /// @notice Golden angle = 2π/φ² in WAD representation
    /// @dev 2π/φ² ≈ 2.399963229728653 rad ≈ 2_399963229728653000 in WAD
    ///      Calculated as: 2 * 3.141592653589793238 / 2.618033988749894848
    uint256 public constant GOLDEN_ANGLE = 2_399963229728653000;

    /// @notice Maximum Fibonacci index that fits in uint256 when scaled by WAD
    /// @dev F(93) = 12200160415121876738, and F(93) * 1e18 < 2^256
    uint256 internal constant MAX_FIB_INDEX = 93;

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when a Fibonacci index exceeds MAX_FIB_INDEX
    /// @param index The requested Fibonacci index
    /// @param max The maximum allowed index
    error FibonacciIndexTooLarge(uint256 index, uint256 max);

    /// @notice Thrown when an input value is zero where non-zero is required
    error ZeroInput();

    /// @notice Thrown when WAD multiplication overflows
    error WadMulOverflow();

    /// @notice Thrown when Zeckendorf decomposition input is zero
    error ZeckendorfZeroInput();

    // ========================================================================
    // INTERNAL MATH HELPERS
    // ========================================================================

    /// @notice Multiplies two WAD values: (a * b) / WAD
    /// @dev Rounds down. Reverts on overflow.
    /// @param a First WAD operand
    /// @param b Second WAD operand
    /// @return result The product in WAD
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256 result) {
        if (a == 0 || b == 0) return 0;
        if (a > type(uint256).max / b) revert WadMulOverflow();
        unchecked {
            result = (a * b) / WAD;
        }
    }

    /// @notice Divides two WAD values: (a * WAD) / b
    /// @dev Rounds down. Reverts on division by zero.
    /// @param a Numerator in WAD
    /// @param b Denominator in WAD
    /// @return result The quotient in WAD
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256 result) {
        if (b == 0) revert ZeroInput();
        if (a == 0) return 0;
        if (a > type(uint256).max / WAD) revert WadMulOverflow();
        unchecked {
            result = (a * WAD) / b;
        }
    }

    // ========================================================================
    // CORE FUNCTIONS
    // ========================================================================

    /// @notice Returns the n-th Fibonacci number in WAD
    /// @dev Uses iterative computation. F(0) = 0, F(1) = 1, F(2) = 1, ...
    ///      The raw Fibonacci number is multiplied by WAD before returning.
    ///      Maximum index is 93 (F(93) * WAD fits uint256).
    /// @param n The Fibonacci index (0-based)
    /// @return The n-th Fibonacci number scaled to WAD
    function fibonacci(uint256 n) internal pure returns (uint256) {
        if (n > MAX_FIB_INDEX) revert FibonacciIndexTooLarge(n, MAX_FIB_INDEX);
        if (n == 0) return 0;
        if (n == 1) return WAD;

        uint256 a = 0;
        uint256 b = 1;

        unchecked {
            for (uint256 i = 2; i <= n; ++i) {
                uint256 temp = a + b;
                a = b;
                b = temp;
            }
        }

        // b holds F(n). Scale to WAD.
        if (b > type(uint256).max / WAD) revert WadMulOverflow();
        unchecked {
            return b * WAD;
        }
    }

    /// @notice Returns the raw (unscaled) n-th Fibonacci number
    /// @dev Used internally for Zeckendorf decomposition. F(0)=0, F(1)=1, F(2)=1, ...
    /// @param n The Fibonacci index (0-based)
    /// @return The raw Fibonacci number (NOT scaled by WAD)
    function _fibRaw(uint256 n) private pure returns (uint256) {
        if (n == 0) return 0;
        if (n == 1) return 1;
        uint256 a = 0;
        uint256 b = 1;
        unchecked {
            for (uint256 i = 2; i <= n; ++i) {
                uint256 temp = a + b;
                a = b;
                b = temp;
            }
        }
        return b;
    }

    /// @notice Returns φ^n in WAD using fast matrix exponentiation
    /// @dev Uses the identity: [[1,1],[1,0]]^n = [[F(n+1),F(n)],[F(n),F(n-1)]]
    ///      Then φ^n = F(n)*φ + F(n-1), computed entirely in WAD fixed-point.
    ///      Matrix entries are WAD-scaled for precision.
    /// @param n The exponent
    /// @return φ^n in WAD representation
    function phiPow(uint256 n) internal pure returns (uint256) {
        if (n == 0) return WAD;
        if (n == 1) return PHI;
        if (n == 2) return PHI_SQUARED;

        // Matrix [[a,b],[c,d]] starts as identity
        uint256 a = WAD;
        uint256 b = 0;
        uint256 c = 0;
        uint256 d = WAD;

        // Base matrix [[1,1],[1,0]] in WAD
        uint256 ma = WAD;
        uint256 mb = WAD;
        uint256 mc = WAD;
        uint256 md = 0;

        uint256 exp = n;

        // Fast exponentiation via repeated squaring
        while (exp > 0) {
            if (exp & 1 == 1) {
                (a, b, c, d) = _matMul(a, b, c, d, ma, mb, mc, md);
            }
            (ma, mb, mc, md) = _matMul(ma, mb, mc, md, ma, mb, mc, md);
            unchecked {
                exp >>= 1;
            }
        }

        // After M^n: a=F(n+1), b=F(n), c=F(n), d=F(n-1) — all in WAD
        // φ^n = F(n)*φ + F(n-1) = wadMul(b, PHI) + d
        return wadMul(b, PHI) + d;
    }

    /// @notice Returns φ^(-n) = 1/φ^n in WAD
    /// @dev Computed as WAD^2 / phiPow(n) for maximum precision.
    /// @param n The exponent (positive)
    /// @return φ^(-n) in WAD representation
    function phiInvPow(uint256 n) internal pure returns (uint256) {
        if (n == 0) return WAD;
        if (n == 1) return PHI_INV;
        // For large n, φ^(-n) underflows to 0. Cap at n=86 where φ^86 > 2^127.
        // Beyond this, wadDiv(WAD, phiPow(n)) rounds to 0 anyway, and
        // phiPow(n) may overflow in matrix multiplication for n > ~170.
        if (n > 86) return 0;

        uint256 phiN = phiPow(n);
        if (phiN == 0) return 0;
        return wadDiv(WAD, phiN);
    }

    /// @notice Token emission for a given epoch
    /// @dev emission(epoch) = F(epoch % 100) * φ^(-(epoch / 100))
    ///      Creates a Fibonacci-patterned emission that decays by golden ratio
    ///      every 100 epochs — a beautiful deflationary curve.
    /// @param epoch The epoch number (0-indexed)
    /// @return The emission amount in WAD
    function fibEmission(uint256 epoch) internal pure returns (uint256) {
        uint256 fibIndex = epoch % 100;
        uint256 decayPeriod = epoch / 100;

        // Cap fibIndex to MAX_FIB_INDEX for safety
        if (fibIndex > MAX_FIB_INDEX) fibIndex = MAX_FIB_INDEX;

        uint256 baseFib = fibonacci(fibIndex);
        if (baseFib == 0) return 0;

        uint256 decay = phiInvPow(decayPeriod);
        return wadMul(baseFib, decay);
    }

    /// @notice Staking APY for a given epoch
    /// @dev APY(epoch) = φ^(-(epoch+1))
    ///      Starts at 1/φ ≈ 61.8% and decreases by factor 1/φ each epoch.
    ///      This is the natural "golden decay" — each epoch's APY relates to
    ///      the previous by the golden ratio.
    /// @param epoch The epoch number (0-indexed)
    /// @return The APY in WAD (e.g., 0.618 * WAD = 61.8%)
    function fibStakingAPY(uint256 epoch) internal pure returns (uint256) {
        return phiInvPow(epoch + 1);
    }

    /// @notice Zeckendorf decomposition — represents n as sum of non-consecutive Fibonacci numbers
    /// @dev Every positive integer has a unique Zeckendorf representation (Zeckendorf's theorem).
    ///      Uses the greedy algorithm: repeatedly subtract the largest F(k) <= remaining.
    ///      Returns indices of the Fibonacci numbers used (NOT the values themselves).
    /// @param n The number to decompose (must be > 0, NOT WAD-scaled — raw integer)
    /// @return indices Array of Fibonacci indices in decreasing order (no two consecutive)
    function zeckendorf(uint256 n) internal pure returns (uint256[] memory indices) {
        if (n == 0) revert ZeckendorfZeroInput();

        // Temporary storage (max ~93 entries for uint256 range)
        uint256[] memory temp = new uint256[](MAX_FIB_INDEX + 1);
        uint256 count = 0;
        uint256 remaining = n;

        while (remaining > 0) {
            // Find largest Fibonacci number <= remaining via linear scan
            uint256 bestVal = 1;
            uint256 bestIdx = 1;

            if (remaining >= 1) {
                uint256 prevA = 0;
                uint256 prevB = 1;

                for (uint256 i = 2; i <= MAX_FIB_INDEX;) {
                    unchecked {
                        uint256 next = prevA + prevB;
                        if (next > remaining) break;
                        bestVal = next;
                        bestIdx = i;
                        prevA = prevB;
                        prevB = next;
                        ++i;
                    }
                }
            }

            temp[count] = bestIdx;
            unchecked {
                remaining -= bestVal;
                ++count;
            }
        }

        // Copy to correctly-sized array
        indices = new uint256[](count);
        for (uint256 i = 0; i < count;) {
            indices[i] = temp[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Calculates a golden-ratio-based fee for AMM operations
    /// @dev fee = amount / φ^phi_level
    ///      Level 0: 100% (full fee), Level 1: ~61.8%, Level 2: ~38.2%, etc.
    ///      Each level reduces the fee by factor 1/φ, following the golden spiral.
    /// @param amount The base amount in WAD
    /// @param phiLevel The phi-level of the user (higher = lower fee)
    /// @return fee The calculated fee in WAD
    function goldenFee(uint256 amount, uint256 phiLevel) internal pure returns (uint256 fee) {
        if (amount == 0) return 0;
        uint256 divisor = phiPow(phiLevel);
        fee = wadDiv(amount, divisor);
    }

    // ========================================================================
    // PHYSICS: Paper VI-VII Derived Functions (2026-04-09)
    // ========================================================================

    /// @notice Reactor neutrino angle: sin²θ₁₃ = φ⁻⁸ + φ⁻¹⁵
    /// @dev Leading φ⁻⁸ from Cl(6) spinor dim, sub-leading φ⁻¹⁵ from 3-form ladder.
    ///      Same φ⁻⁸ controls burn rate, dark energy, χ mixing (P<10⁻⁵).
    ///      Experimental: 0.02200 ± 0.00069, prediction: 0.02202 (0.048%)
    /// @return sin2theta13 sin²θ₁₃ in WAD
    function sin2Theta13() internal pure returns (uint256 sin2theta13) {
        sin2theta13 = phiInvPow(8) + phiInvPow(15);
    }

    /// @notice Higgs CP-violation correction: Δλ_H = 1/(24φ⁸)
    /// @dev = [V_Art(0)]²/4! where V_Art(0) = 1/φ⁴ and 24 = (N_gen+1)!
    ///      Connects Higgs quartic coupling to neutrino CP violation.
    ///      Higgs-Flavor Identity: J²_CP(lep) ≈ Δλ_H (ratio = 1.048)
    ///      Zenodo: Paper VII (DOI: 10.5281/zenodo.19480973)
    /// @return correction Δλ_H in WAD
    function higgsCorrection() internal pure returns (uint256 correction) {
        uint256 phi8 = phiPow(8);
        correction = wadDiv(WAD, 24 * phi8);
    }

    /// @notice Higgs quartic coupling: λ_H = (π + 6φ⁹)/(24πφ⁸)
    /// @dev = φ/(4π) + 1/(24φ⁸). First term = tree-level, second = CP correction.
    ///      Predicts M_H = 125.251 GeV (0.0007% = 0.005σ from experiment).
    ///      6 = N_gen! = 3!, 24 = (N_gen+1)! = 4!
    /// @param piWad π in WAD representation (3_141592653589793238)
    /// @return lambdaH The Higgs quartic coupling in WAD
    function higgsQuarticCoupling(uint256 piWad) internal pure returns (uint256 lambdaH) {
        // Tree: φ/(4π)
        uint256 treeTerm = wadDiv(PHI, 4 * piWad);
        // CP correction: 1/(24φ⁸)
        uint256 cpTerm = higgsCorrection();
        lambdaH = treeTerm + cpTerm;
    }

    /// @notice M_Z normalization factor: √(8(8φ−3))
    /// @dev From spectral action on Cl(9,1). 8φ−3 = V_Art gauge factor.
    ///      M_Z = M_Pl · φ^{−1393/18} / √(8(8φ−3))
    ///      Zenodo: Paper VI-b (DOI: 10.5281/zenodo.19480597)
    /// @return norm The normalization factor in WAD
    function mzNormFactor() internal pure returns (uint256 norm) {
        // 8φ − 3 = 8×PHI/WAD − 3 → in WAD: 8*PHI − 3*WAD
        uint256 inner = 8 * PHI - 3 * WAD; // (8φ−3) in WAD
        uint256 product = 8 * inner;        // 8(8φ−3) in WAD (extra WAD factor)
        // Normalize: product is 8*(8*PHI - 3*WAD) = 8*PHI*8 - 8*3*WAD
        // But we need wadMul semantics. product/WAD = 8(8φ−3) as number.
        // √(product/WAD) in WAD = √(product) * √(WAD)
        // Use Babylonian method for sqrt in WAD
        norm = _wadSqrt(product);
    }

    // ========================================================================
    // PRIVATE HELPERS
    // ========================================================================

    /// @notice Integer square root (Babylonian method) for WAD values
    /// @dev Returns √(x * WAD) to maintain WAD precision
    function _wadSqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        // We want √(x) in WAD: result = √(x × WAD)
        uint256 scaled = x * WAD;
        uint256 z = scaled;
        uint256 y = (z + 1) / 2;
        while (y < z) {
            z = y;
            y = (z + scaled / z) / 2;
        }
        return z;
    }

    /// @notice 2x2 matrix multiplication in WAD arithmetic
    /// @dev Computes [[a,b],[c,d]] * [[e,f],[g,h]] where all entries are WAD-scaled
    function _matMul(
        uint256 a, uint256 b, uint256 c, uint256 d,
        uint256 e, uint256 f, uint256 g, uint256 h
    ) private pure returns (uint256, uint256, uint256, uint256) {
        return (
            wadMul(a, e) + wadMul(b, g),
            wadMul(a, f) + wadMul(b, h),
            wadMul(c, e) + wadMul(d, g),
            wadMul(c, f) + wadMul(d, h)
        );
    }
}
