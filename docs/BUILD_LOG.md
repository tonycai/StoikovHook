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

## [2026-09-25 21:46 JST] Record the spec review decisions

**Goal**: Record Tony's review decisions in `specs/01-design.md` §7 and apply them consistently across the spec.

**Result**:
- Spec status changed to "Approved 2026-09-25". §7 is now a decisions table:
  1. Parameter defaults: adopt the placeholders ($ = 0.05%, α = 1, β = 0.5, bounds 0.01%–1%) and retune after simulation.
  2. No σ-independent skew term.
  3. The fee-matched static pool is the baseline for every claim; 0.05% and 0.30% are context only.
  4. Windows are keyed by `block.number`, not `block.timestamp`.
  5. Keep the stored fallback fee of $ in `afterInitialize`.
- Decision 4 applied throughout: the window definition (§2.3), the recursions and pseudocode (§2.4), the inputs table (§2.5), the state layout (§3.1: new `bLast` `uint40` field, 248 bits total, still one slot), the update schedule (§3.3), the liveness bounds (§5.2) and the manipulation notes (§5.4). M3 now states that claims are made only against the fee-matched baseline.
- README sequence diagram: alt branches renamed to "first swap in this block" / "later swap in the same block". Both diagrams re-rendered with mermaid-cli.
- The spec's math re-validated with MathJax 3: 210 expressions, 0 errors.

**Issues**: Switching the window key to `block.number` removes the guarantee $\Delta t \ge 1$. On chains where consecutive blocks share a timestamp, $\Delta t = 0$, and the variance update would add $\Delta^2/\tau_\sigma$ with no decay. Repeated same-timestamp blocks could then push $ above the ^2$ bound that the overflow argument relies on.
Fix: Floor the elapsed time at 1 s ($\Delta t = \max(\text{now} - t_\text{last}, 1)$). Both updates stay weighted averages, so  \le \max(V_0, C^2)$ still holds. Documented in §2.4, §3.1 and §5.2.

**Next**: Ignore local files, correct the CREATE2 guidance in `CLAUDE.md`, then build the hook skeleton.

---

## [2026-09-25 21:46 JST] Ignore local files and correct the CREATE2 guidance

**Goal**: Keep `.DS_Store` and `.env.dev` out of git, and correct the "CREATE2 address taken" advice in `CLAUDE.md`.

**Result**:
- `.gitignore` now lists `.env.dev` explicitly (it was already covered by `.env*`) and `.DS_Store` under a new macOS section. `git check-ignore -v` confirms both are ignored, and the working tree has no untracked files.
- `CLAUDE.md`, Known Environment Issues: `HookMiner.find` already skips occupied addresses (`HookMiner.sol:36`). Change the bytecode only if mining fails after exhausting all `MAX_LOOP = 160,444` salts (`HookMiner.sol:14`), and after any change re-mine the address and update the deployment script. The old advice ("change `optimizer_runs`") contradicted the pinned-compiler-settings rule.

**Issues**: None.

**Next**: Build the hook skeleton.

---

## [2026-09-25 21:54 JST] README author section

**Goal**: Add an "Author" section at the end of the README, after "Built With AI".

**Result**: Added one sentence on the background relevant to this project (distributed systems, market-making infrastructure) and a contact table: X/Twitter and GitHub as links, the Discord username in code format with no link, because Discord has no public profile URL.

**Issues**: None.

**Next**: Expand the AI usage disclosure (README "Built With AI" and `AI_USAGE.md`).

---

## [2026-09-25 21:55 JST] Expand the AI usage disclosure

**Goal**: Rewrite the README "Built With AI" section and write the full `AI_USAGE.md`, stating honestly what the agent did and what the author did.

**Result**:
- README "Built With AI": the artifact table (design spec, `CLAUDE.md`, build log, commit history), the human review gates, and a link to `AI_USAGE.md`.
- `AI_USAGE.md` has 5 sections: tools used; what the AI did (scaffolding, spec drafting, implementation to spec, tests and scripts, docs, verification tooling); what the human did (concept, engineering constraints, the spec §7 decisions, review gates); where the prompts live; and verification.

