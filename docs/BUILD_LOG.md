# StoikovHook Build Log
ETHGlobal Tokyo 2026 — hacking started 2026-09-25 21:00 JST

## [2026-09-25 21:03 JST] Create the repository from v4-template

**Goal**: Create a public repository from the `uniswapfoundation/v4-template` template and clone it locally.

**Result**:
- Repository: https://github.com/tonycai/StoikovHook (public, created on GitHub at 12:03:53 UTC)
- Command: `gh repo create tonycai/StoikovHook --template uniswapfoundation/v4-template --public --clone`
- Initial commit from the template: `dfbe4cf Initial commit`

**Issues**: After cloning, `lib/forge-std`, `lib/hookmate` and `lib/uniswap-hooks` were empty directories.
Root cause: `--clone` runs a plain `git clone` without `--recurse-submodules`, so the submodules were not checked out.
Fix: Run `forge install`. It checks out the submodules listed in `.gitmodules` recursively, at the revisions pinned in `foundry.lock` (see "Install dependencies and pass the baseline tests" below).

**Next**: Scaffolding (`.gitignore`, `foundry.toml`, directory layout and doc skeletons).

---

## [2026-09-25 21:06 JST] Scaffolding

**Goal**: Fix `.gitignore`, pin the compiler settings (the CREATE2-mined hook address depends on the bytecode), and create `specs/` and the doc skeletons.

**Result**:
- `.gitignore` covers `.env*`, `cache/`, `broadcast/` and `out/`, verified with `git check-ignore -v`.
- `foundry.toml` pins the compiler settings. `forge config` confirms the effective values: `solc = "0.8.30"`, `auto_detect_solc = false`, `evm_version = "cancun"`, `optimizer = true`, `optimizer_runs = 7777`, `via_ir = false`, `bytecode_hash = "none"`.
- Added `specs/` (with `.gitkeep`), `AI_USAGE.md` and `FEEDBACK.md` (headings only).
- Added "Built at ETHGlobal Tokyo 2026" as the first line of `README.md`.

**Issues**:
1. The template's `.gitignore` whitelists `/broadcast` (`!/broadcast`) and ignores only `/broadcast/*/31337/`, `/broadcast/*/5/` and `dry-run/`.
   Root cause: The template dates from the Goerli era and only excludes the local chain and Goerli. Broadcast logs for Sepolia (11155111) and mainnet would be committed to a public repository.
   Fix: Ignore `broadcast/` entirely.
2. The template CI (`.github/workflows/test.yml`) sets `FOUNDRY_PROFILE: ci`, but `foundry.toml` has no `[profile.ci]`.
   Root cause: CI's compiler configuration depends on an environment variable. If someone later adds a `[profile.ci]`, CI would produce different bytecode from local builds.
   Fix: Removed the env var.
3. Note: `FOUNDRY_*` environment variables can still override `foundry.toml` at runtime, and the config file cannot prevent that. Confirmed that no `FOUNDRY_*` or `DAPP_*` variables are set on this machine.
4. Note: `.env*` also ignores `.env.example`. If we ever need to commit one, add `!.env.example`.

Issues 1 and 2 are v4-template problems, to be written up in FEEDBACK.md.

**Next**: Install dependencies, run the baseline tests and make the first commit.

---

## [2026-09-25 21:06 JST] Install dependencies and pass the baseline tests

**Goal**: Install dependencies, confirm that the template's own tests pass under the pinned compiler settings, and make the first commit.

**Result**:
- Toolchain: forge 1.5.0-stable (`1c57854`), solc 0.8.30
- Dependencies (pinned by `foundry.lock`): forge-std v1.10.0 (`8bbcf6e`), uniswap-hooks v1.1.0 (`e59fe72`), hookmate (`33408fb`)
- `forge build`: 80 files compiled successfully
- `forge test` (21:05): **8 passed / 0 failed / 0 skipped**
  - `CounterTest`: `testCounterHooks` 183,563 gas, `testLiquidityHooks` 167,640 gas
  - `EasyPosmTest`: all 6 passed (`test_mintLiquidity` 429,042 gas, `test_increaseLiquidity` 490,783 gas, and others)
