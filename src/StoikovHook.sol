// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Address flags StoikovHook must be deployed with: afterInitialize | beforeSwap (0x1080).
///      Single source of truth for deployment scripts and tests, which need the flags before the
///      hook exists. Must equal the flags implied by StoikovHook.getHookPermissions(); the BaseHook
///      constructor rejects any mismatch.
uint160 constant STOIKOV_HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

/// @title StoikovHook
/// @notice Uniswap v4 dynamic-fee hook that prices swaps like an Avellaneda–Stoikov market maker.
/// @dev Skeleton. The permission set, the dynamic-fee guard, the stored fallback fee and the
///      per-swap fee override are in place. The pricing model (specs/01-design.md §2) is not
///      implemented yet: every swap pays PLACEHOLDER_FEE.
contract StoikovHook is BaseOverrideFee {
    /// @notice Address flags the hook is deployed with: afterInitialize | beforeSwap (0x1080).
    uint160 public constant HOOK_FLAGS = STOIKOV_HOOK_FLAGS;

    /// @notice Base fee f0 in hundredths of a bip (500 = 0.05%).
    /// @dev Written to the pool's stored LP fee at initialization. Dynamic-fee pools start with a
    ///      stored fee of 0, so this makes a missing override fall back to f0 instead of 0 (spec §4.1).
    uint24 public constant BASE_FEE = 500;

    /// @notice Fee charged on every swap until the pricing model lands (3000 = 0.30%).
    /// @dev Deliberately different from BASE_FEE, so tests can tell the per-swap override apart
    ///      from the stored fee.
    uint24 public constant PLACEHOLDER_FEE = 3000;

    constructor(IPoolManager _poolManager) BaseOverrideFee(_poolManager) {}

    /// @dev Reverts for pools without the dynamic-fee flag (checked in BaseOverrideFee), then
    ///      stores BASE_FEE as the pool's fallback LP fee.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        super._afterInitialize(sender, key, sqrtPriceX96, tick);
        poolManager.updateDynamicLPFee(key, BASE_FEE);
        return this.afterInitialize.selector;
    }

    /// @dev Placeholder for the fee model. BaseOverrideFee adds OVERRIDE_FEE_FLAG to the result,
    ///      so PoolManager charges this fee instead of the stored one.
    function _getFee(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (uint24)
    {
        return PLACEHOLDER_FEE;
    }
}
