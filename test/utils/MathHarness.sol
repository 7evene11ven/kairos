// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {FullMath} from "../../src/libraries/FullMath.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/// @notice External wrapper so revert-expectation cheatcodes can observe library reverts, which are
///         otherwise inlined into the test contract itself.
contract MathHarness {
    function msb(uint256 x) external pure returns (uint256) {
        return MathLib.msb(x);
    }

    function lnWad(uint256 x) external pure returns (int256) {
        return MathLib.lnWad(x);
    }

    function log2Wad(uint256 x) external pure returns (int256) {
        return MathLib.log2Wad(x);
    }

    function sqrtWad(uint256 x) external pure returns (uint256) {
        return MathLib.sqrtWad(x);
    }

    function lnRatio(uint256 n, uint256 d) external pure returns (int256) {
        return MathLib.lnRatio(n, d);
    }

    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, d);
    }

    function mulDivUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDivUp(a, b, d);
    }
}
