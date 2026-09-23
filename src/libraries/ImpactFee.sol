// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {FullMath} from "./FullMath.sol";
import {MathLib} from "./MathLib.sol";

/// @title ImpactFee
/// @notice The Kairos *impact premium*: a swap fee proportional to how far a trade displaces the
///         pool's marginal price from where it started the block.
///
/// @dev Motivation. For a constant-product pool, the value an arbitrageur extracts when the external
///      price moves by `m` (log) over a block is, to second order,
///
///          LVR(m) = V * m^2 / 8
///
///      where `V` is the pool's mark-to-market value. The trade that captures it has notional
///      `~ V*|m|/4`. Setting a proportional fee `gamma` therefore transfers `gamma * V * |m| / 4`
///      back to LPs, and the fee that would exactly offset the loss is `gamma = |m|/2`.
///
///      Charging exactly that would drive arbitrage profit to zero and freeze price discovery, so
///      Kairos charges a *fraction* of it. Define the signed displacement `d = ln(P / P_blockStart)`
///      and the marginal fee rate
///
///          rho(d) = theta * |d|
///
///      A swap that carries the pool from `d0` to `d1` is charged the average of `rho` over that
///      interval. Solving the arbitrageur's optimisation against this schedule (see
///      `docs/WHITEPAPER.md`) gives a clean closed form: it closes only a fraction
///      `1/(1+theta)` of each block's price gap.
///
///      That is *not* the same as recapturing `theta/(1+theta)` of LVR. A pool that tracks more
///      slowly accumulates wider gaps — the gap follows an AR(1) with retention `theta/(1+theta)` —
///      and wider gaps generate more LVR to begin with. Carrying that feedback through gives
///
///          recapture = theta / (1 + 2*theta)
///
///      which saturates at **50%**: no impact premium alone recaptures more than half of
///      loss-versus-rebalancing. `theta = 1` recaptures a third, `theta = 3` about 43%.
///      `sim/kairos_sim.py` reproduces both expressions to within a few basis points.
///
///      Because the charge is the integral of a marginal rate, it is *path-additive*: splitting one
///      swap into many consecutive swaps yields the same total premium (up to the second-order
///      difference between averaging in `d` versus in trade size), so the schedule cannot be gamed
///      by fragmenting a trade. `test/unit/ImpactFee.t.sol` bounds the residual leakage.
///      **Where the cap goes.** The premium needs an upper bound, or a price manipulation could
///      make swapping arbitrarily expensive. Clamping the *charge* would silently destroy
///      path-additivity: the marginal rate of a late fragment exceeds the average rate of the whole
///      trade, so a trader could split, keep every fragment under the clamp and pay strictly less.
///      Kairos therefore clamps the *marginal rate* and integrates that instead,
///
///          rho(d) = theta * min(|d|, dMax),     dMax := cap / theta
///
///      which is bounded by `cap` everywhere and still exactly additive along the displacement path.
library ImpactFee {
    uint256 internal constant WAD = 1e18;

    /// @dev No real pool reaches a log displacement of 100 (a factor of e^100); bounding `dMax`
    ///      keeps the squared terms far away from int256 overflow for very small `theta`.
    uint256 internal constant MAX_DISPLACEMENT = 100e18;

    /// @notice `integral_0^d min(|u|, dMax) du`, an odd, monotonically increasing function of `d`.
    function _antiderivative(int256 d, uint256 dMax) private pure returns (int256) {
        uint256 a = MathLib.abs(d);
        uint256 v;
        unchecked {
            v = a <= dMax ? (a * a) / 2 : (dMax * dMax) / 2 + dMax * (a - dMax);
        }
        // `v` is bounded by dMax * MAX_DISPLACEMENT <= 1e40, far inside int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return d >= 0 ? int256(v) : -int256(v);
    }

    /// @notice Mean marginal rate over the displacement interval `[d0, d1]`, divided by `theta`.
    /// @dev Equal to `(|d0| + |d1|) / 2` in the uncapped, same-sign case; correctly handles a swap
    ///      that carries the price back through the block-start level, and saturates at `dMax`.
    function meanRate(int256 d0, int256 d1, uint256 dMax) internal pure returns (uint256) {
        if (d1 == d0) {
            uint256 a = MathLib.abs(d0);
            return a < dMax ? a : dMax;
        }
        unchecked {
            int256 num = _antiderivative(d1, dMax) - _antiderivative(d0, dMax);
            int256 mean = num / (d1 - d0);
            // The integrand is non-negative and the antiderivative is increasing, so `num` and
            // `d1 - d0` always share a sign. Integer division truncates toward zero, so a defensive
            // clamp is all that is needed.
            // forge-lint: disable-next-line(unsafe-typecast)
            return mean > 0 ? uint256(mean) : 0;
        }
    }

    /// @notice Impact premium for a swap carrying the pool from displacement `d0` to `d1`.
    /// @param d0 Signed log displacement from the block-start price, before the swap (WAD).
    /// @param d1 Signed log displacement from the block-start price, after the swap (WAD).
    /// @param theta Recapture parameter (WAD). `theta / (1 + theta)` of LVR is retained by LPs.
    /// @param cap Upper bound on the marginal rate (WAD), supplied by the volatility oracle.
    /// @return premium_ Fee rate to apply to this swap's output, as a WAD.
    function premium(int256 d0, int256 d1, uint256 theta, uint256 cap) internal pure returns (uint256 premium_) {
        if (theta == 0 || cap == 0) return 0;
        uint256 dMax = FullMath.mulDiv(cap, WAD, theta);
        if (dMax > MAX_DISPLACEMENT) dMax = MAX_DISPLACEMENT;

        premium_ = (theta * meanRate(d0, d1, dMax)) / WAD;
        // `theta * dMax / WAD == cap` up to one wei of rounding; re-clamp so the bound is exact.
        if (premium_ > cap) premium_ = cap;
    }
}
