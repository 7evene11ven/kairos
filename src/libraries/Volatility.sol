// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MathLib} from "./MathLib.sol";

/// @title Volatility
/// @notice Exponentially-weighted realised-variance estimator driven by the pool's own price path.
///
/// @dev Kairos observes the marginal price at most once per block: the pool price at the end of a
///      block is, by construction, the price an arbitrageur was willing to leave it at, and is
///      therefore an (approximately unbiased) sample of the external price at that instant.
///
///      Given consecutive observations `p_{k-1}, p_k` (log prices) taken at `t_{k-1}, t_k`, the
///      per-second variance rate is estimated as
///
///          v_k = lambda * v_{k-1} + (1 - lambda) * (p_k - p_{k-1})^2 / (t_k - t_{k-1})
///
///      i.e. RiskMetrics EWMA on the *variance rate* rather than the squared return, which makes the
///      estimator invariant to irregular sampling — essential here, because blocks without swaps
///      produce no observation and the next sample simply covers a longer interval.
///
///      Two clamps bound an adversary's influence:
///        * `MAX_ABS_LOG_RETURN` caps a single observation's contribution, so pushing the pool price
///          to an extreme cannot spike the estimate by more than `(1 - lambda)` of the cap.
///        * `MIN_SAMPLE_INTERVAL` / `MAX_SAMPLE_INTERVAL` bound the time normalisation.
library Volatility {
    uint256 internal constant WAD = 1e18;

    /// @dev RiskMetrics' canonical daily decay factor, applied per observation.
    uint256 internal constant LAMBDA = 0.94e18;
    uint256 internal constant ONE_MINUS_LAMBDA = WAD - LAMBDA;

    /// @dev A single observation is capped at |log return| = 0.5 (~65% price move).
    uint256 internal constant MAX_ABS_LOG_RETURN = 0.5e18;

    /// @dev Sampling intervals are clamped to [1s, 1h] before normalising.
    uint256 internal constant MIN_SAMPLE_INTERVAL = 1;
    uint256 internal constant MAX_SAMPLE_INTERVAL = 3600;

    /// @notice Folds one observation into the EWMA variance rate.
    /// @param varianceRateWad Current per-second variance rate (WAD).
    /// @param logReturn Signed log return observed over the interval (WAD).
    /// @param interval Seconds elapsed between the two observations.
    /// @return Updated per-second variance rate (WAD).
    function update(uint256 varianceRateWad, int256 logReturn, uint256 interval) internal pure returns (uint256) {
        uint256 m = MathLib.abs(logReturn);
        if (m > MAX_ABS_LOG_RETURN) m = MAX_ABS_LOG_RETURN;
        uint256 dt = MathLib.clamp(interval, MIN_SAMPLE_INTERVAL, MAX_SAMPLE_INTERVAL);

        unchecked {
            // sample = m^2 / dt, in WAD. m <= 0.5e18 so m*m <= 2.5e35 — no overflow.
            uint256 sample = ((m * m) / WAD) / dt;
            return (LAMBDA * varianceRateWad + ONE_MINUS_LAMBDA * sample) / WAD;
        }
    }

    /// @notice Instantaneous volatility per sqrt(second), as a WAD.
    function sigma(uint256 varianceRateWad) internal pure returns (uint256) {
        return MathLib.sqrtWad(varianceRateWad);
    }

    /// @notice Expected magnitude of a log price move over `interval` seconds: `sigma * sqrt(dt)`.
    /// @dev This is the natural scale for every fee bound in the protocol — a "one standard
    ///      deviation block move".
    function scaleOver(uint256 varianceRateWad, uint256 interval) internal pure returns (uint256) {
        uint256 dt = MathLib.clamp(interval, MIN_SAMPLE_INTERVAL, MAX_SAMPLE_INTERVAL);
        // sqrt(varianceRate * dt) == sigma * sqrt(dt), computed in one root for precision.
        return MathLib.sqrtWad(varianceRateWad * dt);
    }

    /// @notice Annualised volatility, as a WAD (e.g. 0.8e18 == 80%/yr). View helper for integrators.
    function annualized(uint256 varianceRateWad) internal pure returns (uint256) {
        // sqrt(varianceRate * secondsPerYear)
        return MathLib.sqrtWad(varianceRateWad * 31_536_000);
    }
}
