// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {StoikovHook, FeeParams} from "../../src/StoikovHook.sol";

/// @notice TEST ONLY, never deploy. StoikovHook without the per-block fee cache: it recomputes the fee
///         window on every swap, which is the mutation used in the README Security section. It exists to
///         demonstrate the same-block round-trip attack of spec §5.4.
contract StoikovHookNoCache is StoikovHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    constructor(IPoolManager poolManager_, FeeParams memory params) StoikovHook(poolManager_, params) {}

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        (PoolState memory state,) = _openWindow(_poolState[id], tick);
        _poolState[id] = state;
        uint24 fee = params.zeroForOne ? state.feeDown : state.feeUp;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
