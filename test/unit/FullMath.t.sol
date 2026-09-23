// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {FullMath} from "../../src/libraries/FullMath.sol";
import {MathHarness} from "../utils/MathHarness.sol";
import {Test} from "forge-std/Test.sol";

contract FullMathTest is Test {
    MathHarness internal harness = new MathHarness();

    function test_knownValues() public pure {
        assertEq(FullMath.mulDiv(0, 0, 1), 0);
        assertEq(FullMath.mulDiv(10, 20, 4), 50);
        // The whole point: a product that overflows 256 bits, divided back down.
        assertEq(FullMath.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
        assertEq(FullMath.mulDiv(2 ** 255, 2, 2 ** 255), 2);
    }

    function test_revertsOnOverflow() public {
        vm.expectRevert(FullMath.FullMathOverflow.selector);
        harness.mulDiv(type(uint256).max, type(uint256).max, 1);
    }

    function test_revertsOnZeroDenominator() public {
        vm.expectRevert(FullMath.FullMathDivByZero.selector);
        harness.mulDiv(1, 1, 0);
    }

    /// @dev When the product fits in 256 bits, `mulDiv` must agree with plain arithmetic.
    function testFuzz_agreesWithNativeWhenNoOverflow(uint128 a, uint128 b, uint128 d) public pure {
        vm.assume(d > 0);
        assertEq(FullMath.mulDiv(a, b, d), (uint256(a) * uint256(b)) / uint256(d));
    }

    function testFuzz_identity(uint256 a, uint256 b) public pure {
        vm.assume(b > 0);
        assertEq(FullMath.mulDiv(a, b, b), a);
    }

    /// @dev `mulDivUp` differs from `mulDiv` by exactly one when — and only when — the division is
    ///      inexact.
    function testFuzz_roundsUpOnlyWhenInexact(uint128 a, uint128 b, uint128 d) public pure {
        vm.assume(d > 0);
        uint256 down = FullMath.mulDiv(a, b, d);
        uint256 up = FullMath.mulDivUp(a, b, d);
        bool exact = mulmod(a, b, d) == 0;
        assertEq(up, exact ? down : down + 1);
    }

    /// @dev `result * d + (a*b mod d) == a*b`, verified in modular arithmetic against two coprime
    ///      moduli. Passing both makes an incorrect `result` overwhelmingly unlikely without needing
    ///      a full 512-bit reconstruction in the test itself.
    function testFuzz_satisfiesTheDivisionIdentity(uint256 a, uint256 b, uint256 d) public view {
        vm.assume(d > 0);
        uint256 result;
        try harness.mulDiv(a, b, d) returns (uint256 r) {
            result = r;
        } catch {
            return; // quotient not representable; covered by test_revertsOnOverflow
        }
        uint256 rem = mulmod(a, b, d);
        unchecked {
            assertEq(result * d + rem, a * b, "identity fails mod 2^256");
        }
        uint256 m = type(uint256).max; // 2^256 - 1, coprime to 2^256
        assertEq(addmod(mulmod(result, d, m), rem % m, m), mulmod(a, b, m), "identity fails mod 2^256-1");
    }

    function testFuzz_monotonicInNumerator(uint128 a, uint128 delta, uint128 b, uint128 d) public pure {
        vm.assume(d > 0);
        // Keep `a + delta` inside uint128 so the quotient stays representable; the overflow path is
        // covered separately by test_revertsOnOverflow.
        delta = uint128(bound(delta, 0, type(uint128).max - a));
        assertLe(FullMath.mulDiv(a, b, d), FullMath.mulDiv(uint256(a) + delta, b, d));
    }
}
