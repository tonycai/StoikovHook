// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {StoikovHook, STOIKOV_HOOK_FLAGS, defaultFeeParams} from "../../src/StoikovHook.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {SimTrader} from "./SimTrader.sol";
import {SimLiquidityProvider} from "./SimLiquidityProvider.sol";

/// @title ComparisonSimulationTest
/// @notice Runs identical order flow through a StoikovHook pool and static-fee pools, and reports LP
///         outcomes (spec §6, M3). Deterministic, local only, no RPC, about 10 seconds:
///
///   FOUNDRY_PROFILE=sim forge test -vv
///
///         Results are written to docs/simulation/ (per_seed.csv, summary.json, timeseries_seed0.csv).
///         The assertions only check that the harness is sound; they never assert which pool wins.
///
/// @dev Model, per seed:
///      - An exogenous "true" price path, in ticks: a trend segment (drift plus noise, an information-driven
///        move) followed by a mean-reverting segment (noise around the trend's end level). Only this
///        simulation knows the path; the hook never reads it.
///      - Every block, the arbitrageur trades first in each pool. It pushes the pool price to the edge of
///        the no-arbitrage band around the true price, using that pool's actual fee for the direction, so
///        it only trades when that is profitable after fees. This is the source of LVR.
///      - Then 0-3 noise trades with a random direction and size, identical across pools.
///      - Pools: StoikovHook (dynamic), a fee-matched static pool whose fee equals the volume-weighted
///        average fee noise traders paid in the StoikovHook pool (the primary control, spec §7), and static
///        0.05% and 0.30% pools for reference. All start with the same full-range liquidity at tick 0.
///      Values are in token1 at the true price. LP minus HODL is valued at the final true price. Fees and
///      arbitrage profit are valued at the true price of their block.
contract ComparisonSimulationTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------
    // Scenario
    // ------------------------------------------------------------------

    uint256 internal constant SEEDS = 20;
    uint256 internal constant TREND_BLOCKS = 200;
    uint256 internal constant REVERSION_BLOCKS = 200;
    uint256 internal constant BLOCKS = TREND_BLOCKS + REVERSION_BLOCKS;
    uint256 internal constant BLOCK_TIME = 12;
    /// @dev Trend: 5 ticks per block, ≈ +/-10.5% over the segment; the direction alternates by seed.
    int256 internal constant DRIFT_TICKS = 5;
    /// @dev Per-block standard deviation of the true price: 10 ticks (0.1% per 12-second block).
    int256 internal constant VOL_TICKS = 10;
    /// @dev Mean reversion per block toward the trend's end level: 0.05 (half-life ≈ 14 blocks), 1e4 scale.
    int256 internal constant REVERSION_E4 = 500;
    uint128 internal constant LIQUIDITY = 1_000e18;
    uint256 internal constant MAX_NOISE_TRADES = 3;
    uint256 internal constant NOISE_MIN = 0.05e18;
    uint256 internal constant NOISE_MAX = 1e18;
    /// @dev Exact-input cap for arbitrage swaps; the price limit always binds first.
    int256 internal constant ARB_BUDGET = 1e27;
    uint256 internal constant TRADER_FUNDING = 1_000_000e18;

    // ------------------------------------------------------------------
    // Output layout
    // ------------------------------------------------------------------

    string internal constant OUT_DIR = "docs/simulation";
    string internal constant PER_SEED_CSV = "docs/simulation/per_seed.csv";
    string internal constant SERIES_CSV = "docs/simulation/timeseries_seed0.csv";
    string internal constant SUMMARY_JSON = "docs/simulation/summary.json";

    uint256 internal constant POOLS = 4;
    uint256 internal constant DYNAMIC = 0;
    uint256 internal constant FEE_MATCHED = 1;
    uint256 internal constant STATIC_5BP = 2;
    uint256 internal constant STATIC_30BP = 3;

    /// @dev Metric columns. Values in "mbps" are thousandths of a basis point of the pool's initial value.
    uint256 internal constant METRICS = 14;
    uint256 internal constant M_LP_MINUS_HODL = 0; // mbps
    uint256 internal constant M_FEE_INCOME = 1; // mbps
    uint256 internal constant M_FEE_NOISE = 2; // mbps, fees paid by noise traders
    uint256 internal constant M_FEE_ARB = 3; // mbps, fees paid by the arbitrageur
    uint256 internal constant M_ARB_PROFIT = 4; // mbps, arbitrageur profit after fees (LVR proxy)
    uint256 internal constant M_ARB_PROFIT_TREND = 5; // mbps
    uint256 internal constant M_ARB_PROFIT_REVERSION = 6; // mbps
    uint256 internal constant M_ARB_FEE_TREND = 7; // mbps
    uint256 internal constant M_ARB_FEE_REVERSION = 8; // mbps
    uint256 internal constant M_AVG_FEE_UP = 9; // pips, volume-weighted over price-up swaps
    uint256 internal constant M_AVG_FEE_DOWN = 10; // pips, volume-weighted over price-down swaps
    uint256 internal constant M_AVG_FEE_NOISE = 11; // pips, volume-weighted over noise trades
    uint256 internal constant M_AVG_FEE_ARB = 12; // pips, volume-weighted over arbitrage trades
    uint256 internal constant M_ARB_TRADES = 13; // count

    struct Stats {
        int256 flow0; // Σ trader token0 deltas (negative = paid into the pool)
        int256 flow1;
        uint256 feeValue;
        int256[2] arbProfit; // [trend, reversion]
        uint256[2] volumeByDirection; // [price up, price down], input value
        uint256[2] feeVolumeByDirection; // Σ fee · input value
        uint256[2] volumeByFlow; // [noise, arbitrage]
        uint256[2] feeVolumeByFlow;
        uint256[2] feeValueByFlow; // [noise, arbitrage]
        uint256[2] arbFeeBySegment; // [trend, reversion]
        uint256 arbTrades;
    }

    struct Pool {
        PoolKey key;
        PoolId id;
        bool dynamic;
        uint256 initialValue;
        Stats stats;
    }

    struct Scenario {
        int24[] trueTicks; // index 0 is the starting price; index b is block b
        uint256[] noiseCount;
        bool[] noiseZeroForOne; // BLOCKS * MAX_NOISE_TRADES, row-major by block
        uint256[] noiseSize;
    }

    StoikovHook internal hook;
    PoolSwapTest internal swapper;
    SimTrader internal arbitrageur;
    SimTrader internal noiseTrader;
    SimLiquidityProvider internal liquidityProvider;

    function test_comparisonSimulation() public {
        // The run executes ~80,000 swaps; gas accounting is irrelevant to the results.
        vm.pauseGasMetering();

        deployArtifacts();
        swapper = new PoolSwapTest(poolManager);
        hook = _deployHook();
        vm.createDir(OUT_DIR, true);
        vm.writeFile(SERIES_CSV, "block,segment,true_tick,pool_tick,fee_up_pips,fee_down_pips\n");

        int256[METRICS][POOLS][SEEDS] memory results;
        uint24[SEEDS] memory matchedFees;
        for (uint256 seed; seed < SEEDS; ++seed) {
            (results[seed], matchedFees[seed]) = _runSeed(seed);
        }

        _writePerSeedCsv(results, matchedFees);
        _writeSummaryJson(results, matchedFees);
        _printSummary(results, matchedFees);

        // Harness checks only; none of them asserts which pool wins.
        for (uint256 seed; seed < SEEDS; ++seed) {
            int256 matched = int256(uint256(matchedFees[seed]));
            assertEq(results[seed][FEE_MATCHED][M_AVG_FEE_NOISE], matched, "control charges noise the matched fee");
            assertApproxEqAbs(
                results[seed][DYNAMIC][M_AVG_FEE_NOISE], matched, 1, "noise pays the same average fee in both pools"
            );
            for (uint256 p; p < POOLS; ++p) {
                assertGe(results[seed][p][M_ARB_PROFIT], -1, "arbitrage only trades when profitable after fees");
                assertGt(results[seed][p][M_ARB_TRADES], 0, "the arbitrageur is active in every pool");
            }
        }
    }

    // ------------------------------------------------------------------
    // One seed
    // ------------------------------------------------------------------

    function _runSeed(uint256 seed) internal returns (int256[METRICS][POOLS] memory metrics, uint24 matchedFee) {
        Scenario memory scenario = _scenario(seed);

        // Fresh tokens per seed give fresh pools with the same keys otherwise. Every participant is its
        // own contract: forge scripts must not use the script contract's address.
        (Currency currency0, Currency currency1) = _deployTokens();
        arbitrageur = _newTrader(currency0, currency1);
        noiseTrader = _newTrader(currency0, currency1);
        liquidityProvider = new SimLiquidityProvider(positionManager, permit2);
        _fund(currency0, currency1, address(liquidityProvider), 4 * uint256(LIQUIDITY) + 1e18);

        Pool[POOLS] memory pools;
        pools[DYNAMIC] = _createPool(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        pools[STATIC_5BP] = _createPool(currency0, currency1, 500, 60, IHooks(address(0)));
        pools[STATIC_30BP] = _createPool(currency0, currency1, 3000, 60, IHooks(address(0)));

        bool[POOLS] memory active;
        active[DYNAMIC] = true;
        active[STATIC_5BP] = true;
        active[STATIC_30BP] = true;
        _replay(scenario, pools, active, seed == 0);

        // Fee-matched control: the average fee noise traders actually paid in the StoikovHook pool.
        // A different tick spacing keeps its key unique; with full-range liquidity it does not change
        // the pool's behavior near the traded prices.
        Stats memory dynamicStats = pools[DYNAMIC].stats;
        matchedFee = uint24(
            (dynamicStats.feeVolumeByFlow[0] + dynamicStats.volumeByFlow[0] / 2) / dynamicStats.volumeByFlow[0]
        );
        pools[FEE_MATCHED] = _createPool(currency0, currency1, matchedFee, 10, IHooks(address(0)));

        active[DYNAMIC] = false;
        active[STATIC_5BP] = false;
        active[STATIC_30BP] = false;
        active[FEE_MATCHED] = true;
        _replay(scenario, pools, active, false);

        uint256 finalPriceWad = _priceWad(TickMath.getSqrtPriceAtTick(scenario.trueTicks[BLOCKS]));
        for (uint256 p; p < POOLS; ++p) {
            metrics[p] = _metrics(pools[p], finalPriceWad);
        }
    }

    function _replay(Scenario memory scenario, Pool[POOLS] memory pools, bool[POOLS] memory active, bool record)
        internal
    {
        for (uint256 b = 1; b <= BLOCKS; ++b) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + BLOCK_TIME);

            uint256 segment = b <= TREND_BLOCKS ? 0 : 1;
            uint160 sqrtTrue = TickMath.getSqrtPriceAtTick(scenario.trueTicks[b]);
            uint256 priceWad = _priceWad(sqrtTrue);

            // Fees StoikovHook charges in this block, captured before its first swap opens the window.
            uint24 windowUp;
            uint24 windowDown;
            if (record) (windowUp, windowDown) = hook.previewFees(pools[DYNAMIC].key);

            for (uint256 p; p < POOLS; ++p) {
                if (active[p]) _arbitrage(pools[p], sqrtTrue, priceWad, segment);
            }
            for (uint256 j; j < scenario.noiseCount[b]; ++j) {
                uint256 k = (b - 1) * MAX_NOISE_TRADES + j;
                for (uint256 p; p < POOLS; ++p) {
                    if (active[p]) {
                        _noise(pools[p], scenario.noiseZeroForOne[k], scenario.noiseSize[k], priceWad, segment);
                    }
                }
            }

            if (record) _recordBlock(b, segment, scenario.trueTicks[b], pools[DYNAMIC].id, windowUp, windowDown);
        }
    }

    // ------------------------------------------------------------------
    // Order flow
    // ------------------------------------------------------------------

    /// @dev Trades the pool to the edge of the no-arbitrage band: P = S·(1 - f_up) from below, or
    ///      P = S / (1 - f_down) from above. At that price the marginal trade breaks even after fees.
    function _arbitrage(Pool memory pool, uint160 sqrtTrue, uint256 priceWad, uint256 segment) internal {
        (uint24 feeUp, uint24 feeDown) = _currentFees(pool);
        (uint160 sqrtPool,,,) = poolManager.getSlot0(pool.id);

        uint160 upTarget = uint160(FixedPointMathLib.mulDiv(sqrtTrue, _sqrtOneMinusFee(feeUp), 1e18));
        if (sqrtPool < upTarget) {
            _trade(pool, false, -ARB_BUDGET, upTarget, feeUp, priceWad, true, segment);
            return;
        }
        uint160 downTarget = uint160(FixedPointMathLib.mulDiv(sqrtTrue, 1e18, _sqrtOneMinusFee(feeDown)));
        if (sqrtPool > downTarget) {
            _trade(pool, true, -ARB_BUDGET, downTarget, feeDown, priceWad, true, segment);
        }
    }

    function _noise(Pool memory pool, bool zeroForOne, uint256 size, uint256 priceWad, uint256 segment) internal {
        (uint24 feeUp, uint24 feeDown) = _currentFees(pool);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        _trade(pool, zeroForOne, -int256(size), limit, zeroForOne ? feeDown : feeUp, priceWad, false, segment);
    }

    function _trade(
        Pool memory pool,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        uint24 fee,
        uint256 priceWad,
        bool isArb,
        uint256 segment
    ) internal {
        BalanceDelta delta = (isArb ? arbitrageur : noiseTrader).swap(pool.key, zeroForOne, amountSpecified, limit);
        _account(pool.stats, delta, zeroForOne, fee, priceWad, isArb, segment);
    }

    function _account(
        Stats memory s,
        BalanceDelta delta,
        bool zeroForOne,
        uint24 fee,
        uint256 priceWad,
        bool isArb,
        uint256 segment
    ) internal pure {
        int256 d0 = delta.amount0();
        int256 d1 = delta.amount1();
        s.flow0 += d0;
        s.flow1 += d1;

        uint256 inputValue = zeroForOne ? FixedPointMathLib.mulWad(uint256(-d0), priceWad) : uint256(-d1);
        uint256 feeVolume = inputValue * fee;
        s.feeValue += feeVolume / 1e6;

        uint256 direction = zeroForOne ? 1 : 0;
        s.volumeByDirection[direction] += inputValue;
        s.feeVolumeByDirection[direction] += feeVolume;

        uint256 flow = isArb ? 1 : 0;
        s.volumeByFlow[flow] += inputValue;
        s.feeVolumeByFlow[flow] += feeVolume;
        s.feeValueByFlow[flow] += feeVolume / 1e6;

        if (isArb) {
            s.arbProfit[segment] += d1 + FixedPointMathLib.sMulWad(d0, int256(priceWad));
            s.arbFeeBySegment[segment] += feeVolume / 1e6;
            s.arbTrades += 1;
        }
    }

    function _currentFees(Pool memory pool) internal view returns (uint24 feeUp, uint24 feeDown) {
        if (pool.dynamic) return hook.previewFees(pool.key);
        return (pool.key.fee, pool.key.fee);
    }

    // ------------------------------------------------------------------
    // Scenario generation (deterministic in the seed)
    // ------------------------------------------------------------------

    function _scenario(uint256 seed) internal pure returns (Scenario memory s) {
        s.trueTicks = new int24[](BLOCKS + 1);
        s.noiseCount = new uint256[](BLOCKS + 1);
        s.noiseZeroForOne = new bool[](BLOCKS * MAX_NOISE_TRADES);
        s.noiseSize = new uint256[](BLOCKS * MAX_NOISE_TRADES);

        int256 direction = seed % 2 == 0 ? int256(1) : int256(-1);
        int256 xE4; // true price in ticks, 1e4 fixed point
        int256 anchorE4;
        for (uint256 b = 1; b <= BLOCKS; ++b) {
            int256 shockE4 = VOL_TICKS * _standardNormalE4(_random(seed, b, 0));
            if (b <= TREND_BLOCKS) {
                xE4 += direction * DRIFT_TICKS * 1e4 + shockE4;
                anchorE4 = xE4;
            } else {
                xE4 += REVERSION_E4 * (anchorE4 - xE4) / 1e4 + shockE4;
            }
            s.trueTicks[b] = int24(xE4 / 1e4);

            s.noiseCount[b] = _random(seed, b, 1) % (MAX_NOISE_TRADES + 1);
            for (uint256 j; j < MAX_NOISE_TRADES; ++j) {
                uint256 r = _random(seed, b, 2 + j);
                uint256 k = (b - 1) * MAX_NOISE_TRADES + j;
                s.noiseZeroForOne[k] = (r & 1) == 1;
                s.noiseSize[k] = NOISE_MIN + (r >> 8) % (NOISE_MAX - NOISE_MIN);
            }
        }
    }

    function _random(uint256 seed, uint256 b, uint256 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, b, tag)));
    }

    /// @dev Approximately standard normal, scaled by 1e4: the sum of 12 uniforms minus 6 (Irwin-Hall).
    function _standardNormalE4(uint256 r) internal pure returns (int256) {
        uint256 sum;
        for (uint256 i; i < 12; ++i) {
            sum += (r >> (i * 16)) & 0xFFFF;
        }
        return (int256(2 * sum) - 786_420) * 1e4 / 131_072;
    }

    // ------------------------------------------------------------------
    // Setup helpers
    // ------------------------------------------------------------------

    function _deployHook() internal returns (StoikovHook) {
        address where = address(STOIKOV_HOOK_FLAGS ^ (0x4444 << 144));
        deployCodeTo("StoikovHook.sol:StoikovHook", abi.encode(poolManager, defaultFeeParams()), where);
        return StoikovHook(where);
    }

    function _deployTokens() internal returns (Currency currency0, Currency currency1) {
        MockERC20 tokenA = new MockERC20("Sim Token A", "SIMA", 18);
        MockERC20 tokenB = new MockERC20("Sim Token B", "SIMB", 18);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
    }

    function _newTrader(Currency currency0, Currency currency1) internal returns (SimTrader trader) {
        trader = new SimTrader(swapper, currency0, currency1);
        _fund(currency0, currency1, address(trader), TRADER_FUNDING);
    }

    function _fund(Currency currency0, Currency currency1, address account, uint256 amount) internal {
        MockERC20(Currency.unwrap(currency0)).mint(account, amount);
        MockERC20(Currency.unwrap(currency1)).mint(account, amount);
    }

    function _createPool(Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks)
        internal
        returns (Pool memory pool)
    {
        pool.key = PoolKey(currency0, currency1, fee, tickSpacing, hooks);
        pool.id = pool.key.toId();
        pool.dynamic = address(hooks) != address(0);
        poolManager.initialize(pool.key, Constants.SQRT_PRICE_1_1);

        (uint256 amount0, uint256 amount1) =
            liquidityProvider.mintFullRange(pool.key, Constants.SQRT_PRICE_1_1, LIQUIDITY);
        // At tick 0 the price is 1, so the initial value is simply amount0 + amount1.
        pool.initialValue = amount0 + amount1;
    }

    // ------------------------------------------------------------------
    // Metrics
    // ------------------------------------------------------------------

    function _metrics(Pool memory pool, uint256 finalPriceWad) internal pure returns (int256[METRICS] memory m) {
        Stats memory s = pool.stats;
        uint256 base = pool.initialValue;

        // The pool's reserves are the initial deposit minus all trader flows, so
        // LP - HODL = -(flow0 · P_T + flow1).
        int256 lpMinusHodl = -(FixedPointMathLib.sMulWad(s.flow0, int256(finalPriceWad)) + s.flow1);
        m[M_LP_MINUS_HODL] = _mbps(lpMinusHodl, base);
        m[M_FEE_INCOME] = _mbps(int256(s.feeValue), base);
        m[M_FEE_NOISE] = _mbps(int256(s.feeValueByFlow[0]), base);
        m[M_FEE_ARB] = _mbps(int256(s.feeValueByFlow[1]), base);
        m[M_ARB_PROFIT] = _mbps(s.arbProfit[0] + s.arbProfit[1], base);
        m[M_ARB_PROFIT_TREND] = _mbps(s.arbProfit[0], base);
        m[M_ARB_PROFIT_REVERSION] = _mbps(s.arbProfit[1], base);
        m[M_ARB_FEE_TREND] = _mbps(int256(s.arbFeeBySegment[0]), base);
        m[M_ARB_FEE_REVERSION] = _mbps(int256(s.arbFeeBySegment[1]), base);
        m[M_AVG_FEE_UP] = _weightedFee(s.feeVolumeByDirection[0], s.volumeByDirection[0]);
        m[M_AVG_FEE_DOWN] = _weightedFee(s.feeVolumeByDirection[1], s.volumeByDirection[1]);
        m[M_AVG_FEE_NOISE] = _weightedFee(s.feeVolumeByFlow[0], s.volumeByFlow[0]);
        m[M_AVG_FEE_ARB] = _weightedFee(s.feeVolumeByFlow[1], s.volumeByFlow[1]);
        m[M_ARB_TRADES] = int256(s.arbTrades);
    }

    /// @dev Thousandths of a basis point of `base`.
    function _mbps(int256 value, uint256 base) internal pure returns (int256) {
        return value * 1e7 / int256(base);
    }

    function _weightedFee(uint256 feeVolume, uint256 volume) internal pure returns (int256) {
        return volume == 0 ? int256(0) : int256(feeVolume / volume);
    }

    function _priceWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(uint256(sqrtPriceX96) * sqrtPriceX96, 1e18, 1 << 192);
    }

    /// @dev √(1 - fee) in WAD, with fee in pips.
    function _sqrtOneMinusFee(uint24 fee) internal pure returns (uint256) {
        return FixedPointMathLib.sqrt((1e6 - uint256(fee)) * 1e30);
    }

    // ------------------------------------------------------------------
    // Output
    // ------------------------------------------------------------------

    function _recordBlock(uint256 b, uint256 segment, int24 trueTick, PoolId id, uint24 feeUp, uint24 feeDown)
        internal
    {
        (, int24 poolTick,,) = poolManager.getSlot0(id);
        vm.writeLine(
            SERIES_CSV,
            string.concat(
                vm.toString(b),
                ",",
                segment == 0 ? "trend" : "reversion",
                ",",
                vm.toString(trueTick),
                ",",
                vm.toString(poolTick),
                ",",
                vm.toString(feeUp),
                ",",
                vm.toString(feeDown)
            )
        );
    }

    function _writePerSeedCsv(int256[METRICS][POOLS][SEEDS] memory results, uint24[SEEDS] memory matchedFees)
        internal
    {
        vm.writeFile(
            PER_SEED_CSV,
            "seed,pool,static_fee_pips,lp_minus_hodl_bps,fee_income_bps,fee_noise_bps,fee_arb_bps,arb_profit_bps,arb_profit_trend_bps,arb_profit_reversion_bps,arb_fee_trend_bps,arb_fee_reversion_bps,avg_fee_up_pips,avg_fee_down_pips,avg_fee_noise_pips,avg_fee_arb_pips,arb_trades\n"
        );
        for (uint256 seed; seed < SEEDS; ++seed) {
            for (uint256 p; p < POOLS; ++p) {
                int256[METRICS] memory m = results[seed][p];
                string memory row = string.concat(
                    vm.toString(seed), ",", _poolName(p), ",", _staticFeeLabel(p, matchedFees[seed])
                );
                for (uint256 k = M_LP_MINUS_HODL; k <= M_ARB_FEE_REVERSION; ++k) {
                    row = string.concat(row, ",", _decimal3(m[k]));
                }
                for (uint256 k = M_AVG_FEE_UP; k <= M_ARB_TRADES; ++k) {
                    row = string.concat(row, ",", vm.toString(m[k]));
                }
                vm.writeLine(PER_SEED_CSV, row);
            }
        }
    }

    function _writeSummaryJson(int256[METRICS][POOLS][SEEDS] memory results, uint24[SEEDS] memory matchedFees)
        internal
    {
        string memory json = string.concat(
            "{\n  \"config\": {\"seeds\": ",
            vm.toString(SEEDS),
            ", \"trend_blocks\": ",
            vm.toString(TREND_BLOCKS),
            ", \"reversion_blocks\": ",
            vm.toString(REVERSION_BLOCKS),
            ", \"block_time_s\": ",
            vm.toString(BLOCK_TIME),
            ", \"drift_ticks_per_block\": ",
            vm.toString(DRIFT_TICKS),
            ", \"vol_ticks_per_block\": ",
            vm.toString(VOL_TICKS)
        );
        json = string.concat(
            json,
            ", \"reversion_per_block\": 0.05, \"liquidity\": \"1000e18 full range at tick 0\", \"noise_trades_per_block\": \"0-3\", \"noise_size\": \"0.05e18-1e18 input tokens\", \"hook_params\": \"defaultFeeParams()\"},\n",
            "  \"units\": {\"bps\": \"basis points of the pool's initial value\", \"pips\": \"fee units, hundredths of a basis point of trade size\", \"stats\": \"mean, sample sd, min, max across seeds\"},\n",
            "  \"fee_matched_fee_pips\": ",
            _statsJson(_matchedFeeColumn(matchedFees), false),
            ",\n  \"pools\": [\n"
        );
        for (uint256 p; p < POOLS; ++p) {
            json = string.concat(
                json, "    {\"name\": \"", _poolName(p), "\"", _poolMetricsJson(results, p), "}", p + 1 < POOLS ? ",\n" : "\n"
            );
        }
        json = string.concat(json, "  ],\n  \"paired_stoikov_minus_fee_matched\": {");
        for (uint256 k = M_LP_MINUS_HODL; k <= M_ARB_FEE_REVERSION; ++k) {
            json = string.concat(json, k == 0 ? "" : ", ", "\"", _metricName(k), "\": ", _statsJson(_pairedColumn(results, k), true));
        }
        json = string.concat(
            json,
            ", \"seeds_where_stoikov_lp_minus_hodl_is_higher\": ",
            vm.toString(_countPositive(_pairedColumn(results, M_LP_MINUS_HODL))),
            "}\n}\n"
        );
        vm.writeFile(SUMMARY_JSON, json);
    }

    function _poolMetricsJson(int256[METRICS][POOLS][SEEDS] memory results, uint256 p)
        internal
        pure
        returns (string memory out)
    {
        for (uint256 k; k < METRICS; ++k) {
            out = string.concat(out, ", \"", _metricName(k), "\": ", _statsJson(_column(results, p, k), k <= M_ARB_FEE_REVERSION));
        }
    }

    function _printSummary(int256[METRICS][POOLS][SEEDS] memory results, uint24[SEEDS] memory matchedFees)
        internal
        pure
    {
        console2.log("");
        console2.log(
            string.concat(
                "Comparison simulation: ",
                vm.toString(SEEDS),
                " seeds x ",
                vm.toString(BLOCKS),
                " blocks. Mean +/- sd across seeds; bps of initial pool value."
            )
        );
        (int256 feeMean, int256 feeSd,,) = _stats(_matchedFeeColumn(matchedFees));
        console2.log(string.concat("Fee-matched static fee: ", vm.toString(feeMean), " +/- ", vm.toString(feeSd), " pips"));
        console2.log("");
        console2.log("pool          | LP - HODL         | fee income      | arb profit (LVR) | avg fee up / down | avg fee noise / arb");
        for (uint256 p; p < POOLS; ++p) {
            console2.log(
                string.concat(
                    _pad(_poolName(p), 14),
                    "| ",
                    _pad(_meanSd(_column(results, p, M_LP_MINUS_HODL)), 18),
                    "| ",
                    _pad(_meanSd(_column(results, p, M_FEE_INCOME)), 16),
                    "| ",
                    _pad(_meanSd(_column(results, p, M_ARB_PROFIT)), 17),
                    "| ",
                    _pad(_meanPair(_column(results, p, M_AVG_FEE_UP), _column(results, p, M_AVG_FEE_DOWN)), 18),
                    "| ",
                    _meanPair(_column(results, p, M_AVG_FEE_NOISE), _column(results, p, M_AVG_FEE_ARB))
                )
            );
        }
        console2.log("");
        console2.log("Paired difference, StoikovHook minus fee-matched (bps, mean +/- sd across seeds):");
        for (uint256 k = M_LP_MINUS_HODL; k <= M_ARB_FEE_REVERSION; ++k) {
            console2.log(string.concat("  ", _pad(_metricName(k), 26), _meanSd(_pairedColumn(results, k))));
        }
        int256[] memory lp = _pairedColumn(results, M_LP_MINUS_HODL);
        console2.log(
            string.concat(
                "  StoikovHook LP - HODL higher in ", vm.toString(_countPositive(lp)), "/", vm.toString(SEEDS), " seeds"
            )
        );
    }

    // ------------------------------------------------------------------
    // Statistics and formatting
    // ------------------------------------------------------------------

    function _column(int256[METRICS][POOLS][SEEDS] memory results, uint256 p, uint256 metric)
        internal
        pure
        returns (int256[] memory xs)
    {
        xs = new int256[](SEEDS);
        for (uint256 seed; seed < SEEDS; ++seed) {
            xs[seed] = results[seed][p][metric];
        }
    }

    function _pairedColumn(int256[METRICS][POOLS][SEEDS] memory results, uint256 metric)
        internal
        pure
        returns (int256[] memory xs)
    {
        xs = new int256[](SEEDS);
        for (uint256 seed; seed < SEEDS; ++seed) {
            xs[seed] = results[seed][DYNAMIC][metric] - results[seed][FEE_MATCHED][metric];
        }
    }

    function _matchedFeeColumn(uint24[SEEDS] memory matchedFees) internal pure returns (int256[] memory xs) {
        xs = new int256[](SEEDS);
        for (uint256 seed; seed < SEEDS; ++seed) {
            xs[seed] = int256(uint256(matchedFees[seed]));
        }
    }

    /// @dev Mean, sample standard deviation, min and max.
    function _stats(int256[] memory xs) internal pure returns (int256 mean, int256 sd, int256 min, int256 max) {
        int256 sum;
        min = type(int256).max;
        max = type(int256).min;
        for (uint256 i; i < xs.length; ++i) {
            sum += xs[i];
            if (xs[i] < min) min = xs[i];
            if (xs[i] > max) max = xs[i];
        }
        int256 n = int256(xs.length);
        mean = (sum + (sum >= 0 ? n / 2 : -(n / 2))) / n; // rounded to nearest
        uint256 squares;
        for (uint256 i; i < xs.length; ++i) {
            int256 d = xs[i] - mean;
            squares += uint256(d * d);
        }
        sd = int256(FixedPointMathLib.sqrt(squares / (xs.length - 1)));
    }

    function _countPositive(int256[] memory xs) internal pure returns (uint256 count) {
        for (uint256 i; i < xs.length; ++i) {
            if (xs[i] > 0) count += 1;
        }
    }

    function _meanSd(int256[] memory xs) internal pure returns (string memory) {
        (int256 mean, int256 sd,,) = _stats(xs);
        return string.concat(_decimal3(mean), " +/- ", _decimal3(sd));
    }

    function _meanPair(int256[] memory a, int256[] memory b) internal pure returns (string memory) {
        (int256 meanA,,,) = _stats(a);
        (int256 meanB,,,) = _stats(b);
        return string.concat(vm.toString(meanA), " / ", vm.toString(meanB));
    }

    /// @dev JSON object with mean, sample sd, min and max. `isMbps` formats thousandths of a bps as bps.
    function _statsJson(int256[] memory xs, bool isMbps) internal pure returns (string memory) {
        (int256 mean, int256 sd, int256 min, int256 max) = _stats(xs);
        return string.concat(
            "{\"mean\": ",
            _number(mean, isMbps),
            ", \"sd\": ",
            _number(sd, isMbps),
            ", \"min\": ",
            _number(min, isMbps),
            ", \"max\": ",
            _number(max, isMbps),
            "}"
        );
    }

    function _number(int256 v, bool isMbps) internal pure returns (string memory) {
        return isMbps ? _decimal3(v) : vm.toString(v);
    }

    /// @dev Formats a value in thousandths as a decimal with three places, e.g. -1234 -> "-1.234".
    function _decimal3(int256 v) internal pure returns (string memory) {
        uint256 a = FixedPointMathLib.abs(v);
        uint256 frac = a % 1000;
        string memory padding = frac < 10 ? "00" : frac < 100 ? "0" : "";
        return string.concat(v < 0 ? "-" : "", vm.toString(a / 1000), ".", padding, vm.toString(frac));
    }

    function _metricName(uint256 k) internal pure returns (string memory) {
        if (k == M_LP_MINUS_HODL) return "lp_minus_hodl_bps";
        if (k == M_FEE_INCOME) return "fee_income_bps";
        if (k == M_FEE_NOISE) return "fee_noise_bps";
        if (k == M_FEE_ARB) return "fee_arb_bps";
        if (k == M_ARB_PROFIT) return "arb_profit_bps";
        if (k == M_ARB_PROFIT_TREND) return "arb_profit_trend_bps";
        if (k == M_ARB_PROFIT_REVERSION) return "arb_profit_reversion_bps";
        if (k == M_ARB_FEE_TREND) return "arb_fee_trend_bps";
        if (k == M_ARB_FEE_REVERSION) return "arb_fee_reversion_bps";
        if (k == M_AVG_FEE_UP) return "avg_fee_up_pips";
        if (k == M_AVG_FEE_DOWN) return "avg_fee_down_pips";
        if (k == M_AVG_FEE_NOISE) return "avg_fee_noise_pips";
        if (k == M_AVG_FEE_ARB) return "avg_fee_arb_pips";
        return "arb_trades";
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        uint256 len = bytes(s).length;
        while (len < width) {
            s = string.concat(s, " ");
            ++len;
        }
        return s;
    }

    function _poolName(uint256 p) internal pure returns (string memory) {
        if (p == DYNAMIC) return "StoikovHook";
        if (p == FEE_MATCHED) return "fee-matched";
        if (p == STATIC_5BP) return "static 0.05%";
        return "static 0.30%";
    }

    function _staticFeeLabel(uint256 p, uint24 matchedFee) internal pure returns (string memory) {
        if (p == DYNAMIC) return "dynamic";
        if (p == FEE_MATCHED) return vm.toString(matchedFee);
        if (p == STATIC_5BP) return "500";
        return "3000";
    }
}
