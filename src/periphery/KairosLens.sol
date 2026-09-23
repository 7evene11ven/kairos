// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IKairosPool, IVolatilityFeed} from "../interfaces/IKairosPool.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title KairosLens
/// @notice Read-only aggregation for front ends, risk dashboards and anyone consuming Kairos pools
///         as a volatility feed.
/// @dev Stateless and unprivileged; safe to deploy once per chain and call from anywhere.
contract KairosLens {
    struct PoolView {
        address pool;
        address token0;
        address token1;
        uint128 reserve0;
        uint128 reserve1;
        uint128 totalLiquidity;
        uint256 effectiveLiquidity;
        int256 logPrice;
        int256 blockDisplacement;
        uint256 baseFee;
        uint256 theta;
        uint32 maturityPeriod;
        uint256 varianceRate;
        uint256 sigmaPerSqrtSecond;
        uint256 annualizedVolatility;
        uint256 currentFeeFloor;
        uint128 feeAccrued0;
        uint128 feeAccrued1;
    }

    function poolView(address pool) public view returns (PoolView memory v) {
        IKairosPool p = IKairosPool(pool);
        (uint128 r0, uint128 r1) = p.reserves();
        v = PoolView({
            pool: pool,
            token0: p.token0(),
            token1: p.token1(),
            reserve0: r0,
            reserve1: r1,
            totalLiquidity: p.totalLiquidity(),
            effectiveLiquidity: p.effectiveLiquidity(),
            logPrice: p.logPrice(),
            blockDisplacement: p.blockDisplacement(),
            baseFee: p.baseFee(),
            theta: p.theta(),
            maturityPeriod: p.maturityPeriod(),
            varianceRate: p.varianceRate(),
            sigmaPerSqrtSecond: p.sigmaPerSqrtSecond(),
            annualizedVolatility: p.annualizedVolatility(),
            currentFeeFloor: p.quoteFeeRate(true, 1),
            feeAccrued0: p.feeAccrued0(),
            feeAccrued1: p.feeAccrued1()
        });
    }

    function poolViews(address[] calldata pools) external view returns (PoolView[] memory out) {
        out = new PoolView[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            out[i] = poolView(pools[i]);
        }
    }

    /// @notice Marginal price as a WAD (`token1` per `token0`), derived from reserves.
    function spotPrice(address pool) external view returns (uint256) {
        (uint128 r0, uint128 r1) = IKairosPool(pool).reserves();
        return (uint256(r1) * 1e18) / r0;
    }

    /// @notice Fraction of loss-versus-rebalancing this pool's `theta` is expected to retain, as a
    ///         WAD: `theta / (1 + 2*theta)`.
    /// @dev Accounts for the equilibrium feedback — a slower-tracking pool accumulates wider gaps,
    ///      which generate more LVR — and therefore saturates at 50%, not at 100%.
    function expectedLvrRecapture(address pool) external view returns (uint256) {
        uint256 theta = IKairosPool(pool).theta();
        return (theta * 1e18) / (1e18 + 2 * theta);
    }

    /// @notice Fraction of an external price gap the pool closes per block, as a WAD: `1/(1+theta)`.
    function expectedTrackingRatio(address pool) external view returns (uint256) {
        uint256 theta = IKairosPool(pool).theta();
        return (1e18 * 1e18) / (1e18 + theta);
    }

    /// @notice Annualised LVR a constant-product pool would suffer at the current realised
    ///         volatility, absent any fee: `sigma^2 / 8` per unit time, as a WAD.
    /// @dev The headline number Kairos exists to shrink. Multiply by pool value for a dollar figure.
    function annualizedLvrRate(address pool) external view returns (uint256) {
        uint256 variance = IVolatilityFeed(pool).varianceRate(); // per second, WAD
        return (variance * 31_536_000) / 8;
    }

    /// @notice Quotes a swap through several pools by walking them in order.
    /// @dev Each hop is quoted against *current* reserves, so this is exact for a single hop and an
    ///      upper bound for multi-hop (it ignores the price impact earlier hops would leave behind
    ///      in pools that share a token). Use it for display, not for settlement.
    function quotePath(address[] calldata pools, bool[] calldata directions, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        amountOut = amountIn;
        for (uint256 i; i < pools.length; ++i) {
            (amountOut,) = IKairosPool(pools[i]).quote(directions[i], amountOut);
        }
    }
}
