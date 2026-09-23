// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {KairosFactory} from "../src/KairosFactory.sol";
import {KairosLens} from "../src/periphery/KairosLens.sol";
import {KairosRouter} from "../src/periphery/KairosRouter.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys the factory and periphery.
///
/// @dev Dry run:
///          forge script script/Deploy.s.sol --rpc-url $RPC_URL
///      Broadcast:
///          forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
///
///      Pools are deployed separately, through the factory, once a token pair is chosen.
contract Deploy is Script {
    function run() external returns (KairosFactory factory, KairosRouter router, KairosLens lens) {
        vm.startBroadcast();

        factory = new KairosFactory();
        router = new KairosRouter();
        lens = new KairosLens();

        vm.stopBroadcast();

        console2.log("KairosFactory ", address(factory));
        console2.log("KairosRouter  ", address(router));
        console2.log("KairosLens    ", address(lens));
        console2.log("");
        console2.log("Enabled configurations (baseFee, theta, maturity, blockScoped):");
        console2.log("  5 bps, 1.0, 2h, block-scoped   -- balanced");
        console2.log("  5 bps, 3.0, 2h, block-scoped   -- aggressive recapture");
        console2.log("  5 bps, 3.0, 2h, swap-scoped    -- aggressive, cheaper for retail");
        console2.log("  5 bps, 6.0, 2h, swap-scoped    -- maximal recapture");
        console2.log(" 30 bps, 1.0, 4h, block-scoped   -- long-tail pairs");
    }
}
