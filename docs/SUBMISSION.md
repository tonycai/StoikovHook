# ETHGlobal Tokyo 2026 Submission

Copy for the ETHGlobal submission form. Every number matches the README, the simulation outputs or the chain; the last section lists the source of each one.

## 1. Short description

Uniswap v4 hook that sets fees like a market maker: higher in volatile markets, skewed by direction

## 2. Description

**Problem.** A Uniswap pool is a market maker that never updates its quote: its fee is fixed when the pool is created. When the price moves elsewhere, arbitrageurs trade the pool back into line, and LPs fill those trades at stale prices. This loss is called loss-versus-rebalancing (LVR). A static fee is too high for regular traders in calm markets and too low for arbitrageurs when volatility spikes.

**Solution.** StoikovHook gives the pool the two tools of an Avellaneda–Stoikov market maker. Every block it posts two fees, one per direction, computed only from the pool's own state. A volatility premium raises both. An inventory skew charges more to swaps that push the price further from its slow moving average, and less to swaps that bring it back. No oracle, no admin key, no token custody. Deployed and source-verified on Sepolia.

**Results.** A deterministic Foundry simulation runs identical order flow through every pool, over 20 seeds of 400 blocks. Against a static pool that charges regular traders the same average fee, LPs end +0.160 ± 0.105 bps of pool value ahead, in 20 of 20 seeds. The extra fee income comes entirely from arbitrageurs (+0.175 bps); regular traders pay the same average fee. The effect is small, about 2.2% of the LP's loss versus HODL, and appears only while the price trends. It does not lower LVR in absolute terms; what falls instead is the arbitrageur's share of the value it extracts, from 32.9% to 30.3%.

## 3. How it's made

StoikovHook extends OpenZeppelin uniswap-hooks' `BaseOverrideFee` and enables only `afterInitialize` and `beforeSwap`, so its address must end in flags `0x1080`. It is mined with HookMiner and deployed via CREATE2. `afterInitialize` rejects static-fee pools, seeds the estimators and stores a 0.05% fallback with `updateDynamicLPFee`, since dynamic-fee pools otherwise start at `lpFee = 0`. `beforeSwap` returns the fee for the swap's direction with `OVERRIDE_FEE_FLAG`, so v4 charges it per swap without touching the stored fee.

No oracle: the reference price is a slow EMA (900 s) of the pool's own tick. The skew is the tick's distance from it, which within a liquidity range tracks the pool's inventory to first order. Volatility is an EWMA of squared tick changes, weighted by Δt/(τ+Δt), so no `exp` is needed. Solady's `FixedPointMathLib` does the math with one square root per block, and each pool's state fits in one storage slot.

Fees are computed at the first swap of a block, keyed by `block.number`, and cached. Mutation testing shows why: without the cache, a same-block round trip cuts a large buy's fee from 6,302 to 4,933 pips. Overhead is 3,678 gas on cached swaps and 14,905 when a window opens.

The simulation is a Foundry harness: an arbitrageur that trades only when profitable after each pool's directional fee, random noise traders, and a fee-matched control, over 20 seeds. The reference memory τR was calibrated under a pre-registered rule with training and holdout seeds. 3600 s passed it (+0.042 ± 0.027 bps, t = 6.9). A reversal scenario added after seeing those results showed it doing worse than 900 s (−0.117 ± 0.062 bps, t = −8.5), so the default stayed at 900 s and the override is documented.

Etherscan verification failed on uniswap-hooks' root-relative import of `src/base/BaseHook.sol`; a context remapping fixed it without changing the bytecode.

## 4. Uniswap Foundation: Best Uniswap Stack Contribution

StoikovHook is a v4 hook built on the Uniswap stack end to end: v4-core, v4-periphery's HookMiner, OpenZeppelin uniswap-hooks, the v4-template and hookmate. Integration points:

