# StoikovHook Demo Script

> These are speaker notes, not a script to read aloud. The rules prohibit AI voice-over, so Tony narrates both the video and the live demo personally, speaking freely.
> Unknown values are marked `[TBD: …]` and collected in "Values to Fill In" at the end.
> Only present what is implemented. If a comparison result is unfavorable or mixed, say so.
> Status (2026-09-25): the design spec is done. The contract, tests, simulation and deployment are **not implemented yet**, and every demo scene below depends on them.

---

## Part 1: Video Script (target 3:30, required length 2–4 minutes)

Before recording:
- Run the comparison simulation ahead of time, save its output to a file, and show the saved result on camera.
- Open these tabs in advance: the README, the hook address and both swap transactions on the Sepolia explorer, and the source code at the key lines.
- Enlarge the terminal font, and hide any window that shows an RPC URL or a keystore path.

### 0:00–0:30 The problem (30 s)

**On screen**: The README's "Problem" section, or a simple slide with a CEX order book quoting actively on the left and an AMM with a fixed fee on the right.

**Talking points**:
- AMM LPs quote passively at a fixed fee, like a market maker that never updates its prices.
- The price moves on centralized exchanges first. Arbitrageurs then trade the pool back into line, and LPs fill those trades at stale prices. This loss is called LVR.
- The loss grows with volatility (LVR ∝ σ²).
- A static fee is wrong in both directions: too expensive for regular users in calm markets, too cheap for arbitrageurs in volatile ones.

### 0:30–1:00 The solution (30 s)

**On screen**: The README's "Solution" section and the five points in "How It Works".

**Talking points**:
- One sentence: StoikovHook makes a v4 pool quote like a professional market maker.
- Every block has two fees, one for swaps that push the price up and one for swaps that push it down.
- Volatility premium: the more the market moves, the higher both fees go.
- Inventory skew: swaps that push the pool further out of balance pay more, and swaps that bring it back pay less.
- It uses only the pool's own on-chain state. No oracle, no admin.

### 1:00–2:30 Demo: the comparison simulation (90 s)

**On screen**:
1. The terminal running the comparison scenario, `[TBD: scenario test command, e.g. forge test --match-contract … -vv]`, or its saved output.
2. A zoomed-in results table for the four pools (StoikovHook, static 0.05%, static 0.30%, fee-matched static): LP terminal value, fee income and arbitrageur profit.
3. A zoomed-in view of the fee over time (calm → jump → trend → reversal).

**Talking points**:
- Same price path for every pool: calm → jump → trend → reversal. Arbitrageurs and regular traders make exactly the same trades.
- The key comparison is the fee-matched static pool. Regular users pay the same average fee, so the comparison isolates the effect of the fee's *shape*.
- Result: LP terminal value vs. the fee-matched pool `[TBD: LP terminal value difference, %]`; arbitrageur profit `[TBD: arbitrage profit difference, %]`.
- Against the 0.05% and 0.30% pools: `[TBD: difference vs. the two static tiers]`.
- At the jump, the fee rises from `[TBD: fee before the jump]` to `[TBD: fee after the jump]`.
- Direction asymmetry: within the same window, the side that pushes the price further pays `[TBD: imbalancing-side fee]` and the side that brings it back pays `[TBD: rebalancing-side fee]`.
- If StoikovHook loses in any phase, say which phase and why (for example, reference-price lag).

### 2:30–3:00 Implementation (30 s)

**On screen**: `beforeSwap` and the fee formula in `src/StoikovHook.sol` (`[TBD: line numbers]`), the test output, and the gas snapshot.

**Talking points**:
- v4 dynamic fees: the pool is created with `DYNAMIC_FEE_FLAG`, and `beforeSwap` returns `fee | OVERRIDE_FEE_FLAG` to override the fee on every swap.
- Fixed-point math: variance is scaled by 1e12, the reference price keeps 16 fractional bits, and there is one integer square root per block.
- Each pool's state fits in a single storage slot.
- Gas: `[TBD: cached-path gas]` for later swaps in a block and `[TBD: window-open gas]` for the first swap of a block.
- Tests: `[TBD: total test count]` tests and `[TBD: fuzz runs]` fuzz runs, covering the fee bounds and the guarantee that the hook never reverts a swap.

