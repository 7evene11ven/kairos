// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IKairosFlashCallback, IKairosMintCallback, IKairosSwapCallback} from "./interfaces/IKairosCallbacks.sol";
import {IKairosPool} from "./interfaces/IKairosPool.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {ImpactFee} from "./libraries/ImpactFee.sol";
import {Lock} from "./libraries/Lock.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {MaturityCalendar} from "./libraries/MaturityCalendar.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {Volatility} from "./libraries/Volatility.sol";

interface IKairosPoolDeployer {
    function parameters()
        external
        view
        returns (
            address token0,
            address token1,
            uint256 baseFee,
            uint256 theta,
            uint32 maturityPeriod,
            bool blockScopedPremium
        );
}

/// @title KairosPool
/// @notice A constant-product AMM that prices the cost it imposes on its own liquidity providers.
///
/// @dev Three mechanisms distinguish Kairos from a classical `x * y = k` pool:
///
///      1. **Impact premium.** Every swap pays `baseFee` plus a premium proportional to how far it
///         displaces the marginal price from where the block started. Because the premium is the
///         integral of a marginal rate over displacement, it cannot be dodged by splitting a trade,
///         and because displacement is exactly what generates loss-versus-rebalancing, it charges
///         informed flow without taxing small uninformed flow. See {ImpactFee}.
///
///      2. **Realised-volatility oracle.** The pool samples its own price once per block and
///         maintains an EWMA variance estimate. That estimate bounds the impact premium (so a price
///         manipulation cannot spike fees) and is exposed publicly as an {IVolatilityFeed}.
///
///      3. **Maturity-weighted fee accrual.** Fees are split in proportion to `liquidity * age`
///         rather than `liquidity`, which makes just-in-time liquidity unprofitable. Forfeited
///         weight is not burnt: it dilutes into the same denominator, so committed LPs are paid
///         more. See {MaturityCalendar}.
///
///      Fees are charged on the *output* token and held outside the reserves. A useful consequence
///      is that `reserve0 * reserve1` is exactly invariant under swaps, so price and displacement are
///      determined by the gross input alone and the fee never feeds back into the quote.
contract KairosPool is IKairosPool {
    using MaturityCalendar for MaturityCalendar.State;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant Q192 = 1 << 192;

    /// @dev Permanently locked at initialization so the pool can never be fully drained.
    uint128 public constant MINIMUM_LIQUIDITY = 1000;

    /// @dev Below this, fee-per-effective-liquidity would lose too much precision; fees are parked
    ///      in the orphan pot and folded into the next distribution instead.
    uint256 internal constant MIN_EFFECTIVE_LIQUIDITY = 1000;

    /// @dev The impact premium is capped at this many standard deviations of a block move.
    uint256 internal constant CAP_SIGMA_MULTIPLE = 4e18;
    uint256 internal constant PREMIUM_CAP_FLOOR = 0.0005e18; // 5 bps
    uint256 internal constant PREMIUM_CAP_CEILING = 0.02e18; // 200 bps
    /// @dev Absolute ceiling on `baseFee + premium`, enforced regardless of oracle state.
    uint256 internal constant MAX_TOTAL_FEE = 0.05e18; // 500 bps

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint256 public immutable baseFee;
    uint256 public immutable theta;
    uint32 public immutable maturityPeriod;
    uint32 public immutable genesis;

    /// @notice What the impact premium measures displacement against.
    ///
    /// @dev `true`  — the price this block opened at. A trade is charged for the pool's *cumulative*
    ///                displacement, which prices the adverse selection of transacting against a pool
    ///                that has already moved a long way this block.
    ///      `false` — the price immediately before the swap. A trade is charged for its *own* price
    ///                impact, and nothing else.
    ///
    ///      Both charge the top-of-block arbitrageur identically: it trades first, so the two
    ///      references coincide. They differ only for flow that follows it inside the same block.
    ///      `docs/RESULTS.md` simulates both; the swap-scoped variant charges uninformed flow less
    ///      and wins more of it, while the block-scoped variant prices something the simulation's
    ///      uninformed-by-construction flow cannot exhibit. The choice is left to the deployer.
    bool public immutable blockScopedPremium;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    struct Reserves {
        uint128 reserve0;
        uint128 reserve1;
    }

    struct Clock {
        uint128 totalLiquidity;
        uint32 lastSyncTime; // relative seconds
        uint32 epochTime; // start of the current price epoch
        uint32 prevEpochTime; // start of the previous price epoch
        uint32 lastBlockNumber; // truncated; only ever compared for equality
    }

    struct Oracle {
        int72 blockStartLogPrice;
        int72 lastLogPrice;
        uint80 varianceRateWad;
    }

    /// @notice Maturity-weighted LP position. Keyed by `keccak256(owner, salt)`.
    struct Position {
        uint128 liquidity;
        uint32 startRt; // ramp origin; never moves once set
        uint32 maturityRt; // snapped onto the calendar grid
        uint32 settledRt; // last settlement
        uint256 slopeQ64; // a_i = liquidity * 2^64 / (maturityRt - startRt)
        uint256 feeGrowth0Last;
        uint256 feeGrowth1Last;
        uint256 timeWeighted0Last;
        uint256 timeWeighted1Last;
        uint128 owed0;
        uint128 owed1;
    }

    Reserves public reserves;
    Clock internal _clock;
    Oracle internal _oracle;

    /// @notice Uncollected fees held outside the reserves.
    uint128 public feeAccrued0;
    uint128 public feeAccrued1;

    /// @dev Fees that arrived while no liquidity was mature enough to receive them.
    uint128 internal _orphan0;
    uint128 internal _orphan1;

    uint256 public feeGrowth0X128;
    uint256 public feeGrowth1X128;
    uint256 public timeWeightedFeeGrowth0X128;
    uint256 public timeWeightedFeeGrowth1X128;

    MaturityCalendar.State internal _calendar;

    mapping(bytes32 positionKey => Position) public positions;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    constructor() {
        factory = msg.sender;
        (address t0, address t1, uint256 fee_, uint256 theta_, uint32 maturity_, bool blockScoped_) =
            IKairosPoolDeployer(msg.sender).parameters();
        token0 = t0;
        token1 = t1;
        baseFee = fee_;
        theta = theta_;
        maturityPeriod = maturity_;
        blockScopedPremium = blockScoped_;
        genesis = uint32(block.timestamp);
        _calendar.initialize(uint32(uint256(maturity_) / MaturityCalendar.BUCKETS));
    }

    modifier lock() {
        Lock.acquire();
        _;
        Lock.release();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function totalLiquidity() public view returns (uint128) {
        return _clock.totalLiquidity;
    }

    function clock() external view returns (Clock memory) {
        return _clock;
    }

    function oracle() external view returns (Oracle memory) {
        return _oracle;
    }

    function logPrice() public view returns (int256) {
        return _oracle.lastLogPrice;
    }

    function varianceRate() public view returns (uint256) {
        return _oracle.varianceRateWad;
    }

    function sigmaPerSqrtSecond() external view returns (uint256) {
        return Volatility.sigma(_oracle.varianceRateWad);
    }

    function annualizedVolatility() external view returns (uint256) {
        return Volatility.annualized(_oracle.varianceRateWad);
    }

    function volatilityOver(uint256 interval) external view returns (uint256) {
        return Volatility.scaleOver(_oracle.varianceRateWad, interval);
    }

    function effectiveLiquidity() external view returns (uint256) {
        return _calendar.effectiveLiquidity(_rt());
    }

    /// @notice Log price the current block started at, accounting for an epoch roll that has not
    ///         been written to storage yet.
    function blockStartLogPrice() public view returns (int256) {
        return uint32(block.number) == _clock.lastBlockNumber ? _oracle.blockStartLogPrice : _oracle.lastLogPrice;
    }

    /// @dev The anchor the impact premium measures displacement from. Under the swap-scoped rule it
    ///      is the current price, which makes `d0 = 0` and leaves the premium a function of the
    ///      swap's own impact.
    function _premiumAnchor() internal view returns (int256) {
        return blockScopedPremium ? blockStartLogPrice() : int256(_oracle.lastLogPrice);
    }

    function blockDisplacement() external view returns (int256) {
        return _oracle.lastLogPrice - blockStartLogPrice();
    }

    /// @notice Upper bound on the impact premium, in WAD.
    function premiumCap() public view returns (uint256) {
        uint32 rt = _rt();
        bool rolled = uint32(block.number) != _clock.lastBlockNumber;
        uint32 anchor = rolled ? _clock.epochTime : _clock.prevEpochTime;
        uint256 gap = rt > anchor ? rt - anchor : 1;
        uint256 cap = (CAP_SIGMA_MULTIPLE * Volatility.scaleOver(_oracle.varianceRateWad, gap)) / WAD;
        return MathLib.clamp(cap, PREMIUM_CAP_FLOOR, PREMIUM_CAP_CEILING);
    }

    /// @notice Exactly the fee rate {swap} would charge for this trade, in WAD.
    function quoteFeeRate(bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        (uint256 r0, uint256 r1) = (reserves.reserve0, reserves.reserve1);
        if (r0 == 0 || r1 == 0 || amountIn == 0) return baseFee;
        (uint256 n0, uint256 n1) = _afterSwap(r0, r1, zeroForOne, amountIn);
        int256 anchor = _premiumAnchor();
        int256 d0 = _oracle.lastLogPrice - anchor;
        int256 d1 = MathLib.lnRatio(n1, n0) - anchor;
        uint256 rate = baseFee + ImpactFee.premium(d0, d1, theta, premiumCap());
        return rate > MAX_TOTAL_FEE ? MAX_TOTAL_FEE : rate;
    }

    /// @notice Simulates a swap without touching state.
    function quote(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut, uint256 feeRate) {
        (uint256 r0, uint256 r1) = (reserves.reserve0, reserves.reserve1);
        if (r0 == 0 || r1 == 0 || amountIn == 0) return (0, baseFee);
        uint256 grossOut =
            zeroForOne ? FullMath.mulDiv(amountIn, r1, r0 + amountIn) : FullMath.mulDiv(amountIn, r0, r1 + amountIn);
        feeRate = quoteFeeRate(zeroForOne, amountIn);
        amountOut = grossOut - FullMath.mulDivUp(grossOut, feeRate, WAD);
    }

    /// @notice Fees a position could collect if it settled right now.
    function positionFees(address owner, bytes32 salt) external view returns (uint256 owed0, uint256 owed1) {
        Position storage p = positions[_key(owner, salt)];
        (uint256 a0, uint256 a1) = _pendingAccrual(p, _rt());
        return (p.owed0 + a0, p.owed1 + a1);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IKairosPool
    function initialize(uint256 amount0, uint256 amount1, address owner, bytes32 salt, bytes calldata data)
        external
        lock
        returns (uint128 liquidity)
    {
        if (_clock.totalLiquidity != 0) revert AlreadyInitialized();
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert Overflow();

        uint256 minted = MathLib.sqrt(amount0 * amount1);
        if (minted <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();
        liquidity = _toUint128(minted - MINIMUM_LIQUIDITY);

        // Both bounded by `type(uint128).max` immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserves = Reserves(uint128(amount0), uint128(amount1));

        uint32 rt = _rt();
        int256 lp = MathLib.lnRatio(amount1, amount0);
        _oracle = Oracle({blockStartLogPrice: _toInt72(lp), lastLogPrice: _toInt72(lp), varianceRateWad: 0});
        _clock = Clock({
            totalLiquidity: _toUint128(minted),
            lastSyncTime: rt,
            epochTime: rt,
            prevEpochTime: rt,
            lastBlockNumber: uint32(block.number)
        });
        _calendar.lastCrossedBucket = uint32(uint256(rt) / _calendar.bucketWidth);

        _openPosition(owner, salt, liquidity, rt);
        _collectDeposit(amount0, amount1, data);

        emit Initialize(amount0, amount1, liquidity, lp);
    }

    /*//////////////////////////////////////////////////////////////
                                LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IKairosPool
    function mint(address owner, bytes32 salt, uint128 liquidity, bytes calldata data)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 supply = _clock.totalLiquidity;
        if (supply == 0) revert NotInitialized();
        if (liquidity == 0) revert ZeroLiquidity();

        uint32 rt = _rt();
        _sync(rt);

        amount0 = FullMath.mulDivUp(liquidity, reserves.reserve0, supply);
        amount1 = FullMath.mulDivUp(liquidity, reserves.reserve1, supply);
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        reserves = Reserves(
            _toUint128(uint256(reserves.reserve0) + amount0), _toUint128(uint256(reserves.reserve1) + amount1)
        );
        _clock.totalLiquidity = _toUint128(uint256(supply) + liquidity);
        _refreshLogPrice();

        uint32 maturityRt = _openPosition(owner, salt, liquidity, rt);
        _collectDeposit(amount0, amount1, data);

        emit Mint(owner, salt, liquidity, amount0, amount1, maturityRt);
    }

    /// @inheritdoc IKairosPool
    function burn(bytes32 salt, uint128 liquidity, address recipient)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) revert ZeroLiquidity();

        uint32 rt = _rt();
        _sync(rt);

        bytes32 key = _key(msg.sender, salt);
        Position storage p = positions[key];
        _settle(p, rt);

        uint128 held = p.liquidity;
        if (held < liquidity) revert InsufficientLiquidity();

        uint128 supply = _clock.totalLiquidity;
        amount0 = FullMath.mulDiv(liquidity, reserves.reserve0, supply);
        amount1 = FullMath.mulDiv(liquidity, reserves.reserve1, supply);

        // Withdraw the position's share from the maturity calendar before it stops existing.
        if (rt >= p.maturityRt) {
            _calendar.closeMature(liquidity);
        } else {
            uint256 slopeShare = FullMath.mulDiv(p.slopeQ64, liquidity, held);
            _calendar.closeRamping(liquidity, slopeShare, p.startRt, p.maturityRt);
            p.slopeQ64 -= slopeShare;
        }

        p.liquidity = held - liquidity;
        _clock.totalLiquidity = supply - liquidity;
        // `amount{0,1}` are pro-rata shares of the reserves, so each difference is a checked
        // subtraction whose result is at most the original uint128 reserve.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserves = Reserves(uint128(reserves.reserve0 - amount0), uint128(reserves.reserve1 - amount1));
        _refreshLogPrice();

        if (amount0 > 0) SafeTransferLib.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) SafeTransferLib.safeTransfer(token1, recipient, amount1);

        emit Burn(msg.sender, salt, liquidity, amount0, amount1);
    }

    /// @inheritdoc IKairosPool
    function collect(bytes32 salt, address recipient) external lock returns (uint128 amount0, uint128 amount1) {
        uint32 rt = _rt();
        _sync(rt);

        bytes32 key = _key(msg.sender, salt);
        Position storage p = positions[key];
        _settle(p, rt);

        (amount0, amount1) = (p.owed0, p.owed1);
        if (amount0 > 0) {
            p.owed0 = 0;
            feeAccrued0 -= amount0;
            SafeTransferLib.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            p.owed1 = 0;
            feeAccrued1 -= amount1;
            SafeTransferLib.safeTransfer(token1, recipient, amount1);
        }

        if (p.liquidity == 0) delete positions[key];

        emit Collect(msg.sender, salt, recipient, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                                  SWAP
    //////////////////////////////////////////////////////////////*/

    struct SwapCache {
        uint256 r0;
        uint256 r1;
        uint256 n0;
        uint256 n1;
        uint256 grossOut;
        uint256 feeRate;
        uint256 fee;
        int256 newLog;
    }

    /// @inheritdoc IKairosPool
    function swap(bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient, bytes calldata data)
        external
        lock
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();

        uint32 rt = _rt();
        _sync(rt);
        _rollEpoch(rt);

        SwapCache memory c;
        c.r0 = reserves.reserve0;
        c.r1 = reserves.reserve1;
        if (c.r0 == 0 || c.r1 == 0) revert NotInitialized();

        (c.n0, c.n1) = _afterSwap(c.r0, c.r1, zeroForOne, amountIn);
        c.grossOut = zeroForOne ? c.r1 - c.n1 : c.r0 - c.n0;
        if (c.grossOut == 0) revert InsufficientOutput();

        {
            // The epoch has already been rolled, so `blockStartLogPrice` is current in storage.
            int256 anchor = blockScopedPremium ? int256(_oracle.blockStartLogPrice) : int256(_oracle.lastLogPrice);
            c.newLog = MathLib.lnRatio(c.n1, c.n0);
            uint256 rate = baseFee
                + ImpactFee.premium(int256(_oracle.lastLogPrice) - anchor, c.newLog - anchor, theta, premiumCap());
            c.feeRate = rate > MAX_TOTAL_FEE ? MAX_TOTAL_FEE : rate;
        }

        c.fee = FullMath.mulDivUp(c.grossOut, c.feeRate, WAD);
        amountOut = c.grossOut - c.fee;
        if (amountOut < minAmountOut) revert InsufficientOutput();

        // ---- effects ----
        reserves = Reserves(_toUint128(c.n0), _toUint128(c.n1));
        _oracle.lastLogPrice = _toInt72(c.newLog);
        if (zeroForOne) {
            feeAccrued1 += _toUint128(c.fee);
            _accrue(false, c.fee, rt);
        } else {
            feeAccrued0 += _toUint128(c.fee);
            _accrue(true, c.fee, rt);
        }

        // ---- interactions ----
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        if (amountOut > 0) SafeTransferLib.safeTransfer(tokenOut, recipient, amountOut);
        if (data.length > 0) IKairosSwapCallback(msg.sender).kairosSwapCallback(tokenIn, amountIn, data);

        _settleInput(tokenIn, zeroForOne, rt);

        emit Swap(msg.sender, recipient, zeroForOne, amountIn, amountOut, c.feeRate, c.newLog);
    }

    /// @dev Confirms the pool was paid, and routes any surplus to LPs rather than to the reserves so
    ///      a donation can never move the marginal price (and therefore never move the oracle).
    function _settleInput(address tokenIn, bool zeroForOne, uint32 rt) internal {
        uint256 balance = SafeTransferLib.balanceOf(tokenIn, address(this));
        uint256 required =
            zeroForOne ? uint256(reserves.reserve0) + feeAccrued0 : uint256(reserves.reserve1) + feeAccrued1;
        if (balance < required) revert InsufficientInput();

        uint256 surplus = balance - required;
        if (surplus > 0) {
            if (zeroForOne) feeAccrued0 += _toUint128(surplus);
            else feeAccrued1 += _toUint128(surplus);
            _accrue(zeroForOne, surplus, rt);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  FLASH
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IKairosPool
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external lock {
        uint32 rt = _rt();
        _sync(rt);

        uint256 before0 = SafeTransferLib.balanceOf(token0, address(this));
        uint256 before1 = SafeTransferLib.balanceOf(token1, address(this));

        uint256 fee0 = FullMath.mulDivUp(amount0, baseFee, WAD);
        uint256 fee1 = FullMath.mulDivUp(amount1, baseFee, WAD);

        if (amount0 > 0) SafeTransferLib.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) SafeTransferLib.safeTransfer(token1, recipient, amount1);

        IKairosFlashCallback(msg.sender).kairosFlashCallback(fee0, fee1, data);

        uint256 after0 = SafeTransferLib.balanceOf(token0, address(this));
        uint256 after1 = SafeTransferLib.balanceOf(token1, address(this));
        if (after0 < before0 + fee0 || after1 < before1 + fee1) revert InsufficientInput();

        uint256 paid0 = after0 - before0;
        uint256 paid1 = after1 - before1;
        if (paid0 > 0) {
            feeAccrued0 += _toUint128(paid0);
            _accrue(true, paid0, rt);
        }
        if (paid1 > 0) {
            feeAccrued1 += _toUint128(paid1);
            _accrue(false, paid1, rt);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IKairosPool
    function poke() external lock {
        _sync(_rt());
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL: CLOCK
    //////////////////////////////////////////////////////////////*/

    function _rt() internal view returns (uint32) {
        unchecked {
            return uint32(block.timestamp - genesis);
        }
    }

    function _sync(uint32 rt) internal {
        if (rt == _clock.lastSyncTime) return;
        _calendar.sync(rt, feeGrowth0X128, feeGrowth1X128, timeWeightedFeeGrowth0X128, timeWeightedFeeGrowth1X128);
        _clock.lastSyncTime = rt;
    }

    /// @dev Closes the price epoch that just ended and folds its realised move into the oracle.
    ///      The move is `lastLogPrice - blockStartLogPrice` and it was realised over
    ///      `epochTime - prevEpochTime`; both are known exactly at this point.
    function _rollEpoch(uint32 rt) internal {
        uint32 bn = uint32(block.number);
        Clock memory c = _clock;
        if (bn == c.lastBlockNumber) return;

        Oracle memory o = _oracle;
        uint32 interval;
        unchecked {
            interval = c.epochTime - c.prevEpochTime;
        }
        if (interval > 0) {
            int256 m = int256(o.lastLogPrice) - int256(o.blockStartLogPrice);
            uint256 v = Volatility.update(o.varianceRateWad, m, interval);
            o.varianceRateWad = uint80(v > type(uint80).max ? type(uint80).max : v);
            emit VolatilityObservation(m, interval, v);
        }

        o.blockStartLogPrice = o.lastLogPrice;
        _oracle = o;

        c.prevEpochTime = c.epochTime;
        c.epochTime = rt;
        c.lastBlockNumber = bn;
        _clock = c;
    }

    /// @dev Recomputes the cached log price from reserves. Called after mint/burn, whose rounding
    ///      moves the marginal price by at most one wei per reserve.
    function _refreshLogPrice() internal {
        _oracle.lastLogPrice = _toInt72(MathLib.lnRatio(reserves.reserve1, reserves.reserve0));
    }

    function _afterSwap(uint256 r0, uint256 r1, bool zeroForOne, uint256 amountIn)
        internal
        pure
        returns (uint256 n0, uint256 n1)
    {
        if (zeroForOne) {
            n0 = r0 + amountIn;
            n1 = r1 - FullMath.mulDiv(amountIn, r1, n0);
        } else {
            n1 = r1 + amountIn;
            n0 = r0 - FullMath.mulDiv(amountIn, r0, n1);
        }
        if (n0 == 0 || n1 == 0) revert InsufficientLiquidity();
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL: FEES
    //////////////////////////////////////////////////////////////*/

    /// @dev Folds `amount` of token `isToken0` into the global fee-growth accumulators, weighted by
    ///      the maturity-weighted liquidity eligible at this instant.
    function _accrue(bool isToken0, uint256 amount, uint32 rt) internal {
        if (amount == 0) return;
        uint256 eligible = _calendar.effectiveLiquidity(rt);

        if (eligible < MIN_EFFECTIVE_LIQUIDITY) {
            if (isToken0) _orphan0 += _toUint128(amount);
            else _orphan1 += _toUint128(amount);
            return;
        }

        unchecked {
            if (isToken0) {
                uint256 total = amount + _orphan0;
                if (_orphan0 != 0) _orphan0 = 0;
                uint256 growth = FullMath.mulDiv(total, Q128, eligible);
                feeGrowth0X128 += growth;
                timeWeightedFeeGrowth0X128 += growth * rt;
            } else {
                uint256 total = amount + _orphan1;
                if (_orphan1 != 0) _orphan1 = 0;
                uint256 growth = FullMath.mulDiv(total, Q128, eligible);
                feeGrowth1X128 += growth;
                timeWeightedFeeGrowth1X128 += growth * rt;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL: POSITIONS
    //////////////////////////////////////////////////////////////*/

    function _key(address owner, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt));
    }

    function _openPosition(address owner, bytes32 salt, uint128 liquidity, uint32 rt)
        internal
        returns (uint32 maturityRt)
    {
        bytes32 key = _key(owner, salt);
        Position storage p = positions[key];
        if (p.maturityRt != 0 || p.liquidity != 0) revert PositionExists();

        maturityRt = _calendar.maturityFor(rt, maturityPeriod);
        uint256 slope = _calendar.open(liquidity, rt, maturityRt);

        p.liquidity = liquidity;
        p.startRt = rt;
        p.maturityRt = maturityRt;
        p.settledRt = rt;
        p.slopeQ64 = slope;
        p.feeGrowth0Last = feeGrowth0X128;
        p.feeGrowth1Last = feeGrowth1X128;
        p.timeWeighted0Last = timeWeightedFeeGrowth0X128;
        p.timeWeighted1Last = timeWeightedFeeGrowth1X128;
    }

    /// @dev Accrual a position has earned since its last settlement, without writing.
    function _pendingAccrual(Position storage p, uint32 rt) internal view returns (uint256 add0, uint256 add1) {
        uint128 L = p.liquidity;
        if (L == 0) return (0, 0);

        uint32 maturityRt = p.maturityRt;

        if (p.settledRt >= maturityRt) {
            return _flatAccrual(L, p.feeGrowth0Last, p.feeGrowth1Last, feeGrowth0X128, feeGrowth1X128);
        }

        if (rt <= maturityRt) {
            return
                _rampAccrual(
                    p, feeGrowth0X128, feeGrowth1X128, timeWeightedFeeGrowth0X128, timeWeightedFeeGrowth1X128
                );
        }

        Boundary memory bnd = _maturityBoundary(maturityRt);
        (add0, add1) = _rampAccrual(p, bnd.f0, bnd.f1, bnd.g0, bnd.g1);
        (uint256 m0, uint256 m1) = _flatAccrual(L, bnd.f0, bnd.f1, feeGrowth0X128, feeGrowth1X128);
        unchecked {
            add0 += m0;
            add1 += m1;
        }
    }

    struct Boundary {
        uint256 f0;
        uint256 f1;
        uint256 g0;
        uint256 g1;
    }

    /// @dev Fee growth as it stood at a position's maturity instant.
    ///
    ///      If the bucket has been crossed, that value was recorded exactly. If it has *not* been
    ///      crossed, no sync has run at or past the boundary, so no fee has been distributed since —
    ///      which makes the live accumulators themselves the boundary values. Handling both cases
    ///      keeps this usable as a pure view, before anyone has poked the pool.
    function _maturityBoundary(uint32 maturityRt) internal view returns (Boundary memory bnd) {
        uint32 epoch = _calendar.crossEpochOf(maturityRt);
        if (epoch == 0) {
            return Boundary(feeGrowth0X128, feeGrowth1X128, timeWeightedFeeGrowth0X128, timeWeightedFeeGrowth1X128);
        }
        MaturityCalendar.Snapshot storage s = _calendar.snapshotOf(epoch);
        return
            Boundary(s.feeGrowth0X128, s.feeGrowth1X128, s.timeWeightedFeeGrowth0X128, s.timeWeightedFeeGrowth1X128);
    }

    function _settle(Position storage p, uint32 rt) internal {
        if (p.liquidity == 0) {
            p.settledRt = rt;
            return;
        }
        (uint256 add0, uint256 add1) = _pendingAccrual(p, rt);
        if (add0 > 0) p.owed0 += _toUint128(add0);
        if (add1 > 0) p.owed1 += _toUint128(add1);
        p.feeGrowth0Last = feeGrowth0X128;
        p.feeGrowth1Last = feeGrowth1X128;
        p.timeWeighted0Last = timeWeightedFeeGrowth0X128;
        p.timeWeighted1Last = timeWeightedFeeGrowth1X128;
        p.settledRt = rt;
    }

    /// @dev Full-weight accrual: `L * (F1 - F0) / 2^128`.
    function _flatAccrual(uint128 L, uint256 f0Last, uint256 f1Last, uint256 f0Now, uint256 f1Now)
        internal
        pure
        returns (uint256 add0, uint256 add1)
    {
        unchecked {
            add0 = FullMath.mulDiv(L, f0Now - f0Last, Q128);
            add1 = FullMath.mulDiv(L, f1Now - f1Last, Q128);
        }
    }

    /// @dev Ramping accrual. With weight `(t - t_i)/D` the integral of `L*w dF` telescopes into
    ///
    ///          (a_i / 2^64) * [ (G1 - G0) - t_i * (F1 - F0) ] / 2^128
    ///
    ///      where `G` is the time-weighted fee-growth accumulator. All differences are taken modulo
    ///      2^256, which is exact as long as the true difference fits — the same assumption Uniswap
    ///      V3 makes of its own fee-growth accumulators.
    function _rampAccrual(Position storage p, uint256 f0Now, uint256 f1Now, uint256 g0Now, uint256 g1Now)
        internal
        view
        returns (uint256 add0, uint256 add1)
    {
        unchecked {
            uint256 t = p.startRt;
            uint256 slope = p.slopeQ64;
            uint256 num0 = (g0Now - p.timeWeighted0Last) - t * (f0Now - p.feeGrowth0Last);
            uint256 num1 = (g1Now - p.timeWeighted1Last) - t * (f1Now - p.feeGrowth1Last);
            add0 = FullMath.mulDiv(slope, num0, Q192);
            add1 = FullMath.mulDiv(slope, num1, Q192);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL: TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @dev Pulls a deposit via callback (or accepts a pre-transfer when `data` is empty) and asserts
    ///      the pool ends up holding at least reserves + unclaimed fees for both tokens.
    function _collectDeposit(uint256 amount0, uint256 amount1, bytes calldata data) internal {
        if (data.length > 0) IKairosMintCallback(msg.sender).kairosMintCallback(amount0, amount1, data);

        if (
            SafeTransferLib.balanceOf(token0, address(this)) < uint256(reserves.reserve0) + feeAccrued0
                || SafeTransferLib.balanceOf(token1, address(this)) < uint256(reserves.reserve1) + feeAccrued1
        ) revert InsufficientInput();
    }

    /*//////////////////////////////////////////////////////////////
                                 CASTS
    //////////////////////////////////////////////////////////////*/

    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        // Range checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    function _toInt72(int256 x) internal pure returns (int72) {
        if (x > type(int72).max || x < type(int72).min) revert PriceOutOfRange();
        // Range checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int72(x);
    }
}
