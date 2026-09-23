// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MathLib} from "../../src/libraries/MathLib.sol";
import {MathFixtures} from "../fixtures/MathFixtures.sol";
import {MathHarness} from "../utils/MathHarness.sol";
import {Test} from "forge-std/Test.sol";

contract MathLibTest is Test {
    uint256 internal constant WAD = 1e18;

    /// @dev Absolute tolerance on log outputs, in WAD units (1e-15 of a log unit).
    int256 internal constant LN_TOLERANCE = 1000;

    MathHarness internal harness = new MathHarness();

    /*//////////////////////////////////////////////////////////////
                                  MSB
    //////////////////////////////////////////////////////////////*/

    function test_msb_knownValues() public pure {
        assertEq(MathLib.msb(1), 0);
        assertEq(MathLib.msb(2), 1);
        assertEq(MathLib.msb(3), 1);
        assertEq(MathLib.msb(255), 7);
        assertEq(MathLib.msb(256), 8);
        assertEq(MathLib.msb(type(uint256).max), 255);
    }

    function testFuzz_msb_bracketsValue(uint256 x) public pure {
        vm.assume(x > 0);
        uint256 b = MathLib.msb(x);
        assertGe(x, uint256(1) << b, "below lower bracket");
        if (b < 255) assertLt(x, uint256(1) << (b + 1), "above upper bracket");
    }

    function test_msb_revertsOnZero() public {
        vm.expectRevert(MathLib.LogUndefined.selector);
        harness.msb(0);
    }

    /*//////////////////////////////////////////////////////////////
                                 SQRT
    //////////////////////////////////////////////////////////////*/

    function test_sqrt_knownValues() public pure {
        assertEq(MathLib.sqrt(0), 0);
        assertEq(MathLib.sqrt(1), 1);
        assertEq(MathLib.sqrt(4), 2);
        assertEq(MathLib.sqrt(8), 2);
        assertEq(MathLib.sqrt(9), 3);
        assertEq(MathLib.sqrt(1e18), 1e9);
        assertEq(MathLib.sqrt(type(uint256).max), 340_282_366_920_938_463_463_374_607_431_768_211_455);
    }

    /// @dev The defining property of an integer square root: z^2 <= x < (z+1)^2.
    function testFuzz_sqrt_isExactFloor(uint256 x) public pure {
        uint256 z = MathLib.sqrt(x);
        assertLe(z * z, x, "z^2 > x");
        if (z < type(uint128).max) {
            assertGt((z + 1) * (z + 1), x, "(z+1)^2 <= x");
        }
    }

    function test_sqrtWad_fixtures() public pure {
        uint256[2][12] memory v = MathFixtures.sqrt();
        for (uint256 i; i < v.length; ++i) {
            uint256 got = MathLib.sqrtWad(v[i][0]);
            uint256 want = v[i][1];
            uint256 diff = got > want ? got - want : want - got;
            // sqrtWad floors; the reference rounds half-even, so at most one ulp apart.
            assertLe(diff, 1, "sqrtWad off by more than 1 wei");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              LOGARITHMS
    //////////////////////////////////////////////////////////////*/

    function test_lnWad_matchesReference() public pure {
        int256[2][28] memory v = MathFixtures.ln();
        for (uint256 i; i < v.length; ++i) {
            int256 got = MathLib.lnWad(uint256(v[i][0]));
            int256 want = v[i][1];
            int256 diff = got > want ? got - want : want - got;
            assertLe(diff, LN_TOLERANCE, "lnWad outside tolerance");
        }
    }

    function test_lnWad_oneIsZero() public pure {
        assertEq(MathLib.lnWad(WAD), 0);
        assertEq(MathLib.log2Wad(WAD), 0);
    }

    function test_log2Wad_powersOfTwo() public pure {
        assertEq(MathLib.log2Wad(2 * WAD), int256(WAD));
        assertEq(MathLib.log2Wad(4 * WAD), 2 * int256(WAD));
        assertEq(MathLib.log2Wad(WAD / 2), -int256(WAD));
    }

    function test_lnWad_revertsOnZero() public {
        vm.expectRevert(MathLib.LogUndefined.selector);
        harness.lnWad(0);
    }

    function testFuzz_lnWad_isMonotonic(uint256 a, uint256 b) public pure {
        a = bound(a, 1, type(uint128).max);
        b = bound(b, 1, type(uint128).max);
        if (a > b) (a, b) = (b, a);
        // Equal inputs must give equal outputs; strictly larger inputs must not decrease.
        assertLe(MathLib.lnWad(a), MathLib.lnWad(b), "ln is not monotonic");
    }

    /// @dev The functional equation `ln(a) + ln(b) == ln(a*b)` is an independent check that does not
    ///      rely on any precomputed table. Inputs are kept within [0.1, 1000] so that the WAD
    ///      truncation of `a*b` — not the logarithm — is not what dominates the residual.
    function testFuzz_lnWad_productRule(uint256 a, uint256 b) public pure {
        a = bound(a, 1e17, 1e21);
        b = bound(b, 1e17, 1e21);
        int256 lhs = MathLib.lnWad(a) + MathLib.lnWad(b);
        int256 rhs = MathLib.lnWad((a * b) / WAD);
        int256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        assertLe(diff, 5000, "product rule violated");
    }

    /// @dev `lnRatio(n, d)` must agree with `ln(n) - ln(d)`. Comparing against
    ///      `lnWad(n * WAD / d)` instead would be testing the *reference*, whose truncation error
    ///      explodes when the quotient lands near zero.
    function testFuzz_lnRatio_matchesLogDifference(uint256 n, uint256 d) public pure {
        n = bound(n, 1, type(uint128).max);
        d = bound(d, 1, type(uint128).max);
        int256 got = MathLib.lnRatio(n, d);
        int256 want = MathLib.lnWad(n) - MathLib.lnWad(d);
        int256 diff = got > want ? got - want : want - got;
        assertLe(diff, 3000, "lnRatio disagrees with the difference of logs");
    }

    function test_lnRatio_symmetry() public pure {
        assertEq(MathLib.lnRatio(3e18, 7e18), -MathLib.lnRatio(7e18, 3e18));
        assertEq(MathLib.lnRatio(5, 5), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_clamp(uint256 x, uint256 lo, uint256 hi) public pure {
        vm.assume(lo <= hi);
        uint256 c = MathLib.clamp(x, lo, hi);
        assertGe(c, lo);
        assertLe(c, hi);
        if (x >= lo && x <= hi) assertEq(c, x);
    }
}