### 3:00–3:30 Wrap-up (30 s)

**On screen**: On the Sepolia explorer, the hook address `[TBD: hook contract address]` and two swaps in opposite directions `[TBD: swap transaction hashes ×2]`, with the `fee` field of each `Swap` event open. End on the GitHub repository page.

**Talking points**:
- The low 14 bits of the hook address are `0x1080`, so only the `afterInitialize` and `beforeSwap` callbacks are enabled.
- The two swaps go in opposite directions and pay different fees: `[TBD: fee values of the two transactions]`.
- The repository is github.com/tonycai/StoikovHook. The design spec, build log and AI usage notes are all public.

---

## Part 2: Live Judging (4-minute demo + 3-minute Q&A)

The principle: **conclusion first, then evidence.** Never run a slow script live. Generate every result in advance, and keep any live step down to a few seconds.

### 0:00–0:30 Lead with the conclusion

- One-line pitch: a v4 hook that uses Avellaneda–Stoikov market-making logic to set dynamic fees that protect LPs.
- State three numbers up front:
  1. LP terminal value vs. the fee-matched static pool: `[TBD: LP terminal value difference, %]`
  2. Arbitrageur profit: `[TBD: arbitrage profit difference, %]`
  3. Gas overhead: `[TBD: cached-path gas]` / `[TBD: window-open gas]`
- Announce the three pieces of evidence that follow: simulation results, on-chain transactions, code.

### 0:30–1:30 Evidence 1: the comparison simulation

- Show the saved results table (`[TBD: results file path]`).
- If time allows, run one test live: `[TBD: single test command]`. It takes about `[TBD: single test runtime]` seconds; skip it if it takes more than 10 seconds.
- Point to the rows where the fee rises with the jump and skews by direction.

### 1:30–2:30 Evidence 2: on-chain

- In the pre-opened tabs, show the hook address page and point out that its low 14 bits are `0x1080`.
- Open the `Swap` event of each of the two swap transactions and compare their `fee` values.
- Show a `FeeWindowUpdated` event: the tick, the reference price and the fees on both sides at that moment.

### 2:30–3:30 Evidence 3: the code

- Walk through the README's Repository Guide table; every row points to a `file:line`.
- Show the `beforeSwap` return value `[TBD: line numbers]`, the fee formula `[TBD: line numbers]` and the dynamic-fee check in `afterInitialize` `[TBD: line numbers]`.
- Show the test list and the gas snapshot.

### 3:30–4:00 Limitations and next steps

- Raise the limitations before anyone asks: one fee per swap, uncalibrated parameters, and a lagging reference price.
- Next steps: size-aware fees (S1) and Monte Carlo calibration (S2).

Fallback plan:
- If the network fails, use offline screenshots of the browser pages and the results table: `[TBD: screenshot folder]`.
- Keep a timer out of the camera's view. Start the wrap-up by 3:30 at the latest.

---

## Part 3: Q&A Prep

Open every answer with a one-sentence summary, then expand. Raise the limitations yourself; don't wait for a follow-up question.

### Q1. Does this model hold up in real markets? Do the Avellaneda–Stoikov assumptions apply to an AMM?

- In one sentence: we borrow the **structure** of A–S, and we do not claim it is optimal for an AMM.
- The A–S assumptions: the dealer sets its own quotes, orders arrive as a Poisson process with intensity $Ae^{-k\delta}$, the mid price follows a Brownian motion, the dealer has CARA utility, and the horizon T is finite.
- How an AMM differs:
  - There is no terminal time, so we use the stationary solution (Guéant–Lehalle–Fernandez-Tapia 2013), in which quotes scale linearly with σ.
  - The pool cannot choose where its quotes are centered; the curve does. We control only the fee on each side, and the fee asymmetry implements the reservation-price shift.
