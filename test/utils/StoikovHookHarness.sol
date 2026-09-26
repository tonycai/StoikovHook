// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {StoikovHook, FeeParams} from "../../src/StoikovHook.sol";

/// @notice Exposes StoikovHook's internal fee math so tests can drive it with arbitrary inputs.
contract StoikovHookHarness is StoikovHook {
    constructor(IPoolManager poolManager_, FeeParams memory params) StoikovHook(poolManager_, params) {}

    function computeFees(uint256 variance, int256 displacementX16)
        external
        view
        returns (uint24 feeUp, uint24 feeDown, uint256 sigmaHPips)
    {
        return _computeFees(variance, displacementX16);
    }

    function openWindow(PoolState memory state, int24 tick)
        external
        view
        returns (PoolState memory next, uint256 sigmaHPips)
    {
        return _openWindow(state, tick);
    }

    function validateFeeParams(FeeParams memory params) external pure {
        _validateFeeParams(params);
    }
}
