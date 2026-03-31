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
    // PRIVATE HELPERS
    // ========================================================================

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