- Independent support: in LVR theory, the share of LVR that arbitrageurs capture depends on $f/(\sigma\sqrt{\Delta t})$, which justifies a fee proportional to σ.
- **Limitations**: $\gamma, k, A$ are not estimated from data but folded into constants, and the default parameters are placeholders. Whether the inventory skew pays off is an empirical question that depends on the simulation result, `[TBD: LP terminal value difference, %]`.

### Q2. How much gas does the hook add? Is it still worth it for small trades?

- `[TBD: cached-path gas]` for later swaps in a block and `[TBD: window-open gas]` for the first swap of a block. The design targets are ≤ 5,000 and ≤ 25,000.
- For comparison, a plain v4 swap costs about `[TBD: total gas of a plain swap]` in total.
- Gas is a fixed cost that does not depend on trade size. The fee itself is proportional, so small trades pay proportionally.
- **Limitations**: on L1, very small trades are dominated by gas anyway, and the hook makes that more noticeable. On L2s the overhead is negligible.

### Q3. How is volatility estimated on-chain? Can it be manipulated?

- On the first swap of each block, the hook reads the pool's current tick and compares it with the previous observation.
- It keeps a time-weighted EWMA of the squared tick change, with weight $\Delta t/(\tau+\Delta t)$, so no `exp` is needed. Each observation is capped at ±1000 ticks.
- There is one square root per block. Later swaps read the cached fees.
- Manipulation resistance:
  - Round trips within one block are invisible, because sampling uses block-to-block closes. Same-block manipulation does nothing.
  - Inflating volatility requires actually moving the price across blocks, which costs fees and invites arbitrage. The only effect is a higher LP fee, which is capped and decays over time.
  - Deflating volatility is impossible through trading. It only falls as time passes.
- **Limitations**: a builder that controls two consecutive blocks can shift the snapshot. This has a cost and a bounded payoff (spec §5.4). Close-to-close sampling also misses volatility within a block.

### Q4. What is the fee cap? Will extreme markets lock users out?

- Defaults: a 0.01% floor and a 1% cap, fixed at deployment (placeholder values).
- Example: after a 10% price move within one block, both sides hit the 1% cap. If trades then arrive every 12 seconds with no further price movement, the rebalancing side drops below the cap within about 2 blocks. The continuation side stays capped for about 11.6 minutes (computed in spec §2.7).
- Nobody is locked out. The fee is bounded, and by design there is no revert path (fuzz-tested with `[TBD: fuzz runs]` runs). The hook registers no liquidity callbacks, so LPs can always withdraw.
- **Limitations**: the cap also limits the protection. A 10% jump causes far more than 1% of LVR.

### Q5. How does this differ from existing dynamic fee hooks?

- Common approaches (verify specific project names before citing them: `[TBD: verify names of comparable dynamic fee hooks]`):
  - Adjust a **single** fee from some signal, with the same fee in both directions, stored in `slot0.lpFee`.
  - Depend on an external signal (oracle price or volatility, gas price, and so on) or on a keeper that pushes periodic updates.
- What sets StoikovHook apart:
  1. **Different fees by direction**, overridden per swap instead of one stored fee.
  2. **Inventory skew**: a reservation-price shift taken from market-making theory, not just "raise the fee when volatility is high".
  3. **No external dependencies**: only the pool's own tick, the block number and the block timestamp. No oracle, no keeper.
  4. **Per-block snapshot**: rules out same-block manipulation by design.
  5. **One storage slot of state** and no admin.
- The implementation will build on OpenZeppelin uniswap-hooks' `BaseOverrideFee` (planned).
- **Limitations**: we have not done a systematic survey of other projects. The "common approaches" above summarize categories.

### Q6. How does this hook's inventory skew differ from a real market maker's inventory management?

