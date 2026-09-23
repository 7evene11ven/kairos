// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ImpactFee} from "../../src/libraries/ImpactFee.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {Test} from "forge-std/Test.sol";

contract ImpactFeeTest is Test {
    uint256 internal constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////
                             CLOSED FORMS
    //////////////////////////////////////////////////////////////*/

    function test_meanRate_isMidpointWhenUncapped() public pure {
        uint256 big = type(uint128).max;
        assertEq(ImpactFee.meanRate(0, 1e15, big), 5e14, "0 -> d should average d/2");
        assertEq(ImpactFee.meanRate(1e15, 3e15, big), 2e15, "same-sign average is the midpoint");
        assertEq(ImpactFee.meanRate(-1e15, -3e15, big), 2e15, "sign of the interval must not matter");
    }

    /// @dev A swap that carries the price back through the block-open level still pays, at the
    ///      average of |d| over the crossing: (a^2 + b^2) / (2(a+b)).
    function test_meanRate_handlesSignCrossing() public pure {
        uint256 big = type(uint128).max;
        // From -1e15 to +3e15: (1e30 + 9e30) / (2 * 4e15) = 1.25e15
        assertEq(ImpactFee.meanRate(-1e15, 3e15, big), 1.25e15);
        assertEq(ImpactFee.meanRate(3e15, -1e15, big), 1.25e15, "must be orientation independent");
    }

    function test_meanRate_saturatesAtCap() public pure {
        // Entirely beyond the clamp: the marginal rate is dMax everywhere.
        assertEq(ImpactFee.meanRate(2e15, 4e15, 1e15), 1e15);
        // Straddling the clamp: half the path below it, half above.
        assertLt(ImpactFee.meanRate(0, 2e15, 1e15), 1e15);
        assertGt(ImpactFee.meanRate(0, 2e15, 1e15), 0);
    }

    function testFuzz_meanRate_neverExceedsCap(int128 d0, int128 d1, uint128 dMax) public pure {
        vm.assume(dMax > 0);
        assertLe(ImpactFee.meanRate(d0, d1, dMax), dMax, "mean rate exceeded its clamp");
    }

    function testFuzz_premium_neverExceedsCap(int128 d0, int128 d1, uint256 theta, uint256 cap) public pure {
        theta = bound(theta, 1, 8e18);
        cap = bound(cap, 0, 0.02e18);
        assertLe(ImpactFee.premium(d0, d1, theta, cap), cap, "premium exceeded its cap");
    }

    /*//////////////////////////////////////////////////////////////
                             PATH ADDITIVITY
    //////////////////////////////////////////////////////////////*/

    /// @dev The property the whole design rests on: the charge for `d0 -> d1` equals the charge for
    ///      `d0 -> dm` plus `dm -> d1`, so no trader can profit by fragmenting a trade. Holds even
    ///      when the clamp is active, which is the entire reason the clamp lives on the *marginal*
    ///      rate rather than on the charge.
    function testFuzz_pathAdditivity(int72 a, int72 b, int72 c, uint128 dMax) public pure {
        vm.assume(dMax > 0);
        int256 d0 = a;
        int256 dm = b;
        int256 d1 = c;
        // Order the three points so `dm` genuinely lies between the endpoints.
        if (d0 > d1) (d0, d1) = (d1, d0);
        vm.assume(dm > d0 && dm < d1);

        uint256 whole = ImpactFee.meanRate(d0, d1, dMax) * uint256(d1 - d0);
        uint256 first = ImpactFee.meanRate(d0, dm, dMax) * uint256(dm - d0);
        uint256 second = ImpactFee.meanRate(dm, d1, dMax) * uint256(d1 - dm);

        // Each `meanRate` floors one division, so the split can undershoot by at most the length of
        // each leg — a bound that is vanishing relative to the integral itself.
        assertLe(first + second, whole + uint256(d1 - d0), "split overcharged");
        assertGe(first + second + 2 * uint256(d1 - d0), whole, "split undercharged beyond rounding");
    }

    /// @dev Same statement, expressed the way a trader would exploit it: N equal fragments must not
    ///      cost materially less than one trade covering the same displacement.
    function testFuzz_fragmentingDoesNotDiscount(uint128 span, uint8 pieces, uint128 cap) public pure {
        uint256 d = bound(span, 1e12, 1e20);
        uint256 n = bound(pieces, 2, 32);
        // Real caps are at least 5 bps (5e14). Below ~1e10 the *floor* in each `meanRate` starts to
        // dominate, which is an artefact of the grid rather than a property of the schedule.
        uint256 dMax = bound(cap, 1e10, 1e20);
        d = (d / n) * n;
        vm.assume(d > 0);

        uint256 whole = ImpactFee.meanRate(0, int256(d), dMax) * d;

        uint256 step = d / n;
        uint256 fragmented;
        for (uint256 i; i < n; ++i) {
            fragmented += ImpactFee.meanRate(int256(i * step), int256((i + 1) * step), dMax) * step;
        }

        assertApproxEqRel(fragmented, whole, 0.000001e18, "fragmenting bought a discount");
    }

    /*//////////////////////////////////////////////////////////////
                                THEORY
    //////////////////////////////////////////////////////////////*/

    /// @dev With `theta` the recapture parameter, an arbitrageur closing a gap `m` from a clean
    ///      block start pays `theta * m / 2`. That is the quantity the whitepaper's recapture ratio
    ///      `theta / (1 + theta)` is derived from.
    function testFuzz_premiumEqualsHalfThetaTimesGap(uint96 gap, uint8 thetaMult) public pure {
        uint256 m = bound(gap, 1e12, 1e16);
        uint256 theta = bound(thetaMult, 1, 8) * WAD;
        uint256 cap = 1e18; // effectively unbounded for this range

        uint256 got = ImpactFee.premium(0, int256(m), theta, cap);
        uint256 want = (theta * (m / 2)) / WAD;
        assertApproxEqAbs(got, want, 2, "premium != theta * m / 2");
    }
}
