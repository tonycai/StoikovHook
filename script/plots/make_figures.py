#!/usr/bin/env python3
"""Generate the README and demo figures.

Every number in a data figure is read from the simulation outputs in docs/simulation/ (written by
`FOUNDRY_PROFILE=sim forge test -vv`). The fee-curve figure is computed from the fee formula with the
parameters parsed from src/StoikovHook.sol. Nothing is typed in by hand.

    pip install -r script/plots/requirements.txt
    python3 script/plots/make_figures.py

Writes five SVG files to docs/figures/. Output is deterministic, so rerunning without new data leaves the
files unchanged.
"""

from __future__ import annotations

import csv
import math
import re
from decimal import Decimal
from pathlib import Path
from statistics import mean, median, stdev

import matplotlib

matplotlib.use("svg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SIM = ROOT / "docs" / "simulation"
OUT = ROOT / "docs" / "figures"
HOOK_SOURCE = ROOT / "src" / "StoikovHook.sol"

# Okabe-Ito palette (color-blind safe). Blue and orange always carry the price-up / price-down pair or the
# two compared variants; hatching or markers back up color wherever the distinction matters.
BLUE = "#0072B2"
ORANGE = "#E69F00"
VERMILLION = "#D55E00"
LIGHT_GREY = "#BDBDBD"
DARK_GREY = "#636363"
REFERENCE = "#8C8C8C"
TREND_SHADE = "#EDEDED"

# GitHub renders SVGs through <img>, so text uses the viewer's system sans-serif fonts. Matplotlib lays out
# text with DejaVu Sans metrics; the family is swapped for this stack after saving.
FONT_STACK = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

plt.rcParams.update(
    {
        "font.family": "sans-serif",
        "font.sans-serif": ["DejaVu Sans"],
        "font.size": 10,
        "svg.fonttype": "none",
        "svg.hashsalt": "stoikovhook",
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "savefig.facecolor": "white",
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "grid.color": "#E6E6E6",
        "grid.linewidth": 0.8,
        "axes.axisbelow": True,
        "legend.frameon": False,
        "axes.titleweight": "bold",
    }
)

POOL_ORDER = ["StoikovHook", "fee-matched", "static 0.05%", "static 0.30%"]
POOL_LABEL = {
    "StoikovHook": "StoikovHook",
    "fee-matched": "Fee-matched\nstatic\n(primary control)",
    "static 0.05%": "Static\n0.05%",
    "static 0.30%": "Static\n0.30%",
}
POOL_STYLE = {
    "StoikovHook": dict(color=BLUE, hatch=""),
    "fee-matched": dict(color=VERMILLION, hatch="//"),
    "static 0.05%": dict(color=LIGHT_GREY, hatch=""),
    "static 0.30%": dict(color=DARK_GREY, hatch=""),
}


# ----------------------------------------------------------------------------------------------------------
# Inputs
# ----------------------------------------------------------------------------------------------------------


def read_csv(name: str) -> list[dict[str, str]]:
    with open(SIM / name, newline="") as f:
        return list(csv.DictReader(f))


def load_fee_params() -> dict[str, int]:
    """Parses defaultFeeParams() in src/StoikovHook.sol, so the figure uses the deployed defaults."""
    source = HOOK_SOURCE.read_text()
    body = source[source.index("function defaultFeeParams()") :]
    body = body[: body.index("});")]
    fields = [
        "baseFee", "minFee", "maxFee", "alphaWad", "betaWad", "horizon",
        "volTau", "refTau", "fullSkewTicks", "maxTickDelta", "initialVariance",
    ]  # fmt: skip
    params = {}
    for field in fields:
        match = re.search(rf"\b{field}:\s*([0-9_.e]+)", body)
        if match is None:
            raise ValueError(f"{field} not found in defaultFeeParams()")
        mantissa, _, exponent = match.group(1).replace("_", "").partition("e")
        params[field] = int(Decimal(mantissa) * (Decimal(10) ** int(exponent or 0)))
    return params


# ----------------------------------------------------------------------------------------------------------
# Fee formula: a line-by-line mirror of StoikovHook._computeFees (integer math, same rounding)
# ----------------------------------------------------------------------------------------------------------

WAD = 10**18
VARIANCE_SCALE = 10**12
PIPS_PER_TICK = 100
TICK_LOG = math.log(1.0001)
SECONDS_PER_YEAR = 365 * 24 * 3600


def compute_fees(p: dict[str, int], variance: int, displacement_x16: int) -> tuple[int, int, int]:
    sigma_h_pips_wad = math.isqrt(p["horizon"] * variance) * (PIPS_PER_TICK * 10**12)
    base = p["baseFee"] * WAD + sigma_h_pips_wad * p["alphaWad"] // WAD
    full_skew_x16 = p["fullSkewTicks"] << 16
    displacement = min(abs(displacement_x16), full_skew_x16)
    skew = (sigma_h_pips_wad * p["betaWad"] // WAD) * displacement // full_skew_x16
    if displacement_x16 >= 0:
        up, down = base + skew, max(base - skew, 0)
    else:
        up, down = max(base - skew, 0), base + skew

    def clamp(x: int) -> int:
        return min(max(x // WAD, p["minFee"]), p["maxFee"])

    return clamp(up), clamp(down), sigma_h_pips_wad // WAD


def self_check_formula(p: dict[str, int]) -> None:
    """Guards the mirror against drift: the same expectations as test/StoikovHookFees.t.sol."""
    one = VARIANCE_SCALE  # 1 tick^2/s
    assert compute_fees(p, one, 0) == (846, 846, 346)
    assert compute_fees(p, one, 100 << 16)[:2] == (933, 759)
    assert compute_fees(p, one, -100 << 16)[:2] == (759, 933)
    assert compute_fees(p, one, 200 << 16)[:2] == (1019, 673)
    assert compute_fees(p, 4 * one, 0)[0] == 1192


def variance_for_annualized_vol(annualized: float) -> int:
    ticks_per_sqrt_second = annualized / math.sqrt(SECONDS_PER_YEAR) / TICK_LOG
    return round(ticks_per_sqrt_second**2 * VARIANCE_SCALE)


# ----------------------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------------------


def pips_to_percent_axis(ax, which: str = "right") -> None:
    secondary = ax.secondary_yaxis(which, functions=(lambda pips: pips / 1e4, lambda pct: pct * 1e4))
    secondary.set_ylabel("LP fee (% of trade size)")
    return secondary


def save(fig, name: str) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    fig.savefig(path, format="svg", bbox_inches="tight", pad_inches=0.25, metadata={"Date": None})
    plt.close(fig)
    svg = path.read_text()
    svg = svg.replace("'DejaVu Sans'", FONT_STACK).replace("DejaVu Sans", FONT_STACK)
    svg = svg.replace("sans-serif, sans-serif", "sans-serif")
    path.write_text(svg)
    return path


def t_stat(xs: list[float]) -> float:
    return mean(xs) / (stdev(xs) / math.sqrt(len(xs)))


# ----------------------------------------------------------------------------------------------------------
# Figure 1: fee as a function of inventory skew
# ----------------------------------------------------------------------------------------------------------


def figure_fee_curve(p: dict[str, int]) -> Path:
    levels = [(0.60, "Low volatility, 60%/yr", "-"), (2.40, "Medium, 240%/yr", "--"), (12.0, "High, 1200%/yr", ":")]
    q_values = [i / 100 for i in range(-100, 101)]

    fig, ax = plt.subplots(figsize=(8.6, 5.2))
    for annualized, _label, style in levels:
        variance = variance_for_annualized_vol(annualized)
        ups, downs = [], []
        for q in q_values:
            up, down, _ = compute_fees(p, variance, round(q * p["fullSkewTicks"] * 65536))
            ups.append(up)
            downs.append(down)
        width = 2.4 if style == ":" else 2.0
        ax.plot(q_values, ups, color=BLUE, linestyle=style, linewidth=width)
        ax.plot(q_values, downs, color=ORANGE, linestyle=style, linewidth=width)

    for value, text in [
        (p["maxFee"], f"fmax = {p['maxFee']:,} pips ({p['maxFee'] / 1e4:g}%)"),
        (p["baseFee"], f"f0 = {p['baseFee']:,} pips ({p['baseFee'] / 1e4:g}%)"),
        (p["minFee"], f"fmin = {p['minFee']:,} pips ({p['minFee'] / 1e4:g}%)"),
    ]:
        ax.axhline(value, color=REFERENCE, linestyle=(0, (4, 3)), linewidth=1)
        ax.text(-0.99, value * 1.06, text, color=DARK_GREY, fontsize=9, va="bottom")

    ax.set_yscale("log")
    ax.set_ylim(p["minFee"] * 0.8, p["maxFee"] * 1.6)
    ticks = [100, 200, 500, 1000, 2000, 5000, 10000]
    ax.set_yticks(ticks)
    ax.set_yticklabels([f"{t:,}" for t in ticks])
    ax.minorticks_off()
    ax.set_xlim(-1, 1)
    ax.set_xlabel(f"Inventory skew q̂ (dimensionless) = (pool tick − reference tick) / {p['fullSkewTicks']} ticks, "
                  "clamped to [−1, 1]")
    ax.set_ylabel("LP fee (pips, log scale)")
    secondary = pips_to_percent_axis(ax)
    secondary.set_yticks([t / 1e4 for t in ticks])
    secondary.set_yticklabels([f"{t / 1e4:g}%" for t in ticks])
    ax.axvline(0, color=REFERENCE, linewidth=0.8)

    ax.text(0.04, 200, "q̂ > 0, price above its reference:\nextending the move costs more,\nreverting it costs less",
            fontsize=9, color=DARK_GREY, va="center")
    ax.text(-0.96, 200, "q̂ < 0, price below its reference:\nthe mirror image", fontsize=9, color=DARK_GREY, va="center")

    direction_legend = ax.legend(
        handles=[Line2D([], [], color=BLUE, linewidth=2.2, label="Price-up swaps (buy token0)"),
                 Line2D([], [], color=ORANGE, linewidth=2.2, label="Price-down swaps (sell token0)")],
        loc="upper left", bbox_to_anchor=(0.0, -0.16), fontsize=9, title="Direction", title_fontsize=9,
    )  # fmt: skip
    ax.add_artist(direction_legend)
    ax.legend(
        handles=[Line2D([], [], color=DARK_GREY, linestyle=s, linewidth=2.2 if s == ":" else 2.0, label=l)
                 for _, l, s in levels],
        loc="upper right", bbox_to_anchor=(1.0, -0.16), fontsize=9, title="Estimated volatility", title_fontsize=9,
    )  # fmt: skip
    ax.set_title(
        "StoikovHook fee by direction and inventory skew\n"
        f"f = clamp(f0 + σ_h·(α ± β·q̂), fmin, fmax), defaults: α = {p['alphaWad'] / WAD:g}, "
        f"β = {p['betaWad'] / WAD:g}, h = {p['horizon']} s",
        fontsize=11, loc="left",
    )  # fmt: skip
    return save(fig, "fee-curve.svg")


# ----------------------------------------------------------------------------------------------------------
# Figure 2: time series of one seed
# ----------------------------------------------------------------------------------------------------------


def figure_fee_timeseries() -> Path:
    # Seed choice: seed 0, the only seed whose per-block series the harness records (`record = seed == 0` in
    # test/simulation/ComparisonSimulation.t.sol). That was fixed before any result existed, so the seed is not
    # picked for looks. Its rank among the 20 seeds is computed below and printed in the figure.
    rows = read_csv("timeseries_seed0.csv")
    per_seed = read_csv("per_seed.csv")
    gains = {}
    for seed in {r["seed"] for r in per_seed}:
        by_pool = {r["pool"]: r for r in per_seed if r["seed"] == seed}
        gains[seed] = float(by_pool["StoikovHook"]["lp_minus_hodl_bps"]) - float(
            by_pool["fee-matched"]["lp_minus_hodl_bps"]
        )
    ranked = sorted(gains, key=lambda s: gains[s], reverse=True)
    rank = ranked.index("0") + 1

    blocks = [int(r["block"]) for r in rows]
    true_price = [1.0001 ** int(r["true_tick"]) for r in rows]
    pool_price = [1.0001 ** int(r["pool_tick"]) for r in rows]
    fee_up = [int(r["fee_up_pips"]) for r in rows]
    fee_down = [int(r["fee_down_pips"]) for r in rows]
    trend_end = max(int(r["block"]) for r in rows if r["segment"] == "trend")

    fig, (top, bottom) = plt.subplots(2, 1, figsize=(9.5, 6.4), sharex=True, gridspec_kw={"height_ratios": [1, 1.1]})
    for ax in (top, bottom):
        ax.axvspan(blocks[0] - 0.5, trend_end + 0.5, color=TREND_SHADE, zorder=0, linewidth=0)
        ax.axvline(trend_end + 0.5, color=REFERENCE, linewidth=0.8)

    top.plot(blocks, true_price, color="black", linewidth=1.6, label="True price (known only to the simulation)")
    top.plot(blocks, pool_price, color=BLUE, linewidth=1.0, alpha=0.85, label="StoikovHook pool price, end of block")
    top.set_ylabel("Price (token1 per token0)")
    top.legend(loc="lower right", fontsize=9)
    top.text(trend_end / 2, 1.02, "Trend segment (shaded)", transform=top.get_xaxis_transform(), fontsize=9,
             color=DARK_GREY, ha="center", va="bottom")  # fmt: skip
    top.text((trend_end + blocks[-1]) / 2, 1.02, "Mean-reversion segment", transform=top.get_xaxis_transform(),
             fontsize=9, color=DARK_GREY, ha="center", va="bottom")  # fmt: skip

    bottom.plot(blocks, fee_up, color=BLUE, linewidth=1.3, label="Fee on price-up swaps")
    bottom.plot(blocks, fee_down, color=ORANGE, linewidth=1.3, linestyle=(0, (5, 1.5)), label="Fee on price-down swaps")
    bottom.set_ylabel("LP fee (pips)")
    bottom.set_xlabel("Block (12 s each)")
    bottom.legend(loc="upper right", fontsize=9)
    pips_to_percent_axis(bottom)
    bottom.set_xlim(blocks[0] - 0.5, blocks[-1] + 0.5)

    fig.suptitle(
        "One simulated run: fees follow volatility and skew toward the direction of the move\n"
        f"Seed 0 (fixed before any results; up-trend). Its LP gain over the fee-matched control is "
        f"{gains['0']:+.3f} bps, rank {rank} of {len(gains)} (median {median(gains.values()):+.3f} bps).",
        x=0.01, ha="left", fontsize=11, fontweight="bold",
    )  # fmt: skip
    return save(fig, "fee-timeseries.svg")


# ----------------------------------------------------------------------------------------------------------
# Figure 3: LP performance across seeds
# ----------------------------------------------------------------------------------------------------------


def figure_lp_performance() -> Path:
    rows = read_csv("per_seed.csv")
    seeds = sorted({int(r["seed"]) for r in rows})
    value = {(r["pool"], int(r["seed"])): r for r in rows}

    def column(pool: str, metric: str) -> list[float]:
        return [float(value[(pool, s)][metric]) for s in seeds]

    fig, axes = plt.subplots(1, 3, figsize=(13.5, 5.0), gridspec_kw={"width_ratios": [1.25, 1.25, 1.0]})
    for ax, metric, title, ylabel in [
        (axes[0], "lp_minus_hodl_bps", "(a) LP value minus HODL", "LP − HODL (bps of initial pool value)"),
        (axes[1], "arb_profit_bps", "(b) Arbitrageur profit after fees (LVR proxy)", "Arbitrage profit (bps of initial pool value)"),
    ]:  # fmt: skip
        means = [mean(column(p, metric)) for p in POOL_ORDER]
        sds = [stdev(column(p, metric)) for p in POOL_ORDER]
        x = list(range(len(POOL_ORDER)))
        for i, pool in enumerate(POOL_ORDER):
            style = POOL_STYLE[pool]
            ax.bar(i, means[i], width=0.62, color=style["color"], hatch=style["hatch"], edgecolor="black",
                   linewidth=1.6 if pool == "fee-matched" else 0.6, zorder=2)  # fmt: skip
            ax.errorbar(i, means[i], yerr=sds[i], color="black", capsize=4, linewidth=1, zorder=3)
            offset = sds[i] + (0.05 * max(map(abs, means)))
            ax.text(i, means[i] + (offset if means[i] >= 0 else -offset), f"{means[i]:.3f}", ha="center",
                    va="bottom" if means[i] >= 0 else "top", fontsize=9)  # fmt: skip
        ax.axhline(0, color="black", linewidth=0.8)
        ax.set_xticks(x)
        ax.set_xticklabels([POOL_LABEL[p] for p in POOL_ORDER], fontsize=9)
        ax.set_title(title, fontsize=10.5, loc="left")
        ax.set_ylabel(ylabel)
        low, high = ax.get_ylim()
        ax.set_ylim(low - 0.08 * (high - low), high + 0.08 * (high - low))

    paired = [a - b for a, b in zip(column("StoikovHook", "lp_minus_hodl_bps"), column("fee-matched", "lp_minus_hodl_bps"))]
    ax = axes[2]
    jitter = [((s * 7) % 11 - 5) * 0.035 for s in seeds]  # deterministic horizontal spread
    ax.scatter(jitter, paired, color=BLUE, edgecolor="black", linewidth=0.5, s=36, zorder=3, label="One seed")
    m, sd = mean(paired), stdev(paired)
    ax.hlines(m, -0.3, 0.3, color="black", linewidth=2, zorder=4, label=f"Mean {m:+.3f} bps")
    ax.fill_between([-0.3, 0.3], m - sd, m + sd, color=BLUE, alpha=0.15, zorder=1, label=f"±1 SD ({sd:.3f})")
    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_xlim(-0.6, 0.6)
    ax.set_xticks([])
    positive = sum(1 for d in paired if d > 0)
    ax.set_title(f"(c) Same seed: StoikovHook minus\nfee-matched control, {positive}/{len(paired)} seeds > 0",
                 fontsize=10.5, loc="left")  # fmt: skip
    ax.set_ylabel("Difference in LP − HODL (bps)")
    ax.legend(loc="upper right", fontsize=8.5)
    ax.text(0.03, 0.97, f"t = {t_stat(paired):.1f}", transform=ax.transAxes, fontsize=9, color=DARK_GREY, va="top")

    fig.suptitle(
        f"LP outcome over {len(seeds)} seeds × 400 blocks, identical order flow in every pool (mean ± 1 SD)",
        x=0.01, ha="left", fontsize=11.5, fontweight="bold",
    )  # fmt: skip
    fig.text(0.01, -0.035,
             "The seed-to-seed spread in (a) comes from each price path's impermanent loss. Compared within the same "
             "seed (c), StoikovHook beats its fee-matched control consistently, by a small amount.\nStatic 0.30% "
             "beats both in (a) only because simulated uninformed traders do not react to fees.",
             fontsize=9, color=DARK_GREY, ha="left", va="top")  # fmt: skip
    fig.tight_layout()
    return save(fig, "lp-performance.svg")


# ----------------------------------------------------------------------------------------------------------
# Figure 4: same-block round-trip attack
# ----------------------------------------------------------------------------------------------------------


def figure_attack_defense() -> Path:
    rows = read_csv("attack_defense.csv")
    fee = {(r["variant"], r["step"]): int(r["fee_pips"]) for r in rows}
    with_cache = fee[("with_cache", "large_buy")]
    without_cache = fee[("without_cache", "large_buy")]
    window_up = fee[("with_cache", "window_open_fee_up")]
    window_down = fee[("with_cache", "window_open_fee_down")]
    discount = with_cache - without_cache

    fig, ax = plt.subplots(figsize=(7.6, 5.0))
    bars = [("With per-block fee cache\n(StoikovHook)", with_cache, BLUE, ""),
            ("Without the cache\n(test-only mutant)", without_cache, VERMILLION, "//")]  # fmt: skip
    for i, (label, fee_pips, color, hatch) in enumerate(bars):
        ax.bar(i, fee_pips, width=0.55, color=color, hatch=hatch, edgecolor="black", linewidth=0.8, zorder=2)
        ax.text(i, fee_pips + 120, f"{fee_pips:,} pips", ha="center", va="bottom", fontsize=10, fontweight="bold")
    ax.axhline(window_up, color=DARK_GREY, linestyle=(0, (5, 3)), linewidth=1.1)
    ax.text(1.36, window_up + 90, f"Price-up fee posted at\nwindow open: {window_up:,}", va="bottom", fontsize=8.5,
            color=DARK_GREY)  # fmt: skip
    ax.axhline(window_down, color=DARK_GREY, linestyle=(0, (1, 2)), linewidth=1.3)
    ax.text(1.36, window_down + 90, f"Price-down (rebalancing)\nfee: {window_down:,}", va="bottom", fontsize=8.5,
            color=DARK_GREY)  # fmt: skip
    ax.annotate("", xy=(0.5, without_cache), xytext=(0.5, with_cache),
                arrowprops=dict(arrowstyle="->", color="black", linewidth=1.2))  # fmt: skip
    ax.hlines(without_cache, 0.5, 0.72, color="black", linewidth=0.8)
    ax.text(0.54, (with_cache + without_cache) / 2,
            f"−{discount:,} pips\n(−{discount / with_cache:.1%})", ha="left", va="center", fontsize=9.5)  # fmt: skip
    ax.set_xticks([0, 1])
    ax.set_xticklabels([b[0] for b in bars], fontsize=9.5)
    ax.set_xlim(-0.6, 2.25)
    ax.set_ylim(0, with_cache * 1.22)
    ax.set_ylabel("Fee paid by the 5-token buy (pips)")
    pips_to_percent_axis(ax)
    ax.set_title(
        "Same-block round trip: which fee does the large buy pay?\n"
        "Block N: price pushed up. Block N+1: sell 2 tokens at the discounted rate, pushing the price back, then buy 5.",
        fontsize=10, loc="left",
    )  # fmt: skip
    return save(fig, "attack-defense.svg")


# ----------------------------------------------------------------------------------------------------------
# Figure 5: sensitivity to the reference memory
# ----------------------------------------------------------------------------------------------------------


def figure_ref_tau_sensitivity(p: dict[str, int]) -> Path:
    summary = read_csv("ref_tau_sweep_summary.csv")
    reversal = read_csv("ref_tau_reversal_diagnostic_summary.csv")
    train = [r for r in summary if r["set"] == "train"]
    holdout = [r for r in summary if r["set"] == "holdout"]

    def series(rows):
        rows = sorted(rows, key=lambda r: int(r["ref_tau_s"]))
        return ([int(r["ref_tau_s"]) for r in rows], [float(r["lp_gain_mean_bps"]) for r in rows],
                [float(r["lp_gain_sd_bps"]) for r in rows])  # fmt: skip

    fig, ax = plt.subplots(figsize=(8.6, 5.2))
    x, y, e = series(train)
    ax.errorbar([v * 0.97 for v in x], y, yerr=e, color=BLUE, marker="o", markersize=6, linewidth=2, capsize=3,
                label="Mean-reversion scenario (training seeds 1–20)")  # fmt: skip
    x, y, e = series(reversal)
    ax.errorbar([v * 1.03 for v in x], y, yerr=e, color=ORANGE, marker="s", markersize=6, linewidth=2, capsize=3,
                linestyle=(0, (5, 2)), label="Reversal scenario (seeds 21–40; diagnostic added after the sweep)")  # fmt: skip
    x, y, e = series(holdout)
    ax.errorbar(x, y, yerr=e, color=BLUE, marker="o", markersize=8, markerfacecolor="white", linestyle="none",
                capsize=3, label="Mean-reversion scenario, holdout seeds 21–40")  # fmt: skip

    default = p["refTau"]
    ax.axvline(default, color=DARK_GREY, linestyle=(0, (4, 3)), linewidth=1.2)
    ax.text(default * 1.06, ax.get_ylim()[1] * 0.97, f"Default τR = {default} s", fontsize=9, color=DARK_GREY, va="top")

    # Same-seed improvements of 3600 s over the default, from the per-seed files.
    def improvement(file: str, set_name: str) -> list[float]:
        rows = [r for r in read_csv(file) if r["set"] == set_name]
        by = {(int(r["ref_tau_s"]), int(r["seed"])): float(r["lp_gain_bps"]) for r in rows}
        seeds = sorted({s for (_, s) in by})
        return [by[(3600, s)] - by[(default, s)] for s in seeds]

    mr = improvement("ref_tau_sweep.csv", "holdout")
    rv = improvement("ref_tau_reversal_diagnostic.csv", "reversal")
    ax.text(0.02, 0.03,
            f"τR = 3600 s vs {default} s, same seeds 21–40:  mean reversion {mean(mr):+.3f} bps (t = {t_stat(mr):.1f}),  "
            f"reversal {mean(rv):+.3f} bps (t = {t_stat(rv):.1f})",
            transform=ax.transAxes, fontsize=9, color=DARK_GREY)  # fmt: skip

    ticks = sorted({int(r["ref_tau_s"]) for r in train})
    ax.set_xscale("log")
    ax.set_xticks(ticks)
    ax.set_xticklabels([str(t) for t in ticks])
    ax.minorticks_off()
    ax.set_xlabel("Reference-price memory τR (seconds, log scale)")
    ax.set_ylabel("LP gain over the fee-matched control (bps, mean ± 1 SD)")
    ax.axhline(0, color="black", linewidth=0.8)
    ax.legend(loc="upper left", fontsize=8.5)
    ax.set_title("A longer memory helps when trends persist and hurts when they reverse", fontsize=11, loc="left")
    return save(fig, "ref-tau-sensitivity.svg")


def main() -> None:
    params = load_fee_params()
    self_check_formula(params)
    paths = [
        figure_fee_curve(params),
        figure_fee_timeseries(),
        figure_lp_performance(),
        figure_attack_defense(),
        figure_ref_tau_sensitivity(params),
    ]
    for path in paths:
        print(f"{path.relative_to(ROOT)}  {path.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
