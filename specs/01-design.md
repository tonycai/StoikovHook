# Spec 01 — Inventory- and Volatility-Aware Dynamic Fee

| | |
|---|---|
| Status | **Draft — awaiting review.** Implementation starts only after sign-off. |
| Scope | Design only. This document contains no implementation code. |
| Target | Uniswap v4 (v4-core as pinned by `lib/uniswap-hooks` v1.1.0, `e59fe72`), Solidity 0.8.30, Sepolia |

Code references use `file:line` against the pinned dependencies, with these prefixes:

| Prefix | Path |
|---|---|
| `v4-core/` | `lib/uniswap-hooks/lib/v4-core/src/` |
| `v4-periphery/` | `lib/uniswap-hooks/lib/v4-periphery/src/` |
| `oz-hooks/` | `lib/uniswap-hooks/src/` |

**TL;DR**

- In each block, the pool posts **two** fees: $f_\uparrow$ for swaps that push the price up (`zeroForOne = false`) and $f_\downarrow$ for swaps that push it down (`zeroForOne = true`).
- Fee = base + **volatility premium** (applies to both sides) ± **inventory skew** (applies to one side). The structure follows the stationary Avellaneda–Stoikov / Guéant–Lehalle–Fernandez-Tapia quotes.
- The only inputs are the pool's own `slot0.tick` and `block.timestamp`. No oracle, no liquidity reads, no caller-supplied data.
- State is one storage slot per pool. It is recomputed at most once per block timestamp, and subsequent swaps in that block read the cached fees.
- Callbacks are `afterInitialize` and `beforeSwap`, so the hook address flags are `0x1080`. The fee is returned per swap with `OVERRIDE_FEE_FLAG`.

---

## 1. Problem statement

An AMM pool is a market maker that never updates its quote. Its mid price moves only when someone trades against it, and its half-spread (the LP fee) is fixed when the pool is created. Between blocks the reference market keeps moving. Once the gap between the pool price and the reference price exceeds the fee, an arbitrageur trades the pool back to the reference, and the LPs fill that trade at the stale price. Milionis et al. formalize this cost as *loss-versus-rebalancing* (LVR). For a constant-product pool, LVR accrues at a rate of $\sigma^2/8$ of pool value per unit time. The fee does not change LVR itself; it changes how much of LVR arbitrageurs actually realize. With block time $\Delta t$, that share is approximately $1/(1 + f/(\sigma\sqrt{\Delta t/2}))$. A static fee $f$ is therefore wrong in both regimes. In calm markets it is higher than necessary, so uninformed flow routes to cheaper pools. When $\sigma$ spikes, $f/\sigma$ collapses and arbitrageurs capture most of the LVR at the moment it is largest.

A professional market maker on a centralized exchange manages the same exposure actively. In the Avellaneda–Stoikov (A–S) framework, the dealer does two things. First, it **widens the spread when volatility rises**, because adverse selection and inventory risk both scale with $\sigma$. Second, it **skews both quotes against its inventory**, centering them on a reservation price $r = s - q\gamma\sigma^2(T-t)$. Trades that unwind the position become cheap and trades that extend it become expensive. The constant-product curve already gives the pool an inventory-dependent *mid*, but its *spread* is symmetric and ignores volatility. As a result the pool is the slowest quote in the market in exactly the states where being slow costs the most: high volatility and one-sided, trending flow. StoikovHook closes this gap. It makes the LP fee a per-direction function of realized volatility and inventory displacement, computed only from the pool's own on-chain state.

Non-goals are eliminating LVR (that needs an oracle or an auction), changing the swap curve, and holding tokens in the hook.

---

## 2. Fee model

### 2.1 From Avellaneda–Stoikov to an AMM fee

A–S (finite horizon $T$, CARA risk aversion $\gamma$, fill intensity $A e^{-k\delta}$) gives a reservation price and a total spread:

```math
r = s - q\,\gamma\sigma^2 (T-t), \qquad \delta^a + \delta^b = \gamma\sigma^2 (T-t) + \frac{2}{\gamma}\ln\!\left(1+\frac{\gamma}{k}\right)
```

An AMM has no terminal time. The stationary ($T\to\infty$) solution of the same control problem (Guéant, Lehalle & Fernandez-Tapia 2013, "GLFT") has the closed-form approximation

