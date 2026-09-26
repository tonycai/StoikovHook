// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {StoikovHook, FeeParams, STOIKOV_HOOK_FLAGS, defaultFeeParams} from "../src/StoikovHook.sol";

/// @notice Mines a CREATE2 salt and deploys StoikovHook at an address that carries its permission flags.
/// @dev HookMiner may iterate up to 160,444 salts, which exceeds the default script gas limit. Run with:
///
///   forge script script/00_DeployHook.s.sol \
///     --rpc-url <network> --account <keystore> --sender <deployer> --broadcast \
///     --gas-limit 100000000000 --disable-block-gas-limit
contract DeployHookScript is BaseScript {
    function run() public {
        // The fee parameters are constructor arguments, so they are part of the init code and of the
        // mined address: changing any of them requires re-mining (spec §2.5).
        FeeParams memory params = defaultFeeParams();

        // STOIKOV_HOOK_FLAGS is the same constant the hook's permissions are checked against,
        // so the mined address always matches getHookPermissions().
        bytes memory constructorArgs = abi.encode(poolManager, params);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, STOIKOV_HOOK_FLAGS, type(StoikovHook).creationCode, constructorArgs);

        vm.startBroadcast();
        StoikovHook hook = new StoikovHook{salt: salt}(poolManager, params);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: hook address mismatch");
        console2.log("StoikovHook deployed at:", address(hook));
    }
}