**Issues**: The requested README wording said the oracle-free reference price and per-block fee caching "were made by the author, not the agent". This repository's own record (this log's "Design spec" entry and spec §2.6, §5.4) shows the agent proposed both in the spec it drafted, and the author reviewed and approved them.
Fix: Worded it as the record shows. The agent proposed; the author approved. The author's own decisions are listed explicitly: the concept, the engineering constraints, block-number windows instead of the proposed timestamps, the fee-matched baseline, no σ-independent skew term, and the parameter defaults. Flagged to Tony for confirmation.
To keep the "reviewed diff by diff before it is merged" statement true, the hook skeleton (fee override, hook permissions, swap-script receiver) is held uncommitted until Tony reviews its diff.

**Next**: Tony reviews the hook skeleton diff; after approval, commit and push it following the feature completion checklist.

---

## [2026-09-25 22:01 JST] List the author's decisions explicitly

**Goal**: Following Tony's confirmation of the "agent proposed, author approved" wording, list the author's own decisions explicitly in the README.

**Result**: README "Built With AI" now has a bulleted list of the decisions made by the author (project concept, engineering constraints, block-number fee windows, the fee-matched baseline, the parameter defaults), followed by a separate line naming the agent's proposals that the author approved (the oracle-free reference price, per-block fee caching). `AI_USAGE.md` already lists the same decisions.

**Issues**: None.

**Next**: Commit the reviewed hook skeleton, including removing the Counter example and pointing scripts 01–03 at the StoikovHook pool.

---

## [2026-09-25 22:04 JST] Hook skeleton with per-swap fee override

**Goal**: Build the minimal hook skeleton from the approved spec: `afterInitialize` + `beforeSwap` permissions (flags `0x1080`), `afterInitialize` setting the stored fee to f0, and `beforeSwap` returning a fixed fee with `OVERRIDE_FEE_FLAG`. A test must prove the pool charges the hook's fee rather than its stored fee. Also, as approved, remove the Counter example and point scripts 01–03 at the StoikovHook pool.

**Result**:
- `src/StoikovHook.sol` extends OpenZeppelin `BaseOverrideFee`. `STOIKOV_HOOK_FLAGS` (L15) is the single flag constant shared by the hook, the tests and the deploy script. `_afterInitialize` (L40–L48) rejects static-fee pools and stores `BASE_FEE` = 500 (0.05%). `_getFee` (L52–L59) returns `PLACEHOLDER_FEE` = 3000 (0.30%).
- `test/StoikovHook.t.sol` has 6 tests: flags vs. permissions vs. address bits; fallback fee stored; static-fee pool rejected (`WrappedError(NotDynamicFee)`); `Swap` event `fee` = 3000 in both directions while the stored fee stays 500; a fuzz test (1,000 runs) showing deltas identical to a hookless 0.30% pool and strictly lower output than a 0.05% pool; direct callback calls revert with `NotPoolManager`.
- `forge test`: **12 passed / 0 failed** (6 StoikovHook + 6 EasyPosm; the 2 Counter tests were removed with the example).
- Gas: `test_swap_chargesOverrideFeeInBothDirections` 216,367; fuzz μ 281,542. The hook adds **≈ 2,093 gas** per warm swap (42,707 vs. 40,614 for an identical hookless 0.30% pool, measured with a throwaway probe test).
- Local deployment (anvil, `--unlocked`, no private key): hook at `0x76747994699d9690222a973320c373bf7f931080`, low 14 bits `0x1080`, salt `0x…77ac` (the 30,636th candidate), runtime code 3,867 bytes. Getters verified on-chain: `HOOK_FLAGS` = 4224 (`0x1080`), `BASE_FEE` = 500, `PLACEHOLDER_FEE` = 3000.
- Scripts: `00_DeployHook` deploys StoikovHook, documents the `--gas-limit 100000000000 --disable-block-gas-limit` command and logs the address. `01`, `02` and `03` use `DYNAMIC_FEE_FLAG` with `hookContract` and refuse to run while it is unset. `02` was updated too, because it must target the same pool key as `01`. `03` now sends swap output to `deployerAddress`. Scripts 01–03 are compile-checked only; they will be run end to end with the Sepolia deployment.
- Removed `src/Counter.sol` and `test/Counter.t.sol`.
- README: a "Hook skeleton" row marked ✅ in Core Features, Repository Guide line numbers filled in, Getting Started updated (test count, local deploy command). FEEDBACK: 2 new entries.