```math
\delta^{b}(q) \approx c_0 + \frac{2q+1}{2}\,c_1\sigma, \qquad
\delta^{a}(q) \approx c_0 - \frac{2q-1}{2}\,c_1\sigma, \qquad
c_0 = \frac{1}{\gamma}\ln\!\left(1+\frac{\gamma}{k}\right),\;
c_1 = \sqrt{\frac{\gamma}{2kA}\left(1+\frac{\gamma}{k}\right)^{1+\frac{k}{\gamma}}}
```

The optimal half-spread therefore has three parts: a **constant** $c_0$, a **volatility-proportional** term $\tfrac12 c_1\sigma$, and an **inventory skew** $\pm\,q\,c_1\sigma$. All of them are linear in $\sigma$. The LVR-with-fees result reaches the same scaling from a different direction. Arbitrage leakage depends on $f/(\sigma\sqrt{\Delta t})$, so a fee proportional to $\sigma$ keeps the leaked fraction roughly constant across volatility regimes. StoikovHook adopts the GLFT structure:

| A–S / GLFT | StoikovHook |
|---|---|
| mid price $s$ | pool price $P = 1.0001^{\text{tick}}$ |
| ask / bid half-spread $\delta^a,\ \delta^b$ | LP fee on price-up swaps $f_\uparrow$ / price-down swaps $f_\downarrow$ |
| inventory $q$ | normalized tick displacement $\hat q$ from a slow reference (§2.2) |
| volatility $\sigma$ | EWMA realized volatility of the tick, $\hat\sigma$ (§2.4) |
| $\gamma,\ k,\ A,\ T-t$ | folded into immutable constants $f_0, \alpha, \beta, h$ |

### 2.2 Inventory from price

Within a region of constant liquidity $L$, the pool's virtual token0 reserve is $x = L/\sqrt{P}$. Relative to a reference price $P_\text{ref}$:

```math
\frac{\Delta x}{x_\text{ref}} = \sqrt{\frac{P_\text{ref}}{P}} - 1 \;\approx\; -\tfrac12\ln\frac{P}{P_\text{ref}} \;=\; -\tfrac12\,(\text{tick}-\text{tick}_\text{ref})\,\ln 1.0001
```

So to first order, the pool's *normalized* inventory deviation is proportional to its tick displacement $d = \text{tick} - R$. It does not depend on $L$ or on how liquidity is distributed. When liquidity changes across initialized ticks, the proportionality constant changes but the sign does not, and the skew only needs the sign and a bounded magnitude. $d > 0$ means the pool has sold token0 and accumulated token1 since equilibrium, i.e. it is short token0. A–S then prescribes a *higher* reservation price. Buying token0 from the pool (a price-up swap) should get more expensive, and selling token0 to the pool (a price-down swap) should get cheaper.

The equilibrium reference $R$ is an EMA of the pool's **own** tick with time constant $\tau_R$ (§2.4), not an external oracle price. §2.6 explains why this choice matters for the sign of the skew.

### 2.3 Formula

A **window** is the set of swaps that share a `block.timestamp`. At the first swap of a window, the hook reads the window-open tick $\bar t$, updates its estimators $(V, R)$ and computes two fees. Every swap in that window then pays one of those two fees.

```math
\sigma_h = 100\,\sqrt{h\,V}\quad\text{[pips]}, \qquad
\hat q = \operatorname{clamp}\!\left(\frac{\bar t - R}{Q},\,-1,\,1\right)
```

```math
f(s) = \operatorname{clamp}\Big(f_0 + \sigma_h\,\big(\alpha + \beta\, s\,\hat q\big),\; f_{\min},\; f_{\max}\Big),
\qquad s = \begin{cases} +1 & \texttt{zeroForOne = false}\ (\text{price up}) \\ -1 & \texttt{zeroForOne = true}\ (\text{price down}) \end{cases}
```

$\sigma_h$ is the one-sigma price move over horizon $h$, converted to fee units. One tick is about 1 bp, which is 100 pips; the exact factor is $10^6\ln 1.0001 \approx 99.995$. A swap is *imbalancing* when $s\hat q > 0$ (it pushes the price further from $R$) and *rebalancing* when $s\hat q < 0$.

Properties of the model:

