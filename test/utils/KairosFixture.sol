// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {KairosFactory} from "../../src/KairosFactory.sol";
import {KairosPool} from "../../src/KairosPool.sol";
import {Actor} from "./Actor.sol";
import {MockERC20} from "./MockERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared scaffolding: a factory, a token pair, a pool and a bench of funded actors.
abstract contract KairosFixture is Test {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant BASE_FEE = 0.0005e18; // 5 bps
    uint256 internal constant THETA = 1e18; // 50% LVR recapture
    uint32 internal constant MATURITY = 2 hours;
    bool internal constant BLOCK_SCOPED = true;

    KairosFactory internal factory;
    KairosPool internal pool;
    MockERC20 internal token0;
    MockERC20 internal token1;

    Actor internal alice; // long-term LP
    Actor internal bob; // second LP / JIT attacker
    Actor internal trader;

    function _deploy() internal {
        _deploy(BASE_FEE, THETA, MATURITY, BLOCK_SCOPED);
    }

    function _deploy(uint256 baseFee, uint256 theta, uint32 maturity, bool blockScoped) internal {
        // A realistic starting clock so relative-time arithmetic is exercised away from zero.
        vm.warp(1_735_689_600); // 2025-01-01T00:00:00Z
        vm.roll(21_500_000);

        factory = new KairosFactory();
        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);

        if (!factory.configEnabled(factory.configId(baseFee, theta, maturity, blockScoped))) {
            factory.enableConfig(baseFee, theta, maturity, blockScoped);
        }
        pool = KairosPool(factory.createPool(address(a), address(b), baseFee, theta, maturity, blockScoped));

        token0 = MockERC20(pool.token0());
        token1 = MockERC20(pool.token1());

        alice = new Actor(pool);
        bob = new Actor(pool);
        trader = new Actor(pool);

        _fund(address(alice));
        _fund(address(bob));
        _fund(address(trader));
    }

    function _fund(address who) internal {
        token0.mint(who, 1e30);
        token1.mint(who, 1e30);
    }

    /// @dev Seeds a 1:1 pool with 1,000,000 of each token, owned by `alice`.
    function _seed() internal returns (uint128 liquidity) {
        liquidity = alice.initialize(1_000_000e18, 1_000_000e18, "seed");
    }

    /*//////////////////////////////////////////////////////////////
                                  CLOCK
    //////////////////////////////////////////////////////////////*/

    /// @dev Advances one block. Kairos keys its price epoch off `block.number`, so tests that want
    ///      a fresh block-start price must use this rather than `vm.warp` alone.
    function _nextBlock() internal {
        _nextBlock(12);
    }

    function _nextBlock(uint256 secs) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + secs);
    }

    /// @dev Advances `secs` seconds across a plausible number of 12-second blocks.
    function _skip(uint256 secs) internal {
        vm.roll(block.number + (secs / 12) + 1);
        vm.warp(block.timestamp + secs);
    }

    /*//////////////////////////////////////////////////////////////
                                 ASSERTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The pool must always hold at least its reserves plus every unclaimed fee.
    function _assertSolvent() internal view {
        (uint128 r0, uint128 r1) = pool.reserves();
        assertGe(token0.balanceOf(address(pool)), uint256(r0) + pool.feeAccrued0(), "token0 insolvent");
        assertGe(token1.balanceOf(address(pool)), uint256(r1) + pool.feeAccrued1(), "token1 insolvent");
    }

    function _k() internal view returns (uint256) {
        (uint128 r0, uint128 r1) = pool.reserves();
        return uint256(r0) * uint256(r1);
    }

    function _reserves() internal view returns (uint256, uint256) {
        (uint128 r0, uint128 r1) = pool.reserves();
        return (r0, r1);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