| Integration | Where |
|---|---|
| Hook base contract: `BaseOverrideFee` from OpenZeppelin uniswap-hooks v1.1.0 | `src/StoikovHook.sol:L79`; inherited permissions `lib/uniswap-hooks/src/fee/BaseOverrideFee.sol:L75-L92` |
| Permissions `afterInitialize` + `beforeSwap`, address flags `0x1080`, one constant shared by the hook, tests and deploy script | `src/StoikovHook.sol:L18` |
| `afterInitialize`: dynamic-fee check, estimator seeding, stored fallback fee via `IPoolManager.updateDynamicLPFee` | `src/StoikovHook.sol:L174-L196` (fallback at L194); check at `BaseOverrideFee.sol:L45` |
| `beforeSwap` per-swap fee override | `src/StoikovHook.sol:L200-L219` (`_getFee`); `BaseOverrideFee.sol:L67` adds `OVERRIDE_FEE_FLAG`, which v4-core parses only for dynamic-fee pools (`v4-core/src/libraries/Hooks.sol:L263`) and validates in `Pool.swap` (`v4-core/src/libraries/Pool.sol:L303-L305`) |
| Pool state read with `StateLibrary.getSlot0` (the tick); per-pool state keyed by `PoolId` | `src/StoikovHook.sol:L209`, `L131`; state struct `L84-L99` |
| Fee formula, estimator update, parameter validation | `src/StoikovHook.sol:L260-L286`, `L222-L254`, `L290-L299` |
| `FeeWindowUpdated` event and the `previewFees` view, for indexers and front ends | `src/StoikovHook.sol:L135-L137`, `L162-L170` |
| Address mining with HookMiner and deployment through the CREATE2 deployer | `script/sepolia/DeployDemo.s.sol:L54-L57`, `L62` |
| Pool creation and full-range liquidity in one PositionManager `multicall` (`initializePool` + `modifyLiquidities`); Permit2 approvals; swaps through the V4 swap router | `script/sepolia/DeployDemo.s.sol:L103-L122`, `L95-L100`, `L124-L134` |
| Tests against a real PoolManager, reading the charged fee from PoolManager's own `Swap` event | `test/utils/StoikovHookFixture.sol:L45-L51`, `L103-L118`; `test/StoikovHook.t.sol:L88` |
| Live on Sepolia: hook `0x67b97620e35DAf13de266F84cAbC8c8d45755080` on the official PoolManager, source verified. Opposite-direction swaps paid 1,987 and 2,799 pips, as recorded in `Swap` events | `docs/deployments/sepolia.md` |

Contributions back to the stack, all in `FEEDBACK.md` with `file:line` evidence and a suggested fix:

- uniswap-hooks' root-relative imports (`BaseOverrideFee.sol:6`) break Etherscan verification. The fix is a one-line context remapping.
- v4-template: Sepolia and mainnet broadcast logs are committed by default; `03_Swap.s.sol` sends swap output to the script contract's address; `docs/` is ignored; `BaseScript.deployerAddress` is wrong in keyless dry runs; the `Deployers` token helpers fail in scripts; CI names an undefined profile.
- Documentation: dynamic-fee pools start with `lpFee = 0`; the unmodified example hook's mined address is already taken on public testnets (confirmed by Dayitva, Uniswap Foundation).

## 5. AI usage

StoikovHook was built by one person, Tony Cai, in three layers: Claude (chat) for planning and review, Claude Code for execution, and the author for final decisions and sign-off.

- **What the AI did.** Claude Code drafted the spec; wrote the contract, tests, simulation, scripts and docs; and ran every build, test and on-chain check.
- **Proposed by the AI, approved by the author.** The oracle-free reference price, per-block fee caching, the fee-matched static baseline, informed and uninformed order flow in the simulation, the placeholder parameter values and the stored fallback fee.
- **The author's decisions.** The concept and its goal; the engineering constraints; fee windows keyed by block number rather than timestamp; no volatility-independent skew term; the simulation requirements (deterministic and local, a trend and a mean-reverting segment, at least 20 seeds, results published either way); a pre-registered rule and a holdout set for calibrating τR; and overriding that rule to keep τR = 900 s after an out-of-distribution diagnostic.
- **Done by the author personally.** Reviewing every diff that touches fee computation, pool state or funds; keystore and key management; the live Sepolia broadcast; and contact with the Uniswap team.

Each attribution is sourced in `AI_USAGE.md`, and `docs/BUILD_LOG.md` is the per-task record.

## 6. Future

StoikovHook is an unaudited testnet prototype. The next steps follow from its known limitations:

- **Calibrate across scenarios.** Only τR has been calibrated, and on a single price generator; the other defaults are placeholders. Next is a Monte Carlo sweep over α, β, h, τσ and τR on paths with jumps, repeated trend reversals and regime switches, reporting LP PnL against LVR.
- **Adaptive τR.** No fixed reference memory was best in both regimes tested, so a τR that adapts to the regime is the next experiment.
- **Fee-sensitive order flow.** The simulation assumes regular traders ignore fees. Adding routing to competing pools, concentrated liquidity and arbitrage gas costs would test whether the gain survives.
- **Size-aware fees.** Charging the skew averaged over a swap's price path would close the "cross the reference, then trade big" gap.
- **Audit before mainnet**, and retune the 12-second horizon for each chain.

## 7. Tech stack