- Commit: `6aee28d chore: bootstrap from v4-template` (local only, not yet pushed)

**Issues**: `forge install` took about 67 seconds, because uniswap-hooks nests several layers of submodules (v4-core, v4-periphery, openzeppelin-contracts, solmate, permit2 and others). This is expected, not a fault.

**Next**: Write the design spec `specs/01-design.md` (dynamic fee model). Implementation starts only after Tony approves it.

---

## [2026-09-25 21:17 JST] Set up the build log

**Goal**: Create `docs/BUILD_LOG.md` as the main development log and backfill the work done since hacking started.

**Result**: Created `docs/BUILD_LOG.md` with 3 backfilled entries (repository creation, scaffolding, baseline tests). From now on, one entry is appended per completed task. Entries are timestamped in JST to the minute and never contain RPC URLs, private keys or other secrets.

**Issues**: `git add docs/BUILD_LOG.md` was refused because the path is ignored.
Root cause: The v4-template `.gitignore` contains `docs/`. It is meant for `forge doc` output, but it blocks the whole `docs/` directory.
Fix: Removed `docs/` from `.gitignore` and confirmed with `git check-ignore` that `docs/BUILD_LOG.md` can be tracked.
Note: If we ever run `forge doc`, point its output outside `docs/`, or the generated files will mix with our own docs. This is another template issue for FEEDBACK.md.

**Next**: Finish `specs/01-design.md`, then write `CLAUDE.md` and the README skeleton.

---

## [2026-09-25 21:26 JST] Design spec: dynamic fee model

**Goal**: Write `specs/01-design.md` for Uniswap Foundation engineers. It fixes the fee formula, on-chain state, callbacks, security constraints and MVP scope, and contains no implementation code.

**Result**:
- `specs/01-design.md` (373 lines) has 7 sections: problem statement, fee model, on-chain state, callbacks and permissions, security constraints, scope (5 MVP deliverables, acceptance criteria A1–A10, stretch goals S1–S6), and open questions for review.
- The fee formula follows the GLFT structure (the stationary T→∞ solution of A–S): $f(s) = \mathrm{clamp}(f_0 + \sigma_h(\alpha + \beta s \hat q), f_{\min}, f_{\max})$, split by direction into $f_\uparrow$ and $f_\downarrow$.
- The only inputs are the pool's own `slot0.tick` and `block.timestamp`. No oracle.
- Per-pool state packs into one slot (208 bits). Each timestamp window is updated only on its first swap; later swaps read the cache.
- Callbacks are `afterInitialize` + `beforeSwap`, so the hook address flags are `0x1080`. The fee is overridden per swap through `OVERRIDE_FEE_FLAG`.
- Every claim about v4 interfaces cites `file:line`. The worked numbers (fee table, decay time after a volatility shock, bit-width bounds) were recomputed with a script.

**Issues**:
1. Dynamic-fee pools start with `slot0.lpFee = 0` (`LPFeeLibrary.sol:51-54`). If the hook ever failed to return an override fee, that swap would pay zero fee.
   Fix: The spec requires calling `updateDynamicLPFee(key, f0)` in `afterInitialize` as a fallback, which the library comment at `LPFeeLibrary.sol:48` also recommends. Recorded as a v4 interface pitfall for FEEDBACK.md.
2. If the inventory skew were computed from live per-swap state, a single transaction could make a small opposite-direction trade across the reference price and then trade large at the discounted rate.
   Fix: Fees are snapshotted per timestamp window and stay fixed within it. The residual cross-block risk is documented in §5.4 and addressed by S1.
3. With τ_R = 900, an EMA reference stored as an integer tick would never move for displacements under 901 ticks, because integer division truncates the update to 0.
   Fix: The spec stores the reference as fixed point with 16 fractional bits.

**Next**: Tony reviews the spec (§7 lists 5 open questions). Meanwhile, write `CLAUDE.md` and the README skeleton.

---

## [2026-09-25 21:30 JST] CLAUDE.md and README skeleton

**Goal**: Write the AI collaboration rules in `CLAUDE.md` and a judge-facing README skeleton with 12 sections.