1. **Volatility widens both sides.** The mean fee $\tfrac12(f_\uparrow + f_\downarrow) = f_0 + \alpha\sigma_h$ (when unclamped) rises with $\hat\sigma$.
2. **Revenue-neutral skew.** The skew shifts fee from rebalancing to imbalancing flow without changing the mean. It is equivalent to moving the pool's effective quote midpoint from $P$ to $P(1+\beta\sigma_h\hat q)$, which is the A–S reservation-price shift.
3. **Bounded shift.** $\beta \le \alpha$ guarantees $f_\downarrow, f_\uparrow \ge f_0$. The quote midpoint therefore never moves by more than the half-spread, and the pool never quotes through its own inferred fair price.
4. **Calm-market limit.** As $\hat\sigma \to 0$, both fees converge to $f_0$ and the skew vanishes (no risk means no reason to skew, consistent with A–S).
5. **Window invariance.** Both fees are fixed for the whole window, so trades inside the window cannot change them (§5.4).

### 2.4 Estimators

At window open ($\text{now} > t_\text{last}$), with $\Delta t = \text{now} - t_\text{last} \ge 1$:

```math
\Delta = \operatorname{clamp}\big(\bar t - \text{tick}_\text{last},\,-C,\,C\big)
```

```math
V \leftarrow \frac{\tau_\sigma V + \Delta^2}{\tau_\sigma + \Delta t}, \qquad
R \leftarrow \frac{\tau_R R + \Delta t\cdot\bar t}{\tau_R + \Delta t}
```

- These are time-aware EWMAs with weight $a = \Delta t/(\tau + \Delta t)$. That weight is a first-order approximation of $1 - e^{-\Delta t/\tau}$, so no `exp` is needed. It stays in $[0,1)$, matches the exponential for $\Delta t \ll \tau$, and decays *more slowly* than exponential over one long idle gap. That makes fees stay high longer after a shock when nobody trades, which is the conservative direction.
- $V$ estimates **variance per second** in ticks²/s. If each step carries $\Delta^2 = v\,\Delta t$, the fixed point of the recursion is $V = v$. Winsorizing at $\pm C$ bounds how much one observation can move the estimate.
- $\Delta$ is measured between *window-open* ticks, so $V$ is a close-to-close estimator over active windows. Moves that revert inside a window are not seen. This is deliberate; see §5.4.
- $\hat q$ uses $R$ **after** the update. After a long idle gap, $R \to \bar t$, so a stale reference cannot produce a large spurious skew.

Pseudocode for the whole `beforeSwap` path (design-level, not implementation):

```
S = state[poolId]
if block.timestamp > S.tLast:                        # window open, once per timestamp
    t̄  = getSlot0(poolId).tick
    Δt = block.timestamp − S.tLast
    Δ  = clamp(t̄ − S.tickLast, −C, C)
    S.V = (τσ·S.V + Δ²) / (τσ + Δt)
    S.R = (τR·S.R + Δt·t̄) / (τR + Δt)
    d   = clamp(t̄ − S.R, −Q, Q)
    sv  = isqrt(S.V)
    S.feeUp   = clamp(f0 + sv·(Kσ + Kq·d), fmin, fmax)
    S.feeDown = clamp(f0 + sv·(Kσ − Kq·d), fmin, fmax)
    S.tLast, S.tickLast = block.timestamp, t̄
    emit FeeWindowUpdated(poolId, t̄, S.R, sv, S.feeUp, S.feeDown)
fee = params.zeroForOne ? S.feeDown : S.feeUp
return (selector, ZERO_DELTA, fee | OVERRIDE_FEE_FLAG)
```

### 2.5 Constant vs. computed

With $K_\sigma = 100\,\alpha\sqrt h$ and $K_q = 100\,\beta\sqrt h / Q$ precomputed off-chain, the fee is $f_0 + \sqrt V\,(K_\sigma \pm K_q\,d)$. The only runtime nonlinearity is one integer square root per window.

| Quantity | Kind | Source |
|---|---|---|
| $f_0, f_{\min}, f_{\max}$ | immutable | constructor |
| $\alpha, \beta, h, Q$ | immutable, folded into $K_\sigma, K_q$ | constructor (precomputed off-chain) |
| $\tau_\sigma, \tau_R, C, V_0$ | immutable | constructor |
| $\bar t$ (window-open tick) | per window | `StateLibrary.getSlot0` via `extsload` (`v4-core/libraries/StateLibrary.sol:40`) |
| $\Delta t$ | per window | `block.timestamp` − stored `tLast` |
| $V, R$ | per window | hook storage, recursions in §2.4 |
| $\sqrt V$ | per window | integer square root |
| $f_\uparrow, f_\downarrow$ | per window, cached | computed at window open |
| $s$ (direction) | per swap | `params.zeroForOne` |

