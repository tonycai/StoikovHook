# Feedback

Developer-experience notes on the Uniswap v4 toolchain, collected while building StoikovHook at ETHGlobal Tokyo 2026. Each entry states what happened, the root cause with a `file:line` reference where possible, and a suggestion. Versions: `uniswapfoundation/v4-template` at the time of generation (2026-09-25), OpenZeppelin uniswap-hooks v1.1.0 (`e59fe72`), forge 1.5.0. `v4-core/src/...` line numbers refer to the v4-core revision pinned by uniswap-hooks v1.1.0.

## What Worked Well

- **The template works out of the box with custom compiler settings.** After we pinned `solc 0.8.30`, `optimizer_runs = 7777` and `bytecode_hash = "none"`, all 8 baseline tests passed on the first run (80 files compiled).
- **`foundry.lock` pins submodule revisions.** `forge install` checked out exactly the pinned revisions of forge-std, uniswap-hooks and hookmate, so installs are reproducible.
- **`BaseOverrideFee` fits a per-swap dynamic fee exactly.** Its permission set (`afterInitialize` + `beforeSwap`), built-in dynamic-fee check and non-view `_getFee` extension point match our design (`lib/uniswap-hooks/src/fee/BaseOverrideFee.sol:45,52-55,67,75-83`).
- **v4-core is readable.** Comments on the fee paths made it possible to confirm the exact semantics from source. Examples: the override is only parsed for dynamic-fee pools (`v4-core/src/libraries/Hooks.sol:263`), and the override flag is validated and stripped in `Pool.swap` (`v4-core/src/libraries/Pool.sol:303-305`).

## Pain Points

- **v4-template: `.gitignore` hides `docs/`.** The template ignores `docs/` (intended for `forge doc` output), so a project's own documentation under `docs/` is silently ignored. `git add docs/BUILD_LOG.md` failed with "paths are ignored". `docs/` is a very common place for project docs.
  *Suggestion:* point `forge doc` at a dedicated output path, or ignore only the generated book (e.g. `docs/book/`).
- **v4-template: CI depends on an undefined profile.** `.github/workflows/test.yml` sets `FOUNDRY_PROFILE: ci`, but `foundry.toml` has no `[profile.ci]`. That is harmless today, but it makes CI's compiler configuration depend on an environment variable. For hooks this is a footgun, because the CREATE2-mined address depends on the exact bytecode, so any drift between CI and local builds changes the address.
  *Suggestion:* either add an explicit `[profile.ci]` that inherits the default compiler settings, or drop the env var.

## Documentation Gaps

- **Dynamic-fee pools start with `lpFee = 0`.** `getInitialLPFee` returns 0 for dynamic-fee pools (`v4-core/src/libraries/LPFeeLibrary.sol:51-54`). The only guidance we found is the source comment recommending `updateDynamicLPFee` in `afterInitialize` (`LPFeeLibrary.sol:48`). For hooks that only use the per-swap override, the stored fee is never read, so if any code path forgot to set `OVERRIDE_FEE_FLAG`, that swap would be charged **0**. Tools that display `slot0.lpFee` also show 0 for these pools.
  *Suggestion:* call this out in the dynamic-fee guide. `BaseOverrideFee` could also optionally set a non-zero stored fallback fee in `_afterInitialize`.

## Bugs Encountered

- **v4-template: broadcast logs for real networks are committed by default.** The `.gitignore` whitelists `/broadcast` (`!/broadcast`) and ignores only `/broadcast/*/31337/`, `/broadcast/*/5/` and `dry-run/`. Chain 5 is the deprecated Goerli testnet. Broadcast logs from Sepolia (11155111) or mainnet are therefore committed unless the developer notices. These logs contain deployer addresses and full transaction data, which is surprising in a public repo created from the template.
  *Suggestion:* ignore `broadcast/` entirely, or at least update the chain IDs.

## Suggestions

- The fixes proposed above, in priority order: (1) broadcast ignore rule, (2) `docs/` ignore rule, (3) dynamic-fee `lpFee = 0` documentation, (4) CI profile.
