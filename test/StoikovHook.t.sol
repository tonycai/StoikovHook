// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {StoikovHook, STOIKOV_HOOK_FLAGS} from "../src/StoikovHook.sol";

contract StoikovHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant TICK_SPACING = 60;
    uint128 internal constant LIQUIDITY = 100e18;

    Currency internal currency0;
    Currency internal currency1;
    StoikovHook internal hook;

    /// @dev Dynamic-fee pool that uses StoikovHook.
    PoolKey internal hookedKey;
    /// @dev Hookless pool with a static fee equal to StoikovHook.PLACEHOLDER_FEE (0.30%).
    PoolKey internal placeholderFeeKey;
    /// @dev Hookless pool with a static fee equal to StoikovHook.BASE_FEE (0.05%), the hooked pool's stored fee.
    PoolKey internal baseFeeKey;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // The low 14 bits of the address carry the permission flags; the high bits namespace it.
        address hookAddress = address(STOIKOV_HOOK_FLAGS ^ (0x4444 << 144));
        deployCodeTo("StoikovHook.sol:StoikovHook", abi.encode(poolManager), hookAddress);
        hook = StoikovHook(hookAddress);

        hookedKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook));
        placeholderFeeKey = PoolKey(currency0, currency1, hook.PLACEHOLDER_FEE(), TICK_SPACING, IHooks(address(0)));
        baseFeeKey = PoolKey(currency0, currency1, hook.BASE_FEE(), TICK_SPACING, IHooks(address(0)));

        _initializeWithFullRangeLiquidity(hookedKey);
        _initializeWithFullRangeLiquidity(placeholderFeeKey);
        _initializeWithFullRangeLiquidity(baseFeeKey);
    }

    // ------------------------------------------------------------------
    // Permissions and address flags
    // ------------------------------------------------------------------

    function test_hookFlags_matchPermissionsAndAddress() public view {
        assertEq(uint256(STOIKOV_HOOK_FLAGS), 0x1080, "flags must be afterInitialize | beforeSwap");
        assertEq(
            _flagsFromPermissions(hook.getHookPermissions()),
            STOIKOV_HOOK_FLAGS,
            "getHookPermissions() must match HOOK_FLAGS"
        );
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK, STOIKOV_HOOK_FLAGS, "address bits must match HOOK_FLAGS"
        );
    }

    // ------------------------------------------------------------------
    // afterInitialize
    // ------------------------------------------------------------------

    function test_afterInitialize_storesBaseFeeAsFallback() public view {
        (,,, uint24 storedFee) = poolManager.getSlot0(hookedKey.toId());
        assertEq(storedFee, hook.BASE_FEE(), "stored LP fee must be BASE_FEE, not the dynamic-pool default of 0");
    }

    function test_afterInitialize_revertsForStaticFeePool() public {
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(BaseOverrideFee.NotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(staticKey, Constants.SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------
    // beforeSwap: the pool charges the hook's override fee
    // ------------------------------------------------------------------

    function test_swap_chargesOverrideFeeInBothDirections() public {
        PoolId id = hookedKey.toId();

        vm.recordLogs();
        _swap(hookedKey, true, 1e18);
        assertEq(_feeFromSwapEvent(id), hook.PLACEHOLDER_FEE(), "zeroForOne swap must pay the override fee");

        vm.recordLogs();
        _swap(hookedKey, false, 1e18);
        assertEq(_feeFromSwapEvent(id), hook.PLACEHOLDER_FEE(), "oneForZero swap must pay the override fee");

        // The override applies per swap and leaves the stored fee untouched.
        (,,, uint24 storedFee) = poolManager.getSlot0(id);
        assertEq(storedFee, hook.BASE_FEE(), "stored LP fee must be unchanged");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_swap_matchesStaticPoolAtOverrideFee(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 10e18);

        BalanceDelta hooked = _swap(hookedKey, zeroForOne, amountIn);
        BalanceDelta placeholderFee = _swap(placeholderFeeKey, zeroForOne, amountIn);
        BalanceDelta baseFee = _swap(baseFeeKey, zeroForOne, amountIn);

        // Identical deltas to a static pool at PLACEHOLDER_FEE: the override fee is what was charged.
        assertEq(hooked.amount0(), placeholderFee.amount0(), "amount0 must match the 0.30% static pool");
        assertEq(hooked.amount1(), placeholderFee.amount1(), "amount1 must match the 0.30% static pool");

        // Strictly less output than a static pool at BASE_FEE: the stored fee was not what was charged.
        int128 hookedOut = zeroForOne ? hooked.amount1() : hooked.amount0();
        int128 baseFeeOut = zeroForOne ? baseFee.amount1() : baseFee.amount0();
        assertLt(hookedOut, baseFeeOut, "output must be below the 0.05% static pool");
    }

    // ------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------

    function test_callbacks_revertWhenNotCalledByPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), hookedKey, Constants.SQRT_PRICE_1_1, 0);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), hookedKey, params, Constants.ZERO_BYTES);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

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

    /// @dev Returns the `fee` field of the last PoolManager `Swap` event recorded for `id`.
    function _feeFromSwapEvent(PoolId id) internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(poolManager) && logs[i].topics[0] == IPoolManager.Swap.selector
                    && logs[i].topics[1] == PoolId.unwrap(id)
            ) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "no Swap event recorded for the pool");
    }

    function _flagsFromPermissions(Hooks.Permissions memory p) internal pure returns (uint160 flags) {
        if (p.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) flags |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) flags |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) flags |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) flags |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }
}