- A real market maker knows its exact position, can hedge on other venues, and works to explicit inventory targets and risk limits.
- StoikovHook **infers** inventory from price: how far the current tick sits from an EMA of the pool's own tick. Within a range of constant liquidity, that displacement is proportional to the change in holdings to first order, independent of how much liquidity there is (spec §2.2).
- The reference is a slow moving average of the pool's own price, not an external fair price. With an external fair price, the "rebalancing" direction would coincide with arbitrage flow, and the skew would end up subsidizing arbitrageurs (spec §2.6).
- The pool cannot hedge. It can only steer order flow through fees.
- **Limitations**: the approximation gets coarser across tick ranges with different liquidity. The skew applies to the whole pool and ignores individual LP ranges. The reference lags, so for about τ_R after a genuine repricing, regular users trading in the same direction also pay more.

### Likely follow-ups

- **Why no oracle?** It adds a layer of trust and latency, and using an external price as the reference would flip the direction of the skew (see Q6).
- **Can splitting trades get around it?** Not within a block, because of the snapshot. The remaining gap is a single large trade that crosses the reference price; size-aware fees (S1) are planned to close it.
- **Doesn't the skew hurt regular users?** The skew is revenue-neutral: the average of the two fees is unchanged, and trades that rebalance the pool get a discount.
- **Why h = 12 seconds?** It is the block time of the target chain. An L2 deployment would need retuning.
- **How was AI used?** Spec first, then implementation, using Claude Code. Tony reviews the diff of every change that touches fees, state or fund safety. See `AI_USAGE.md` and `docs/BUILD_LOG.md`.

---

## Values to Fill In

| # | Placeholder | Source | Where it appears |
|---|---|---|---|
| 1 | `[TBD: LP terminal value difference, %]` | Comparison simulation (M3), vs. the fee-matched static pool | P1 demo, P2 conclusion, Q1 |
| 2 | `[TBD: arbitrage profit difference, %]` | Comparison simulation (M3) | P1 demo, P2 conclusion |
| 3 | `[TBD: difference vs. the two static tiers]` | Comparison simulation (M3), vs. 0.05% / 0.30% | P1 demo |
| 4 | `[TBD: fee before the jump]` / `[TBD: fee after the jump]` | `FeeWindowUpdated` output from the simulation | P1 demo |
| 5 | `[TBD: imbalancing-side fee]` / `[TBD: rebalancing-side fee]` | Simulation or unit test (A4) | P1 demo |
| 6 | `[TBD: cached-path gas]` / `[TBD: window-open gas]` | Gas snapshot (A8) | P1 implementation, P2 conclusion, Q2 |
| 7 | `[TBD: total gas of a plain swap]` | Gas snapshot of a control pool without the hook | Q2 |
| 8 | `[TBD: total test count]` / `[TBD: fuzz runs]` | `forge test` output (A1, A7) | P1 implementation, Q4 |
| 9 | `[TBD: hook contract address]` | Sepolia deployment (A10) | P1 wrap-up |
| 10 | `[TBD: swap transaction hashes ×2]` / `[TBD: fee values of the two transactions]` | Sepolia deployment (A10) | P1 wrap-up |
| 11 | `[TBD: scenario test command, e.g. forge test --match-contract … -vv]` | Set once M3 is implemented | P1 demo |
| 12 | `[TBD: single test command]` / `[TBD: single test runtime]` | Timed locally | P2 evidence 1 |
| 13 | `[TBD: results file path]` | Where the M3 output is saved | P2 evidence 1 |
| 14 | `[TBD: line numbers]` | README Repository Guide | P1 implementation, P2 evidence 3 |
| 15 | `[TBD: screenshot folder]` | Demo prep | P2 fallback plan |
| 16 | `[TBD: verify names of comparable dynamic fee hooks]` | Research before the demo | Q5 |
| 17 | Video link | Add to the README "Demo" section after uploading | README |