Cost per swap: one `SLOAD` and a branch. Extra cost per window: one `extsload` (the `slot0` slot is already warm because `PoolManager.swap` checks initialization before calling the hook, `v4-core/PoolManager.sol:196,202`), one `SSTORE`, one `isqrt` and a few `mul`/`div`.

Constructor arguments are part of the CREATE2 init code. Changing **any** parameter therefore changes the mined hook address, for the same reason compiler settings are pinned in `foundry.toml`. Parameters are fixed per deployment, so a new parameter set means a new hook and a new pool.

### 2.6 Why the skew helps, and when it would not

- **Re-centering the no-arbitrage band.** After an up-move in the reference price, arbitrage leaves the pool at the *upper* edge of its band: $S \approx P(1+f_\uparrow)$. In expectation the fair price sits above $P$. A positive $d$ is the pool's own record of that move. The skew raises $f_\uparrow$ and lowers $f_\downarrow$, which shifts the quote midpoint up by $\beta\sigma_h\hat q$, toward where $S$ probably is. The next continuation arbitrageur then finds a smaller edge. This happens without the LPs selling more inventory at the stale price.
- **The benefit depends on the signal.** Leakage is convex in $f$. If the pool's position inside the band told us nothing, a mean-preserving skew would slightly *increase* expected arbitrage leakage (Jensen's inequality). The skew is only justified because $d$ carries information about where $S$ sits relative to $P$. This is an empirical claim. The M3 scenario and the S2 simulation (§6) exist to measure it, and the results will be reported whichever way they go.
- **Why the reference is internal.** If $R$ were an external fair price, "rebalancing toward $R$" would be the same direction as arbitrage flow, and the skew would *subsidize* LVR. With an internal EMA, rebalancing means trading against the pool's recent net flow, which is the A–S meaning.

### 2.7 Placeholder parameters

The defaults target an ETH/USDC-class pair on 12 s blocks (Sepolia), with $h$ = block time. They are placeholders until calibration (S2).

| Param | Default | Meaning |
|---|---|---|
| $f_0$ | 500 pips (0.05%) | fee floor in calm markets |
| $\alpha$ | 1.0 | volatility premium = one horizon-sigma |
| $\beta$ | 0.5 | maximum skew = ±½ horizon-sigma; requires $\beta \le \alpha$ |
| $h$ | 12 s | horizon = block time |
| $Q$ | 200 ticks (≈2%) | displacement that gives full skew |
| $\tau_\sigma$ | 300 s | volatility memory (half-life ≈ 208 s) |
| $\tau_R$ | 900 s | equilibrium memory (half-life ≈ 624 s) |
| $C$ | 1000 ticks (≈10%) | winsorization bound per observation |
| $V_0$ | 1 tick²/s (≈56% annualized) | seed variance at initialization |
| $f_{\min}$ / $f_{\max}$ | 100 / 10 000 pips (0.01% / 1%) | hard bounds |

Sanity check. At 60% annualized volatility, $\hat\sigma \approx 1.07$ ticks/√s and $\sigma_h \approx 371$ pips.

| Regime | $\hat q$ | $f_\uparrow$ | $f_\downarrow$ |
|---|---|---|---|
| calm (60% ann.) | 0 | 871 | 871 |
| calm | +1 | 1056 | 685 |
| stressed (4× vol) | 0 | 1983 | 1983 |
| stressed | +1 | 2724 | 1241 |
| one-window 10% move (Δ = 1000) | any | 10 000 (cap) | 10 000 (cap) |

After a one-window 10% move, $V \approx 3.2\times10^3$ ticks²/s and both sides hit the cap. Assume steady trading every 12 s and no further price movement. The rebalancing side drops below the cap within 2 windows. The continuation side stays capped for about 58 windows (≈ 11.6 min), because $R$ lags and $\hat q$ stays at 1 over that period.

---

## 3. On-chain state

### 3.1 Per pool (`mapping(PoolId => State)`, packed into one 256-bit slot)

