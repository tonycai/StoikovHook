#!/usr/bin/env python3
"""Generate the logo and cover image for the submission form.

    pip install -r script/plots/requirements.txt
    python3 script/plots/make_brand.py

Writes to docs/brand/:

    logo.svg             the logo source, 512 x 512
    logo-512.png         the logo, rendered from the same geometry as logo.svg
    logo-64.png          logo-512.png downsampled, to check the logo at small sizes
    cover-1280x720.png   the cover image, 16:9

The logo is an original mark: a shared stem that forks into two strokes, the price-up fee (blue) and the
price-down fee (orange), which separate as the inventory skew grows. The colors are the direction colors of
the figures. The cover's curve is computed from the contract's fee formula with the parameters parsed from
src/StoikovHook.sol. Output is deterministic.
"""

from __future__ import annotations

import io
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import Circle, FancyBboxPatch
from PIL import Image

from make_figures import BLUE, ORANGE, ROOT, compute_fees, load_fee_params, self_check_formula, variance_for_annualized_vol

BRAND = ROOT / "docs" / "brand"

# Logo geometry, in a 512 x 512 box with y pointing down (SVG coordinates). The whole mark stays inside a
# circle of radius 215 around the center, so a round avatar crop does not cut it.
LOGO_SIZE = 512
TILE = "#F2F4F7"
TILE_RADIUS = 104
INK = "#26313D"  # the stem and the fork: the one fee both sides pay at the reference
STROKE = 56  # about 7 px at 64 x 64
STEM = ((104, 256), (232, 256))
UP = ((232, 256), (400, 140))
DOWN = ((232, 256), (400, 372))
NODE_RADIUS = 42

TEXT = "#1F2933"
TEXT_SECONDARY = "#475467"
PX_TO_PT = 0.72  # figures are rendered at 100 dpi, so 1 px = 0.72 pt


def logo_svg() -> str:
    def stroke(segment, color: str) -> str:
        (x0, y0), (x1, y1) = segment
        return f'<path d="M{x0} {y0}L{x1} {y1}" stroke="{color}"/>'

    cx, cy = STEM[1]
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{LOGO_SIZE}" height="{LOGO_SIZE}" viewBox="0 0 {LOGO_SIZE} {LOGO_SIZE}">
  <title>StoikovHook</title>
  <rect width="{LOGO_SIZE}" height="{LOGO_SIZE}" rx="{TILE_RADIUS}" fill="{TILE}"/>
  <g fill="none" stroke-width="{STROKE}" stroke-linecap="round">
    {stroke(UP, BLUE)}
    {stroke(DOWN, ORANGE)}
    {stroke(STEM, INK)}
  </g>
  <circle cx="{cx}" cy="{cy}" r="{NODE_RADIUS}" fill="{INK}"/>
