# Comparison Simulation

Identical order flow through a StoikovHook pool and three static-fee pools, over 20 random seeds (spec §6, M3).

```bash
FOUNDRY_PROFILE=sim forge test -vv
```

It is deterministic, runs locally with no RPC, and takes about 45 seconds for all simulation tests (about 8 seconds with `--match-contract ComparisonSimulationTest`). The `sim` profile in `foundry.toml` runs only `test/simulation/` and is the only profile allowed to write here; the default `forge test` excludes the simulation. It prints the summary tables and rewrites the three files in this directory. The code is in [`test/simulation/ComparisonSimulation.t.sol`](../../test/simulation/ComparisonSimulation.t.sol). Its assertions only check that the harness is sound (the control really is fee-matched, arbitrage never trades at a loss); none of them asserts which pool wins.

## Model

For each seed, 400 blocks of 12 seconds:

| Component | Definition |
|---|---|
| True price | Exists only in the simulation; the hook never reads it. **Trend segment** (blocks 1–200): drift of 5 ticks per block (≈ ±10.5% over the segment; the direction alternates by seed) plus N(0, 10 ticks) noise. **Mean-reversion segment** (blocks 201–400): pulls 5% per block toward the trend's end level, plus N(0, 10 ticks) noise. 10 ticks per 12-second block is roughly 160% annualized volatility, a stressed regime. |
| Arbitrageur (informed flow) | Trades first in every block, in every pool. It moves the pool price to the edge of the no-arbitrage band around the true price, P = S·(1 − f_up) from below or S / (1 − f_down) from above, using that pool's actual fee for the direction. It therefore only trades when that is profitable after fees. No gas cost. |
| Noise traders (uninformed flow) | 0–3 trades per block, each with a random direction and a random input size of 0.05–1 token. Identical in every pool. |
| Pools | Same full-range liquidity (L = 1,000e18, about 1,000 of each token at price 1) and same starting price in all four. **StoikovHook** with `defaultFeeParams()`. **Fee-matched static pool** (the primary control): its fee equals the volume-weighted average fee noise traders actually paid in the StoikovHook pool for the same seed (2,198 ± 88 pips across seeds), so uninformed traders pay the same average fee in both pools (to within one pip: the control's fee is rounded to a whole pip). **Static 0.05% and 0.30%** for reference. |
| Accounting | Values are in token1 at the true price. **LP − HODL**: the pool's final reserves minus the initial deposit held unchanged, both valued at the final true price. Exact here, because the only LP is the pool's full-range position and the protocol fee is zero. **Arbitrage profit** (the LVR proxy) and **fees** are valued at the true price of their block. All in basis points of the pool's initial value. |

## Results

20 seeds × 400 blocks. Mean ± standard deviation across seeds, in bps of initial pool value; fees in pips.

| Pool | LP − HODL | Fee income | Arbitrage profit | Avg fee up / down | Avg fee noise / arbitrage |
|---|---|---|---|---|---|
| StoikovHook | −7.036 ± 3.771 | 4.759 ± 0.393 | 0.582 ± 0.085 | 2177 / 2230 | 2197 / 2480 |
| Fee-matched static | −7.196 ± 3.834 | 4.584 ± 0.356 | 0.573 ± 0.090 | 2198 / 2198 | 2198 / 2198 |
| Static 0.05% | −10.497 ± 3.844 | 1.273 ± 0.071 | 1.072 ± 0.112 | 500 / 500 | 500 / 500 |
| Static 0.30% | −5.766 ± 3.830 | 6.017 ± 0.367 | 0.490 ± 0.089 | 3000 / 3000 | 3000 / 3000 |

The large cross-seed spread in LP − HODL comes from the price path: each seed's trend creates a different impermanent loss. Comparing pools **within the same seed** removes that spread:

| StoikovHook minus fee-matched, same seed | Mean ± sd | t (n = 20) | Seeds > 0 |
|---|---|---|---|
| LP − HODL | **+0.160 ± 0.105** | 6.8 | **20 / 20** |
| Fees paid by noise traders | 0.000 ± 0.001 | — | — |
| Fees paid by the arbitrageur | +0.175 ± 0.109 | 7.2 | 20 / 20 |
| … in the trend segment | +0.179 ± 0.097 | 8.2 | 20 / 20 |
| … in the mean-reversion segment | −0.004 ± 0.024 | −0.8 | — |
| Arbitrage profit | +0.009 ± 0.011 | 3.8 | — |

Arbitrageur's share of the value its trades extract, i.e. profit / (profit + fees it paid), computed from `per_seed.csv`: StoikovHook **30.3%**, fee-matched 32.9%, static 0.05% 68.4%, static 0.30% 26.6%.

> **Correction, 2026-09-26.** The first published version computed standard deviations with a truncated integer square root. That understated them by up to 0.001 bps and overstated t statistics slightly; for example, the holdout improvement was first reported as ± 0.026, t = 7.2, and is ± 0.027, t = 6.9. The harness now computes both from exact sums. No mean, no per-seed value and no conclusion changed.

## What this shows, and what it does not

1. **Against the fair control, StoikovHook LPs end up ahead in every seed**, by +0.160 bps of pool value over 400 blocks (80 minutes), with the same fees charged to uninformed traders. The effect is consistent but small: about 2.2% of the LP's loss versus HODL in this scenario.
2. **The gain comes from fees on arbitrage flow during the trend.** Continuation-direction arbitrage pays the higher skewed fee. In seed 0's up-trend, the price-up fee averages 2,688 pips against 1,504 for price-down and is higher in 196 of 200 blocks (`timeseries_seed0.csv`). The effect is the same for up- and down-trend seeds (+0.163 and +0.156).
3. **There is no gain in the mean-reversion segment.** The reference price is a slow EMA (τR = 900 s, 75 blocks), so it still lags the end of the trend: the skew stays in the trend's direction in 155 of 200 reversion blocks, and reversal-direction arbitrage gets the discount. This is the lag listed in spec §5.5.
4. **The hook does not reduce the arbitrageur's absolute profit.** It is 1.6% *higher* (+0.009 bps). The arbitrageur trades as often (166 vs. 165 trades per seed) at larger deviations, and pays correspondingly more in fees. What falls is the arbitrageur's **share** of the value extracted, from 32.9% to 30.3%. LPs recapture more of it as fees, which matches the spec's claim ("shrinks the share of LVR that arbitrageurs capture"), not a claim that LVR itself falls.
5. **Static 0.30% has the best absolute LP − HODL** (−5.766 vs. −7.036). In this model, noise traders do not react to fees, so any pool that charges them more earns more with no loss of volume. That is exactly why the fee-matched pool is the control for every claim (spec §7). Static 0.05% does worst: the arbitrageur keeps 68% of the value it extracts.

## Limitations

- Uninformed flow is fee-inelastic, and there are no competing venues. With real routing, higher fees would lose volume.
- The arbitrageur has perfect information, no gas cost and no latency, and always trades at the top of the block.
- A single full-range LP; no concentrated liquidity.
- One stylized scenario (drift, volatility, mean reversion as above) and one uncalibrated parameter set (`defaultFeeParams()`). The results are not a forecast for any real pair.
- The fee-matched fee is chosen after the fact from the StoikovHook run, which is an idealized control.
- The hook's volatility estimate also sees the price impact of noise trades, not only moves in the true price.

## Calibration experiment: reference memory τR

`FOUNDRY_PROFILE=sim forge test --match-contract RefTauSweepTest -vv` (about 60 seconds). The code is [`test/simulation/RefTauSweep.t.sol`](../../test/simulation/RefTauSweep.t.sol).

**Protocol, fixed before the first run.** Sweep τR ∈ {60, 150, 300, 600, 900 (default), 1800, 3600} s on training seeds 1–20. The objective is the same-seed LP − HODL gain of StoikovHook over its own fee-matched control, with the control re-matched for every τR. Select the best τR (a tie keeps the default). Validate it on held-out seeds 21–40: adopt it only if its per-seed improvement over the default has a positive mean with paired t ≥ 2.0.

Training, seeds 1–20 (same-seed gain over the fee-matched control, bps of pool value):

| τR (s) | LP gain | t | Seeds > 0 | Trend arbitrage-fee gain | Reversion arbitrage-fee gain | Arbitrageur's share, StoikovHook / control |
|---|---|---|---|---|---|---|
| 60 | 0.001 ± 0.031 | 0.2 | 9 | 0.011 | −0.009 | 33.3% / 32.8% |
| 150 | 0.029 ± 0.041 | 3.2 | 14 | 0.045 | −0.012 | 32.8% / 32.8% |
| 300 | 0.077 ± 0.063 | 5.5 | 19 | 0.099 | −0.013 | 32.0% / 32.8% |
| 600 | 0.142 ± 0.094 | 6.7 | 19 | 0.165 | −0.010 | 30.7% / 32.9% |
| **900** | 0.166 ± 0.102 | 7.3 | 20 | 0.183 | −0.001 | 30.2% / 33.0% |
| 1800 | 0.196 ± 0.113 | 7.8 | 20 | 0.192 | +0.020 | 29.5% / 33.1% |
| **3600** | 0.206 ± 0.114 | 8.1 | 20 | 0.194 | +0.027 | 29.3% / 33.1% |

Holdout, seeds 21–40: τR = 900 s gains 0.189 ± 0.081 and τR = 3600 s gains 0.231 ± 0.094. The improvement of 3600 s over 900 s is **+0.042 ± 0.027 bps, t = 6.9, better in 19/20 seeds**, so the pre-registered rule says to adopt 3600 s.

**Shorter memory does not fix the reversion segment; longer memory does.** A short τR makes both segments worse. A long τR lifts the reversion segment from about zero (−0.001) to positive (+0.027 in training, +0.049 in the holdout) without costing anything in the trend segment (0.183 → 0.194).

### Decision: keep τR = 900 s

- **Pre-registered rule:** adopt the selected τR if its improvement over 900 s on the holdout seeds is positive with paired t ≥ 2.
- **Result:** τR = 3600 s meets the rule (+0.042 ± 0.027 bps, t = 6.9, better in 19/20 seeds).
- **Why the rule was overridden:** the training and holdout seeds come from the same generator, and every run contains exactly one trend away from the starting price. A long memory, which keeps the reference near the starting price, wins by construction. The holdout set protects against overfitting to particular seeds, not against overfitting to the scenario.
- **Out-of-distribution diagnostic (added after seeing the sweep results, not part of the pre-registered protocol):** `test_refTauReversalDiagnostic`, seeds 21–40, replaces the mean-reverting segment with a trend in the opposite direction.

  | τR (s) | LP gain, reversal scenario | Arbitrage-fee gain during the reversal |
  |---|---|---|
  | 300 | 0.191 ± 0.064 | +0.091 |
  | **900** | **0.287 ± 0.087** | +0.086 |
  | 1800 | 0.234 ± 0.096 | +0.016 |
  | 3600 | 0.170 ± 0.102 | **−0.058** |

  τR = 3600 s is worse than 900 s by −0.117 ± 0.062 bps (t = −8.5, worse in 20/20 seeds), and 900 s is the best of the four values. With a long memory the reference goes stale, and continuation arbitrage in the new direction receives the discount.
- **Conclusion:** τR = 900 s stays as the default because it is the most robust value across the two regimes tested. It is not claimed to be optimal.
- **Follow-up work:** recalibrate on a scenario set with repeated trend reversals and regime switches, or investigate an adaptive τR.

Files: `ref_tau_sweep.csv` (per seed), `ref_tau_sweep_summary.csv` (per τR and set; use this for the sensitivity plot), `ref_tau_reversal_diagnostic.csv` and `ref_tau_reversal_diagnostic_summary.csv`.

## Files

`per_seed.csv`: one row per seed and pool.

| Column | Unit | Meaning |
|---|---|---|
| `seed`, `pool`, `static_fee_pips` | — | `static_fee_pips` is `dynamic` for StoikovHook |
| `lp_minus_hodl_bps` | bps | LP value minus HODL value at the final true price |
| `fee_income_bps`, `fee_noise_bps`, `fee_arb_bps` | bps | Fees earned by the LP, in total and split by who paid them |
| `arb_profit_bps`, `arb_profit_trend_bps`, `arb_profit_reversion_bps` | bps | Arbitrage profit after fees, in total and per segment |
| `arb_fee_trend_bps`, `arb_fee_reversion_bps` | bps | Fees paid by the arbitrageur, per segment |
| `avg_fee_up_pips`, `avg_fee_down_pips` | pips | Volume-weighted average fee on price-up / price-down swaps |
| `avg_fee_noise_pips`, `avg_fee_arb_pips` | pips | Volume-weighted average fee paid by noise traders / the arbitrageur |
| `arb_trades` | count | Arbitrage trades |

`attack_defense.csv`: the same-block round-trip attack against StoikovHook and a test-only mutant without the per-block cache (`test/simulation/AttackDefense.t.sol`): each step's direction, size and the fee charged.

Figures built from these files are in [`docs/figures/`](../figures/); regenerate them with `python3 script/plots/make_figures.py`.

`summary.json`: the configuration, then for each pool and metric the mean, sample standard deviation, min and max across seeds, plus the paired StoikovHook − fee-matched differences.

`timeseries_seed0.csv`: one row per block for seed 0 (an up-trend seed): `block`, `segment`, `true_tick`, `pool_tick` (StoikovHook pool at the end of the block), `fee_up_pips`, `fee_down_pips` (the StoikovHook fees in force for that block).