**Result**:
- `CLAUDE.md`: project context, tech stack, hard constraints (pinned compiler settings, permissions matching the HookMiner flags, keystore only, never print RPC URLs, no `--resume` against live networks), known environment issues, and working agreements.
- `README.md` rewritten from scratch, replacing the template content. Sections in order: title and tagline, Problem, Solution, Architecture (2 Mermaid diagrams), Core Features, How It Works, Tech Stack, Repository Guide (placeholder table), Getting Started, Deployed Contracts (placeholder), Demo (placeholder), Built With AI.
- Every unimplemented item is marked "🚧 In progress", and a "Project status: design phase" callout sits at the top.
- Both Mermaid diagrams were verified by rendering them locally with mermaid-cli 11.17.0 (a component flowchart and a 12-step sequence diagram).

**Issues**: The first version of the component diagram used `flowchart LR` with PoolManager drawn as a subgraph. The `beforeSwap()` label on an edge leaving the subgraph border was half hidden behind a node.
Root cause: Labels on edges that start at a subgraph border are placed inside the subgraph.
Fix: Switched to `flowchart TB`. PoolManager and Pool are now ordinary nodes inside a "Uniswap v4 core" subgraph, and StoikovHook and its state sit in a second subgraph. After re-rendering, every label is fully visible.
The sequence-diagram messages also avoid `;` and `|` (Mermaid treats `;` as a statement separator), so the return value is written as "fee + OVERRIDE_FEE_FLAG".

**Next**: Add the feature completion workflow to `CLAUDE.md`.

---

## [2026-09-25 21:30 JST] Define the feature completion workflow

**Goal**: Define the wrap-up steps for every completed feature under "Working Agreements" in `CLAUDE.md`.

**Result**: `CLAUDE.md` gained 3 subsections:
- Feature completion checklist: update the README (Core Features status, Repository Guide line numbers, Mermaid diagrams), append to BUILD_LOG, log issues in FEEDBACK.md, then commit and push to main.
- Branching: single maintainer, commit directly to main.
- Commit discipline: one feature per commit; check for `.env*`, `cache/` and `broadcast/` before committing.

**Issues**: None.

**Next**: Flesh out Goals, Core Features and Non-Goals in the README, and write `docs/DEMO_SCRIPT.md`.

---

## [2026-09-25 21:35 JST] README goals and scope, demo script, first FEEDBACK entries

**Goal**: Flesh out Goals, Core Features and Non-Goals in the README; create `docs/DEMO_SCRIPT.md` (video script, live judging flow, Q&A prep); update FEEDBACK.md and push, following the CLAUDE.md workflow.

**Result**:
- README:
  - Added Goals (G1–G4). Each has a verification method, and all are 📋 Planned.
  - Converted Core Features to a table with ✅ / 🚧 / 📋 statuses. Only scaffolding is ✅. The 5 fee-related features are 🚧 (spec drafted, code not started). Tests, the comparison simulation and the Sepolia deployment are 📋.
  - Added Non-Goals (6 items).
- `docs/DEMO_SCRIPT.md`: a 5-segment video script (3:30 total), a 4-minute live flow that leads with conclusions, Q&A prep with 6 required questions and 5 likely follow-ups, and a list of 17 values to fill in.
- `FEEDBACK.md`: first 5 entries (3 v4-template issues, 1 v4 interface note, 1 prioritized list of suggestions), plus 4 things that worked well.
- Spec update (separate commit `8af5950`): M3 adds a fee-matched static baseline, and A9 now covers 4 pools.

**Issues**: G1 was first drafted as "LP terminal value beats the static 0.05% and 0.30% pools".
Root cause: The simulated uninformed flow is scripted and does not react to fees. Under that setup a higher static fee always favors LPs, so beating 0.30% would mostly reflect the average fee level and say nothing about the model.
Fix: The primary comparison is now a static pool that charges uninformed traders the same average fee, which isolates the effect of the fee's *shape*. The 0.05% and 0.30% pools are reported alongside for reference. Synced to spec M3/A9, pending Tony's review.

