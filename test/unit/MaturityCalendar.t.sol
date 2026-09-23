// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MaturityCalendar} from "../../src/libraries/MaturityCalendar.sol";
import {CalendarHarness} from "../utils/CalendarHarness.sol";
import {Test} from "forge-std/Test.sol";

contract MaturityCalendarTest is Test {
    uint32 internal constant MATURITY = 7200; // 2h, 32 buckets of 225s
    uint32 internal constant BUCKET_WIDTH = MATURITY / uint32(MaturityCalendar.BUCKETS);

    CalendarHarness internal cal;

    function setUp() public {
        cal = new CalendarHarness(MATURITY);
    }

    /*//////////////////////////////////////////////////////////////
                                 BASICS
    //////////////////////////////////////////////////////////////*/

    function test_freshPositionHasZeroWeight() public {
        cal.open(1000, 1e18);
        assertEq(cal.effectiveLiquidity(1000), 0, "age zero must carry zero weight");
    }

    function test_weightRampsThenSaturates() public {
        cal.open(0, 1e18);
        assertEq(cal.effectiveLiquidity(0), 0);
        assertApproxEqRel(cal.effectiveLiquidity(MATURITY / 2), 0.5e18, 0.05e18);
        cal.sync(MATURITY * 2);
        assertEq(cal.effectiveLiquidity(MATURITY * 2), 1e18, "must saturate at full weight");
        cal.sync(MATURITY * 10);
        assertEq(cal.effectiveLiquidity(MATURITY * 10), 1e18, "must not keep growing");
    }

    function test_maturityIsSnappedUpOntoTheGrid() public {
        cal.open(1, 1e18);
        (,, uint32 maturityRt,,) = cal.entries(0);
        assertEq(maturityRt % BUCKET_WIDTH, 0, "maturity must land on a bucket boundary");
        assertGe(maturityRt, 1 + MATURITY, "never matures early");
        assertLt(maturityRt, 1 + MATURITY + BUCKET_WIDTH, "never matures more than one bucket late");
    }

    function test_crossingRecordsExactlyOneEpochPerSync() public {
        cal.open(0, 1e18);
        cal.open(BUCKET_WIDTH * 2, 1e18); // a different bucket
        assertEq(cal.epochCount(), 0);

        cal.sync(MATURITY * 3); // both mature in one sweep
        assertEq(cal.epochCount(), 1, "one sync should mint exactly one snapshot");
        assertEq(cal.bitmap(), 0, "bitmap must be empty once everything matured");
        assertEq(cal.matureLiquidity(), 2e18);
    }

    function test_closingEmptiesTheBucket() public {
        uint256 i = cal.open(0, 1e18);
        assertTrue(cal.bitmap() != 0, "bucket should be flagged");
        cal.close(i, 100);
        assertEq(cal.bitmap(), 0, "bucket flag must clear when it empties");
        assertEq(cal.effectiveLiquidity(MATURITY * 2), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        AGAINST THE DEFINITION
    //////////////////////////////////////////////////////////////*/

    /// @dev The O(1) accumulators must agree with a direct evaluation of
    ///      `sum_i L_i * min(1, age_i / D_i)` at every point in time.
    function testFuzz_matchesBruteForce(uint32[8] memory offsets, uint96[8] memory sizes, uint32 probe) public {
        uint32 t;
        for (uint256 i; i < 8; ++i) {
            t += uint32(bound(offsets[i], 0, 3 * uint256(BUCKET_WIDTH)));
            cal.open(t, uint128(bound(sizes[i], 1e12, 1e24)));
        }

        uint32 at = uint32(bound(probe, t, uint256(t) + 4 * uint256(MATURITY)));
        cal.sync(at);

        uint256 got = cal.effectiveLiquidity(at);
        uint256 want = cal.bruteForce(at);
        // Each position contributes at most one wei of floor-rounding.
        assertApproxEqAbs(got, want, 8, "accumulators drifted from the definition");
    }

    /// @dev Same, but with positions being closed part-way through, which is where the bucket
    ///      bookkeeping is easiest to get wrong.
    function testFuzz_matchesBruteForceWithClosures(uint32[6] memory offsets, uint96[6] memory sizes, uint8 closeMask)
        public
    {
        uint32 t = 10;
        for (uint256 i; i < 6; ++i) {
            t += uint32(bound(offsets[i], 1, 2 * uint256(BUCKET_WIDTH)));
            cal.open(t, uint128(bound(sizes[i], 1e12, 1e24)));
        }

        uint32 mid = t + MATURITY / 2;
        cal.sync(mid);
        for (uint256 i; i < 6; ++i) {
            if (closeMask & (1 << i) != 0) cal.close(i, mid);
        }

        uint32 at = mid + MATURITY * 2;
        cal.sync(at);
        assertApproxEqAbs(cal.effectiveLiquidity(at), cal.bruteForce(at), 8, "closures corrupted the accumulators");
    }

    /*//////////////////////////////////////////////////////////////
                             BOUNDED WORK
    //////////////////////////////////////////////////////////////*/

    /// @dev A pool left idle for years must not make the next caller pay for the whole gap. The
    ///      crossing loop is bounded by `BUCKETS + 1` regardless of how much time has passed.
    function test_syncIsBoundedAfterLongIdle() public {
        for (uint256 i; i < MaturityCalendar.BUCKETS; ++i) {
            cal.open(uint32(i * BUCKET_WIDTH), 1e18);
        }

        uint256 before = gasleft();
        cal.sync(MATURITY * 5000); // ~1.1 years later
        uint256 used = before - gasleft();

        assertLt(used, 1_500_000, "unbounded catch-up");
        assertEq(cal.bitmap(), 0);
        assertEq(cal.matureLiquidity(), uint128(MaturityCalendar.BUCKETS) * 1e18);
    }

    /// @dev And the *following* sync must not re-walk the skipped range.
    function test_syncAfterIdleIsCheap() public {
        cal.open(0, 1e18);
        cal.sync(MATURITY * 5000);

        uint256 before = gasleft();
        cal.sync(MATURITY * 10_000);
        assertLt(before - gasleft(), 50_000, "second catch-up re-walked the gap");
    }
}
