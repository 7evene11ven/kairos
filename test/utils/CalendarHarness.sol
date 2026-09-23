// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MaturityCalendar} from "../../src/libraries/MaturityCalendar.sol";

/// @notice Wraps {MaturityCalendar} together with a plain list of every position ever opened, so the
///         O(1) accumulators can be checked against a brute-force recomputation.
contract CalendarHarness {
    using MaturityCalendar for MaturityCalendar.State;

    struct Entry {
        uint128 liquidity;
        uint32 startRt;
        uint32 maturityRt;
        uint256 slopeQ64;
        bool closed;
    }

    MaturityCalendar.State internal _state;
    Entry[] public entries;
    uint32 public immutable maturityPeriod;

    constructor(uint32 maturityPeriod_) {
        maturityPeriod = maturityPeriod_;
        _state.initialize(uint32(uint256(maturityPeriod_) / MaturityCalendar.BUCKETS));
    }

    function sync(uint32 rt) public {
        _state.sync(rt, 0, 0, 0, 0);
    }

    function open(uint32 rt, uint128 liquidity) external returns (uint256 index) {
        sync(rt);
        uint32 maturityRt = _state.maturityFor(rt, maturityPeriod);
        uint256 slope = _state.open(liquidity, rt, maturityRt);
        entries.push(Entry(liquidity, rt, maturityRt, slope, false));
        return entries.length - 1;
    }

    function close(uint256 index, uint32 rt) external {
        sync(rt);
        Entry storage e = entries[index];
        require(!e.closed, "already closed");
        if (rt >= e.maturityRt) {
            _state.closeMature(e.liquidity);
        } else {
            _state.closeRamping(e.liquidity, e.slopeQ64, e.startRt, e.maturityRt);
        }
        e.closed = true;
    }

    function effectiveLiquidity(uint32 rt) external view returns (uint256) {
        return _state.effectiveLiquidity(rt);
    }

    /// @notice The definition, computed the slow way: `sum_i L_i * min(1, (rt - t_i) / D_i)`.
    function bruteForce(uint32 rt) external view returns (uint256 total) {
        for (uint256 i; i < entries.length; ++i) {
            Entry storage e = entries[i];
            if (e.closed) continue;
            if (rt >= e.maturityRt) {
                total += e.liquidity;
            } else if (rt > e.startRt) {
                total += (uint256(e.liquidity) * (rt - e.startRt)) / (e.maturityRt - e.startRt);
            }
        }
    }

    function matureLiquidity() external view returns (uint128) {
        return _state.matureLiquidity;
    }

    function bitmap() external view returns (uint64) {
        return _state.bitmap;
    }

    function lastCrossedBucket() external view returns (uint32) {
        return _state.lastCrossedBucket;
    }

    function epochCount() external view returns (uint32) {
        return _state.epochCount;
    }

    function entryCount() external view returns (uint256) {
        return entries.length;
    }
}
