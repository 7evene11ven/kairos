// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IKairosMintCallback, IKairosSwapCallback} from "../interfaces/IKairosCallbacks.sol";
import {IKairosPool} from "../interfaces/IKairosPool.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

/// @title KairosRouter
/// @notice User-facing entry point: deadlines, slippage bounds and multi-hop routing.
/// @dev The pool pulls funds through a callback, so the router only ever moves tokens it was
///      explicitly asked to move, and never holds a balance between transactions.
contract KairosRouter is IKairosSwapCallback, IKairosMintCallback {
    error Expired();
    error TooLittleReceived();
    error TooMuchRequested();
    error EmptyPath();
    error UnknownPool();

    /// @dev Set for the duration of a single pool call so the callback can authenticate its caller.
    address internal transient _activePool;

    struct SwapCallbackData {
        address payer;
    }

    struct MintCallbackData {
        address payer;
    }

    modifier checkDeadline(uint256 deadline) {
        // A deadline is inherently a timestamp comparison, and the manipulation a validator can
        // achieve (seconds) is irrelevant next to the deadlines users actually set (minutes).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  SWAPS
    //////////////////////////////////////////////////////////////*/

    struct ExactInputSingleParams {
        address pool;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
        uint256 deadline;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        checkDeadline(p.deadline)
        returns (uint256 amountOut)
    {
        amountOut = _swap(p.pool, p.zeroForOne, p.amountIn, p.recipient, msg.sender);
        if (amountOut < p.amountOutMinimum) revert TooLittleReceived();
    }

    struct ExactInputParams {
        /// @dev Pools to route through, in order.
        address[] pools;
        /// @dev `zeroForOne` for each hop; must be the same length as `pools`.
        bool[] directions;
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
        uint256 deadline;
    }

    /// @notice Routes an exact input through a sequence of pools.
    /// @dev Every intermediate hop settles to the router, which then funds the next hop from its own
    ///      balance; only the first hop pulls from the caller.
    function exactInput(ExactInputParams calldata p) external checkDeadline(p.deadline) returns (uint256 amountOut) {
        uint256 hops = p.pools.length;
        if (hops == 0 || hops != p.directions.length) revert EmptyPath();

        uint256 amount = p.amountIn;
        for (uint256 i; i < hops; ++i) {
            bool last = i == hops - 1;
            amount = _swap(
                p.pools[i],
                p.directions[i],
                amount,
                last ? p.recipient : address(this),
                i == 0 ? msg.sender : address(this)
            );
        }

        amountOut = amount;
        if (amountOut < p.amountOutMinimum) revert TooLittleReceived();
    }

    function _swap(address pool, bool zeroForOne, uint256 amountIn, address recipient, address payer)
        internal
        returns (uint256)
    {
        _activePool = pool;
        uint256 out =
            IKairosPool(pool).swap(zeroForOne, amountIn, 0, recipient, abi.encode(SwapCallbackData({payer: payer})));
        _activePool = address(0);
        return out;
    }

    /// @inheritdoc IKairosSwapCallback
    function kairosSwapCallback(address tokenIn, uint256 amountIn, bytes calldata data) external {
        if (msg.sender != _activePool) revert UnknownPool();
        SwapCallbackData memory d = abi.decode(data, (SwapCallbackData));
        if (d.payer == address(this)) {
            SafeTransferLib.safeTransfer(tokenIn, msg.sender, amountIn);
        } else {
            SafeTransferLib.safeTransferFrom(tokenIn, d.payer, msg.sender, amountIn);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    struct AddLiquidityParams {
        address pool;
        bytes32 salt;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        address owner;
        uint256 deadline;
    }

    function addLiquidity(AddLiquidityParams calldata p)
        external
        checkDeadline(p.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        _activePool = p.pool;
        (amount0, amount1) =
            IKairosPool(p.pool).mint(p.owner, p.salt, p.liquidity, abi.encode(MintCallbackData({payer: msg.sender})));
        _activePool = address(0);
        if (amount0 > p.amount0Max || amount1 > p.amount1Max) revert TooMuchRequested();
    }

    struct InitializeParams {
        address pool;
        uint256 amount0;
        uint256 amount1;
        bytes32 salt;
        address owner;
        uint256 deadline;
    }

    function initializePool(InitializeParams calldata p)
        external
        checkDeadline(p.deadline)
        returns (uint128 liquidity)
    {
        _activePool = p.pool;
        liquidity = IKairosPool(p.pool)
            .initialize(p.amount0, p.amount1, p.owner, p.salt, abi.encode(MintCallbackData({payer: msg.sender})));
        _activePool = address(0);
    }

    /// @inheritdoc IKairosMintCallback
    function kairosMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        if (msg.sender != _activePool) revert UnknownPool();
        MintCallbackData memory d = abi.decode(data, (MintCallbackData));
        if (amount0Owed > 0) {
            SafeTransferLib.safeTransferFrom(IKairosPool(msg.sender).token0(), d.payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            SafeTransferLib.safeTransferFrom(IKairosPool(msg.sender).token1(), d.payer, msg.sender, amount1Owed);
        }
    }
}
