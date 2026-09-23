// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {KairosPool} from "../../src/KairosPool.sol";
import {IKairosPool} from "../../src/interfaces/IKairosPool.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";
import {ImpactFee} from "../../src/libraries/ImpactFee.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {Volatility} from "../../src/libraries/Volatility.sol";
import {Actor} from "../utils/Actor.sol";
import {KairosFixture} from "../utils/KairosFixture.sol";

contract KairosPoolTest is KairosFixture {
    function setUp() public {
        _deploy();
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_setsState() public {
        uint128 liquidity = _seed();

        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 1_000_000e18);
        assertEq(r1, 1_000_000e18);
        assertEq(pool.totalLiquidity(), liquidity + pool.MINIMUM_LIQUIDITY());
        assertEq(pool.logPrice(), 0, "1:1 pool should have log price zero");
        assertEq(pool.varianceRate(), 0);
        _assertSolvent();
    }

    function test_initialize_locksMinimumLiquidity() public {
        uint128 liquidity = _seed();
        // The locked units belong to no position, so they never dilute fee entitlements ...
        _skip(MATURITY * 2);
        pool.poke();
        assertEq(pool.effectiveLiquidity(), liquidity, "locked units must stay out of the fee split");
        // ... but they do stay in the supply, so the pool can never be fully drained.
        assertEq(pool.totalLiquidity() - liquidity, pool.MINIMUM_LIQUIDITY());
    }

    function test_initialize_revertsWhenAlreadySeeded() public {
        _seed();
        vm.expectRevert(IKairosPool.AlreadyInitialized.selector);
        bob.initialize(1e18, 1e18, "x");
    }

    /*//////////////////////////////////////////////////////////////
                                  SWAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Because Kairos takes its fee from the *output* and holds it outside the reserves,
    ///      `reserve0 * reserve1` is exactly invariant under a swap — a stronger statement than the
    ///      "k never decreases" that fee-on-input pools can make.
    function test_swap_preservesInvariantExactly() public {
        _seed();
        _nextBlock();

        uint256 kBefore = _k();
        trader.swap(true, 1000e18);
        uint256 kAfter = _k();

        // Only the rounding of the output (always in the pool's favour) may move k, and only up.
        assertGe(kAfter, kBefore, "k decreased");
        assertLt(kAfter - kBefore, kBefore / 1e12, "k moved by more than rounding dust");
        _assertSolvent();
    }

    function test_swap_outputMatchesConstantProductMinusFee() public {
        _seed();
        _nextBlock();

        uint256 amountIn = 100e18;
        (uint256 r0, uint256 r1) = _reserves();
        uint256 grossOut = FullMath.mulDiv(amountIn, r1, r0 + amountIn);

        (uint256 quotedOut, uint256 quotedRate) = pool.quote(true, amountIn);
        uint256 actualOut = trader.swap(true, amountIn);

        assertEq(actualOut, quotedOut, "quote disagrees with execution");
        assertEq(actualOut, grossOut - FullMath.mulDivUp(grossOut, quotedRate, WAD), "output formula");
    }

    function test_swap_revertsOnSlippage() public {
        _seed();
        _nextBlock();
        vm.expectRevert(IKairosPool.InsufficientOutput.selector);
        trader.swapMin(true, 100e18, 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                            THE IMPACT PREMIUM
    //////////////////////////////////////////////////////////////*/

    /// @dev A trade that barely moves the price is uninformed flow and pays the base fee alone.
    function test_premium_vanishesForNegligibleImpact() public {
        _seed();
        _nextBlock();
        // 1e-10 of the pool: displacement is ~2e-10, premium ~1e-10 -> rounds to nothing.
        assertEq(pool.quoteFeeRate(true, 100_000), BASE_FEE, "dust trade should pay base fee only");
    }

    /// @dev The headline claim: the premium equals `theta * |d| / 2` for a swap starting at the
    ///      block-open price. Compared here against an independent recomputation from reserves.
    function test_premium_matchesClosedForm() public {
        _seed();
        _nextBlock();

        uint256 amountIn = 100e18;
        (uint256 r0, uint256 r1) = _reserves();
        uint256 n0 = r0 + amountIn;
        uint256 n1 = r1 - FullMath.mulDiv(amountIn, r1, n0);

        int256 d1 = MathLib.lnRatio(n1, n0); // block started at d = 0
        uint256 expected = BASE_FEE + (THETA * MathLib.abs(d1) / 2) / WAD;

        assertLt(expected - BASE_FEE, pool.premiumCap(), "test must stay in the uncapped regime");
        assertEq(pool.quoteFeeRate(true, amountIn), expected, "premium != theta * |d| / 2");
    }

    /// @dev Splitting a trade must not buy a discount. The residual is the second-order difference
    ///      between averaging the marginal rate in displacement versus in trade size.
    function test_premium_isSplitProof() public {
        _seed();
        _nextBlock();

        uint256 total = 400e18;

        uint256 snapshot = vm.snapshotState();
        trader.swap(true, total);
        uint256 oneShot = pool.feeAccrued1();
        vm.revertToState(snapshot);

        for (uint256 i; i < 8; ++i) {
            trader.swap(true, total / 8);
        }
        uint256 split = pool.feeAccrued1();

        assertApproxEqRel(split, oneShot, 0.01e18, "splitting moved total fees by more than 1%");
    }

    function testFuzz_premium_splitProof(uint256 amountIn, uint8 pieces) public {
        _seed();
        _nextBlock();
        amountIn = bound(amountIn, 1e18, 300e18);
        uint256 n = bound(pieces, 2, 10);
        amountIn = (amountIn / n) * n; // exact division keeps the two paths comparable

        uint256 snapshot = vm.snapshotState();
        trader.swap(true, amountIn);
        uint256 oneShot = pool.feeAccrued1();
        vm.revertToState(snapshot);

        for (uint256 i; i < n; ++i) {
            trader.swap(true, amountIn / n);
        }
        assertApproxEqRel(pool.feeAccrued1(), oneShot, 0.02e18, "split leaked more than 2%");
    }

    /// @dev The premium is measured against the price the *block* opened at, so the arbitrageur who
    ///      closes an overnight gap pays, and the next block starts clean.
    function test_premium_resetsEachBlock() public {
        _seed();
        _nextBlock();

        trader.swap(true, 200e18);
        assertGt(MathLib.abs(pool.blockDisplacement()), 0, "displacement should be non-zero");
        uint256 rateSameBlock = pool.quoteFeeRate(true, 1e18);

        _nextBlock();
        assertEq(pool.blockDisplacement(), 0, "new block must reset displacement");
        uint256 rateNewBlock = pool.quoteFeeRate(true, 1e18);

        assertGt(rateSameBlock, rateNewBlock, "continuing a displaced block should cost more");
        // A fresh block starts from d = 0, so a dust trade pays the base fee and nothing else.
        assertEq(pool.quoteFeeRate(true, 100_000), BASE_FEE, "a fresh block starts at the base fee");
    }

    /// @dev A swap that pushes the price back toward the block-open level still pays, because the
    ///      premium integrates |d| rather than the signed displacement.
    function test_premium_chargedInBothDirections() public {
        _seed();
        _nextBlock();
        trader.swap(true, 200e18);

        uint256 rateBack = pool.quoteFeeRate(false, 200e18);
        assertGt(rateBack, BASE_FEE, "retracing the block move must still pay a premium");
    }

    /// @dev The marginal rate saturates at the cap, so the *average* rate approaches it from below
    ///      as the trade grows but never exceeds it.
    function test_premium_isCapped() public {
        _seed();
        _nextBlock();
        uint256 cap = pool.premiumCap();

        // A trade worth 20% of the pool: uncapped premium would be ~9%, far above every bound.
        uint256 rate = pool.quoteFeeRate(true, 200_000e18);
        assertLe(rate, BASE_FEE + cap, "premium exceeded the oracle-derived cap");
        assertGt(rate, BASE_FEE + (cap * 99) / 100, "premium should saturate near the cap");

        // And the hard ceiling holds no matter what the oracle says.
        assertLt(rate, 0.05e18);
    }

    /*//////////////////////////////////////////////////////////////
                         SWAP-SCOPED PREMIUM MODE
    //////////////////////////////////////////////////////////////*/

    /// @dev Under the swap-scoped rule a trade is charged for its own price impact and nothing else,
    ///      so a second trade in an already-displaced block pays the same as the first did.
    function test_swapScoped_chargesOnlyOwnImpact() public {
        _deploy(BASE_FEE, THETA, MATURITY, false);
        _seed();
        _nextBlock();

        uint256 first = pool.quoteFeeRate(true, 100e18);
        trader.swap(true, 2000e18); // displace the block considerably
        uint256 second = pool.quoteFeeRate(true, 100e18);

        // Not bit-identical: the earlier swap grew reserve0, so the same notional now moves the
        // price fractionally less. What matters is that the block's displacement contributes nothing.
        assertApproxEqRel(second, first, 0.001e18, "swap-scoped premium must ignore prior displacement");
        assertLt(second, first, "deeper reserves should mean marginally less impact");
        assertGt(first, BASE_FEE, "a price-moving trade still pays");
    }

    /// @dev The two modes agree exactly for the top-of-block trade, which is the one the closed form
    ///      is derived for. They can only differ for flow that follows it.
    function test_premiumModesAgreeAtTopOfBlock() public {
        uint256 snapshot = vm.snapshotState();
        _deploy(BASE_FEE, THETA, MATURITY, true);
        _seed();
        _nextBlock();
        uint256 blockScoped = pool.quoteFeeRate(true, 500e18);
        vm.revertToState(snapshot);

        _deploy(BASE_FEE, THETA, MATURITY, false);
        _seed();
        _nextBlock();
        assertEq(pool.quoteFeeRate(true, 500e18), blockScoped, "modes disagree on the first trade");
    }

    /// @dev Same-block displacement makes the block-scoped rule strictly more expensive.
    function test_blockScopedCostsMoreAfterDisplacement() public {
        uint256 snapshot = vm.snapshotState();

        _deploy(BASE_FEE, THETA, MATURITY, false);
        _seed();
        _nextBlock();
        trader.swap(true, 2000e18);
        uint256 swapScoped = pool.quoteFeeRate(true, 100e18);
        vm.revertToState(snapshot);

        _deploy(BASE_FEE, THETA, MATURITY, true);
        _seed();
        _nextBlock();
        trader.swap(true, 2000e18);
        assertGt(pool.quoteFeeRate(true, 100e18), swapScoped, "block-scoped should price the displacement");
    }

    /*//////////////////////////////////////////////////////////////
                          MATURITY-WEIGHTED FEES
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint, capture a swap and burn inside one block: the classic JIT sandwich. It must earn
    ///      exactly zero, and every fee must land with the LP that was already there.
    function test_jitLiquidityEarnsNothing() public {
        _seed();
        _skip(MATURITY * 2); // alice fully matured
        _nextBlock();

        // Bob front-runs with 10x alice's liquidity.
        uint128 jitLiquidity = pool.totalLiquidity() * 10;
        bob.mint("jit", jitLiquidity);

        trader.swap(true, 5000e18);

        bob.burn("jit", jitLiquidity);
        (uint128 bobFee0, uint128 bobFee1) = bob.collect("jit");

        assertEq(bobFee0, 0, "JIT LP collected token0 fees");
        assertEq(bobFee1, 0, "JIT LP collected token1 fees");

        (, uint128 aliceFee1) = alice.collect("seed");
        assertGt(aliceFee1, 0, "resident LP earned nothing");
        // Everything the swap paid ends up with the LP that was already there, bar rounding dust:
        // entitlements floor, so the pool may retain a few wei that no position can claim.
        assertLe(pool.feeAccrued1(), 4, "more than dust stranded in the pool");
        _assertSolvent();
    }

    /// @dev A half-aged position earns at half weight. With one fully mature LP and one half-aged
    ///      LP of equal size, the split is 2:1.
    function test_maturityRampSplitsFeesByAge() public {
        _seed();
        uint128 seedLiquidity = pool.totalLiquidity() - pool.MINIMUM_LIQUIDITY();

        _skip(MATURITY * 2); // alice: weight 1

        bob.mint("ramp", seedLiquidity);
        _skip(MATURITY / 2); // bob: weight ~0.5
        _nextBlock();

        trader.swap(true, 2000e18);

        (, uint256 aliceOwed1) = pool.positionFees(address(alice), "seed");
        (, uint256 bobOwed1) = pool.positionFees(address(bob), "ramp");

        assertApproxEqRel(aliceOwed1, 2 * bobOwed1, 0.05e18, "expected a 2:1 split at weight 1 vs 0.5");
        assertApproxEqRel(aliceOwed1 + bobOwed1, pool.feeAccrued1(), 0.001e18, "fees leaked");
    }

    /// @dev Weight is monotonically non-decreasing in age and saturates at maturity.
    function test_maturityWeightSaturates() public {
        _seed();
        uint128 seedLiquidity = pool.totalLiquidity() - pool.MINIMUM_LIQUIDITY();
        _skip(MATURITY * 2);

        bob.mint("ramp", seedLiquidity);
        uint256 atMint = pool.effectiveLiquidity();

        _skip(MATURITY / 2);
        pool.poke();
        uint256 atHalf = pool.effectiveLiquidity();

        _skip(MATURITY); // comfortably past bob's snapped maturity
        pool.poke();
        uint256 atFull = pool.effectiveLiquidity();

        _skip(MATURITY * 3);
        pool.poke();
        uint256 muchLater = pool.effectiveLiquidity();

        assertEq(atMint, seedLiquidity, "fresh liquidity must carry zero weight");
        assertApproxEqRel(atHalf, seedLiquidity * 3 / 2, 0.05e18, "half weight expected");
        assertEq(atFull, seedLiquidity * 2, "full weight expected at maturity");
        assertEq(muchLater, atFull, "weight must saturate, not keep growing");
    }

    /// @dev In the same block as the only mint, every position has age zero, so eligible liquidity
    ///      is exactly zero and the fee has nobody to go to. It must be parked, not lost.
    function test_feesAccruedBeforeAnyoneMaturedAreNotLost() public {
        _seed(); // alice mints at t=0 ...
        trader.swap(true, 1000e18); // ... and the swap lands in the very same block

        uint256 parked = pool.feeAccrued1();
        assertGt(parked, 0);
        assertEq(pool.effectiveLiquidity(), 0, "no liquidity should be eligible yet");
        assertEq(pool.feeGrowth1X128(), 0, "fee growth must not move with a zero denominator");
        (, uint256 owedNow) = pool.positionFees(address(alice), "seed");
        assertEq(owedNow, 0, "nothing is claimable while no liquidity is mature");

        // Once alice matures and any further fee arrives, the parked amount flushes through.
        _skip(MATURITY * 2);
        _nextBlock();
        trader.swap(true, 1000e18);

        (, uint256 owedLater) = pool.positionFees(address(alice), "seed");
        assertApproxEqRel(owedLater, pool.feeAccrued1(), 0.001e18, "orphaned fees never reached LPs");
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_mint_thenBurn_returnsCapital() public {
        _seed();
        _skip(MATURITY * 2);

        (uint256 in0, uint256 in1) = bob.mint("p", 100_000e18);
        (uint256 out0, uint256 out1) = bob.burn("p", 100_000e18);

        assertLe(out0, in0, "burn returned more token0 than deposited");
        assertLe(out1, in1, "burn returned more token1 than deposited");
        assertApproxEqRel(out0, in0, 0.000001e18);
        assertApproxEqRel(out1, in1, 0.000001e18);
    }

    function test_mint_rejectsDuplicateSalt() public {
        _seed();
        bob.mint("p", 1000e18);
        vm.expectRevert(IKairosPool.PositionExists.selector);
        bob.mint("p", 1000e18);
    }

    function test_burn_rejectsOverdraw() public {
        _seed();
        bob.mint("p", 1000e18);
        vm.expectRevert(IKairosPool.InsufficientLiquidity.selector);
        bob.burn("p", 1001e18);
    }

    function test_partialBurnOfRampingPositionKeepsWeightProportional() public {
        _seed();
        uint128 seedLiquidity = pool.totalLiquidity() - pool.MINIMUM_LIQUIDITY();
        _skip(MATURITY * 2);

        bob.mint("p", 100_000e18);
        _skip(MATURITY / 2);
        pool.poke();
        uint256 before = pool.effectiveLiquidity();

        bob.burn("p", 50_000e18); // halve it mid-ramp
        uint256 afterBurn = pool.effectiveLiquidity();

        uint256 bobWeightBefore = before - seedLiquidity;
        uint256 bobWeightAfter = afterBurn - seedLiquidity;
        assertApproxEqRel(bobWeightAfter * 2, bobWeightBefore, 0.001e18, "weight did not halve with the position");
    }

    function test_collectDeletesEmptyPosition() public {
        _seed();
        bob.mint("p", 1000e18);
        bob.burn("p", 1000e18);
        bob.collect("p");
        // Slot is cleared, so the salt becomes reusable.
        bob.mint("p", 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                                 FLASH
    //////////////////////////////////////////////////////////////*/

    function test_flash_paysLPs() public {
        _seed();
        _skip(MATURITY * 2);
        pool.poke();

        uint256 growthBefore = pool.feeGrowth0X128();
        trader.flash(10_000e18, 0);

        assertGt(pool.feeGrowth0X128(), growthBefore, "flash fee did not reach LPs");
        assertEq(pool.feeAccrued0(), FullMath.mulDivUp(10_000e18, BASE_FEE, WAD));
        _assertSolvent();
    }

    function test_flash_revertsOnUnderpayment() public {
        _seed();
        trader.setUnderpayFlash(true);
        vm.expectRevert(IKairosPool.InsufficientInput.selector);
        trader.flash(10_000e18, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           VOLATILITY ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @dev Drives a price path and re-derives the EWMA independently from observed log prices.
    ///      This checks the plumbing that is easy to get wrong: which move is folded in, when, and
    ///      over what interval.
    function test_oracle_matchesIndependentEwma() public {
        _seed();

        int256 prevPrice = pool.logPrice();
        uint256 prevTime = block.timestamp;
        int256 pendingMove;
        uint256 pendingInterval;
        uint256 expected;
        bool havePending;

        for (uint256 i; i < 12; ++i) {
            _nextBlock();

            // The pool folds in the *previous* epoch's move when the first swap of a new block lands.
            if (havePending) {
                expected = Volatility.update(expected, pendingMove, pendingInterval);
            }

            trader.swap(i % 2 == 0, 3000e18);

            assertEq(pool.varianceRate(), expected, "oracle disagrees with the reference EWMA");

            int256 price = pool.logPrice();
            pendingMove = price - prevPrice;
            pendingInterval = block.timestamp - prevTime;
            havePending = true;
            prevPrice = price;
            prevTime = block.timestamp;
        }

        assertGt(pool.varianceRate(), 0, "oracle never warmed up");
        assertGt(pool.annualizedVolatility(), 0);
    }

    function test_oracle_isFlatWhenPriceIsFlat() public {
        _seed();
        for (uint256 i; i < 10; ++i) {
            _nextBlock();
            // Round-trip trades leave the price essentially where it started.
            uint256 out = trader.swap(true, 1000e18);
            trader.swap(false, out);
        }
        assertLt(pool.annualizedVolatility(), 0.02e18, "flat price should read as near-zero vol");
    }

    function test_oracle_raisesTheFeeCap() public {
        _seed();
        uint256 coldCap = pool.premiumCap();

        for (uint256 i; i < 20; ++i) {
            _nextBlock();
            trader.swap(i % 2 == 0, 20_000e18);
        }
        _nextBlock();

        assertGt(pool.premiumCap(), coldCap, "a volatile pool should tolerate a larger premium");
    }

    /*//////////////////////////////////////////////////////////////
                              CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Every wei of fee is either owed to a position or still parked as orphaned; the pool must
    ///      never promise more than it holds.
    function test_feeConservation() public {
        _seed();
        _skip(MATURITY * 2);

        bob.mint("b", 250_000e18);
        _skip(MATURITY * 2);

        for (uint256 i; i < 6; ++i) {
            _nextBlock();
            trader.swap(i % 2 == 0, 5000e18);
        }

        (uint256 a0, uint256 a1) = pool.positionFees(address(alice), "seed");
        (uint256 b0, uint256 b1) = pool.positionFees(address(bob), "b");

        assertLe(a0 + b0, pool.feeAccrued0(), "token0 over-promised");
        assertLe(a1 + b1, pool.feeAccrued1(), "token1 over-promised");

        alice.collect("seed");
        bob.collect("b");
        _assertSolvent();
    }

    /// @dev Tokens pushed in outside a swap are credited to LPs, never to the reserves — otherwise a
    ///      donation would move the marginal price and, with it, the volatility oracle.
    function test_donationsGoToLPsNotToPrice() public {
        _seed();
        _skip(MATURITY * 2);
        _nextBlock();

        uint256 snapshot = vm.snapshotState();
        trader.swap(true, 1e18);
        int256 priceWithoutDonation = pool.logPrice();
        uint256 growthWithoutDonation = pool.feeGrowth0X128();
        vm.revertToState(snapshot);

        token0.mint(address(pool), 5000e18);
        trader.swap(true, 1e18);

        assertEq(pool.logPrice(), priceWithoutDonation, "donation moved the marginal price");
        assertGt(pool.feeGrowth0X128(), growthWithoutDonation, "donation did not reach LPs");
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_reentrancyBlocked() public {
        _seed();
        _nextBlock();
        Reenterer attacker = new Reenterer(pool);
        token0.mint(address(attacker), 1e24);
        token1.mint(address(attacker), 1e24);
        vm.expectRevert();
        attacker.attack();
    }
}

/// @notice Attempts to re-enter `swap` from inside the swap callback.
contract Reenterer {
    KairosPool internal immutable pool;
    bool internal entered;

    constructor(KairosPool p) {
        pool = p;
    }

    function attack() external {
        pool.swap(true, 1e18, 0, address(this), "1");
    }

    function kairosSwapCallback(address tokenIn, uint256 amountIn, bytes calldata) external {
        if (!entered) {
            entered = true;
            pool.swap(true, 1e18, 0, address(this), "1");
        }
        (bool ok,) = tokenIn.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amountIn));
        require(ok, "pay failed");
    }
}
