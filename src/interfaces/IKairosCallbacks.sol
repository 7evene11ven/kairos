// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice Called by {KairosPool.swap} after the output has been sent, so callers may source the
///         input from the proceeds (flash swap) or simply pull it from the trader.
interface IKairosSwapCallback {
    /// @param tokenIn Token the pool expects to receive.
    /// @param amountIn Exact amount the pool must be paid before the swap returns.
    /// @param data Opaque payload forwarded from the original `swap` call.
    function kairosSwapCallback(address tokenIn, uint256 amountIn, bytes calldata data) external;
}

/// @notice Called by {KairosPool.mint} and {KairosPool.initialize} to collect the deposit.
interface IKairosMintCallback {
    function kairosMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

/// @notice Called by {KairosPool.flash} to collect the loan plus its fee.
interface IKairosFlashCallback {
    function kairosFlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}
