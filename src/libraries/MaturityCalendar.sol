// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title MaturityCalendar
/// @notice Constant-gas bookkeeping for *maturity-weighted* liquidity.
///
/// @dev Problem. Kairos pays fees in proportion to `liquidity * maturity weight`, where a position
///      minted at `t_i` carries weight
///
///          w_i(t) = min(1, (t - t_i) / D_i)
///
///      This makes just-in-time liquidity worthless: a position minted and burnt inside one block has
///      weight zero and earns nothing, and the fees it would have claimed accrue to everyone else.
///      The catch is that every live position's weight changes every second, so the denominator used
///      to split fees — the total effective liquidity — is a moving target.
///
///      Solution. While a position is ramping, its contribution is *linear in time*:
///
///          L_i * (t - t_i) / D_i  =  a_i * t - a_i * t_i,     a_i := L_i * 2^64 / D_i
///
///      so the whole ramping cohort collapses into two running sums, and matured positions into a
///      third:
///
///          E(t) = ((t * A - B) >> 64) + C
///          A = sum a_i        B = sum a_i * t_i        C = sum L_i (matured)
///
///      The only event that cannot be folded into a running sum is a position *reaching* maturity,
///      which must move it from (A, B) into C. Those are handled exactly like Uniswap V3 handles
///      price ticks — but on the time axis. Maturities are snapped up to a fixed grid of buckets, a
///      bitmap records which buckets hold liquidity, and buckets are crossed lazily when time
///      advances past them. Rounding maturities onto the grid bounds the crossing loop to
///      `BUCKETS + 1` iterations, and it also makes fee settlement *exact*: fee growth only changes
///      when the pool syncs, so the value recorded at crossing time is precisely the value that held
///      at the bucket boundary.
///
///      Buckets are keyed by absolute index in a mapping, so a crossing record is never overwritten
///      and a position can settle arbitrarily far in the future. The 64-bit bitmap is circular,
///      which is safe because live maturities always span at most `BUCKETS + 1 = 33` consecutive
///      indices.
library MaturityCalendar {
    /// @dev Number of buckets spanning one maturity period.
    uint256 internal constant BUCKETS = 32;

    /// @dev Live maturities always fall within this many buckets of the last crossed one.
    uint256 internal constant WINDOW = BUCKETS + 1;

    error BucketNotCrossed();
    error CalendarOverflow();

    /// @notice Fee-growth values captured at the instant a bucket was crossed.
    struct Snapshot {
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 timeWeightedFeeGrowth0X128;
        uint256 timeWeightedFeeGrowth1X128;
    }

    /// @notice Aggregated ramping liquidity that matures inside one bucket.
    struct Bucket {
        uint256 slopeSumQ64; // sum of a_i
        uint256 slopeTimeSumQ64; // sum of a_i * t_i
        uint128 liquiditySum; // sum of L_i
        uint32 crossEpoch; // 0 == not yet crossed; else index into `snapshots`
    }

    struct State {
        uint256 slopeQ64; // A
        uint256 slopeTimeQ64; // B
        uint128 matureLiquidity; // C
        uint32 lastCrossedBucket;
        uint32 epochCount;
        uint64 bitmap; // circular, bit = bucketIndex % 64
        uint32 bucketWidth; // seconds
        mapping(uint256 bucketIndex => Bucket) buckets;
        mapping(uint256 epoch => Snapshot) snapshots;
    }

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function initialize(State storage s, uint32 bucketWidth) internal {
        s.bucketWidth = bucketWidth;
    }

    /*//////////////////////////////////////////////////////////////
                                 READING
    //////////////////////////////////////////////////////////////*/

    /// @notice Total maturity-weighted liquidity eligible for fees at relative time `rt`.
    /// @dev Correct whether or not {sync} has run: any bucket that should have been crossed by `rt`
    ///      but has not been is folded in on the fly. Without that, the ramping term would keep
    ///      growing past 100% weight for positions that are already mature, and a stale read could
    ///      report more eligible liquidity than the pool actually has.
    ///
    ///      On the hot path this costs one extra warm SLOAD: callers sync first, which leaves
    ///      `lastCrossedBucket == rt / bucketWidth` and skips the loop entirely.
    function effectiveLiquidity(State storage s, uint32 rt) internal view returns (uint256) {
        uint256 a = s.slopeQ64;
        uint256 b = s.slopeTimeQ64;
        uint256 c = s.matureLiquidity;

        unchecked {
            uint256 toBucket = uint256(rt) / s.bucketWidth;
            uint256 lastCrossed = s.lastCrossedBucket;
            uint64 bitmap = s.bitmap;

            if (toBucket > lastCrossed && bitmap != 0) {
                uint256 endBucket = lastCrossed + WINDOW;
                if (toBucket < endBucket) endBucket = toBucket;
                for (uint256 i = lastCrossed + 1; i <= endBucket; ++i) {
                    if (bitmap & _bit(i) == 0) continue;
                    Bucket storage bk = s.buckets[i];
                    a -= bk.slopeSumQ64;
                    b -= bk.slopeTimeSumQ64;
                    c += bk.liquiditySum;
                }
            }

            // `rt * A >= B` holds by construction: B accumulates the *same* rounded `a_i` values
            // multiplied by start times that never exceed `rt` for a live ramping position.
            return ((uint256(rt) * a - b) >> 64) + c;
        }
    }

    /// @notice Epoch index recorded when the bucket containing `maturityRt` was crossed, or zero if
    ///         it has not been crossed yet.
    function crossEpochOf(State storage s, uint32 maturityRt) internal view returns (uint32) {
        return s.buckets[uint256(maturityRt) / s.bucketWidth].crossEpoch;
    }

    function snapshotOf(State storage s, uint32 epoch) internal view returns (Snapshot storage) {
        return s.snapshots[epoch];
    }

    /// @notice Maturity timestamp for a position opened at `rt`, snapped up onto the bucket grid.
    function maturityFor(State storage s, uint32 rt, uint32 maturityPeriod) internal view returns (uint32) {
        unchecked {
            uint256 bw = s.bucketWidth;
            uint256 target = uint256(rt) + maturityPeriod;
            uint256 bucket = (target + bw - 1) / bw;
            uint256 maturityRt = bucket * bw;
            if (maturityRt > type(uint32).max) revert CalendarOverflow();
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint32(maturityRt);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 WRITING
    //////////////////////////////////////////////////////////////*/

    /// @notice Advances the calendar to `rt`, moving every newly matured cohort from (A, B) into C.
    /// @dev Must be called *before* any fee is folded into `feeGrowth`, so that the snapshot written
    ///      for a bucket equals the fee growth that actually held at its boundary.
    /// @return crossed True if at least one bucket was crossed.
    function sync(
        State storage s,
        uint32 rt,
        uint256 feeGrowth0X128,
        uint256 feeGrowth1X128,
        uint256 tw0X128,
        uint256 tw1X128
    ) internal returns (bool crossed) {
        unchecked {
            uint256 toBucket = uint256(rt) / s.bucketWidth;
            uint256 lastCrossed = s.lastCrossedBucket;
            if (toBucket <= lastCrossed) return false;

            uint64 bitmap = s.bitmap;
            if (bitmap != 0) {
                // Nothing can mature beyond `lastCrossed + WINDOW`, which bounds this loop.
                uint256 endBucket = lastCrossed + WINDOW;
                if (toBucket < endBucket) endBucket = toBucket;

                // 0 doubles as "no snapshot minted for this sync yet"; explicit for clarity.
                uint32 epoch = 0;
                for (uint256 b = lastCrossed + 1; b <= endBucket; ++b) {
                    uint64 mask = _bit(b);
                    if (bitmap & mask == 0) continue;

                    if (epoch == 0) {
                        epoch = ++s.epochCount;
                        Snapshot storage snap = s.snapshots[epoch];
                        snap.feeGrowth0X128 = feeGrowth0X128;
                        snap.feeGrowth1X128 = feeGrowth1X128;
                        snap.timeWeightedFeeGrowth0X128 = tw0X128;
                        snap.timeWeightedFeeGrowth1X128 = tw1X128;
                        crossed = true;
                    }

                    Bucket storage bk = s.buckets[b];
                    s.slopeQ64 -= bk.slopeSumQ64;
                    s.slopeTimeQ64 -= bk.slopeTimeSumQ64;
                    s.matureLiquidity += bk.liquiditySum;

                    bk.slopeSumQ64 = 0;
                    bk.slopeTimeSumQ64 = 0;
                    bk.liquiditySum = 0;
                    bk.crossEpoch = epoch;

                    bitmap &= ~mask;
                }
                s.bitmap = bitmap;
            }

            // Safe to jump straight to `toBucket`: everything in (endBucket, toBucket] was empty.
            // `toBucket = rt / bucketWidth` with `rt` a uint32, so it always fits.
            // forge-lint: disable-next-line(unsafe-typecast)
            s.lastCrossedBucket = uint32(toBucket);
        }
    }

    /// @notice Registers a freshly minted, still-ramping position.
    /// @return slopeQ64 The position's `a_i`, which the caller must store for exact settlement.
    function open(State storage s, uint128 liquidity, uint32 startRt, uint32 maturityRt)
        internal
        returns (uint256 slopeQ64)
    {
        unchecked {
            slopeQ64 = (uint256(liquidity) << 64) / (uint256(maturityRt) - startRt);
            s.slopeQ64 += slopeQ64;
            s.slopeTimeQ64 += slopeQ64 * startRt;

            uint256 b = uint256(maturityRt) / s.bucketWidth;
            Bucket storage bk = s.buckets[b];
            bk.slopeSumQ64 += slopeQ64;
            bk.slopeTimeSumQ64 += slopeQ64 * startRt;
            bk.liquiditySum += liquidity;
            s.bitmap |= _bit(b);
        }
    }

    /// @notice Removes part (or all) of a position that has *not* yet matured.
    function closeRamping(State storage s, uint128 liquidity, uint256 slopeQ64, uint32 startRt, uint32 maturityRt)
        internal
    {
        unchecked {
            s.slopeQ64 -= slopeQ64;
            s.slopeTimeQ64 -= slopeQ64 * startRt;

            uint256 b = uint256(maturityRt) / s.bucketWidth;
            Bucket storage bk = s.buckets[b];
            bk.slopeSumQ64 -= slopeQ64;
            bk.slopeTimeSumQ64 -= slopeQ64 * startRt;
            bk.liquiditySum -= liquidity;

            if (bk.liquiditySum == 0 && bk.slopeSumQ64 == 0) {
                s.bitmap &= ~(_bit(b));
            }
        }
    }

    /// @notice Removes part (or all) of a position that has already matured.
    function closeMature(State storage s, uint128 liquidity) internal {
        unchecked {
            s.matureLiquidity -= liquidity;
        }
    }

    /// @dev Circular bitmap position for an absolute bucket index. Live maturities span at most
    ///      `WINDOW = 33` consecutive indices, so a 64-slot ring cannot alias.
    function _bit(uint256 bucketIndex) private pure returns (uint64) {
        // `bucketIndex & 63 < 64`, so the shift amount fits a uint64 exactly.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(1) << uint64(bucketIndex & 63);
    }

    /// @notice Marks liquidity as permanently mature without an associated position.
    /// @dev Unused by the pool today; kept for integrations that seed protocol-owned liquidity.
    function seedMature(State storage s, uint128 liquidity) internal {
        unchecked {
            s.matureLiquidity += liquidity;
        }
    }
}
