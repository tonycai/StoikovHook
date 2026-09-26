// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";

import {StoikovHookFixture} from "./utils/StoikovHookFixture.sol";

import {StoikovHook, STOIKOV_HOOK_FLAGS} from "../src/StoikovHook.sol";

/// @notice End-to-end tests: real swaps through PoolManager against a StoikovHook pool.
contract StoikovHookTest is StoikovHookFixture {
    using StateLibrary for IPoolManager;

    /// @dev Fee both directions pay right after initialization with the default parameters:
    ///      f0 + α·σ_h(V0) = 500 + floor(100 · √(12 · 1)) = 500 + 346.
    uint24 internal constant SEEDED_FEE = 846;

    // ------------------------------------------------------------------
    // Permissions, initialization and access control
    // ------------------------------------------------------------------

    function test_hookFlags_matchPermissionsAndAddress() public view {
        assertEq(uint256(STOIKOV_HOOK_FLAGS), 0x1080, "flags must be afterInitialize | beforeSwap");
        assertEq(
            _flagsFromPermissions(hook.getHookPermissions()),
            STOIKOV_HOOK_FLAGS,
            "getHookPermissions() must match the flag constant"
        );
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK, STOIKOV_HOOK_FLAGS, "address bits must match the flags"
        );
    }

    function test_afterInitialize_seedsStateAndFallbackFee() public view {
        StoikovHook.PoolState memory state = hook.getPoolState(hookedId);
        assertEq(state.lastBlock, block.number, "window key");
        assertEq(state.lastTimestamp, block.timestamp, "timestamp");
        assertEq(state.lastTick, 0, "pool starts at tick 0");
        assertEq(state.refTickX16, 0, "reference starts at the initial tick");
        assertEq(state.variance, hook.initialVariance(), "variance starts at V0");
        assertEq(state.feeUp, SEEDED_FEE, "seeded price-up fee");
        assertEq(state.feeDown, SEEDED_FEE, "seeded price-down fee");

        (,,, uint24 storedFee) = poolManager.getSlot0(hookedId);
        assertEq(storedFee, hook.baseFee(), "stored LP fee must be baseFee, not the dynamic-pool default of 0");
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

    function test_callbacks_revertWhenNotCalledByPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), hookedKey, Constants.SQRT_PRICE_1_1, 0);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), hookedKey, params, Constants.ZERO_BYTES);
    }

    // ------------------------------------------------------------------
    // The pool charges the hook's fee, not its stored fee
    // ------------------------------------------------------------------

    function test_swap_chargesHookFeeNotStoredFee() public {
        assertEq(_swapAndGetFee(true, 1e18), SEEDED_FEE, "zeroForOne pays the hook's fee");
        assertEq(_swapAndGetFee(false, 1e18), SEEDED_FEE, "oneForZero pays the hook's fee");

        (,,, uint24 storedFee) = poolManager.getSlot0(hookedId);
        assertEq(storedFee, hook.baseFee(), "the per-swap override leaves the stored fee untouched");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_swap_matchesStaticPoolAtHookFee(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 10e18);

        BalanceDelta hooked = _swap(hookedKey, zeroForOne, amountIn);
        BalanceDelta seededFee = _swap(seededFeeKey, zeroForOne, amountIn);
        BalanceDelta baseFee = _swap(baseFeeKey, zeroForOne, amountIn);

        // Identical deltas to a static pool at the hook's fee: that fee is what was charged.
        assertEq(hooked.amount0(), seededFee.amount0(), "amount0 must match the static pool at the hook fee");
        assertEq(hooked.amount1(), seededFee.amount1(), "amount1 must match the static pool at the hook fee");

        // Strictly less output than a static pool at the stored fee: the stored fee was not charged.
        int128 hookedOut = zeroForOne ? hooked.amount1() : hooked.amount0();
        int128 baseFeeOut = zeroForOne ? baseFee.amount1() : baseFee.amount0();
        assertLt(hookedOut, baseFeeOut, "output must be below the static pool at the stored fee");
    }

    // ------------------------------------------------------------------
    // Inventory skew: direction of the fee asymmetry
    // ------------------------------------------------------------------

    function test_skewZero_bothDirectionsPayTheSame() public {
        // No price movement since initialization: q̂ = 0.
        _nextBlock(BLOCK_TIME);
        (uint24 feeUp, uint24 feeDown) = hook.previewFees(hookedKey);
        assertEq(feeUp, feeDown, "no displacement, no skew");
        assertEq(_swapAndGetFee(true, 1e15), feeDown, "charged fee matches the preview");
    }

    function test_skewPositive_afterPriceRise_priceUpPaysMore() public {
        _swap(hookedKey, false, 1e18); // push the price up (sell token1 for token0)
        _nextBlock(BLOCK_TIME);

        (uint24 feeUp, uint24 feeDown) = hook.previewFees(hookedKey);
        assertGt(feeUp, feeDown, "above the reference: extending the move costs more than reverting it");
        assertEq(_swapAndGetFee(false, 1e15), feeUp, "price-up swap pays feeUp");
        assertEq(_swapAndGetFee(true, 1e15), feeDown, "price-down swap pays feeDown");
    }

    function test_skewNegative_afterPriceFall_priceDownPaysMore() public {
        _swap(hookedKey, true, 1e18); // push the price down (sell token0 for token1)
        _nextBlock(BLOCK_TIME);

        (uint24 feeUp, uint24 feeDown) = hook.previewFees(hookedKey);
        assertGt(feeDown, feeUp, "below the reference: extending the move costs more than reverting it");
        assertEq(_swapAndGetFee(true, 1e15), feeDown, "price-down swap pays feeDown");
        assertEq(_swapAndGetFee(false, 1e15), feeUp, "price-up swap pays feeUp");
    }

    // ------------------------------------------------------------------
    // Volatility: higher volatility raises both fees, then they decay
    // ------------------------------------------------------------------

    function test_volatility_jumpRaisesFeesThenQuietWindowsDecayThem() public {
        _swap(hookedKey, false, 1e18); // a ≈2% jump
        _nextBlock(BLOCK_TIME);

        (uint24 feeUp, uint24 feeDown) = hook.previewFees(hookedKey);
        uint256 previousSum = uint256(feeUp) + feeDown;
        assertGt(feeUp, SEEDED_FEE, "price-up fee rises after the jump");
        assertGt(feeDown, SEEDED_FEE, "price-down fee rises after the jump");

        // Quiet windows: tiny swaps open each window without moving the tick, so the variance decays.
        for (uint256 i; i < 5; ++i) {
            _swap(hookedKey, true, 1e6);
            _nextBlock(BLOCK_TIME);
            (feeUp, feeDown) = hook.previewFees(hookedKey);
            uint256 sum = uint256(feeUp) + feeDown;
            assertLt(sum, previousSum, "the mean fee decays while the price stays put");
            assertGe(feeDown, hook.baseFee(), "fees never drop below f0 while beta <= alpha");
            previousSum = sum;
        }
    }

    // ------------------------------------------------------------------
    // Per-block caching
    // ------------------------------------------------------------------

    function test_sameBlock_allSwapsPayTheWindowFees() public {
        _swap(hookedKey, false, 1e18); // make the next window asymmetric
        _nextBlock(BLOCK_TIME);
        (uint24 feeUp, uint24 feeDown) = hook.previewFees(hookedKey);

        assertEq(_swapAndGetFee(true, 1e18), feeDown, "1st swap, down");
        StoikovHook.PoolState memory afterFirst = hook.getPoolState(hookedId);

        assertEq(_swapAndGetFee(false, 3e18), feeUp, "2nd swap, up");
        assertEq(_swapAndGetFee(true, 5e17), feeDown, "3rd swap, down");
        assertEq(_swapAndGetFee(false, 1e17), feeUp, "4th swap, up");

        StoikovHook.PoolState memory afterLast = hook.getPoolState(hookedId);
        assertEq(abi.encode(afterLast), abi.encode(afterFirst), "state is written once per block");
    }

    function test_sameBlock_roundTripCannotLowerLaterFee() public {
        _swap(hookedKey, false, 1e18); // price above the reference in the next window
        _nextBlock(BLOCK_TIME);
        (uint24 feeUp, uint24 feeDown) = hook.previewFees(hookedKey);
        assertGt(feeUp, feeDown);

        // Sell token0 at the discounted rate, pushing the price back through the reference...
        assertEq(_swapAndGetFee(true, 2e18), feeDown);
        // ...then buy a large size. It still pays the window-open price-up fee, not the discount.
        assertEq(_swapAndGetFee(false, 5e18), feeUp, "the round trip did not change the fee");
    }

    function test_newBlockSameTimestamp_opensWindowWithoutReverting() public {
        _swap(hookedKey, false, 1e18);
        vm.roll(block.number + 1); // a new block with the same timestamp: elapsed time is floored at 1 s

        uint24 fee = _swapAndGetFee(false, 1e15);
        StoikovHook.PoolState memory state = hook.getPoolState(hookedId);
        assertEq(state.lastBlock, block.number, "a new window opened");
        assertEq(fee, state.feeUp, "the swap paid the new window's fee");
    }

    // ------------------------------------------------------------------
    // Bounds under arbitrary swap sequences
    // ------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_swapSequence_feesStayWithinBounds(uint256 seed) public {
        uint24 minFee = hook.minFee();
        uint24 maxFee = hook.maxFee();

        for (uint256 i; i < 10; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.roll(block.number + 1 + (r % 3));
            vm.warp(block.timestamp + (r >> 8) % 40); // includes 0: several blocks, one timestamp
            bool zeroForOne = (r >> 16) % 2 == 0;
            uint256 amountIn = bound(r >> 24, 1e6, 3e18);

            (uint24 previewUp, uint24 previewDown) = hook.previewFees(hookedKey);
            uint24 fee = _swapAndGetFee(zeroForOne, amountIn);

            assertEq(fee, zeroForOne ? previewDown : previewUp, "charged fee matches the preview");
            assertGe(fee, minFee, "fee >= fmin");
            assertLe(fee, maxFee, "fee <= fmax");
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

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
