// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Lock
/// @notice EIP-1153 transient-storage reentrancy guard.
/// @dev Costs ~200 gas per guarded call versus ~5,000 for a warm storage slot, and self-clears at the
///      end of the transaction, so a call that reverts and is caught upstream can never leave the
///      pool permanently wedged.
library Lock {
    /// @dev `keccak256("kairos.lock.v1")`.
    bytes32 internal constant SLOT = 0x6e15b6bd031cd75ebfa5434c56bb4a23d0389c767312177e562c6dfe18b5815c;

    error Reentrancy();

    function acquire() internal {
        bytes32 slot = SLOT;
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    function release() internal {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }
}