| Field | Type | Meaning | Bounds / precision |
|---|---|---|---|
| `tLast` | `uint32` | timestamp of the last window open | valid until 2106 |
| `tickLast` | `int24` | window-open tick of the last observation | $[-887272, 887272]$ (`v4-core/libraries/TickMath.sol:20,23`) |
| `refTick` | `int40` | EMA reference $R$, fixed point with 16 fractional bits | $\lvert R\rvert \le 887272\cdot2^{16} < 2^{39}$ |
| `variance` | `uint64` | EWMA variance $V$, ticks²/s scaled by $10^{12}$ | $V \le \max(V_0, C^2) = 10^6 \Rightarrow < 2^{64}$ |
| `feeUp` | `uint24` | cached $f_\uparrow$ for the current window | $[f_{\min}, f_{\max}]$ |
| `feeDown` | `uint24` | cached $f_\downarrow$ for the current window | $[f_{\min}, f_{\max}]$ |

Total: 208 bits, so one slot.

Precision matters for both estimators. With $\tau_R = 900$ and $\Delta t = 1$, an integer reference would move by $\lfloor (\bar t - R)/901 \rfloor$, which is zero for any displacement under 901 ticks, so $R$ would never move. 16 fractional bits give a resolution of about $1.5\times10^{-5}$ tick. The $10^{12}$ scale on $V$ serves the same purpose for the $\Delta^2/(\tau_\sigma+\Delta t)$ increment.

Invariant: $V \le \max(V_0, C^2)$. The update is a weighted average of $V$ and $\Delta^2/\Delta t \le C^2$, so it cannot leave that bound (§5.2).

### 3.2 Global (immutable)

`poolManager`, $f_0, f_{\min}, f_{\max}, K_\sigma, K_q, Q, \tau_\sigma, \tau_R, C, V_0$.

### 3.3 Update schedule

| Event | State written |
|---|---|
| `afterInitialize` | all fields: `tLast = now`, `tickLast = tick`, $R$ = tick, $V = V_0$, fees from $V_0$ with $\hat q = 0$ |
| `beforeSwap`, first swap with `block.timestamp > tLast` | all fields (window open) |
| `beforeSwap`, later swaps in the same timestamp | none (read-only) |
| add/remove liquidity, donate | none (the hook is not called) |

`afterSwap` is not needed. Only swaps change the tick; liquidity changes and donations do not. The `slot0.tick` read at the next window open is therefore the closing tick of the last active window, so the hook sees every close without running after every swap.

The window key is `block.timestamp` rather than `block.number`. On chains where several blocks share a timestamp, those blocks form one window, which guarantees $\Delta t \ge 1$.

---

## 4. Hook callbacks and permissions

| Callback | Flag (`v4-core/libraries/Hooks.sol`) | Used | Why |
|---|---|---|---|
| `beforeInitialize` | `1 << 13` | no | the tick is not available yet; `afterInitialize` is enough |
| `afterInitialize` | `1 << 12` (`:30`) | **yes** | validate the fee mode, seed state |
| `before/afterAddLiquidity`, `before/afterRemoveLiquidity` | `1 << 11` … `1 << 8` | no | LP entry and exit never touch the hook, so **the hook cannot block withdrawals** |
| `beforeSwap` | `1 << 7` (`:38`) | **yes** | window update, per-swap fee override |
| `afterSwap` | `1 << 6` | no | the next window-open `slot0.tick` already gives the close (§3.3) |
| `before/afterDonate` | `1 << 5`, `1 << 4` | no | — |
| all `*ReturnDelta` | `1 << 3` … `1 << 0` | no | the hook never takes or gives tokens and has zero custody |

The hook address therefore must have low 14 bits equal to `AFTER_INITIALIZE | BEFORE_SWAP = 0x1080`. The flags passed to `HookMiner.find` (`v4-periphery/utils/HookMiner.sol:23`) must be derived from the same permission set that `getHookPermissions()` returns. The `BaseHook` constructor enforces this through `validateHookAddress` (`oz-hooks/base/BaseHook.sol:60`).

### 4.1 `afterInitialize(sender, key, sqrtPriceX96, tick)`

