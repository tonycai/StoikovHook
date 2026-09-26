# AI Usage

StoikovHook is built by one person, Tony Cai, with AI tools. This document states plainly what the AI did, what it proposed, what the author decided and what the author did personally. Every attribution here can be checked against the repository: the spec, the build log and the git history. Where a record differs from memory, the build log wins.

## 1. Workflow

Three layers:

| Layer | Who | Role |
|---|---|---|
| Planning and review | **Claude** (chat) | Planning tasks and reviewing results. |
| Execution | **Claude Code CLI** | Drafting the spec; writing the contract, tests, simulation, scripts and docs; running every build, test and on-chain check; git operations and repository metadata. |
| Decisions and sign-off | **The author** | Final decisions, diff review, keys, the live broadcast and contact with the Uniswap team. |

Commits produced with Claude Code carry a `Co-Authored-By: Claude …` trailer.

## 2. What the AI Did

All of the following was done by Claude Code:

- **Scaffolding.** Created the repository from `uniswapfoundation/v4-template`, pinned the compiler settings in `foundry.toml`, installed dependencies and ran the baseline tests. Along the way it found and fixed template issues: the `broadcast/` ignore rule, the ignored `docs/` directory and the undefined CI profile (see `FEEDBACK.md`).
- **Design spec drafting.** Wrote `specs/01-design.md` from the author's brief: the mapping from Avellaneda–Stoikov to AMM fees, the fee formula, the on-chain estimators, the state layout, the callback and permission plan, the security analysis and the MVP scope. Every claim about v4 interfaces cites `file:line` in the pinned dependencies.
- **Implementation to spec.** Implemented the contract as specified, after the author approved the spec. Every change to fee computation or pool state was shown to the author as a diff before it was committed.
- **Tests and scripts.** Wrote and ran the Foundry unit, fuzz and gas tests, the mutation checks and the deployment scripts.
- **Simulation and calibration.** Built the comparison simulation, the τR calibration sweep and the figure script, and ran the sweep, the holdout check and the reversal diagnostic (`docs/simulation/README.md`).
- **Deployment checks.** Ran the Sepolia dry runs and a fork rehearsal, then checked the live deployment on chain and verified the source on Etherscan (`docs/deployments/sepolia.md`).
- **Documentation.** Wrote the README, build-log entries, the demo script, the submission copy and FEEDBACK entries, and translated the early Chinese-language docs into English.
- **Verification tooling.** Rendered the Mermaid diagrams locally, compiled every LaTeX expression with MathJax, recomputed the spec's worked numbers with a script, and checked every deployment on chain.

## 3. Proposed by the AI, Approved by the Author

| Proposal | Where it was proposed | Where it was approved |
|---|---|---|
| Oracle-free reference price: measure inventory against an EMA of the pool's own tick | Spec draft (`docs/BUILD_LOG.md`, 2026-09-25 21:26) | Spec approval (`specs/01-design.md`, approved 2026-09-25) |
| Per-block fee caching, so a same-block round trip cannot lower a later fee. The agent keyed windows by timestamp; the author changed the key to block number | Spec draft (build log, 2026-09-25 21:26, issue 2) | Spec §7, decision 4 |
| The fee-matched static pool as the comparison baseline | When the first draft of goal G1 compared against fixed fee tiers (build log, 2026-09-25 21:35) | Spec §7, decision 3 |
| Informed arbitrage flow and uninformed noise flow in the simulation | First spec draft, M3 (commit `7f27177`) | The author approved the spec, then made both flows a requirement of the simulation task (build log, 2026-09-26 11:06) |
| The placeholder parameter values (spec §2.7) | Spec draft | Spec §7, decision 1: adopt them and retune after simulation |
| The stored fallback fee of f0 in `afterInitialize` | Spec draft (build log, 2026-09-25 21:26, issue 1) | Spec §7, decision 5 |

## 4. What the Author Did

**Decisions:**

- **The concept and its goal.** Applying Avellaneda–Stoikov market-making logic to Uniswap v4 dynamic fees, with two fee drivers (inventory deviation from equilibrium and recent volatility), the directional rule (imbalancing trades pay more, rebalancing trades pay less, volatility raises all fees) and the goal of shrinking the share of LPs' adverse-selection loss (LVR) that arbitrageurs keep.
- **Engineering constraints.** Pinning compiler settings because the CREATE2-mined hook address depends on the bytecode; keystore-only key handling; never printing RPC URLs; spec-first development; small commits; the English-only policy (all in `CLAUDE.md`).
- **Fee windows keyed by `block.number`**, not the agent's proposed `block.timestamp`, because block producers can nudge timestamps (spec §7, decision 4).
- **No volatility-independent skew term**, to keep the MVP formula minimal (spec §7, decision 2).
- **Simulation requirements.** Deterministic and local, a trend and a mean-reverting segment, at least 20 seeds, results published either way (build log, 2026-09-26 11:06).
- **The τR calibration protocol.** A rule fixed before the first run, training seeds 1–20 and a holdout set of seeds 21–40, and no change to the default unless the gain held (build log, 2026-09-26 11:22).
- **Overriding that rule to keep τR = 900 s.** τR = 3600 s passed the rule, but lost in the out-of-distribution reversal scenario. The author kept 900 s as the more robust default (build log, 2026-09-26 11:22; `docs/simulation/README.md`).

**Done personally:**

- **Diff review.** Every change to fee computation, pool state, hook permissions or anything that touches funds was shown to the author as a diff and approved before it was committed. The author also approves corrections the agent flags, such as the revised CREATE2 collision guidance in `CLAUDE.md`.
- **Keys.** The Foundry keystore and the deployer key. The AI never handled a private key.
- **The live Sepolia broadcast**, run from the author's keystore (build log, 2026-09-26 13:06).
- **Contact with the Uniswap team**, including the Discord confirmation that the CREATE2 address collision is expected behavior (`FEEDBACK.md`).

## 5. Where the Prompts Live

- **Standing instructions**: `CLAUDE.md`, the rules Claude Code works under in every session.
- **Design intent**: `specs/`, written and reviewed before implementation.
- **Task history**: `docs/BUILD_LOG.md`. Each entry's "Goal" is a task the author requested, followed by the outcome, the problems hit and how they were resolved.
- The conversations themselves, in Claude and in Claude Code, are not committed verbatim. The build log is the per-task record.

## 6. Verification

- **Tests.** Every code change must pass `forge test` before it is committed. The test count and gas figures for each change are recorded in `docs/BUILD_LOG.md`.
- **Evidence.** `CLAUDE.md` requires every conclusion Claude Code reports to carry `file:line` evidence. Claims about v4 behavior in the spec and in `FEEDBACK.md` cite the pinned source.
- **Numbers and rendering.** The spec's worked numbers were recomputed with a script. Mermaid diagrams and LaTeX were rendered locally before publishing.
- **Deployments.** Before an address is published, it is checked on chain: the flag bits, the code and the getters. For the Sepolia deployment, the runtime bytecode was also compared with a clean local build before the source was verified on Etherscan.
- **Honesty rule.** The README only marks features ✅ when they are implemented and tested. Everything else stays 🚧 or 📋.
