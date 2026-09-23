// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IVolatilityFeed
/// @notice Read interface for the realised-volatility estimator every Kairos pool maintains.
/// @dev Free to read and useful well beyond the pool itself: option pricers, dynamic-LTV lending
///      markets and risk engines can consume it without trusting an off-chain publisher.
interface IVolatilityFeed {
    /// @notice EWMA realised variance per second, as a WAD.
    function varianceRate() external view returns (uint256);

    /// @notice Volatility per sqrt(second), as a WAD.
    function sigmaPerSqrtSecond() external view returns (uint256);

    /// @notice Annualised volatility, as a WAD (0.8e18 == 80%/yr).
    function annualizedVolatility() external view returns (uint256);

    /// @notice Expected magnitude of a log price move over `interval` seconds, as a WAD.
    function volatilityOver(uint256 interval) external view returns (uint256);
}

/// @title IKairosPool
interface IKairosPool is IVolatilityFeed {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Initialize(uint256 amount0, uint256 amount1, uint128 liquidity, int256 logPrice);
    event Mint(
        address indexed owner,
        bytes32 indexed salt,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint32 maturity
    );
    event Burn(address indexed owner, bytes32 indexed salt, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Collect(address indexed owner, bytes32 indexed salt, address recipient, uint128 amount0, uint128 amount1);
    event Swap(
        address indexed sender,
        address indexed recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeRate,
        int256 logPrice
    );
    event Flash(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    );
    event VolatilityObservation(int256 logReturn, uint32 interval, uint256 varianceRate);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AlreadyInitialized();
    error NotInitialized();
    error ZeroLiquidity();
    error ZeroAmount();
    error PositionExists();
    error InsufficientOutput();
    error InsufficientInput();
    error InsufficientLiquidity();
    error PriceOutOfRange();
    error Overflow();

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @notice Flat fee applied to every swap, as a WAD.
    function baseFee() external view returns (uint256);
    /// @notice LVR recapture parameter. The pool closes `1/(1+theta)` of each block's price gap;
    ///         in equilibrium LPs retain `theta/(1+2*theta)` of loss-versus-rebalancing.
    function theta() external view returns (uint256);
    /// @notice Seconds a position must age before it earns fees at full weight.
    function maturityPeriod() external view returns (uint32);
    function genesis() external view returns (uint32);

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    function reserves() external view returns (uint128 reserve0, uint128 reserve1);
    function totalLiquidity() external view returns (uint128);
    /// @notice Maturity-weighted liquidity currently eligible for fees.
    function effectiveLiquidity() external view returns (uint256);
    /// @notice `ln(reserve1 / reserve0)` as a signed WAD.
    function logPrice() external view returns (int256);
    /// @notice Signed log displacement of the pool price from where it started this block.
    function blockDisplacement() external view returns (int256);
    /// @notice Fee rate a swap of `amountIn` would pay right now, as a WAD.
    function quoteFeeRate(bool zeroForOne, uint256 amountIn) external view returns (uint256);
    /// @notice Simulates a swap without touching state.
    function quote(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut, uint256 feeRate);
    /// @notice Current upper bound on the impact premium, as a WAD.
    function premiumCap() external view returns (uint256);
    /// @notice Log price this block opened at, as a signed WAD.
    function blockStartLogPrice() external view returns (int256);
    /// @notice Fees collected but not yet claimed, held outside the reserves.
    function feeAccrued0() external view returns (uint128);
    function feeAccrued1() external view returns (uint128);
    /// @notice Fees a position could collect if it settled right now.
    function positionFees(address owner, bytes32 salt) external view returns (uint256 owed0, uint256 owed1);

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function initialize(uint256 amount0, uint256 amount1, address owner, bytes32 salt, bytes calldata data)
        external
        returns (uint128 liquidity);

    function mint(address owner, bytes32 salt, uint128 liquidity, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);

    function burn(bytes32 salt, uint128 liquidity, address recipient)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(bytes32 salt, address recipient) external returns (uint128 amount0, uint128 amount1);

    function swap(bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient, bytes calldata data)
        external
        returns (uint256 amountOut);

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;

    /// @notice Advances the maturity calendar without any other side effect.
    function poke() external;
}
