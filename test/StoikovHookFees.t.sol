// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {StoikovHookHarness} from "./utils/StoikovHookHarness.sol";

import {StoikovHook, FeeParams, STOIKOV_HOOK_FLAGS, defaultFeeParams} from "../src/StoikovHook.sol";

/// @notice Unit and fuzz tests of the fee math (spec §2.3–§2.4), driven directly through a harness.
/// @dev Expected values use the default parameters: f0 = 500, α = 1, β = 0.5, h = 12 s, Q = 200 ticks,
///      τσ = 300 s, τR = 900 s, C = 1000 ticks. With V = 1 tick²/s, σ_h = 100·√12 = 346.41 pips.
contract StoikovHookFeesTest is Test {
    int256 internal constant X16 = 1 << 16;
    uint256 internal constant VARIANCE_SCALE = 1e12;
    uint64 internal constant ONE_TICK_SQ_PER_S = 1e12;

    StoikovHookHarness internal hook;
    uint160 internal namespace = 0x5555;

    function setUp() public {
        hook = _deploy(defaultFeeParams());
    }

    // ------------------------------------------------------------------
    // Inventory skew: positive, negative and zero
    // ------------------------------------------------------------------

    function test_skewZero_bothDirectionsPayTheSame() public view {
        (uint24 feeUp, uint24 feeDown, uint256 sigmaHPips) = hook.computeFees(ONE_TICK_SQ_PER_S, 0);
        assertEq(sigmaHPips, 346, "sigma_h = 100 * sqrt(12)");
        assertEq(feeUp, 846, "f0 + alpha * sigma_h");
        assertEq(feeDown, 846, "no displacement, no skew");
    }

    function test_skewPositive_priceUpPaysMore() public view {
        // Price 100 ticks above the reference: q = +0.5, skew = beta * sigma_h * 0.5 = 86.6 pips.
        (uint24 feeUp, uint24 feeDown,) = hook.computeFees(ONE_TICK_SQ_PER_S, 100 * X16);
        assertEq(feeUp, 933, "846.41 + 86.60");
        assertEq(feeDown, 759, "846.41 - 86.60");
    }

    function test_skewNegative_priceDownPaysMore() public view {
        (uint24 feeUp, uint24 feeDown,) = hook.computeFees(ONE_TICK_SQ_PER_S, -100 * X16);
        assertEq(feeUp, 759, "mirror image of the positive case");
        assertEq(feeDown, 933, "mirror image of the positive case");
    }

    function test_skewSaturatesAtFullSkewTicks() public view {
        (uint24 upAtQ, uint24 downAtQ,) = hook.computeFees(ONE_TICK_SQ_PER_S, 200 * X16);
        (uint24 upFar, uint24 downFar,) = hook.computeFees(ONE_TICK_SQ_PER_S, 10_000 * X16);
        assertEq(upAtQ, 1019, "846.41 + 173.21 at q = 1");
        assertEq(downAtQ, 673, "846.41 - 173.21 at q = 1");
        assertEq(upFar, upAtQ, "q is capped at 1");
        assertEq(downFar, downAtQ, "q is capped at 1");
    }

    function test_zeroVolatility_feesEqualBaseFeeWithNoSkew() public view {
        (uint24 feeUp, uint24 feeDown,) = hook.computeFees(0, 500 * X16);
        assertEq(feeUp, 500, "no risk, no premium");
        assertEq(feeDown, 500, "no risk, no skew");
    }

    function test_betaEqualsAlpha_rebalancingSideFloorsExactlyAtBaseFee() public {
        // beta = alpha is the boundary the constructor allows: at full skew the rebalancing side pays
        // f0 + sigma_h * (alpha - beta) = f0 exactly, never less.
        FeeParams memory p = defaultFeeParams();
        p.betaWad = p.alphaWad;
        StoikovHookHarness custom = _deploy(p);

        (uint24 feeUp, uint24 feeDown,) = custom.computeFees(ONE_TICK_SQ_PER_S, 200 * X16);
        assertEq(feeDown, p.baseFee, "rebalancing side lands exactly on f0");
        assertEq(feeUp, 1192, "500 + 2 * 346.41");
    }

    // ------------------------------------------------------------------
    // Volatility: higher volatility raises both fees
    // ------------------------------------------------------------------

    function test_higherVolatility_raisesBothFees() public view {
        // Quadrupling the variance doubles sigma_h: 346.41 -> 692.82 pips.
        (uint24 upLow, uint24 downLow,) = hook.computeFees(ONE_TICK_SQ_PER_S, 0);
        (uint24 upHigh, uint24 downHigh,) = hook.computeFees(4 * ONE_TICK_SQ_PER_S, 0);
        assertEq(upHigh, 1192, "500 + 692.82");
        assertGt(upHigh, upLow);
        assertGt(downHigh, downLow);

        // With full skew, the rebalancing side still rises because alpha > beta.
        (upLow, downLow,) = hook.computeFees(ONE_TICK_SQ_PER_S, 200 * X16);
        (upHigh, downHigh,) = hook.computeFees(4 * ONE_TICK_SQ_PER_S, 200 * X16);
        assertGt(upHigh, upLow, "imbalancing side rises");
        assertGt(downHigh, downLow, "rebalancing side rises too");
    }

    function test_extremeVolatility_clampsAtMaxFee() public view {
        // V = C^2: a 1000-tick move every second.
        (uint24 feeUp, uint24 feeDown,) = hook.computeFees(1000 * 1000 * VARIANCE_SCALE, -300 * X16);
        assertEq(feeUp, hook.maxFee());
        assertEq(feeDown, hook.maxFee());
    }

    // ------------------------------------------------------------------
    // Bounds: any input, any valid parameters
    // ------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_computeFees_withinBoundsForAnyInput(uint64 variance, int256 displacementX16) public view {
        (uint24 feeUp, uint24 feeDown,) = hook.computeFees(variance, displacementX16);
        _assertFeeInvariants(feeUp, feeDown, displacementX16, defaultFeeParams());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_computeFees_withinBoundsForAnyValidParams(
        FeeParams memory params,
        uint64 variance,
        int256 displacementX16
    ) public {
        params = _boundParams(params);
        StoikovHookHarness custom = _deploy(params);

        (uint24 feeUp, uint24 feeDown,) = custom.computeFees(variance, displacementX16);
        _assertFeeInvariants(feeUp, feeDown, displacementX16, params);
    }

    // ------------------------------------------------------------------
    // Window update (spec §2.4)
    // ------------------------------------------------------------------

    function test_openWindow_followsSpecRecursion() public {
        vm.warp(1_000_000);
        StoikovHook.PoolState memory state = _state(0, 0, ONE_TICK_SQ_PER_S, uint32(block.timestamp - 12));

        (StoikovHook.PoolState memory next,) = hook.openWindow(state, 10);

        // V' = (tau_sigma * V + delta^2) / (tau_sigma + dt), R' = (tau_R * R + dt * tick) / (tau_R + dt)
        assertEq(next.variance, (300 * ONE_TICK_SQ_PER_S + 10 * 10 * VARIANCE_SCALE) / (300 + 12), "variance");
        assertEq(next.refTickX16, (12 * 10 * X16) / (900 + 12), "reference");
        assertEq(next.lastTick, 10);
        assertEq(next.lastTimestamp, block.timestamp);
        assertEq(next.lastBlock, block.number);
    }

    function test_openWindow_sameTimestamp_floorsElapsedAtOneSecond() public {
        vm.warp(1_000_000);
        StoikovHook.PoolState memory state = _state(0, 0, ONE_TICK_SQ_PER_S, uint32(block.timestamp));

        (StoikovHook.PoolState memory next,) = hook.openWindow(state, 100);

        assertEq(next.variance, (300 * ONE_TICK_SQ_PER_S + 100 * 100 * VARIANCE_SCALE) / (300 + 1), "dt = 1");
        assertEq(next.refTickX16, (1 * 100 * X16) / (900 + 1), "dt = 1");
    }

    function test_openWindow_winsorizesLargeMoves() public {
        vm.warp(1_000_000);
        StoikovHook.PoolState memory state = _state(0, 0, ONE_TICK_SQ_PER_S, uint32(block.timestamp - 12));

        (StoikovHook.PoolState memory next,) = hook.openWindow(state, 5000);

        assertEq(next.variance, (300 * ONE_TICK_SQ_PER_S + 1000 * 1000 * VARIANCE_SCALE) / (300 + 12), "capped at C");
    }

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_openWindow_isTotalAndBounded(
        int24 lastTick,
        int24 tick,
        int40 refTickX16,
        uint64 variance,
        uint32 lastTimestamp,
        uint32 nowTimestamp,
        uint40 blockNumber
    ) public {
        lastTick = int24(bound(lastTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        refTickX16 = int40(bound(refTickX16, int256(TickMath.MIN_TICK) * X16, int256(TickMath.MAX_TICK) * X16));
        vm.warp(nowTimestamp);
        vm.roll(blockNumber);

        (StoikovHook.PoolState memory next,) =
            hook.openWindow(_state(lastTick, refTickX16, variance, lastTimestamp), tick);

        FeeParams memory params = defaultFeeParams();
        _assertFeeInvariants(next.feeUp, next.feeDown, int256(tick) * X16 - next.refTickX16, params);

        uint256 varianceCap = uint256(params.maxTickDelta) * params.maxTickDelta * VARIANCE_SCALE;
        assertLe(next.variance, variance > varianceCap ? variance : varianceCap, "variance stays a weighted average");

        int256 tickX16 = int256(tick) * X16;
        assertGe(next.refTickX16, refTickX16 < tickX16 ? refTickX16 : tickX16, "reference between old R and tick");
        assertLe(next.refTickX16, refTickX16 > tickX16 ? refTickX16 : tickX16, "reference between old R and tick");
        assertEq(next.lastTick, tick);
        assertEq(next.lastBlock, blockNumber);
    }

    // ------------------------------------------------------------------
    // Parameter validation (spec §5.1)
    // ------------------------------------------------------------------

    function test_validateFeeParams_acceptsDefaults() public view {
        hook.validateFeeParams(defaultFeeParams());
    }

    function test_validateFeeParams_rejectsEachInvalidParameter() public {
        FeeParams memory p;

        p = defaultFeeParams();
        p.minFee = 0;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.minFee = p.baseFee + 1;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.baseFee = p.maxFee + 1;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.maxFee = hook.FEE_CEILING() + 1;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.betaWad = p.alphaWad + 1;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.alphaWad = hook.MAX_ALPHA_WAD() + 1;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.horizon = 0;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.horizon = hook.MAX_HORIZON() + 1;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.volTau = 0;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.refTau = 0;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.fullSkewTicks = 0;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.maxTickDelta = 0;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.maxTickDelta = hook.MAX_TICK_DELTA_LIMIT() + 1;
        _expectInvalid(p);

        p = defaultFeeParams();
        p.initialVariance = uint64(uint256(p.maxTickDelta) * p.maxTickDelta * VARIANCE_SCALE + 1);
        _expectInvalid(p);
    }

    function test_constructor_revertsOnInvalidParams() public {
        FeeParams memory p = defaultFeeParams();
        p.betaWad = p.alphaWad + 1;

        // Same steps as forge-std's deployCodeTo, which hides the constructor's revert reason.
        address where = _nextHookAddress();
        vm.etch(where, abi.encodePacked(vm.getCode("StoikovHook.sol:StoikovHook"), abi.encode(address(0xBEEF), p)));
        (bool success, bytes memory revertData) = where.call("");

        assertFalse(success, "construction must fail");
        assertEq(revertData, abi.encodeWithSelector(StoikovHook.InvalidFeeParams.selector));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _assertFeeInvariants(uint24 feeUp, uint24 feeDown, int256 displacementX16, FeeParams memory p)
        internal
        pure
    {
        assertGe(feeUp, p.minFee, "feeUp >= fmin");
        assertLe(feeUp, p.maxFee, "feeUp <= fmax");
        assertGe(feeDown, p.minFee, "feeDown >= fmin");
        assertLe(feeDown, p.maxFee, "feeDown <= fmax");

        // With beta <= alpha, the skew never takes either side below f0 (spec §2.3, property 3).
        assertGe(feeUp, p.baseFee, "feeUp >= f0");
        assertGe(feeDown, p.baseFee, "feeDown >= f0");

        // The side that extends the displacement never pays less than the side that reverts it.
        if (displacementX16 > 0) assertGe(feeUp, feeDown, "price above reference: up >= down");
        else if (displacementX16 < 0) assertGe(feeDown, feeUp, "price below reference: down >= up");
        else assertEq(feeUp, feeDown, "no displacement: symmetric");
    }

    function _boundParams(FeeParams memory p) internal view returns (FeeParams memory) {
        p.minFee = uint24(bound(p.minFee, 1, hook.FEE_CEILING()));
        p.baseFee = uint24(bound(p.baseFee, p.minFee, hook.FEE_CEILING()));
        p.maxFee = uint24(bound(p.maxFee, p.baseFee, hook.FEE_CEILING()));
        p.alphaWad = uint64(bound(p.alphaWad, 0, hook.MAX_ALPHA_WAD()));
        p.betaWad = uint64(bound(p.betaWad, 0, p.alphaWad));
        p.horizon = uint32(bound(p.horizon, 1, hook.MAX_HORIZON()));
        p.volTau = uint32(bound(p.volTau, 1, type(uint32).max));
        p.refTau = uint32(bound(p.refTau, 1, type(uint32).max));
        p.fullSkewTicks = uint24(bound(p.fullSkewTicks, 1, type(uint24).max));
        p.maxTickDelta = uint24(bound(p.maxTickDelta, 1, hook.MAX_TICK_DELTA_LIMIT()));
        p.initialVariance =
            uint64(bound(p.initialVariance, 0, uint256(p.maxTickDelta) * p.maxTickDelta * VARIANCE_SCALE));
        return p;
    }

    function _expectInvalid(FeeParams memory p) internal {
        vm.expectRevert(StoikovHook.InvalidFeeParams.selector);
        hook.validateFeeParams(p);
    }

    function _deploy(FeeParams memory p) internal returns (StoikovHookHarness h) {
        address where = _nextHookAddress();
        deployCodeTo(
            "StoikovHookHarness.sol:StoikovHookHarness", abi.encode(IPoolManager(address(0xBEEF)), p), where
        );
        return StoikovHookHarness(where);
    }

    /// @dev A fresh address whose low 14 bits carry the hook's permission flags.
    function _nextHookAddress() internal returns (address) {
        return address(STOIKOV_HOOK_FLAGS ^ (namespace++ << 144));
    }

    function _state(int24 lastTick, int40 refTickX16, uint64 variance, uint32 lastTimestamp)
        internal
        pure
        returns (StoikovHook.PoolState memory)
    {
        return StoikovHook.PoolState({
            lastBlock: 0,
            lastTimestamp: lastTimestamp,
            lastTick: lastTick,
            refTickX16: refTickX16,
            variance: variance,
            feeUp: 0,
            feeDown: 0
        });
    }
}
