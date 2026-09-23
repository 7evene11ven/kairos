// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title FullMath
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value
///         without any loss of precision, by carrying the 512-bit intermediate product.
/// @dev Implementation follows Remco Bloemen's `mulmod` trick (MIT licensed), as popularised by
///      Uniswap V3. Rewritten for Solidity >=0.8 with explicit `unchecked` blocks and custom errors.
library FullMath {
    error FullMathOverflow();
    error FullMathDivByZero();

    /// @notice Calculates `floor(a * b / denominator)` with full precision.
    /// @dev Reverts if the result overflows a uint256 or the denominator is zero.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b.
            uint256 prod0; // least significant 256 bits
            uint256 prod1; // most significant 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases: 256 by 256 division.
            if (prod1 == 0) {
                if (denominator == 0) revert FullMathDivByZero();
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // The result must fit in 256 bits.
            if (denominator <= prod1) revert FullMathOverflow();

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of the denominator.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                // Flip `twos` such that it is 2**256 / twos.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert `denominator` mod 2**256 using Newton-Raphson. Correct for four bits, then
            // double the correct bits each step: 8, 16, 32, 64, 128, 256.
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
        }
    }

    /// @notice Calculates `ceil(a * b / denominator)` with full precision.
    function mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) != 0) {
            unchecked {
                if (result == type(uint256).max) revert FullMathOverflow();
                result += 1;
            }
        }
    }
}