| Category | Used in this project |
|---|---|
| Ethereum developer tools | Foundry (forge, cast, anvil) |
| Blockchain networks | Ethereum Sepolia |
| Programming languages | Solidity 0.8.30; Python 3.9 (figures only) |
| Smart contract libraries | Uniswap v4-core, Uniswap v4-periphery (HookMiner), OpenZeppelin uniswap-hooks v1.1.0, Solady v0.1.26, Permit2, hookmate, forge-std |
| Sponsor technology | Uniswap v4 hooks (dynamic fees) |
| Other | Etherscan (source verification), matplotlib 3.9.4 (figures), Mermaid (diagrams), GitHub |
| AI tools | Claude Code |
| Not used | No frontend or web framework, no database, no oracle, no indexer |

## Images

Generated by scripts in `script/plots/`, deterministic.

- **Logo**: `docs/brand/logo-512.png` (512×512; source `docs/brand/logo.svg`). An original mark: one stem that forks into the price-up fee (blue) and the price-down fee (orange). `docs/brand/logo-64.png` shows it at 64×64.
- **Cover**: `docs/brand/cover-1280x720.png` (16:9), from `make_brand.py`.
- **Gallery**: the five figures as 1600-pixel-wide PNGs in `docs/figures/png/`, from `make_figures.py`, in this order:
  1. `fee-curve.png`: the whole mechanism in one picture
  2. `fee-timeseries.png`: the two fees during one simulated run
  3. `lp-performance.png`: LP outcome over 20 seeds
  4. `attack-defense.png`: the same-block round trip, with and without the cache
  5. `ref-tau-sensitivity.png`: the τR calibration

## Sources for Every Number

Lengths: short description 99 characters (limit 100); description 245 words; how it's made 299 words; future 149 words.

| Number | Used in | Source |
|---|---|---|
| 20 seeds × 400 blocks | 2, 3 | `README.md:178`; `docs/simulation/README.md:13` |
| LP − HODL +0.160 ± 0.105 bps vs. the fee-matched pool, positive in 20 of 20 seeds | 2 | `README.md:187`; `docs/simulation/summary.json`, `paired_stoikov_minus_fee_matched.lp_minus_hodl_bps` and `seeds_where_stoikov_lp_minus_hodl_is_higher` |
| Arbitrageurs pay +0.175 bps more in fees; regular traders pay the same (difference 0.000 ± 0.001 bps) | 2 | `README.md:188`; `summary.json`, `fee_arb_bps` and `fee_noise_bps` |
| About 2.2% of the LP's loss versus HODL | 2 | `README.md:187` |
| Arbitrageur's share of extracted value 32.9% → 30.3% | 2 | `README.md:182-183`, `README.md:202` |
| Gain only while the price trends | 2 | `README.md:203` |
| Address flags `0x1080` | 3, 4 | `README.md:103`; `src/StoikovHook.sol:L18` |
| 0.05% stored fallback fee | 3 | `README.md:103`; `src/StoikovHook.sol:L194` |
| Dynamic-fee pools start at `lpFee = 0` | 3 | `FEEDBACK.md:38`; `v4-core/src/libraries/LPFeeLibrary.sol:51-54` |
| Reference EMA of 900 s | 3, 5 | `README.md:209`; `docs/simulation/README.md:88` |
| EWMA weight Δt/(τ+Δt) | 3 | `specs/01-design.md:115` |
| One square root per block; one storage slot per pool | 3 | `specs/01-design.md:153`, `specs/01-design.md:22`, `specs/01-design.md:212` |
| 6,302 vs. 4,933 pips after a same-block round trip | 3 | `README.md:153`; `docs/simulation/attack_defense.csv` |
| 3,678 gas cached, 14,905 gas window open (warm) | 3 | `README.md:168-169` |
| τR = 3600 s passed the rule: +0.042 ± 0.027 bps, t = 6.9 | 3 | `docs/simulation/README.md:84`, `docs/simulation/README.md:91` |
| Reversal scenario: 3600 s vs. 900 s −0.117 ± 0.062 bps, t = −8.5 | 3 | `docs/simulation/README.md:102` |
| uniswap-hooks v1.1.0 | 4 | `README.md:215` |
| Hook `0x67b97620…5080`; swap fees 1,987 and 2,799 pips | 4 | `README.md:307`, `README.md:324-325`; `docs/deployments/sepolia.md:17`, `docs/deployments/sepolia.md:84-85` |
| 12-second horizon h | 6 | `src/StoikovHook.sol:L55-L57`; `README.md` fee-curve figure title |
| Solidity 0.8.30; uniswap-hooks v1.1.0; Solady v0.1.26 | 7 | `README.md:213`, `README.md:215`, `README.md:217`; `foundry.toml`; `foundry.lock` |
| Python 3.9; matplotlib 3.9.4 | 7 | `script/plots/requirements.txt`; plotting environment `python3 --version` = 3.9.6 |
| PNGs 1600 px wide | Images | `script/plots/make_figures.py`, `PNG_WIDTH` |
| Cover: "LPs ahead in 20/20 seeds" (against the fee-matched pool) | Images | `README.md:187` |