1. **Require a dynamic-fee pool** (`key.fee == DYNAMIC_FEE_FLAG`, `v4-core/libraries/LPFeeLibrary.sol:15`), otherwise revert. `PoolManager` only honors an override for dynamic-fee pools (`Hooks.sol:263`). A static-fee pool would silently ignore the hook's fees.
2. **Seed state** as described in §3.3.
3. **Set the stored LP fee to $f_0$** with `poolManager.updateDynamicLPFee(key, f0)` (`v4-core/PoolManager.sol:339-346`). Dynamic pools start with `slot0.lpFee = 0` (`LPFeeLibrary.sol:51-54`), and the library's own comment recommends this call from `afterInitialize` (`:48`). This is defense in depth: if an override were ever missing, swaps would fall back to $f_0$ instead of 0. It also means tools that read `slot0.lpFee` see a sensible value. It runs once per pool, and `initialize` is not behind the unlock lock (`PoolManager.sol:117`).
4. Emit `FeeWindowUpdated` and return the selector.

### 4.2 `beforeSwap(sender, key, params, hookData)`

1. If this is the first swap of a new timestamp, open a window (§2.4) and emit `FeeWindowUpdated`.
2. Select `params.zeroForOne ? feeDown : feeUp`.
3. Return `(selector, ZERO_DELTA, fee | OVERRIDE_FEE_FLAG)`. `OVERRIDE_FEE_FLAG` is `0x400000` (`LPFeeLibrary.sol:19`). `PoolManager` strips the flag and validates `fee ≤ MAX_LP_FEE = 1_000_000` (`Pool.sol:303-305`, `LPFeeLibrary.sol:25`). A protocol fee, if enabled, composes on top (`Pool.sol:307`).

`sender`, `hookData` and `amountSpecified` are ignored, so the fee cannot be influenced by router-supplied data. The fee each swap actually paid can be observed from `PoolManager`'s own `Swap` event, which carries `fee` (`v4-core/interfaces/IPoolManager.sol:91-99`). No extra per-swap hook event is needed.

`Hooks.beforeSwap` skips the hook when `msg.sender == hook` (`Hooks.sol:253`). StoikovHook never calls `PoolManager.swap`, so every swap goes through the override.

### 4.3 Implementation base (proposed)

OpenZeppelin `BaseOverrideFee` (`oz-hooks/fee/BaseOverrideFee.sol`) already has exactly this permission set (`:75-83`). It already provides the dynamic-fee check (`:45`), the override return (`:67`) and a **non-view** `_getFee` extension point (`:52-55`), so state updates fit there. StoikovHook would extend it: `_getFee` would carry the logic of §4.2, and `_afterInitialize` would call `super` and then seed state and set the stored fee.

### 4.4 Event

`FeeWindowUpdated(PoolId indexed id, int24 tick, int24 refTick, uint256 sqrtVariance, uint24 feeUp, uint24 feeDown)` is emitted once per window, not once per swap.

---

## 5. Security constraints

### 5.1 Fee bounds

- **Deploy-time invariants** (the constructor reverts otherwise): $0 < f_{\min} \le f_0 \le f_{\max} \le 100\,000$ (a 10% ceiling, well below `MAX_LP_FEE = 1_000_000`); $\beta \le \alpha$; $Q > 0$; $C > 0$; $\tau_\sigma, \tau_R \ge 1$; $V_0 \le C^2$.
- **Runtime**: every returned fee is clamped to $[f_{\min}, f_{\max}]$ before it is narrowed to `uint24`. Because $f_{\max} < 2^{22}$, OR-ing in `OVERRIDE_FEE_FLAG` cannot collide with the fee bits, and the result always passes `removeOverrideFlagAndValidate` (`Pool.sol:304`).
- **Every path returns the override flag.** There is no early return without it. The stored fallback of $f_0$ (§4.1) covers the case where that invariant is ever broken.

### 5.2 Overflow and liveness

A revert inside `beforeSwap` blocks every swap in the pool. The design goal is that **the fee function is total**: for every reachable state it returns without reverting. Solidity 0.8 checked arithmetic is only a safety net. The bounds hold by construction and are fuzz-tested:

- tick $\in [-887272, 887272]$ (< $2^{20}$); $\Delta$ is winsorized to $\pm C$ before squaring.
- $V \le \max(V_0, C^2)$ is invariant (§3.1), so $\sqrt V \le C$ and $\sigma_h$ and the pre-clamp fee stay far below $2^{64}$.
- $\Delta t$ is only computed when `block.timestamp > tLast`, so $\Delta t \ge 1$. Denominators $\tau + \Delta t \ge 2$.
- All intermediates are computed in `int256`/`uint256`. The only narrowing casts are `feeUp`/`feeDown` (after the clamp), `refTick` (bounded above), `variance` (invariant) and `tickLast` (a valid tick).
- Division rounds toward zero. The fractional `refTick` avoids a stuck reference, and fee rounding error is at most 1 pip.
- Worst-case failure mode: swaps pause. LP funds are always withdrawable because no liquidity callbacks are registered.

### 5.3 Rejecting callers other than PoolManager

- Every `IHooks` entry point is `onlyPoolManager` (`oz-hooks/base/BaseHook.sol:66-67`), and any other caller reverts with `NotPoolManager`. Callbacks that are not implemented revert with `HookNotImplemented` (e.g. `BaseHook.sol:120`).
- At construction, `validateHookAddress` (`BaseHook.sol:60`) makes deployment revert if the address's flag bits do not match `getHookPermissions()`.
- There are no privileged roles: no owner, no setters, no proxy. Parameters are immutable. The only external calls are to `PoolManager` (the `extsload` read, and `updateDynamicLPFee` once at initialization). There is no token custody and no approval, so there is no reentrancy surface beyond the trusted `PoolManager`.
- Pools are permissionless. Anyone can create a pool with any pair that points at the hook, but state is keyed by `PoolId`, so pools cannot interfere with each other. Non-dynamic pools revert at initialization.

### 5.4 Economic manipulation

- **Window snapshot.** Within a timestamp, every trader faces a fixed fee pair. Without the snapshot, a single transaction could sell token0 at the discounted rebalancing rate to push the tick past $R$, then buy a large size at the new "rebalancing" discount. With the snapshot, the second leg still pays the $f_\uparrow$ computed from the window-open state.
- **Cross-window displacement.** Someone controlling the last transaction of block N and the first of block N+1 (for example a builder) can move $\bar t$. That costs fees plus exposure to other arbitrageurs across the block boundary, and the gain is at most $2\beta\sigma_h$ times the notional of the next trade. This is a documented residual risk. The "cross $R$, then trade big" variant is closed by S1.
- **Volatility inflation** requires actually moving the close-to-close price, which costs fees and arbitrage losses. Its only effect is higher LP fees, capped at $f_{\max}$, and it decays with $\tau_\sigma$. One observation can add at most $C^2/(\tau_\sigma + 1)$ to $V$. **Volatility deflation** is impossible through trading; $V$ only falls with time.
- **Quoting.** Quoters simulate the swap including `beforeSwap`, so off-chain quotes reflect the direction-dependent fee. A window-open update inside a simulation is reverted along with it.

### 5.5 Known limitations

- There is one fee per swap. A swap that crosses $R$ pays the window-open rate for its whole size (S1 addresses this).
- $R$ lags genuine repricing. For about $\tau_R$ after a real move, continuation flow pays more, including uninformed continuation flow. This is intended but has a cost.
- Parameters are calibrated for ETH-class volatility on 12 s blocks. Other pairs or chains need their own deployment.
- The model shrinks the share of LVR that arbitrageurs capture but does not remove LVR. Oracle-based and auction-based designs attack the problem differently.

---

## 6. Scope

### 6.1 MVP (must ship for the demo)

| ID | Deliverable |
|---|---|
| M1 | `StoikovHook` implementing §2–§5: `afterInitialize` + `beforeSwap`, immutable parameters, single-slot state, `FeeWindowUpdated` event |
| M2 | Foundry unit, fuzz and gas tests (see the criteria below) |
| M3 | Deterministic **scenario comparison**: one scripted price path (calm → jump → trend → reversal), an arbitrageur that trades each pool to the reference price whenever that is profitable net of fees, and scripted uninformed flow. Pools compared: StoikovHook vs. static 0.05% and 0.30%. Outputs: LP fee income, arbitrageur profit (realized LVR) and LP value marked to the reference price |
| M4 | Deployment script: mine the address (flags taken from `getHookPermissions()`), deploy with CREATE2, initialize a dynamic-fee pool, add liquidity, run demo swaps. Runs end-to-end on anvil (Sepolia fork) and on Sepolia |
| M5 | README repository guide with `file:line` pointers, plus deployed addresses and transaction hashes |

