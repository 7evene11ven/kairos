// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {KairosPool} from "../../src/KairosPool.sol";
import {
    IKairosFlashCallback,
    IKairosMintCallback,
    IKairosSwapCallback
} from "../../src/interfaces/IKairosCallbacks.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A distinct on-chain identity that can hold Kairos positions and pay for its own swaps.
/// @dev Positions are keyed by `(owner, salt)` and `burn`/`collect` authenticate on `msg.sender`,
///      so tests that need several independent LPs need several of these.
contract Actor is IKairosMintCallback, IKairosSwapCallback, IKairosFlashCallback {
    KairosPool public immutable pool;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    /// @dev When set, the flash callback repays strictly less than it owes.
    bool public underpayFlash;

    uint256 internal _flashPrincipal0;
    uint256 internal _flashPrincipal1;

    constructor(KairosPool _pool) {
        pool = _pool;
        token0 = MockERC20(_pool.token0());
        token1 = MockERC20(_pool.token1());
    }

    /*//////////////////////////////////////////////////////////////
                                CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function kairosMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        require(msg.sender == address(pool), "bad caller");
        if (amount0Owed > 0) token0.transfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) token1.transfer(msg.sender, amount1Owed);
    }

    function kairosSwapCallback(address tokenIn, uint256 amountIn, bytes calldata) external {
        require(msg.sender == address(pool), "bad caller");
        MockERC20(tokenIn).transfer(msg.sender, amountIn);
    }

    function kairosFlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external {
        require(msg.sender == address(pool), "bad caller");
        uint256 owed0 = _flashPrincipal0 + fee0;
        uint256 owed1 = _flashPrincipal1 + fee1;
        if (underpayFlash) {
            if (owed0 > 0) owed0 -= 1;
            if (owed1 > 0) owed1 -= 1;
        }
        if (owed0 > 0) token0.transfer(msg.sender, owed0);
        if (owed1 > 0) token1.transfer(msg.sender, owed1);
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function initialize(uint256 amount0, uint256 amount1, bytes32 salt) external returns (uint128) {
        return pool.initialize(amount0, amount1, address(this), salt, "1");
    }

    function mint(bytes32 salt, uint128 liquidity) external returns (uint256, uint256) {
        return pool.mint(address(this), salt, liquidity, "1");
    }

    function burn(bytes32 salt, uint128 liquidity) external returns (uint256, uint256) {
        return pool.burn(salt, liquidity, address(this));
    }

    function collect(bytes32 salt) external returns (uint128, uint128) {
        return pool.collect(salt, address(this));
    }

    function swap(bool zeroForOne, uint256 amountIn) external returns (uint256) {
        return pool.swap(zeroForOne, amountIn, 0, address(this), "1");
    }

    function swapMin(bool zeroForOne, uint256 amountIn, uint256 minOut) external returns (uint256) {
        return pool.swap(zeroForOne, amountIn, minOut, address(this), "1");
    }

    function flash(uint256 amount0, uint256 amount1) external {
        _flashPrincipal0 = amount0;
        _flashPrincipal1 = amount1;
        pool.flash(address(this), amount0, amount1, "1");
        _flashPrincipal0 = 0;
        _flashPrincipal1 = 0;
    }

    function setUnderpayFlash(bool v) external {
        underpayFlash = v;
    }

    function balances() external view returns (uint256, uint256) {
        return (token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }
}
