// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {FullMath} from "./FullMath.sol";

/// @title MathLib
/// @notice Fixed-point primitives used across Kairos: integer square roots, WAD square roots and
///         base-2 / natural logarithms accurate to ~1e-17 absolute over the full representable range.
/// @dev All "WAD" quantities are 18-decimal fixed point. Logarithms are returned as signed WADs.
///      Log accuracy is validated against a 50-decimal `mpmath` reference in `test/unit/MathLib.t.sol`.
library MathLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TWO_WAD = 2e18;

    /// @dev ln(2) in WAD, correctly rounded.
    int256 internal constant LN2_WAD = 693_147_180_559_945_309;

    error LogUndefined();
    error SqrtOverflow();

    /*//////////////////////////////////////////////////////////////
                              BIT UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Index of the most significant bit of `x`, i.e. `floor(log2(x))`.
    /// @dev Reverts (via `LogUndefined`) when `x == 0`.
    function msb(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) revert LogUndefined();
        assembly {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            r := or(r, shl(2, lt(0xf, shr(r, x))))
            r := or(r, shl(1, lt(0x3, shr(r, x))))
            r := or(r, lt(0x1, shr(r, x)))
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ROOTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `floor(sqrt(x))` for arbitrary uint256 `x`.
    /// @dev Seeds Newton's method from a power of two derived from the MSB, which puts the initial
    ///      guess within a factor of two of the root. Eight iterations then give >256 bits of
    ///      precision (error squares each step), and a final correction guarantees the floor.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        unchecked {
            z = uint256(1) << ((msb(x) >> 1) + 1);
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            uint256 zd = x / z;
            if (z > zd) z = zd;
        }
    }

    /// @notice Square root of a WAD-scaled number, returned as a WAD.
    function sqrtWad(uint256 x) internal pure returns (uint256) {
        if (x > type(uint256).max / WAD) revert SqrtOverflow();
        return sqrt(x * WAD);
    }

    /*//////////////////////////////////////////////////////////////
                               LOGARITHMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Base-2 logarithm of a WAD-scaled number, returned as a signed WAD.
    /// @dev For `x < WAD` the identity `log2(x) = -log2(WAD^2 / x)` is used so the core routine only
    ///      ever handles `x >= WAD`. The fractional part is recovered by repeated squaring: each of
    ///      the 59 iterations resolves one additional bit of the mantissa.
    function log2Wad(uint256 x) internal pure returns (int256) {
        if (x == 0) revert LogUndefined();

        bool negate;
        if (x < WAD) {
            negate = true;
            x = FullMath.mulDiv(WAD, WAD, x);
        }

        unchecked {
            // Integer part: floor(log2(x / WAD)).
            uint256 n = msb(x / WAD);
            uint256 result = n * WAD;

            // Mantissa in [WAD, 2*WAD).
            uint256 y = x >> n;
            if (y != WAD) {
                for (uint256 delta = WAD >> 1; delta > 0; delta >>= 1) {
                    y = (y * y) / WAD;
                    if (y >= TWO_WAD) {
                        result += delta;
                        y >>= 1;
                    }
                }
            }
            // `result` is bounded by 256 * WAD (the widest possible integer part plus a fractional
            // part below WAD), so the int256 cast cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            return negate ? -int256(result) : int256(result);
        }
    }

    /// @notice Natural logarithm of a WAD-scaled number, returned as a signed WAD.
    function lnWad(uint256 x) internal pure returns (int256) {
        unchecked {
            // |log2Wad| <= 256e18 and LN2_WAD < 1e18, so the product stays far inside int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (log2Wad(x) * LN2_WAD) / int256(WAD);
        }
    }

    /// @notice `ln(numerator / denominator)` as a signed WAD, without materialising the ratio in WAD
    ///         when it would overflow.
    /// @dev Used on the swap hot path where `numerator`/`denominator` are raw token reserves.
    function lnRatio(uint256 numerator, uint256 denominator) internal pure returns (int256) {
        if (numerator == 0 || denominator == 0) revert LogUndefined();
        if (numerator == denominator) return 0;
        // ln(n/d) = ln(n) - ln(d); computing the WAD ratio directly keeps full precision for the
        // near-unity ratios that dominate real swaps, and mulDiv absorbs the intermediate overflow.
        if (numerator > denominator) {
            return lnWad(FullMath.mulDiv(numerator, WAD, denominator));
        }
        return -lnWad(FullMath.mulDiv(denominator, WAD, numerator));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function abs(int256 x) internal pure returns (uint256) {
        unchecked {
            // Both branches are exact in two's complement, including x == type(int256).min where
            // the unchecked negation yields the correct magnitude 2^255.
            // forge-lint: disable-next-line(unsafe-typecast)
            return x >= 0 ? uint256(x) : uint256(-x);
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }
}