**Issues**:
1. Tests and scripts could not read `StoikovHook.HOOK_FLAGS` through the contract type name (solc error 9582), and they need the flags before the hook exists.
   Fix: a file-level constant `STOIKOV_HOOK_FLAGS` that all three import. The contract's public `HOOK_FLAGS` is derived from it.
2. Every `forge test` run prints `error: file src/base/BaseHook.sol not found`, caused by the lib-root-relative import in `BaseOverrideFee.sol:6`. The build and all tests succeed, and the bytecode is unaffected. A context remapping did not help and was reverted. Left as is by Tony's decision and logged in FEEDBACK.md.
3. The template's `03_Swap.s.sol` sent swap output to `address(this)`, which is unreachable in a broadcast. Fixed and logged in FEEDBACK.md.
4. The test's placeholder fee (3000) must differ from the stored fee (500); otherwise the test could not tell the override apart from the fallback.
5. Without the gas flags, the deployment simulation also succeeded for this bytecode. The flags stay in the documented command, because the salt position changes whenever the bytecode does.
6. Review gate: the skeleton touches fee handling, hook permissions and the swap receiver, so it was held uncommitted until Tony approved the diff.

**Next**: Core fee logic: σ_h, q̂, their combination with the clamp, and per-block caching.

---

## [2026-09-25 22:04 JST] End of day 1 (2026-09-25)

**Goal**: Wrap up day 1: list what was done, record the current state, and set tomorrow's first priority and the environment to restore.

**Result**: Tasks completed today, in order:
1. `6aee28d` Bootstrap from v4-template: pinned compiler settings, fixed the template's `.gitignore` and CI profile, baseline tests passing.
2. `793df02` Build log set up and backfilled.
3. `7f27177` Design spec `specs/01-design.md` (fee model, state, callbacks, security, scope).
4. `65d0425` `CLAUDE.md` and a 12-section README skeleton with 2 Mermaid diagrams.
5. `ee57db0` Feature completion workflow in `CLAUDE.md`.
6. `8af5950` Fee-matched static baseline added to the scenario spec.
7. `fd4cdeb` README Goals / Non-Goals, `docs/DEMO_SCRIPT.md`, first FEEDBACK entries.
8. `f5099db` GitHub description (93 characters) and 9 topics; README and spec rendering verified.
9. `ab8234b` ETHGlobal Tokyo banner in the README.
10. `469b64e` English-only language policy; 3 files translated.
11. `92fe722` Spec approved; review decisions in §7; block-number windows with Δt floored at 1 s.
12. `d5b0bcc` `.DS_Store` and `.env.dev` ignored; CREATE2 collision guidance corrected.
13. `5df81dd` README Author section.
14. `5512840` AI usage disclosure (README and `AI_USAGE.md`).
15. `0742381` Author's decisions listed explicitly.
16. `a5d3206` StoikovHook skeleton (reviewed diff), Counter example removed, scripts 01–03 pointed at the StoikovHook pool, 2 FEEDBACK entries.

Current state:
- `forge test`: **12 passed / 0 failed** (6 StoikovHook, including a 1,000-run fuzz test; 6 EasyPosm helper tests).
- Hook address flags: `0x1080` (`afterInitialize` | `beforeSwap`), verified on a local anvil deployment at `0x76747994699d9690222a973320c373bf7f931080`. No Sepolia deployment yet.
- Gas: the skeleton adds ≈ 2,093 gas per warm swap compared with an identical hookless pool. It currently charges a fixed 0.30% placeholder fee.

**Issues**: None open. The known `forge test` diagnostic (`src/base/BaseHook.sol not found`) is harmless and logged in FEEDBACK.md.

**Next**:
- First priority tomorrow: the core fee logic from spec §2, replacing the placeholder:
  - σ_h: EWMA tick-volatility estimate updated per block-number window, with Δt = max(now − tLast, 1).
  - q̂: displacement of the window-open tick from its slow EMA reference, clamped to [−1, 1].
  - f(direction) = clamp(f0 + σ_h × (α ± β·q̂), fmin, fmax).
  - Computed once per block and cached in the single-slot state.
  - OpenZeppelin `Math` for sqrt/mulDiv; no hand-written ln/exp (the spec needs none).
  - A fuzz test that fees always stay within [fmin, fmax], and gas measured against today's ≈ 2,093 baseline.
  - The fee logic diff goes to Tony for review before it is committed.
