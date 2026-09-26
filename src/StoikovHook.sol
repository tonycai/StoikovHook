// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Address flags StoikovHook must be deployed with: afterInitialize | beforeSwap (0x1080).
///      Single source of truth for deployment scripts and tests, which need the flags before the
///      hook exists. Must equal the flags implied by StoikovHook.getHookPermissions(); the BaseHook
///      constructor rejects any mismatch.
uint160 constant STOIKOV_HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

/// @notice Deployment parameters of the fee model (specs/01-design.md §2.7). Fees are in pips
///         (hundredths of a bip: 3000 = 0.30%).
struct FeeParams {
    /// @dev f0: fee floor in calm markets.
    uint24 baseFee;
    /// @dev fmin: hard lower bound on any fee.
    uint24 minFee;
    /// @dev fmax: hard upper bound on any fee.
    uint24 maxFee;
    /// @dev α: volatility premium per unit of horizon volatility, WAD (1e18 = 1.0).
    uint64 alphaWad;
    /// @dev β: maximum inventory skew per unit of horizon volatility, WAD. Must not exceed α.
    uint64 betaWad;
    /// @dev h: seconds of price movement the fee is sized for.
    uint32 horizon;
    /// @dev τσ: memory of the volatility estimator, in seconds.
    uint32 volTau;
    /// @dev τR: memory of the equilibrium reference price, in seconds.
    uint32 refTau;
    /// @dev Q: displacement from the reference, in ticks, at which the skew saturates.
    uint24 fullSkewTicks;
    /// @dev C: winsorization bound on a single window-to-window tick change.
    uint24 maxTickDelta;
    /// @dev V0: variance a new pool starts with, in ticks²/s scaled by VARIANCE_SCALE (1e12).
    uint64 initialVariance;
}

/// @notice Defaults for an ETH/USDC-class pair on 12-second blocks (spec §2.7, approved in §7).
function defaultFeeParams() pure returns (FeeParams memory) {
    return FeeParams({
        baseFee: 500, // 0.05%
        minFee: 100, // 0.01%
        maxFee: 10_000, // 1%
        alphaWad: 1e18, // the premium equals one horizon-sigma
        betaWad: 0.5e18, // the skew moves each side by at most half a horizon-sigma
        // One block on Ethereum and Sepolia. The share of LVR that arbitrageurs capture depends
        // on fee / (σ·√blockTime), so the fee is sized against one block of volatility.
        horizon: 12,
        // About 25 blocks: long enough to average out single-block noise, short enough to react
        // to a volatility regime change within minutes (half-life ≈ 208 s).
        volTau: 300,
        // 3 × volTau: the reference tracks the recent equilibrium rather than the current price
        // (half-life ≈ 624 s).
        refTau: 900,
        // ≈ 2%: about 6 standard deviations of 15-minute price movement at 60% annualized volatility.
        fullSkewTicks: 200,
        maxTickDelta: 1000, // ≈ 10% per observation
        initialVariance: 1e12 // 1 tick²/s ≈ 56% annualized volatility
    });
}

