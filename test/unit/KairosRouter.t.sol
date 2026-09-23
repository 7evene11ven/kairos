// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {KairosPool} from "../../src/KairosPool.sol";
import {KairosLens} from "../../src/periphery/KairosLens.sol";
import {KairosRouter} from "../../src/periphery/KairosRouter.sol";
import {KairosFixture} from "../utils/KairosFixture.sol";
import {MockERC20} from "../utils/MockERC20.sol";

contract KairosRouterTest is KairosFixture {
    KairosRouter internal router;
    KairosLens internal lens;

    address internal user = address(0xBEEF);

    KairosPool internal poolB; // shares token1 with `pool`, for multi-hop
    MockERC20 internal token2;

    function setUp() public {
        _deploy();
        _seed();
        _skip(MATURITY * 2);

        router = new KairosRouter();
        lens = new KairosLens();

        token0.mint(user, 1e27);
        token1.mint(user, 1e27);

        vm.startPrank(user);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _deploySecondPool() internal {
        token2 = new MockERC20("Token C", "C", 18);
        poolB =
            KairosPool(factory.createPool(address(token1), address(token2), BASE_FEE, THETA, MATURITY, BLOCK_SCOPED));

        token2.mint(user, 1e27);
        vm.startPrank(user);
        token2.approve(address(router), type(uint256).max);
        router.initializePool(
            KairosRouter.InitializeParams({
                pool: address(poolB),
                amount0: 1_000_000e18,
                amount1: 1_000_000e18,
                salt: "seedB",
                owner: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        _skip(MATURITY * 2);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAPS
    //////////////////////////////////////////////////////////////*/

    function test_exactInputSingle() public {
        _nextBlock();
        (uint256 expectedOut,) = pool.quote(true, 1000e18);

        uint256 before = token1.balanceOf(user);
        vm.prank(user);
        uint256 out = router.exactInputSingle(
            KairosRouter.ExactInputSingleParams({
                pool: address(pool),
                zeroForOne: true,
                amountIn: 1000e18,
                amountOutMinimum: 0,
                recipient: user,
                deadline: block.timestamp
            })
        );

        assertEq(out, expectedOut, "router output disagreed with the quote");
        assertEq(token1.balanceOf(user) - before, out);
        _assertSolvent();
    }

    function test_exactInputSingle_respectsSlippage() public {
        _nextBlock();
        (uint256 expectedOut,) = pool.quote(true, 1000e18);

        vm.prank(user);
        vm.expectRevert(KairosRouter.TooLittleReceived.selector);
        router.exactInputSingle(
            KairosRouter.ExactInputSingleParams({
                pool: address(pool),
                zeroForOne: true,
                amountIn: 1000e18,
                amountOutMinimum: expectedOut + 1,
                recipient: user,
                deadline: block.timestamp
            })
        );
    }

    function test_exactInputSingle_respectsDeadline() public {
        _nextBlock();
        vm.prank(user);
        vm.expectRevert(KairosRouter.Expired.selector);
        router.exactInputSingle(
            KairosRouter.ExactInputSingleParams({
                pool: address(pool),
                zeroForOne: true,
                amountIn: 1000e18,
                amountOutMinimum: 0,
                recipient: user,
                deadline: block.timestamp - 1
            })
        );
    }

    function test_multiHop() public {
        _deploySecondPool();
        _nextBlock();

        address[] memory pools = new address[](2);
        pools[0] = address(pool); // token0 -> token1
        pools[1] = address(poolB); // token1 -> token2
        bool[] memory dirs = new bool[](2);
        dirs[0] = true;
        dirs[1] = address(token1) < address(token2);

        uint256 before = token2.balanceOf(user);
        vm.prank(user);
        uint256 out = router.exactInput(
            KairosRouter.ExactInputParams({
                pools: pools,
                directions: dirs,
                amountIn: 1000e18,
                amountOutMinimum: 0,
                recipient: user,
                deadline: block.timestamp
            })
        );

        assertGt(out, 0, "multi-hop produced nothing");
        assertEq(token2.balanceOf(user) - before, out, "recipient did not receive the output");
        // Two hops of ~5bps plus impact: strictly worse than one hop, but in the same ballpark.
        assertLt(out, 1000e18);
        assertGt(out, 995e18);
        // The router must never retain a balance.
        assertEq(token1.balanceOf(address(router)), 0, "router held dust");
    }

    function test_callbackRejectsUnknownCaller() public {
        vm.expectRevert(KairosRouter.UnknownPool.selector);
        router.kairosSwapCallback(address(token0), 1, abi.encode(KairosRouter.SwapCallbackData({payer: user})));
    }

    /*//////////////////////////////////////////////////////////////
                               LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity() public {
        vm.prank(user);
        (uint256 a0, uint256 a1) = router.addLiquidity(
            KairosRouter.AddLiquidityParams({
                pool: address(pool),
                salt: "u1",
                liquidity: 100_000e18,
                amount0Max: type(uint256).max,
                amount1Max: type(uint256).max,
                owner: user,
                deadline: block.timestamp
            })
        );

        assertApproxEqRel(a0, 100_000e18, 0.0001e18);
        assertApproxEqRel(a1, 100_000e18, 0.0001e18);

        // Ownership sits with `user`, so only they can withdraw it.
        vm.prank(user);
        pool.burn("u1", 100_000e18, user);
    }

    function test_addLiquidity_respectsMaxAmounts() public {
        vm.prank(user);
        vm.expectRevert(KairosRouter.TooMuchRequested.selector);
        router.addLiquidity(
            KairosRouter.AddLiquidityParams({
                pool: address(pool),
                salt: "u2",
                liquidity: 100_000e18,
                amount0Max: 1e18,
                amount1Max: type(uint256).max,
                owner: user,
                deadline: block.timestamp
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  LENS
    //////////////////////////////////////////////////////////////*/

    function test_lens_reportsPoolState() public {
        _nextBlock();
        trader.swap(true, 5000e18);

        KairosLens.PoolView memory v = lens.poolView(address(pool));
        assertEq(v.token0, address(token0));
        assertEq(v.baseFee, BASE_FEE);
        assertEq(v.theta, THETA);
        assertEq(v.maturityPeriod, MATURITY);
        assertGt(v.effectiveLiquidity, 0);
        assertEq(v.feeAccrued1, pool.feeAccrued1());
    }

    /// @dev The headline economics, surfaced for dashboards. At theta = 1 the pool closes half of
    ///      each price gap per block and retains a third of LVR — the two differ because a
    ///      slower-tracking pool accumulates wider gaps. See `docs/RESULTS.md`.
    function test_lens_reportsTheoreticalRecapture() public view {
        assertApproxEqRel(lens.expectedLvrRecapture(address(pool)), uint256(1e18) / 3, 0.0001e18);
        assertApproxEqRel(lens.expectedTrackingRatio(address(pool)), 0.5e18, 0.0001e18);
    }

    function test_lens_spotPrice() public view {
        assertApproxEqRel(lens.spotPrice(address(pool)), 1e18, 0.0001e18);
    }
}
