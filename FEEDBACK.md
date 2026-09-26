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

- **OpenZeppelin uniswap-hooks' root-relative imports break Etherscan verification, and `forge test` reports them as missing.** OZ `BaseOverrideFee.sol` imports its base contract lib-root-relative: `import {BaseHook} from "src/base/BaseHook.sol";` (`lib/uniswap-hooks/src/fee/BaseOverrideFee.sol:6`; the same pattern appears in `BaseDynamicFee.sol`, `BaseDynamicAfterFee.sol`, `BaseCustomAccounting.sol`, `BaseCustomCurve.sol` and `BaseAsyncSwap.sol`). `forge build` resolves these imports on its own, so the hook compiles. Two things still break:
  1. Every `forge test` run prints `error: file src/base/BaseHook.sol not found`, pointing at that line. Build and tests are unaffected (41/41 pass in this repo).
  2. **Source verification fails.** `forge verify-contract` sends a standard JSON input whose remappings do not cover these imports, and Etherscan rejects it: `Fail - Unable to verify. Solidity Compilation Error: Source "src/base/BaseHook.sol" not found`. Compiling that same standard JSON locally with solc 0.8.30 (`forge verify-contract … --show-standard-json-input`, then `solc --standard-json`) reproduces the error exactly.

  *Reproduction:* forge 1.5.0-stable (`1c57854`), uniswap-hooks v1.1.0 (`e59fe72`), template remappings unchanged. Add a contract that inherits `@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol`, then run `forge test`, or deploy it and run `forge verify-contract`.
  *Fix for verification:* one context-specific remapping in `remappings.txt`, `lib/uniswap-hooks/:src/=lib/uniswap-hooks/src/`, which applies only to imports inside that library. With it, StoikovHook verified on Sepolia as an exact match. Its creation and runtime bytecode are identical with and without the remapping, under both of our Foundry profiles, and the bytecode on chain is identical to the local build.
  *Correction:* we first tried this same remapping to silence the `forge test` message. It had no effect on the message, so we reverted it and called the issue cosmetic. That was wrong: the remapping is required for verification, and it is now committed. The `forge test` message remains. (While trying, we also found that `remappings.txt` rejects comment lines with "invalid remapping format".)
  *Suggestion:* use package-relative imports inside uniswap-hooks (e.g. `../base/BaseHook.sol`). Until then, document the remapping above in the uniswap-hooks README and in v4-template's `remappings.txt`, since every hook built on these base contracts will hit the verification failure.

- **v4-template: `Deployers` cannot create tokens from a forge script.** `Deployers.deployToken` mints to `address(this)` (`test/utils/Deployers.sol:39`). Forge rejects any use of a script contract's own address ("Usage of `address(this)` detected in script contract"), and `BaseScript` inherits `Deployers` (`script/base/BaseScript.sol:19`), so calling `deployCurrencyPair()` from a script fails at the first mint. We hit this building the comparison simulation and worked around it with dedicated participant contracts that receive the tokens.
  *Suggestion:* pass the token recipient as a parameter, or mark the token helpers as test-only.

- **v4-template: `BaseScript.deployerAddress` is wrong in keyless dry runs.** It is resolved in the constructor (`script/base/BaseScript.sol:38`). There, `getDeployer()` falls back to `msg.sender` when no wallet flag is given (`:75-81`), and in a script's constructor that is forge's default sender `0x1804c8AB…`, not `--sender`. A dry run with only `--sender` (no key) therefore mints and sends tokens to the wrong account, and the next `transferFrom` from the real broadcaster fails with `TRANSFER_FROM_FAILED`. With `--account` the value is correct, so the dry run and the real broadcast silently differ.
  *Reproduction:* a script that mints to `deployerAddress` and then adds liquidity, run with `--rpc-url <sepolia> --sender <address>` and no wallet flags.
  *Workaround:* read the broadcaster from `msg.sender` inside `run()`, which forge sets to `--sender`, and call `vm.startBroadcast(broadcaster)` (see `script/sepolia/DeployDemo.s.sol`).
  *Suggestion:* resolve the deployer inside `run()`, or document that `deployerAddress` requires a wallet flag.

## Documentation Gaps

- **Dynamic-fee pools start with `lpFee = 0`.** `getInitialLPFee` returns 0 for dynamic-fee pools (`v4-core/src/libraries/LPFeeLibrary.sol:51-54`). The only guidance we found is the source comment recommending `updateDynamicLPFee` in `afterInitialize` (`LPFeeLibrary.sol:48`). For hooks that only use the per-swap override, the stored fee is never read, so if any code path forgot to set `OVERRIDE_FEE_FLAG`, that swap would be charged **0**. Tools that display `slot0.lpFee` also show 0 for these pools.
  *Suggestion:* call this out in the dynamic-fee guide. `BaseOverrideFee` could also optionally set a non-zero stored fallback fee in `_afterInitialize`.

## Bugs Encountered

- **v4-template: broadcast logs for real networks are committed by default.** The `.gitignore` whitelists `/broadcast` (`!/broadcast`) and ignores only `/broadcast/*/31337/`, `/broadcast/*/5/` and `dry-run/`. Chain 5 is the deprecated Goerli testnet. Broadcast logs from Sepolia (11155111) or mainnet are therefore committed unless the developer notices. These logs contain deployer addresses and full transaction data, which is surprising in a public repo created from the template.
  *Suggestion:* ignore `broadcast/` entirely, or at least update the chain IDs.

- **v4-template: `03_Swap.s.sol` sends swap output to an unreachable address.** The swap sets `receiver: address(this)`. In a broadcast `forge script`, `address(this)` is the script contract's address, which has no code on the target chain and no key holder. On a live network the output tokens would be unrecoverable.
  *Suggestion:* send the output to the broadcasting account, e.g. `deployerAddress` from `BaseScript` (the fix we applied), or `msg.sender`.

## Suggestions

- The fixes proposed above, in priority order: (1) broadcast ignore rule, (2) `03_Swap.s.sol` swap receiver, (3) root-relative imports in uniswap-hooks, which break Etherscan verification, (4) `docs/` ignore rule, (5) dynamic-fee `lpFee = 0` documentation, (6) `BaseScript.deployerAddress` in keyless dry runs, (7) `Deployers` token helpers in scripts, (8) CI profile.
