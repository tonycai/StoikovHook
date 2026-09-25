# AI Usage

StoikovHook is built by one person, Tony Cai, with an AI coding agent. This document states plainly what the agent did, what the author did, and how both are verified. Every claim here can be checked against the repository: the spec, the build log and the git history.

## 1. Tools Used

| Tool | Role |
|---|---|
| **Claude Code CLI** | Execution layer: scaffolding, reading dependency source, writing contracts, tests, scripts and docs, running `forge`, local deployments, git operations and repository metadata. |
| **Claude** | Drafting the design spec and reviewing it against the v4 source code. |

Commits produced with the agent carry a `Co-Authored-By: Claude …` trailer.

## 2. What the AI Did

- **Scaffolding.** Created the repository from `uniswapfoundation/v4-template`, pinned the compiler settings in `foundry.toml`, installed dependencies and ran the baseline tests. Along the way it found and fixed template issues: the `broadcast/` ignore rule, the ignored `docs/` directory and the undefined CI profile (see `FEEDBACK.md`).
- **Design spec drafting.** Wrote `specs/01-design.md` from the author's brief: the mapping from Avellaneda–Stoikov to AMM fees, the fee formula, the on-chain estimators, the state layout, the callback and permission plan, the security analysis and the MVP scope. Two of its proposals were the agent's: measuring inventory against the pool's own EMA price instead of an oracle, and snapshotting fees once per block. Every claim about v4 interfaces cites `file:line` in the pinned dependencies.
- **Implementation to spec.** Implements the contract as specified in `specs/01-design.md`; the pricing model is 🚧 in progress.
- **Tests and scripts.** Writes the Foundry unit and fuzz tests and the deployment script, and runs them.
- **Documentation.** Writes the README, build-log entries, the demo script and FEEDBACK entries, and translated the early Chinese-language docs into English.
- **Verification tooling.** Rendered the Mermaid diagrams locally, compiled every LaTeX expression with MathJax, recomputed the spec's worked numbers with a script, and verified local deployments on-chain.

## 3. What the Human Did

The author set the direction and made the decisions that shape the project:

- **The concept.** Applying Avellaneda–Stoikov market-making logic to Uniswap v4 dynamic fees, with two fee drivers (inventory deviation from equilibrium and recent volatility), the directional rule (imbalancing trades pay more, rebalancing trades pay less, volatility raises all fees) and the goal of reducing LPs' adverse-selection loss (LVR).
- **Engineering constraints.** Pinning compiler settings because the CREATE2-mined hook address depends on the bytecode; keystore-only key handling; never printing RPC URLs; spec-first development; small commits; the English-only policy (all in `CLAUDE.md`).
- **Spec review decisions** (recorded in `specs/01-design.md` §7):
  - Chose `block.number` over the agent's proposed `block.timestamp` as the fee-window key, because block producers can nudge timestamps.
  - Adopted the fee-matched static pool as the only fair comparison baseline.
  - Rejected adding a volatility-independent skew term, to keep the MVP formula minimal.
  - Accepted the placeholder parameters and kept the stored fallback fee.
  - Reviewed and approved the agent's proposals for an oracle-free reference price and per-block fee caching.
- **Review gates.** Every change to fee computation, hook permissions or anything that touches funds is shown to the author as a diff and approved before it is committed. The author also approves corrections the agent flags, such as the revised CREATE2 collision guidance in `CLAUDE.md`.

## 4. Where the Prompts Live

- **Standing instructions**: `CLAUDE.md`, the rules the agent works under in every session.
- **Design intent**: `specs/`, written and reviewed before implementation.
- **Task history**: `docs/BUILD_LOG.md`. Each entry's "Goal" is a task the author requested, followed by the outcome, the problems hit and how they were resolved.
- The prompts themselves were given interactively in Claude Code sessions and are not committed verbatim. The build log is the per-task record.

## 5. Verification

- **Tests.** Every code change must pass `forge test` before it is committed. The test count and gas figures for each change are recorded in `docs/BUILD_LOG.md`.
- **Evidence.** `CLAUDE.md` requires every conclusion the agent reports to carry `file:line` evidence. Claims about v4 behavior in the spec and in `FEEDBACK.md` cite the pinned source.
- **Numbers and rendering.** The spec's worked numbers were recomputed with a script. Mermaid diagrams and LaTeX were rendered locally before publishing.
- **Deployments.** Before an address is published, it is checked on-chain: the flag bits, the code and the getters. The Sepolia deployment is 🚧 in progress.
- **Honesty rule.** The README only marks features ✅ when they are implemented and tested. Everything else stays 🚧 or 📋.
