// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {StoikovHookFixture} from "./utils/StoikovHookFixture.sol";

/// @notice Measures the gas StoikovHook adds to a swap: the same swap in the hooked pool minus the same
///         swap in a hookless pool with identical liquidity. Run with `-vv` to print the numbers.
/// @dev "Warm" repeats the methodology of the skeleton's 2,093-gas baseline: both pools are touched
///      earlier in the same transaction. "Cold" first calls `vm.cool` on the hook and PoolManager. The
///      measured cold-minus-warm difference (about 2,010 gas) matches one cold read of the hook's state
///      slot, not an additional cold-account surcharge. Treat the cold figures as a lower bound for the
///      first swap in a real transaction, which may also pay up to 2,500 gas for a cold hook address.
contract StoikovHookGasTest is StoikovHookFixture {
    /// @dev Spec §6 A8 budgets for the hook's own execution.
    uint256 internal constant CACHED_PATH_BUDGET = 5_000;
    uint256 internal constant WINDOW_OPEN_PATH_BUDGET = 25_000;

    function test_gas_cachedPath_warm() public {
        _warmUp();
        uint256 overhead = _report("cached path, warm", false);
        assertLe(overhead, CACHED_PATH_BUDGET);
    }

    function test_gas_windowOpenPath_warm() public {
        _warmUp();
        _nextBlock(BLOCK_TIME);
        uint256 overhead = _report("window-open path, warm", false);
        assertLe(overhead, WINDOW_OPEN_PATH_BUDGET);
    }

    function test_gas_cachedPath_cold() public {
        _warmUp();
        _report("cached path, cold", true);
    }

    function test_gas_windowOpenPath_cold() public {
        _warmUp();
        _nextBlock(BLOCK_TIME);
        _report("window-open path, cold", true);
    }

    /// @dev Touches both pools once, in the current block, so the measured swaps are not first-ever swaps.
    function _warmUp() internal {
        _swap(hookedKey, true, 1e15);
        _swap(seededFeeKey, true, 1e15);
    }

    /// @dev Gas of a 1e18 zeroForOne swap in the hooked pool minus the same swap in the hookless pool.
    ///      The hookless pool is measured second, so a window-open cost cannot leak into it.
    function _report(string memory label, bool cold) internal returns (uint256 overhead) {
        uint256 hooked = _measure(hookedKey, cold);
        uint256 hookless = _measure(seededFeeKey, cold);
        overhead = hooked - hookless;
        console2.log(label);
        console2.log("  hookless swap, execution gas:", hookless);
        console2.log("  hooked swap, execution gas:  ", hooked);
        console2.log("  hook overhead:               ", overhead);
    }

    function _measure(PoolKey memory key, bool cold) internal returns (uint256 used) {
        if (cold) {
            vm.cool(address(hook));
            vm.cool(address(poolManager));
        }
        uint256 before = gasleft();
        _swap(key, true, 1e18);
        used = before - gasleft();
    }
}
