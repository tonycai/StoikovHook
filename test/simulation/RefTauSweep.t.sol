// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {FeeParams, defaultFeeParams} from "../../src/StoikovHook.sol";

import {SimulationBase} from "./SimulationBase.sol";

/// @title RefTauSweepTest
/// @notice Calibration experiment for the reference-price memory τR (`FeeParams.refTau`), validated on
///         held-out seeds. The protocol was fixed before the first run:
///         - Grid: τR ∈ {60, 150, 300, 600, 900 (current default), 1800, 3600} seconds.
///         - Training, seeds 1–20: for each τR, the mean same-seed LP − HODL gain of StoikovHook over its
///           own fee-matched control. The control's fee is re-matched for every τR.
///         - Selection: the τR with the highest training mean; a tie keeps the default.
///         - Holdout, seeds 21–40, never used for selection: run the selected τR and the default. The
///           selected τR is adopted only if its per-seed improvement over the default has a positive mean
///           with a paired t of at least 2.0. Otherwise the default stays.
///
///   FOUNDRY_PROFILE=sim forge test --match-contract RefTauSweepTest -vv
///
///         Writes docs/simulation/ref_tau_sweep.csv (per seed) and ref_tau_sweep_summary.csv (per τR).
///         Reference pools are skipped: only StoikovHook and its fee-matched control run.
contract RefTauSweepTest is SimulationBase {
    string internal constant SWEEP_CSV = "docs/simulation/ref_tau_sweep.csv";
    string internal constant SWEEP_SUMMARY_CSV = "docs/simulation/ref_tau_sweep_summary.csv";
    string internal constant REVERSAL_CSV = "docs/simulation/ref_tau_reversal_diagnostic.csv";
    string internal constant REVERSAL_SUMMARY_CSV = "docs/simulation/ref_tau_reversal_diagnostic_summary.csv";

    string internal sweepCsv = SWEEP_CSV;
    string internal summaryCsv = SWEEP_SUMMARY_CSV;

    uint256 internal constant SET_SIZE = 20;
    uint256 internal constant TRAIN_FIRST_SEED = 1;
    uint256 internal constant HOLDOUT_FIRST_SEED = 21;
    uint256 internal constant GRID_SIZE = 7;
    /// @dev Adoption threshold on the holdout set: paired t >= 2.0, in thousandths.
    int256 internal constant MIN_HOLDOUT_T_E3 = 2000;

    /// @dev Same-seed differences, StoikovHook minus its fee-matched control, in mbps.
    struct SetResult {
        int256[] lpGain;
        int256[] arbFeeGain;
        int256[] arbProfitChange;
        int256[] trendArbFeeGain;
        int256[] reversionArbFeeGain;
        int256 stoikovArbProfit;
        int256 stoikovArbFee;
        int256 matchedArbProfit;
        int256 matchedArbFee;
    }

    function test_refTauSweep() public {
        vm.pauseGasMetering();
        _setUpHarness();
        vm.writeFile(
            SWEEP_CSV,
            "set,ref_tau_s,seed,matched_fee_pips,lp_gain_bps,arb_fee_gain_bps,arb_profit_change_bps,trend_arb_fee_gain_bps,reversion_arb_fee_gain_bps\n"
        );
        vm.writeFile(
            SWEEP_SUMMARY_CSV,
            "set,ref_tau_s,seeds,lp_gain_mean_bps,lp_gain_sd_bps,lp_gain_t,lp_gain_seeds_positive,trend_arb_fee_gain_mean_bps,trend_arb_fee_gain_t,reversion_arb_fee_gain_mean_bps,reversion_arb_fee_gain_t,arb_profit_change_mean_bps,stoikov_arb_share_pct,matched_arb_share_pct\n"
        );

        uint32[GRID_SIZE] memory grid = [uint32(60), 150, 300, 600, 900, 1800, 3600];
        uint32 defaultTau = defaultFeeParams().refTau;

        console2.log("");
        console2.log("tau_R sweep. Same-seed StoikovHook minus fee-matched control, bps of pool value; t over 20 seeds.");
        console2.log("set      tau_R  | LP gain (t, seeds>0)            | trend arb-fee gain | reversion arb-fee gain | arb profit chg | arb share S / M");

        // Training: seeds 1-20.
        uint256 best;
        int256 bestMean = type(int256).min;
        for (uint256 i; i < GRID_SIZE; ++i) {
            SetResult memory r = _runSet("train", grid[i], TRAIN_FIRST_SEED, uint160(0x4500 + i));
            (int256 mean,,,) = _stats(r.lpGain);
            if (mean > bestMean || (mean == bestMean && grid[i] == defaultTau)) {
                bestMean = mean;
                best = i;
            }
        }
        uint32 selectedTau = grid[best];
        console2.log(string.concat("Selected on training: tau_R = ", vm.toString(selectedTau), " s"));

        // Holdout: seeds 21-40.
        SetResult memory holdoutDefault = _runSet("holdout", defaultTau, HOLDOUT_FIRST_SEED, 0x4600);
        if (selectedTau == defaultTau) {
            console2.log("Decision: the default already scores best on training; keep tau_R = 900 s.");
            return;
        }
        SetResult memory holdoutSelected = _runSet("holdout", selectedTau, HOLDOUT_FIRST_SEED, 0x4601);

        int256[] memory improvement = new int256[](SET_SIZE);
        for (uint256 k; k < SET_SIZE; ++k) {
            improvement[k] = holdoutSelected.lpGain[k] - holdoutDefault.lpGain[k];
        }
        int256 tE3 = _tE3(improvement);
        console2.log(
            string.concat(
                "Holdout improvement of tau_R = ",
                vm.toString(selectedTau),
                " s over the default: ",
                _meanSd(improvement),
                " bps, t = ",
                _decimal3(tE3),
                ", better in ",
                vm.toString(_countPositive(improvement)),
                "/20 seeds"
            )
        );
        (int256 improvementMean,,,) = _stats(improvement);
        console2.log(
            improvementMean > 0 && tE3 >= MIN_HOLDOUT_T_E3
                ? "Decision: the improvement holds on the holdout set; adopt the selected tau_R."
                : "Decision: the improvement does not hold on the holdout set; keep the default tau_R = 900 s."
        );
    }

    /// @notice Diagnostic, not part of the decision rule: the same comparison on a scenario whose second
    ///         segment reverses the first trend, which is the case where a long memory should hurt most.
    ///         Seeds 21-40, results in docs/simulation/ref_tau_reversal_diagnostic.csv.
    function test_refTauReversalDiagnostic() public {
        vm.pauseGasMetering();
        _setUpHarness();
        reverseSecondSegment = true;
        vm.writeFile(
            REVERSAL_CSV,
            "set,ref_tau_s,seed,matched_fee_pips,lp_gain_bps,arb_fee_gain_bps,arb_profit_change_bps,first_trend_arb_fee_gain_bps,reversal_arb_fee_gain_bps\n"
        );
        sweepCsv = REVERSAL_CSV;
        summaryCsv = REVERSAL_SUMMARY_CSV;
        vm.writeFile(
            REVERSAL_SUMMARY_CSV,
            "set,ref_tau_s,seeds,lp_gain_mean_bps,lp_gain_sd_bps,lp_gain_t,lp_gain_seeds_positive,first_trend_arb_fee_gain_mean_bps,first_trend_arb_fee_gain_t,reversal_arb_fee_gain_mean_bps,reversal_arb_fee_gain_t,arb_profit_change_mean_bps,stoikov_arb_share_pct,matched_arb_share_pct\n"
        );

        console2.log("");
        console2.log("Reversal diagnostic (trend, then the opposite trend), seeds 21-40. Columns as above; the");
        console2.log("third column is the first trend and the fourth the reversal trend.");
        uint32[4] memory taus = [uint32(300), 900, 1800, 3600];
        SetResult[4] memory results;
        for (uint256 i; i < 4; ++i) {
            results[i] = _runSet("reversal", taus[i], HOLDOUT_FIRST_SEED, uint160(0x4700 + i));
        }
        int256[] memory improvement = new int256[](SET_SIZE);
        for (uint256 k; k < SET_SIZE; ++k) {
            improvement[k] = results[3].lpGain[k] - results[1].lpGain[k];
        }
        console2.log(
            string.concat(
                "tau_R = 3600 s minus 900 s on the reversal scenario: ",
                _meanSd(improvement),
                " bps, t = ",
                _decimal3(_tE3(improvement)),
                ", better in ",
                vm.toString(_countPositive(improvement)),
                "/20 seeds"
            )
        );
    }

    /// @dev Runs StoikovHook with `refTau = tau` and its fee-matched control over SET_SIZE seeds.
    function _runSet(string memory set, uint32 tau, uint256 firstSeed, uint160 namespace)
        internal
        returns (SetResult memory r)
    {
        FeeParams memory params = defaultFeeParams();
        params.refTau = tau;
        hook = _deployHook(params, namespace);

        r.lpGain = new int256[](SET_SIZE);
        r.arbFeeGain = new int256[](SET_SIZE);
        r.arbProfitChange = new int256[](SET_SIZE);
        r.trendArbFeeGain = new int256[](SET_SIZE);
        r.reversionArbFeeGain = new int256[](SET_SIZE);

        for (uint256 k; k < SET_SIZE; ++k) {
            uint256 seed = firstSeed + k;
            (int256[METRICS][POOLS] memory m, uint24 matchedFee) = _runSeed(seed, false, false);
            r.lpGain[k] = m[DYNAMIC][M_LP_MINUS_HODL] - m[FEE_MATCHED][M_LP_MINUS_HODL];
            r.arbFeeGain[k] = m[DYNAMIC][M_FEE_ARB] - m[FEE_MATCHED][M_FEE_ARB];
            r.arbProfitChange[k] = m[DYNAMIC][M_ARB_PROFIT] - m[FEE_MATCHED][M_ARB_PROFIT];
            r.trendArbFeeGain[k] = m[DYNAMIC][M_ARB_FEE_TREND] - m[FEE_MATCHED][M_ARB_FEE_TREND];
            r.reversionArbFeeGain[k] = m[DYNAMIC][M_ARB_FEE_REVERSION] - m[FEE_MATCHED][M_ARB_FEE_REVERSION];
            r.stoikovArbProfit += m[DYNAMIC][M_ARB_PROFIT];
            r.stoikovArbFee += m[DYNAMIC][M_FEE_ARB];
            r.matchedArbProfit += m[FEE_MATCHED][M_ARB_PROFIT];
            r.matchedArbFee += m[FEE_MATCHED][M_FEE_ARB];

            vm.writeLine(
                sweepCsv,
                string.concat(
                    string.concat(set, ",", vm.toString(tau), ",", vm.toString(seed), ",", vm.toString(matchedFee)),
                    string.concat(",", _decimal3(r.lpGain[k]), ",", _decimal3(r.arbFeeGain[k])),
                    string.concat(",", _decimal3(r.arbProfitChange[k]), ",", _decimal3(r.trendArbFeeGain[k])),
                    string.concat(",", _decimal3(r.reversionArbFeeGain[k]))
                )
            );
        }
        _report(set, tau, r);
    }

    function _report(string memory set, uint32 tau, SetResult memory r) internal {
        vm.writeLine(summaryCsv, string.concat(_summaryHead(set, tau, r), _summaryTail(r)));
        console2.log(string.concat(_consoleHead(set, tau, r), _consoleTail(r)));
    }

    function _summaryHead(string memory set, uint32 tau, SetResult memory r) internal pure returns (string memory) {
        (int256 mean, int256 sd,,) = _stats(r.lpGain);
        string memory head = string.concat(set, ",", vm.toString(tau), ",", vm.toString(SET_SIZE));
        return string.concat(
            head,
            string.concat(",", _decimal3(mean), ",", _decimal3(sd)),
            string.concat(",", _decimal3(_tE3(r.lpGain)), ",", vm.toString(_countPositive(r.lpGain)))
        );
    }

    function _summaryTail(SetResult memory r) internal pure returns (string memory) {
        return string.concat(
            string.concat(",", _meanCsv(r.trendArbFeeGain), ",", _decimal3(_tE3(r.trendArbFeeGain))),
            string.concat(",", _meanCsv(r.reversionArbFeeGain), ",", _decimal3(_tE3(r.reversionArbFeeGain))),
            string.concat(",", _meanCsv(r.arbProfitChange)),
            string.concat(",", _shares(r, ","))
        );
    }

    function _consoleHead(string memory set, uint32 tau, SetResult memory r) internal pure returns (string memory) {
        string memory lp = string.concat(
            _meanSd(r.lpGain), " (t ", _decimal3(_tE3(r.lpGain)), ", ", vm.toString(_countPositive(r.lpGain)), ")"
        );
        return string.concat(_pad(set, 9), _pad(vm.toString(tau), 7), "| ", _pad(lp, 32), "| ");
    }

    function _consoleTail(SetResult memory r) internal pure returns (string memory) {
        return string.concat(
            string.concat(_pad(_meanT(r.trendArbFeeGain), 19), "| "),
            string.concat(_pad(_meanT(r.reversionArbFeeGain), 23), "| "),
            string.concat(_pad(_meanCsv(r.arbProfitChange), 15), "| "),
            _shares(r, " / ")
        );
    }

    function _meanCsv(int256[] memory xs) internal pure returns (string memory) {
        (int256 mean,,,) = _stats(xs);
        return _decimal3(mean);
    }

    function _meanT(int256[] memory xs) internal pure returns (string memory) {
        return string.concat(_meanCsv(xs), " (t ", _decimal3(_tE3(xs)), ")");
    }

    function _shares(SetResult memory r, string memory separator) internal pure returns (string memory) {
        return string.concat(
            _decimal3(_sharePctE3(r.stoikovArbProfit, r.stoikovArbFee)),
            separator,
            _decimal3(_sharePctE3(r.matchedArbProfit, r.matchedArbFee))
        );
    }

    /// @dev Paired t statistic over the seeds, in thousandths: mean / (sd / √n), computed from exact integer
    ///      sums as Σx · √(n − 1) / √(n·Σx² − (Σx)²).
    function _tE3(int256[] memory xs) internal pure returns (int256) {
        int256 n = int256(xs.length);
        int256 sum;
        int256 sumSquares;
        for (uint256 i; i < xs.length; ++i) {
            sum += xs[i];
            sumSquares += xs[i] * xs[i];
        }
        uint256 spread = uint256(n * sumSquares - sum * sum);
        if (spread == 0) return 0;
        return sum * int256(FixedPointMathLib.sqrt(uint256(n - 1) * 1e12)) / int256(FixedPointMathLib.sqrt(spread * 1e6));
    }

    /// @dev The arbitrageur's share of the value its trades extract, profit / (profit + fees), in thousandths of a percent.
    function _sharePctE3(int256 profit, int256 fee) internal pure returns (int256) {
        return profit * 100_000 / (profit + fee);
    }
}