**Acceptance criteria**. All are verifiable from the repo or on-chain.

| # | Criterion |
|---|---|
| A1 | `forge test` passes. The fuzz tests of the fee function and swap sequences use ≥ 1 000 runs |
| A2 | Initializing a pool with a static fee (e.g. 3000) reverts. Initializing with `DYNAMIC_FEE_FLAG` succeeds, and afterwards `slot0.lpFee == f0` |
| A3 | Calling `afterInitialize` / `beforeSwap` from any address other than `PoolManager` reverts with `NotPoolManager` |
| A4 | In a window with $\hat q > 0$ and $V > 0$, a `zeroForOne = false` swap pays a strictly higher fee than a `zeroForOne = true` swap in the same window. With $\hat q = 0$ both pay the same fee. Checked through the `fee` field of `PoolManager`'s `Swap` event, with protocol fee 0 |
| A5 | After a scripted jump, the next window's mean fee is higher. With no further price movement it then decays monotonically toward $f_0$ as time passes (`vm.warp`) |
| A6 | Swaps in the same block see the same `(feeUp, feeDown)`. A same-block round trip followed by a large swap pays the same fee as the large swap alone |
| A7 | Across fuzzed sequences of $(\Delta t,\ \text{direction},\ \text{size})$, every fee lies in $[f_{\min}, f_{\max}]$ and no swap reverts inside the hook |
| A8 | Gas measured with Foundry gas snapshots and recorded in `docs/BUILD_LOG.md`. Targets: cached path ≤ 5 000 gas; window-open path ≤ 25 000 gas (hook execution only) |
| A9 | The M3 comparison runs deterministically and prints a metrics table for all three pools. The result is reported in the README **whichever way it comes out** |
| A10 | On Sepolia: the hook is deployed at an address whose low 14 bits equal `0x1080`, the source is verified on the explorer, a dynamic-fee pool is initialized, and at least 2 swaps in opposite directions paid different fees. Transaction hashes are recorded |

### 6.2 Stretch (if time allows)

| ID | Item |
|---|---|
| S1 | **Size-aware fee**: estimate the post-swap displacement from `amountSpecified` and in-range liquidity (`StateLibrary.getLiquidity`, `StateLibrary.sol:183`) and charge the path-averaged skew. This closes the "cross $R$, then trade big" residual |
| S2 | **Monte Carlo calibration**: GBM with jumps, arbitrage plus noise traders, a sweep over $(\alpha, \beta, h, \tau_\sigma, \tau_R)$ against static tiers, reporting the LP PnL / LVR ratio |
| S3 | Read-only fee dashboard showing live $f_\uparrow / f_\downarrow$ and $\hat\sigma$ from `FeeWindowUpdated` and `Swap` events |
| S4 | Per-pool parameters through a factory that deploys one hook per parameter set. This keeps the no-admin property; there are no mutable setters |
| S5 | Intra-window range estimator (Parkinson high/low through `afterSwap`). Trade-off: more gas, and intra-block extremes are easier to manipulate |
| S6 | L2 deployment (e.g. Unichain) with $h$ retuned to that chain's block time |

**Out of scope**: custom curves or return-delta accounting, hook-owned liquidity, MEV auctions, and external price oracles as the inventory reference.

---

## 7. Open questions for review

1. Are the parameter defaults in §2.7 acceptable as placeholders until S2?
2. Should the skew scale with $\sigma$ (the GLFT form used here), or should an additional σ-independent component keep it active in calm markets?
3. Are static 0.05% and 0.30% the right M3 baselines?
4. Window key: `block.timestamp` (proposed) or `block.number`?
5. Setting the stored LP fee to $f_0$ in `afterInitialize` (§4.1): keep it?

## References

- M. Avellaneda, S. Stoikov. *High-frequency trading in a limit order book.* Quantitative Finance, 2008.
- O. Guéant, C.-A. Lehalle, J. Fernandez-Tapia. *Dealing with the inventory risk: a solution to the market making problem.* Mathematics and Financial Economics, 2013.
- J. Milionis, C. C. Moallemi, T. Roughgarden, A. L. Zhang. *Automated Market Making and Loss-Versus-Rebalancing.* 2022.
- J. Milionis, C. C. Moallemi, T. Roughgarden. *Automated Market Making and Arbitrage Profits in the Presence of Fees.* 2023.