**Next**: Push. Then set the GitHub description and topics, and check how the README (including Mermaid) renders on GitHub.

---

## [2026-09-25 21:37 JST] GitHub repository metadata and render check

**Goal**: Push local commits, set the repository description and topics, and confirm that the README (especially the Mermaid diagrams) renders correctly on GitHub.

**Result**:
- Push: 7 commits `dfbe4cf..fd4cdeb` to `origin/main`. Confirmed beforehand that no `.env*`, `cache/`, `broadcast/` or `out/` paths are tracked.
- Description (93 characters): "Uniswap v4 hook using the Avellaneda-Stoikov model for dynamic fees that protect LPs from LVR"
- Topics (9): avellaneda-stoikov, defi, dynamic-fees, ethglobal, foundry, market-making, solidity, uniswap-hooks, uniswap-v4
- README on GitHub: both Mermaid diagrams render with no "Unable to render" error, and screenshots confirm both are complete with readable labels. The NOTE callout and all 4 tables render correctly, and no raw ```mermaid source is left on the page.
- `specs/01-design.md`: GitHub detects 199 math expressions. Compiling each one locally with MathJax 3 (the engine GitHub uses) gives 199/199 without errors, 7 of them display equations.

**Issues**: The automated browser tab ran in the background (`document.visibilityState = "hidden"`), so GitHub's `<math-renderer>` never ran and screenshots showed raw `$...$`.
Root cause: GitHub renders math only once the page is visible. Mermaid renders inside an iframe and is unaffected.
Fix: Confirmed in the DOM that all 199 expressions are recognized as math, then compiled each one locally with `mathjax-full@3` with errors set to throw. No syntax errors. The README itself contains no math.

**Next**: Add the banner image `docs/ethglobal-tokyo-2026.png` to the top of the README.

---

## [2026-09-25 21:38 JST] README banner

**Goal**: Place `docs/ethglobal-tokyo-2026.png` as a banner above the README title.

**Result**:
- Image: PNG, 1920×1080, 8-bit RGB, no alpha channel, 347,188 bytes (under 1 MB, so no compression needed).
- `git check-ignore -v` prints nothing (exit 1), so the image is not ignored.
- Inserted `<p align="center"><img src="docs/ethglobal-tokyo-2026.png" … width="100%"></p>` as README lines 1–3, using a relative path.
- Checked the image visually: it is the ETHGlobal Tokyo event banner (September 25–27, 2026).

**Issues**: An untracked `.DS_Store` (macOS Finder metadata) appeared in the working tree, and `.gitignore` had a change this task did not make (a new `.env.dev` line, already covered by `.env*`). Following the commit discipline, only this task's files were staged, and neither item was committed. Left for Tony to decide.

**Next**: After pushing, confirm in the browser that the banner displays on GitHub.

---

## [2026-09-25 21:45 JST] Adopt an English-only language policy

**Goal**: Add a Language Policy to the top of `CLAUDE.md` requiring all repository content to be written in idiomatic English, then rewrite every Chinese passage already in the repository.

**Result**:
- "Language Policy" is now the first section of `CLAUDE.md`. It covers docs, comments and NatSpec, commit messages, identifiers, revert messages, test names and the demo script.
- A scan of all tracked and untracked non-ignored files outside `lib/` for CJK characters found Chinese in 3 files: `CLAUDE.md` (55 lines), `docs/BUILD_LOG.md` (121 lines) and `docs/DEMO_SCRIPT.md` (151 lines). All commit messages were already in English.
- Rewrote all three in English. A re-scan finds 0 lines with CJK characters.
- `docs/BUILD_LOG.md`: earlier entries were translated in place with every timestamp, commit hash and number unchanged. The field labels are now Goal / Result / Issues / Next.
- Follow-up from the previous entry: the README banner loads on GitHub at its natural 1920×1080 size and renders full width above the title.

**Issues**: The build log is append-only, but the new policy required translating its existing entries.
Fix: Translated in place without changing any facts, timestamps or numbers. This is the only rewrite of past entries.

**Next**: Record the spec review decisions in `specs/01-design.md` §7, then start the hook skeleton.

---