</svg>
"""


def draw_logo(fig, left_px: float, top_px: float, size_px: float) -> None:
    """Draws the logo into a square of size_px pixels whose top-left corner is at (left_px, top_px)."""
    width_px, height_px = fig.get_size_inches() * fig.dpi
    ax = fig.add_axes([left_px / width_px, 1 - (top_px + size_px) / height_px, size_px / width_px, size_px / height_px])
    ax.set_xlim(0, LOGO_SIZE)
    ax.set_ylim(LOGO_SIZE, 0)
    ax.set_aspect("equal")
    ax.axis("off")
    scale_pt = size_px / LOGO_SIZE * PX_TO_PT
    tile = FancyBboxPatch((0, 0), LOGO_SIZE, LOGO_SIZE, boxstyle=f"round,pad=0,rounding_size={TILE_RADIUS}",
                          facecolor=TILE, edgecolor="none")  # fmt: skip
    ax.add_patch(tile)
    for (x0, y0), (x1, y1), color in [(*UP, BLUE), (*DOWN, ORANGE), (*STEM, INK)]:
        ax.plot([x0, x1], [y0, y1], color=color, linewidth=STROKE * scale_pt, solid_capstyle="round")
    ax.add_patch(Circle(STEM[1], NODE_RADIUS, facecolor=INK, edgecolor="none", zorder=3))  # on top, as in logo.svg


def render_png(fig, transparent: bool = False) -> Image.Image:
    buffer = io.BytesIO()
    fig.savefig(buffer, format="png", dpi=fig.dpi, transparent=transparent, metadata={"Software": None})
    plt.close(fig)
    return Image.open(buffer)


def save_png(image: Image.Image, name: str) -> Path:
    path = BRAND / name
    image.save(path, format="PNG", optimize=True)
    return path


def make_logo() -> list[Path]:
    svg = BRAND / "logo.svg"
    svg.write_text(logo_svg())
    fig = plt.figure(figsize=(LOGO_SIZE / 100, LOGO_SIZE / 100), dpi=100)
    draw_logo(fig, 0, 0, LOGO_SIZE)
    logo = render_png(fig, transparent=True).convert("RGBA")
    small = logo.resize((64, 64), Image.Resampling.LANCZOS)
    return [svg, save_png(logo, "logo-512.png"), save_png(small, "logo-64.png")]


def make_cover() -> Path:
    width, height = 1280, 720
    fig = plt.figure(figsize=(width / 100, height / 100), dpi=100)
    fig.patch.set_facecolor("white")

    # Left: logo, name, tagline. Bottom: the key points, all as stated in the README.
    left = 80
    draw_logo(fig, left, 140, 112)
    fig.text(left / width, 1 - 350 / height, "StoikovHook", fontsize=84 * PX_TO_PT, fontweight="bold", color=TEXT)
    fig.text(left / width, 1 - 420 / height, "Market-maker fees for Uniswap v4", fontsize=36 * PX_TO_PT,
             color=TEXT_SECONDARY)  # fmt: skip
    fig.text(left / width, 1 - 560 / height, "Live on Sepolia  ·  LPs ahead in 20/20 seeds  ·  No oracle",
             fontsize=30 * PX_TO_PT, color=TEXT)  # fmt: skip

    # Right: the fee curve reduced to its shape. The two strokes are the price-up and price-down fees computed
    # from the contract's formula for q̂ from 0 to 1 at medium volatility (240%/yr, the dashed pair in
    # docs/figures/fee-curve.svg). The stem on the left is illustrative: the one fee both sides pay at the
    # reference, as in the logo.
    params = load_fee_params()
    self_check_formula(params)
    variance = variance_for_annualized_vol(2.40)
    skews = [i / 50 for i in range(51)]
    fees = [compute_fees(params, variance, round(q * params["fullSkewTicks"] * 65536)) for q in skews]
    up = [f[0] for f in fees]
    down = [f[1] for f in fees]
    base = up[0]
    assert base == down[0]

    ax = fig.add_axes([740 / width, 1 - 480 / height, 300 / width, 360 / height])
    ax.axis("off")
    ax.set_xlim(-0.55, 1.0)
    spread = up[-1] - base
    ax.set_ylim(base - 1.25 * spread, base + 1.25 * spread)
    stem_pt = 12 * PX_TO_PT
    line = dict(linewidth=stem_pt, solid_capstyle="round", clip_on=False)
    ax.plot(skews, up, color=BLUE, **line)
    ax.plot(skews, down, color=ORANGE, **line)
    ax.plot([-0.5, 0], [base, base], color=INK, **line)
    ax.plot([0], [base], marker="o", markersize=26 * PX_TO_PT, color=INK, zorder=3, clip_on=False)
    label = dict(fontsize=26 * PX_TO_PT, fontweight="bold", va="center", ha="left", clip_on=False)
    ax.text(1.06, up[-1], "pays more", color=BLUE, **label)
    ax.text(1.06, down[-1], "pays less", color=ORANGE, **label)

    cover = render_png(fig).convert("RGB")
    assert cover.size == (width, height), cover.size
    return save_png(cover, "cover-1280x720.png")


def main() -> None:
    BRAND.mkdir(parents=True, exist_ok=True)
    for path in [*make_logo(), make_cover()]:
        size = ""
        if path.suffix == ".png":
            with Image.open(path) as image:
                size = f"{image.width}x{image.height}"
        print(f"{path.relative_to(ROOT)}  {size}  {path.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
