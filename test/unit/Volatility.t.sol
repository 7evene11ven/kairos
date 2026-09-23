// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MathLib} from "../../src/libraries/MathLib.sol";
import {Volatility} from "../../src/libraries/Volatility.sol";
import {Test} from "forge-std/Test.sol";

contract VolatilityTest is Test {
    uint256 internal constant WAD = 1e18;

    function test_zeroReturnDecaysTowardZero() public pure {
        uint256 v = 1e12;
        for (uint256 i; i < 200; ++i) {
            v = Volatility.update(v, 0, 12);
        }
        assertLt(v, 1e12 / 1000, "estimate should decay when the price stops moving");
    }

    /// @dev Fed a constant-magnitude return at a constant interval, the EWMA must converge to the
    ///      variance *rate* `m^2 / dt`.
    function test_convergesToTrueVarianceRate() public pure {
        int256 m = 0.005e18; // 0.5% log move
        uint256 dt = 12;
        uint256 target = ((uint256(m) * uint256(m)) / WAD) / dt;

        uint256 v;
        for (uint256 i; i < 400; ++i) {
            v = Volatility.update(v, i % 2 == 0 ? m : -m, dt);
        }
        assertApproxEqRel(v, target, 0.001e18, "EWMA did not converge to m^2/dt");
    }

    /// @dev Sampling irregularly must not bias the estimate: the same total variance delivered in
    ///      one long step or several short ones should read the same.
    function test_isInvariantToSamplingInterval() public pure {
        // varianceRate = 1e-6 per second (1e12 as a WAD), realised over 12s and over 48s.
        int256 short_ = int256(MathLib.sqrtWad(1e12 * 12));
        int256 long_ = int256(MathLib.sqrtWad(1e12 * 48));

        uint256 a;
        uint256 b;
        for (uint256 i; i < 400; ++i) {
            a = Volatility.update(a, short_, 12);
            b = Volatility.update(b, long_, 48);
        }
        assertApproxEqRel(a, b, 0.01e18, "estimate depends on sampling cadence");
    }

    function test_clampsExtremeObservations() public pure {
        uint256 capped = Volatility.update(0, int256(Volatility.MAX_ABS_LOG_RETURN), 12);
        uint256 absurd = Volatility.update(0, 50e18, 12);
        assertEq(capped, absurd, "an extreme move must not exceed the clamped contribution");
    }

    function test_clampsSamplingInterval() public pure {
        assertEq(Volatility.update(0, 1e15, 0), Volatility.update(0, 1e15, 1), "dt must floor at 1s");
        assertEq(
            Volatility.update(0, 1e15, 10 days),
            Volatility.update(0, 1e15, Volatility.MAX_SAMPLE_INTERVAL),
            "dt must ceil at MAX_SAMPLE_INTERVAL"
        );
    }

    function testFuzz_updateIsBounded(uint80 v, int72 m, uint32 dt) public pure {
        uint256 maxSample = ((Volatility.MAX_ABS_LOG_RETURN * Volatility.MAX_ABS_LOG_RETURN) / WAD);
        uint256 next = Volatility.update(v, m, dt);
        // The new estimate is a convex combination of the old one and a bounded sample.
        assertLe(next, MathLib.max(v, maxSample), "EWMA escaped its inputs");
    }

    /// @dev Annualisation is just a change of units; a 12s sigma of 5bps should read as a plausible
    ///      crypto-like annual volatility.
    function test_annualizedMatchesHandCalculation() public pure {
        // sigma * sqrt(12s) = 5e-4  =>  varianceRate = (5e-4)^2 / 12
        uint256 varianceRate = ((0.0005e18 * 0.0005e18) / WAD) / 12;
        uint256 annual = Volatility.annualized(varianceRate);
        // sqrt(31_536_000 / 12) * 5e-4 ~= 0.811
        assertApproxEqRel(annual, 0.811e18, 0.01e18);
    }
}