/// @title StoikovHook
/// @notice Uniswap v4 dynamic-fee hook that prices swaps like an Avellaneda–Stoikov market maker.
///         Every block, it posts one fee for swaps that push the price up and one for swaps that push
///         it down: f = clamp(f0 + σ_h·(α ± β·q̂), fmin, fmax) (specs/01-design.md §2.3).
/// @dev σ_h is an EWMA estimate of tick volatility over the horizon h, in pips. q̂ ∈ [-1, 1] is the
///      pool tick's displacement from a slow EMA of its own price. Both are updated once per block,
///      on the block's first swap, from the pool's own slot0 tick; later swaps in the block reuse the
///      cached fees.
contract StoikovHook is BaseOverrideFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Per-pool state, packed into one 248-bit storage slot (spec §3.1).
    struct PoolState {
        /// @dev Block number of the last window open: the fee window key (spec §7).
        uint40 lastBlock;
        /// @dev Timestamp of the last window open, used for elapsed time.
        uint32 lastTimestamp;
        /// @dev Pool tick at the last window open.
        int24 lastTick;
        /// @dev EMA reference tick R, with 16 fractional bits.
        int40 refTickX16;
        /// @dev EWMA variance V, in ticks²/s scaled by VARIANCE_SCALE.
        uint64 variance;
        /// @dev Cached fee for price-up swaps (zeroForOne = false).
        uint24 feeUp;
        /// @dev Cached fee for price-down swaps (zeroForOne = true).
        uint24 feeDown;
    }

    /// @notice Address flags the hook is deployed with: afterInitialize | beforeSwap (0x1080).
    uint160 public constant HOOK_FLAGS = STOIKOV_HOOK_FLAGS;
    /// @notice Fixed-point scale of the stored variance.
    uint256 public constant VARIANCE_SCALE = 1e12;
    /// @notice Deploy-time ceiling on maxFee (10%), far below v4's MAX_LP_FEE (100%).
    uint24 public constant FEE_CEILING = 100_000;
    /// @notice Deploy-time ceiling on α.
    uint64 public constant MAX_ALPHA_WAD = 10e18;
    /// @notice Deploy-time ceiling on the horizon h.
    uint32 public constant MAX_HORIZON = 1 days;
    /// @notice Deploy-time ceiling on C, so that C² · VARIANCE_SCALE fits the uint64 variance.
    uint24 public constant MAX_TICK_DELTA_LIMIT = 4000;

    uint256 internal constant WAD = 1e18;
    int256 internal constant X16 = 1 << 16;
    /// @dev One tick moves the price by ln(1.0001) ≈ 1e-4, i.e. about 100 pips (99.995 exactly).
    uint256 internal constant PIPS_PER_TICK = 100;

    uint24 public immutable baseFee;
    uint24 public immutable minFee;
    uint24 public immutable maxFee;
    uint64 public immutable alphaWad;
    uint64 public immutable betaWad;
    uint32 public immutable horizon;
    uint32 public immutable volTau;
    uint32 public immutable refTau;
    uint24 public immutable fullSkewTicks;
    uint24 public immutable maxTickDelta;
    uint64 public immutable initialVariance;

    mapping(PoolId => PoolState) internal _poolState;

    /// @notice Emitted when a pool's fee window opens, and once at initialization.
    /// @param sigmaHPips One-horizon volatility σ_h in pips, rounded down.
    event FeeWindowUpdated(
        PoolId indexed id, int24 tick, int24 refTick, uint256 sigmaHPips, uint24 feeUp, uint24 feeDown
    );

    error InvalidFeeParams();

    constructor(IPoolManager _poolManager, FeeParams memory params) BaseOverrideFee(_poolManager) {
        _validateFeeParams(params);
        baseFee = params.baseFee;
        minFee = params.minFee;
        maxFee = params.maxFee;
        alphaWad = params.alphaWad;
        betaWad = params.betaWad;
        horizon = params.horizon;
        volTau = params.volTau;
        refTau = params.refTau;
        fullSkewTicks = params.fullSkewTicks;
        maxTickDelta = params.maxTickDelta;
        initialVariance = params.initialVariance;
    }

    /// @notice Returns the stored state of a pool.
    function getPoolState(PoolId id) external view returns (PoolState memory) {
        return _poolState[id];
    }

    /// @notice Returns the fees the next swap in the pool would pay in the current block.
    function previewFees(PoolKey calldata key) external view returns (uint24 feeUp, uint24 feeDown) {
        PoolId id = key.toId();
        PoolState memory state = _poolState[id];
        if (block.number > state.lastBlock) {
            (, int24 tick,,) = poolManager.getSlot0(id);
            (state,) = _openWindow(state, tick);
        }
        return (state.feeUp, state.feeDown);
    }

    /// @dev Rejects static-fee pools (checked in BaseOverrideFee), seeds the estimators and stores
    ///      baseFee as the pool's fallback LP fee (spec §4.1).
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        super._afterInitialize(sender, key, sqrtPriceX96, tick);

        PoolId id = key.toId();
        (uint24 feeUp, uint24 feeDown, uint256 sigmaHPips) = _computeFees(initialVariance, 0);
        _poolState[id] = PoolState({
            lastBlock: uint40(block.number),
            lastTimestamp: uint32(block.timestamp),
            lastTick: tick,
            refTickX16: int40(int256(tick) * X16),
            variance: initialVariance,
            feeUp: feeUp,
            feeDown: feeDown
        });
        emit FeeWindowUpdated(id, tick, tick, sigmaHPips, feeUp, feeDown);

        poolManager.updateDynamicLPFee(key, baseFee);
        return this.afterInitialize.selector;
    }

    /// @dev Opens a new fee window on the first swap of each block, then returns the cached fee for
    ///      the swap's direction. BaseOverrideFee adds OVERRIDE_FEE_FLAG to the result.
    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = key.toId();
        PoolState memory state = _poolState[id];

        if (block.number > state.lastBlock) {
            (, int24 tick,,) = poolManager.getSlot0(id);
            uint256 sigmaHPips;
            (state, sigmaHPips) = _openWindow(state, tick);
            _poolState[id] = state;
            emit FeeWindowUpdated(
                id, tick, int24(int256(state.refTickX16) / X16), sigmaHPips, state.feeUp, state.feeDown
            );
        }

        return params.zeroForOne ? state.feeDown : state.feeUp;
    }

    /// @dev Updates the estimators with the window-open tick and recomputes both fees (spec §2.4).
    function _openWindow(PoolState memory state, int24 tick)
        internal
        view
        returns (PoolState memory next, uint256 sigmaHPips)
    {
        // Elapsed seconds, floored at 1 because consecutive blocks can share a timestamp. The floor
        // keeps both updates weighted averages, so V never exceeds max(V, C² · VARIANCE_SCALE).
        uint256 elapsed = block.timestamp > state.lastTimestamp ? block.timestamp - state.lastTimestamp : 1;

        // V ← (τσ·V + Δ²) / (τσ + Δt), with the window-to-window tick change Δ winsorized at ±C.
        uint256 tickDelta = FixedPointMathLib.min(FixedPointMathLib.abs(int256(tick) - state.lastTick), maxTickDelta);
        uint256 variance =
            (uint256(volTau) * state.variance + tickDelta * tickDelta * VARIANCE_SCALE) / (uint256(volTau) + elapsed);

        // R ← (τR·R + Δt·tick) / (τR + Δt), on ticks with 16 fractional bits.
        int256 tickX16 = int256(tick) * X16;
        int256 refX16 = (int256(uint256(refTau)) * state.refTickX16 + int256(elapsed) * tickX16)
            / int256(uint256(refTau) + elapsed);

        uint24 feeUp;
        uint24 feeDown;
        (feeUp, feeDown, sigmaHPips) = _computeFees(variance, tickX16 - refX16);

        next = PoolState({
            lastBlock: uint40(block.number),
            lastTimestamp: uint32(block.timestamp),
            lastTick: tick,
            refTickX16: int40(refX16),
            variance: uint64(variance),
            feeUp: feeUp,
            feeDown: feeDown
        });
    }

    /// @dev f(s) = clamp(f0 + σ_h·(α + β·s·q̂), fmin, fmax), computed in WAD-scaled pips (spec §2.3).
    ///      Total for any variance < 2^64 and any displacement: no input makes it revert.
    /// @param variance EWMA variance in ticks²/s, scaled by VARIANCE_SCALE.
    /// @param displacementX16 Pool tick minus the reference tick, with 16 fractional bits.
    function _computeFees(uint256 variance, int256 displacementX16)
        internal
        view
        returns (uint24 feeUp, uint24 feeDown, uint256 sigmaHPips)
    {
        // σ_h = √(h·V): in ticks scaled by 1e6, since V is scaled by 1e12. Then ticks → pips (×100)
        // and 1e6 → WAD (×1e12).
        uint256 sigmaHPipsWad = FixedPointMathLib.sqrt(uint256(horizon) * variance) * (PIPS_PER_TICK * 1e12);
        sigmaHPips = sigmaHPipsWad / WAD;

        uint256 baseWad = uint256(baseFee) * WAD + FixedPointMathLib.mulWad(sigmaHPipsWad, alphaWad);

        // Skew magnitude β·σ_h·|q̂|, where |q̂| = min(|displacement| / Q, 1).
        uint256 fullSkewX16 = uint256(fullSkewTicks) << 16;
        uint256 displacement = FixedPointMathLib.min(FixedPointMathLib.abs(displacementX16), fullSkewX16);
        uint256 skewWad =
            FixedPointMathLib.mulDiv(FixedPointMathLib.mulWad(sigmaHPipsWad, betaWad), displacement, fullSkewX16);

        // Price above the reference: price-up swaps push it further away and pay +β; price-down swaps
        // bring it back and pay −β. Mirrored when the price is below the reference.
        (uint256 upWad, uint256 downWad) = displacementX16 >= 0
            ? (baseWad + skewWad, FixedPointMathLib.zeroFloorSub(baseWad, skewWad))
            : (FixedPointMathLib.zeroFloorSub(baseWad, skewWad), baseWad + skewWad);

        feeUp = uint24(FixedPointMathLib.clamp(upWad / WAD, minFee, maxFee));
        feeDown = uint24(FixedPointMathLib.clamp(downWad / WAD, minFee, maxFee));
    }

    /// @dev Deploy-time invariants (spec §5.1). They bound every intermediate value in _computeFees
    ///      and _openWindow, so the fee path cannot overflow or revert.
    function _validateFeeParams(FeeParams memory p) internal pure {
        if (p.minFee == 0 || p.minFee > p.baseFee || p.baseFee > p.maxFee || p.maxFee > FEE_CEILING) {
            revert InvalidFeeParams();
        }
        if (p.betaWad > p.alphaWad || p.alphaWad > MAX_ALPHA_WAD) revert InvalidFeeParams();
        if (p.horizon == 0 || p.horizon > MAX_HORIZON) revert InvalidFeeParams();
        if (p.volTau == 0 || p.refTau == 0 || p.fullSkewTicks == 0) revert InvalidFeeParams();
        if (p.maxTickDelta == 0 || p.maxTickDelta > MAX_TICK_DELTA_LIMIT) revert InvalidFeeParams();
        if (p.initialVariance > uint256(p.maxTickDelta) * p.maxTickDelta * VARIANCE_SCALE) revert InvalidFeeParams();
    }
}
