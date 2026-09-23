// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title SafeTransferLib
/// @notice ERC-20 transfer helpers that tolerate non-standard tokens returning no data.
/// @dev Reverts if the call fails or returns a falsy word. Does not check for contract existence —
///      the pool only ever talks to tokens whose balance it has already read.
library SafeTransferLib {
    error TransferFailed();
    error TransferFromFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        bool success;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(ptr, 0x24), amount)
            success := and(
                or(and(eq(mload(0x00), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                call(gas(), token, 0, ptr, 0x44, 0x00, 0x20)
            )
        }
        if (!success) revert TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        bool success;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(ptr, 0x24), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(ptr, 0x44), amount)
            success := and(
                or(and(eq(mload(0x00), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                call(gas(), token, 0, ptr, 0x64, 0x00, 0x20)
            )
        }
        if (!success) revert TransferFromFailed();
    }

    function balanceOf(address token, address account) internal view returns (uint256 amount) {
        bool success;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), and(account, 0xffffffffffffffffffffffffffffffffffffffff))
            success := staticcall(gas(), token, ptr, 0x24, 0x00, 0x20)
            amount := mload(0x00)
            success := and(success, gt(returndatasize(), 31))
        }
        if (!success) revert TransferFailed();
    }
}
