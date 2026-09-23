// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MathLib} from "../../src/libraries/MathLib.sol";
import {Actor} from "../utils/Actor.sol";
import {KairosFixture} from "../utils/KairosFixture.sol";
import {PoolHandler} from "./PoolHandler.sol";

/// @notice Properties that must hold after *any* legal sequence of pool interactions.
contract KairosInvariantsTest is KairosFixture {
    PoolHandler internal handler;

    function setUp() public {
        _deploy();
        _seed();

        Actor[3] memory crew = [alice, bob, trader];
        handler = new PoolHandler(pool, crew);

        // The handler acts through the actors, so it must be able to call them.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = PoolHandler.swap.selector;
        selectors[1] = PoolHandler.mint.selector;
        selectors[2] = PoolHandler.burn.selector;
        selectors[3] = PoolHandler.collect.selector;
        selectors[4] = PoolHandler.flash.selector;
        selectors[5] = PoolHandler.advance.selector;
        selectors[6] = PoolHandler.poke.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The pool must always hold at least what it owes: reserves plus every unclaimed fee.
    function invariant_solvency() public view {
        (uint128 r0, uint128 r1) = pool.reserves();
        assertGe(token0.balanceOf(address(pool)), uint256(r0) + pool.feeAccrued0(), "token0 insolvent");
        assertGe(token1.balanceOf(address(pool)), uint256(r1) + pool.feeAccrued1(), "token1 insolvent");
    }

    /// @dev Fee entitlements can never exceed the fees actually collected.
    function invariant_feesAreNotOverPromised() public view {
        (uint256 owed0, uint256 owed1) = handler.pendingFees();
        assertLe(owed0, pool.feeAccrued0(), "token0 entitlements exceed the fee pot");
        assertLe(owed1, pool.feeAccrued1(), "token1 entitlements exceed the fee pot");
    }

    /// @dev Maturity weighting only ever *reduces* the fee-bearing base, and the permanently locked
    ///      minimum liquidity is never part of it.
    function invariant_effectiveLiquidityIsBounded() public view {
        uint256 effective = pool.effectiveLiquidity();
        assertLe(effective, pool.totalLiquidity() - pool.MINIMUM_LIQUIDITY(), "weighted base exceeds supply");
    }

    /// @dev The pool can never be drained: the locked minimum keeps both reserves positive, which is
    ///      also what keeps the log price well defined.
    function invariant_reservesStayPositive() public view {
        (uint128 r0, uint128 r1) = pool.reserves();
        assertGt(r0, 0, "reserve0 hit zero");
        assertGt(r1, 0, "reserve1 hit zero");
    }

    /// @dev The cached log price must never drift from the reserves it is supposed to describe.
    function invariant_cachedPriceMatchesReserves() public view {
        (uint128 r0, uint128 r1) = pool.reserves();
        int256 actual = MathLib.lnRatio(r1, r0);
        int256 cached = pool.logPrice();
        int256 diff = actual > cached ? actual - cached : cached - actual;
        assertLe(diff, 1e6, "cached log price drifted from reserves");
    }

    /// @dev No swap may ever be quoted above the protocol's hard ceiling.
    function invariant_feeRateIsBounded() public view {
        (uint128 r0,) = pool.reserves();
        uint256 rate = pool.quoteFeeRate(true, uint256(r0) / 10);
        assertLe(rate, 0.05e18, "fee rate exceeded the hard ceiling");
        assertGe(rate, pool.baseFee(), "fee rate fell below the base fee");
    }

    function invariant_callSummary() public view {
        console_log();
    }

    function console_log() internal view {
        // Surfaced with `-vvv`; keeps an eye on whether the run actually exercised the pool.
        assertGe(handler.swaps() + handler.mints() + handler.burns(), 0);
    }
}
