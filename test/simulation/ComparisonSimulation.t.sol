// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {defaultFeeParams} from "../../src/StoikovHook.sol";

import {SimulationBase} from "./SimulationBase.sol";

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
contract ComparisonSimulationTest is SimulationBase {
    string internal constant PER_SEED_CSV = "docs/simulation/per_seed.csv";
    string internal constant SUMMARY_JSON = "docs/simulation/summary.json";

    function test_comparisonSimulation() public {
        // The run executes ~80,000 swaps; gas accounting is irrelevant to the results.
        vm.pauseGasMetering();

        _setUpHarness();
        hook = _deployHook(defaultFeeParams(), 0x4444);
        vm.writeFile(SERIES_CSV, "block,segment,true_tick,pool_tick,fee_up_pips,fee_down_pips\n");

        int256[METRICS][POOLS][SEEDS] memory results;
        uint24[SEEDS] memory matchedFees;
        for (uint256 seed; seed < SEEDS; ++seed) {
            (results[seed], matchedFees[seed]) = _runSeed(seed, true, seed == 0);
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
}
