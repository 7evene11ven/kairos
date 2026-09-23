// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IKairosMintCallback, IKairosSwapCallback} from "../src/interfaces/IKairosCallbacks.sol";
import {KairosFixture} from "./utils/KairosFixture.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Measures the hot paths and asserts ceilings, so a change that quietly doubles the cost of
///         a swap fails CI instead of shipping.
/// @dev Calls the pool directly (rather than through an actor) so the reported numbers are the ones
///      an integrator would actually pay.
contract GasTest is KairosFixture, IKairosMintCallback, IKairosSwapCallback {
    function setUp() public {
        _deploy();
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        pool.initialize(1_000_000e18, 1_000_000e18, address(this), "seed", "1");
        _skip(MATURITY * 2);
    }

    function kairosMintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        if (a0 > 0) token0.transfer(msg.sender, a0);
        if (a1 > 0) token1.transfer(msg.sender, a1);
    }

    function kairosSwapCallback(address tokenIn, uint256 amountIn, bytes calldata) external {
        MockERC20(tokenIn).transfer(msg.sender, amountIn);
    }

    function test_gasReport() public {
        // Cold path: the first swap the pool has seen in a long time. Every storage slot it touches
        // is cold, and the maturity calendar has buckets waiting to be crossed.
        _nextBlock();
        uint256 g = gasleft();
        pool.swap(true, 1000e18, 0, address(this), "1");
        uint256 coldSwap = g - gasleft();

        // Second swap in the same block: no epoch roll, no calendar work, everything warm.
        g = gasleft();
        pool.swap(true, 1000e18, 0, address(this), "1");
        uint256 sameBlockSwap = g - gasleft();

        // Warm the pool the way an active market would, then measure the first swap of a block —
        // the number that actually recurs.
        for (uint256 i; i < 6; ++i) {
            _nextBlock();
            pool.swap(i % 2 == 0, 1000e18, 0, address(this), "1");
        }
        _nextBlock();
        g = gasleft();
        pool.swap(true, 1000e18, 0, address(this), "1");
        uint256 firstSwap = g - gasleft();

        g = gasleft();
        pool.mint(address(this), "p", 100_000e18, "1");
        uint256 mintGas = g - gasleft();

        _skip(MATURITY * 2);
        _nextBlock();
        pool.swap(false, 1000e18, 0, address(this), "1");

        g = gasleft();
        pool.burn("p", 50_000e18, address(this));
        uint256 burnGas = g - gasleft();

        g = gasleft();
        pool.collect("p", address(this));
        uint256 collectGas = g - gasleft();

        console2.log("swap  (cold pool)       ", coldSwap);
        console2.log("swap  (first of block)  ", firstSwap);
        console2.log("swap  (same block)      ", sameBlockSwap);
        console2.log("mint                    ", mintGas);
        console2.log("burn                    ", burnGas);
        console2.log("collect                 ", collectGas);

        // Ceilings, not targets. Generous enough not to be brittle, tight enough to catch a
        // regression that matters.
        assertLt(coldSwap, 260_000, "cold swap regressed");
        assertLt(firstSwap, 130_000, "first-of-block swap regressed");
        assertLt(sameBlockSwap, 60_000, "same-block swap regressed");
        assertLt(mintGas, 340_000, "mint regressed");
        assertLt(burnGas, 200_000, "burn regressed");
        assertLt(collectGas, 100_000, "collect regressed");
    }
}