- Environment to restore before starting: `forge install` if the clone is fresh, then an anvil Sepolia fork with `--block-time 1` (`anvil --fork-url "$SEPOLIA_RPC_URL" --block-time 1`, with the RPC URL coming from the local environment and never printed). Check that `forge test` is green before writing code.

---

## [2026-09-26 10:32 JST] Volatility and inventory fee model

**Goal**: Replace the placeholder `_getFee` with the approved fee model (spec §2): σ_h from block-to-block tick changes, q̂ from the displacement against a slow EMA of the pool's own price, f = clamp(f0 + σ_h·(α ± β·q̂), fmin, fmax), computed once per block. Use a public fixed-point library, with no hand-written ln/exp.

**Result**:
- `src/StoikovHook.sol`: `_getFee` (L200–L219) opens a fee window on a block's first swap and returns the cached fee for the swap's direction. `_openWindow` (L222–L254) updates the EWMA variance and the EMA reference, with elapsed time floored at 1 s. `_computeFees` (L260–L286) implements the formula. The parameters are constructor arguments (`FeeParams`, defaults with their rationale at L48–L69), validated at deploy time (L290–L299, including β ≤ α). Also new: read-only `previewFees` and `getPoolState`.
- Math: Solady v0.1.26 (`acd959a`), a new pinned dependency with remapping `solady/=lib/solady/src/`. It provides `sqrt`, `mulWad`, `mulDiv`, `abs`, `min`, `clamp` and `zeroFloorSub`. The spec's formulas need no ln/exp.
- "Window length": the fee window is one block (spec §7). The configurable estimator memory is `volTau` = 300 s (about 25 blocks), with its rationale in the code.
- `forge test`: **41 passed / 0 failed**. 35 are StoikovHook tests (14 integration, 17 fee-math, 4 gas) and 6 are EasyPosm tests. Fuzz: fees within [fmin, fmax] and ≥ f0 for any input (5,000 runs), any valid parameters (1,000 runs), any pool state and timestamps (5,000 runs), and random multi-block swap sequences (1,000 runs).
- Exact fee checks with the defaults: 846/846 at q̂ = 0, 933/759 at q̂ = ±0.5, 1019/673 at full skew, 1192 at 4× variance. The β = α boundary puts the rebalancing side exactly on f0 = 500.
- Gas, as extra gas over an identical hookless swap. The skeleton baseline was 2,093 warm.
  - Cached path: **3,678 warm** / 5,678 cold (budget ≤ 5,000, warm).
  - Window-open path: **14,905 warm** / 16,905 cold (budget ≤ 25,000, warm).
  - For reference, the hookless swap uses 40,120 warm / 48,120 cold.
- Runtime size: 9,738 bytes (limit 24,576).
- Mutation checks on the 41-test suite: flipping the skew sign fails 10 tests (9 of 40 before the β = α boundary test); removing the per-block cache fails 7 and reproduces the spec §5.4 attack (6,301 → 4,933 pips). Recorded in the README Security section.
- Spec: A8 now defines the gas budgets on the warm measurement (Tony's decision); the §4.4 event field is renamed `sigmaHPips`. README: Core Features and Goals G3/G4 marked ✅, new Security and Gas sections, Repository Guide line numbers updated.

**Issues**:
1. The cold measurement shows only about 2,000 gas over warm, which matches one cold read of the hook's state slot. It does not include the roughly 2,500-gas cold-account surcharge that the `vm.cool` documentation suggests should appear. The cause was not investigated; the cold figures are reported as a lower bound.
2. The cold cached path (5,678) is above 5,000. Tony's decision: budgets apply to the warm measurement, consistent with the 2,093 baseline. The cap stays at 5,000, and both figures are published.
3. No new Uniswap toolchain issues, so FEEDBACK.md is unchanged.

**Next**: The comparison simulation (M3): trend and mean-reversion price paths, arbitrage and noise flow, StoikovHook vs. a fee-matched static pool (plus 0.05% and 0.30% for reference), at least 20 seeds, results in `docs/simulation/`.

---
