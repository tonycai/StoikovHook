// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./libraries/EasyPosm.sol";
import {BaseTest} from "./BaseTest.sol";

import {StoikovHook, STOIKOV_HOOK_FLAGS, defaultFeeParams} from "../../src/StoikovHook.sol";

/// @notice Shared setup: a StoikovHook pool plus hookless comparison pools, all with identical
///         full-range liquidity at price 1:1 (tick 0).
abstract contract StoikovHookFixture is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_SPACING = 60;
    uint128 internal constant LIQUIDITY = 100e18;
    uint256 internal constant BLOCK_TIME = 12;

    Currency internal currency0;
    Currency internal currency1;
    StoikovHook internal hook;

    /// @dev Dynamic-fee pool that uses StoikovHook.
    PoolKey internal hookedKey;
    PoolId internal hookedId;
    /// @dev Hookless pool whose static fee equals the hooked pool's seeded fee.
    PoolKey internal seededFeeKey;
    /// @dev Hookless pool whose static fee equals StoikovHook.baseFee, the hooked pool's stored fee.
    PoolKey internal baseFeeKey;

    function setUp() public virtual {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // The low 14 bits of the address carry the permission flags; the high bits namespace it.
        address hookAddress = address(STOIKOV_HOOK_FLAGS ^ (0x4444 << 144));
        deployCodeTo("StoikovHook.sol:StoikovHook", abi.encode(poolManager, defaultFeeParams()), hookAddress);
        hook = StoikovHook(hookAddress);
        vm.label(hookAddress, "StoikovHook");

        hookedKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook));
        hookedId = hookedKey.toId();
        _initializeWithFullRangeLiquidity(hookedKey);

        uint24 seededFee = hook.getPoolState(hookedId).feeUp;
        seededFeeKey = PoolKey(currency0, currency1, seededFee, TICK_SPACING, IHooks(address(0)));
        baseFeeKey = PoolKey(currency0, currency1, hook.baseFee(), TICK_SPACING, IHooks(address(0)));
        _initializeWithFullRangeLiquidity(seededFeeKey);
        _initializeWithFullRangeLiquidity(baseFeeKey);
    }

    function _initializeWithFullRangeLiquidity(PoolKey memory key) internal {
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            LIQUIDITY
        );
        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            LIQUIDITY,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    /// @dev Swaps in the hooked pool and returns the fee PoolManager charged, read from its Swap event.
    function _swapAndGetFee(bool zeroForOne, uint256 amountIn) internal returns (uint24 fee) {
        vm.recordLogs();
        _swap(hookedKey, zeroForOne, amountIn);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(poolManager) && logs[i].topics[0] == IPoolManager.Swap.selector
                    && logs[i].topics[1] == PoolId.unwrap(hookedId)
            ) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "no Swap event recorded for the hooked pool");
    }

    /// @dev Moves to the next block, `secondsElapsed` later.
    function _nextBlock(uint256 secondsElapsed) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + secondsElapsed);
    }
}
