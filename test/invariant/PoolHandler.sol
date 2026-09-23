// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {KairosPool} from "../../src/KairosPool.sol";
import {Actor} from "../utils/Actor.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Drives a Kairos pool through random but always-legal sequences of user actions, and
///         records enough shadow state for the invariant contract to check conservation properties.
contract PoolHandler is CommonBase, StdCheats, StdUtils {
    KairosPool public immutable pool;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    Actor[3] public actors;
    bytes32[3] internal salts = [bytes32("a"), bytes32("b"), bytes32("c")];

    /// @dev Liquidity each actor currently holds under its salt, mirrored so the handler never
    ///      attempts an illegal burn (which would just be a wasted run).
    mapping(uint256 => uint128) public heldLiquidity;

    uint256 public totalCollected0;
    uint256 public totalCollected1;
    uint256 public swaps;
    uint256 public mints;
    uint256 public burns;

    constructor(KairosPool pool_, Actor[3] memory actors_) {
        pool = pool_;
        token0 = MockERC20(pool_.token0());
        token1 = MockERC20(pool_.token1());
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (uint256 idx, Actor a) {
        idx = seed % 3;
        a = actors[idx];
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amountIn) external {
        (, Actor a) = _actor(actorSeed);
        (uint128 r0, uint128 r1) = pool.reserves();
        uint256 reserveIn = zeroForOne ? r0 : r1;
        amountIn = bound(amountIn, 1e12, reserveIn / 4);
        try a.swap(zeroForOne, amountIn) {
            swaps++;
        } catch {}
    }

    function mint(uint256 actorSeed, uint256 liquidity) external {
        (uint256 idx, Actor a) = _actor(actorSeed);
        if (heldLiquidity[idx] != 0) return; // one open position per salt
        liquidity = bound(liquidity, 1e15, 5_000_000e18);
        try a.mint(salts[idx], uint128(liquidity)) {
            heldLiquidity[idx] = uint128(liquidity);
            mints++;
        } catch {}
    }

    function burn(uint256 actorSeed, uint256 fraction) external {
        (uint256 idx, Actor a) = _actor(actorSeed);
        uint128 held = heldLiquidity[idx];
        if (held == 0) return;
        uint128 amount = uint128(bound(fraction, 1, held));
        try a.burn(salts[idx], amount) {
            heldLiquidity[idx] = held - amount;
            burns++;
        } catch {}
    }

    function collect(uint256 actorSeed) external {
        (uint256 idx, Actor a) = _actor(actorSeed);
        try a.collect(salts[idx]) returns (uint128 c0, uint128 c1) {
            totalCollected0 += c0;
            totalCollected1 += c1;
            if (heldLiquidity[idx] == 0) {
                // The pool deletes emptied positions, so the salt becomes reusable.
            }
        } catch {}
    }

    function flash(uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        (, Actor a) = _actor(actorSeed);
        (uint128 r0, uint128 r1) = pool.reserves();
        amount0 = bound(amount0, 0, r0 / 2);
        amount1 = bound(amount1, 0, r1 / 2);
        try a.flash(amount0, amount1) {} catch {}
    }

    /// @dev Time and block height must move together, since the pool keys its price epoch off
    ///      `block.number` and its maturity calendar off `block.timestamp`.
    function advance(uint256 blocks, uint256 secondsPerBlock) external {
        uint256 n = bound(blocks, 1, 40);
        uint256 spb = bound(secondsPerBlock, 1, 600);
        vm.roll(block.number + n);
        vm.warp(block.timestamp + n * spb);
    }

    function poke() external {
        try pool.poke() {} catch {}
    }

    function pendingFees() external view returns (uint256 owed0, uint256 owed1) {
        for (uint256 i; i < 3; ++i) {
            (uint256 a0, uint256 a1) = pool.positionFees(address(actors[i]), salts[i]);
            owed0 += a0;
            owed1 += a1;
        }
    }

    function heldLiquidityTotal() external view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) {
            total += heldLiquidity[i];
        }
    }
}
