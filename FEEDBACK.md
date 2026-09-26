# Feedback

Developer-experience notes on the Uniswap v4 toolchain, collected while building StoikovHook at ETHGlobal Tokyo 2026. Each entry gives what happened, `file:line` evidence and a suggested fix.

Versions: `uniswapfoundation/v4-template` as generated on 2026-09-25, OpenZeppelin uniswap-hooks v1.1.0 (`e59fe72`), forge 1.5.0. Line numbers in v4-template files refer to the template as generated, which is commit `dfbe4cf` in this repository. `v4-core/src/...` line numbers refer to the v4-core revision pinned by uniswap-hooks v1.1.0.

## What Worked Well

- **The template works out of the box with custom compiler settings.** After we pinned `solc 0.8.30`, `optimizer_runs = 7777` and `bytecode_hash = "none"`, all 8 baseline tests passed on the first run (80 files compiled).
- **`foundry.lock` pins submodule revisions.** `forge install` checked out exactly the pinned revisions of forge-std, uniswap-hooks and hookmate, so installs are reproducible.
- **`BaseOverrideFee` fits a per-swap dynamic fee exactly.** Its permission set (`afterInitialize` + `beforeSwap`), built-in dynamic-fee check and non-view `_getFee` extension point match our design (`lib/uniswap-hooks/src/fee/BaseOverrideFee.sol:45,52-55,67,75-83`).
- **v4-core is readable.** Comments on the fee paths made it possible to confirm the exact semantics from source. Examples: the override is only parsed for dynamic-fee pools (`v4-core/src/libraries/Hooks.sol:263`), and the override flag is validated and stripped in `Pool.swap` (`v4-core/src/libraries/Pool.sol:303-305`).

## Pain Points

- **v4-template: `.gitignore` hides `docs/`.** The template ignores `docs/` (`.gitignore:12`), intended for `forge doc` output, so a project's own documentation under `docs/` is silently ignored. `git add docs/BUILD_LOG.md` failed with "paths are ignored".
  *Suggestion:* point `forge doc` at a dedicated output path, or ignore only the generated book (e.g. `docs/book/`).

- **v4-template: CI depends on an undefined profile.** The workflow sets `FOUNDRY_PROFILE: ci` (`.github/workflows/test.yml:9`), but `foundry.toml` defines only `[profile.default]` (`foundry.toml:1`). That is harmless today, but it lets CI's compiler configuration depend on an environment variable. For hooks this is a trap: the CREATE2-mined address depends on the exact bytecode, so any drift between CI and local builds changes the address.
  *Suggestion:* add an explicit `[profile.ci]` that inherits the default compiler settings, or drop the variable.

- **OpenZeppelin uniswap-hooks: root-relative imports break Etherscan verification.** `BaseOverrideFee.sol` imports `"src/base/BaseHook.sol"` (`lib/uniswap-hooks/src/fee/BaseOverrideFee.sol:6`). The same pattern is in `BaseDynamicFee.sol`, `BaseDynamicAfterFee.sol`, `BaseCustomAccounting.sol`, `BaseCustomCurve.sol` and `BaseAsyncSwap.sol`. `forge build` resolves these imports on its own, but:
  1. `forge verify-contract` sends a standard JSON input whose remappings do not cover them. Etherscan rejects it: `Source "src/base/BaseHook.sol" not found`. Compiling that same JSON locally with `solc --standard-json` reproduces the error.
  2. Every `forge test` run prints `error: file src/base/BaseHook.sol not found`. Build and tests still pass.

  *Reproduction:* forge 1.5.0-stable (`1c57854`), uniswap-hooks v1.1.0, template remappings unchanged. Inherit `BaseOverrideFee`, deploy, and run `forge verify-contract`.
  *Workaround:* one context-specific remapping in `remappings.txt`, `lib/uniswap-hooks/:src/=lib/uniswap-hooks/src/`. With it, StoikovHook verified on Sepolia as an exact match, and its bytecode is unchanged. It does not remove the `forge test` message. (`remappings.txt` also rejects comment lines with "invalid remapping format".)
  *Suggestion:* use package-relative imports inside uniswap-hooks (e.g. `../base/BaseHook.sol`). Until then, document the remapping in the uniswap-hooks README and add it to v4-template's `remappings.txt`.

- **v4-template: `Deployers` cannot create tokens from a forge script.** `Deployers.deployToken` mints to `address(this)` (`test/utils/Deployers.sol:39`), and `BaseScript` inherits `Deployers` (`script/base/BaseScript.sol:19`). Forge rejects any use of a script contract's own address ("Usage of `address(this)` detected in script contract"), so `deployCurrencyPair()` fails in a script at the first mint.
  *Suggestion:* pass the token recipient as a parameter, or mark the token helpers as test-only.

- **v4-template: `BaseScript.deployerAddress` is wrong in keyless dry runs.** It is set in the constructor (`script/base/BaseScript.sol:37`). There, `getDeployer()` falls back to `msg.sender` when no wallet flag is given (`script/base/BaseScript.sol:70-78`, fallback at `:76`), which in a constructor is forge's default sender `0x1804c8AB…`, not `--sender`. A dry run with only `--sender` mints to the wrong account, and the broadcaster's next `transferFrom` fails with `TRANSFER_FROM_FAILED`. With `--account` the value is correct, so the dry run and the real broadcast silently differ.
  *Reproduction:* a script that mints to `deployerAddress` and then adds liquidity, run with `--rpc-url <sepolia> --sender <address>` and no wallet flags.
  *Suggestion:* resolve the deployer inside `run()` from `msg.sender`, which forge sets to `--sender` (our workaround, `script/sepolia/DeployDemo.s.sol:48-59`), or document that `deployerAddress` needs a wallet flag.

## Documentation Gaps

- **Dynamic-fee pools start with `lpFee = 0`.** `getInitialLPFee` returns 0 for dynamic-fee pools (`v4-core/src/libraries/LPFeeLibrary.sol:51-54`). The only guidance we found is the source comment recommending `updateDynamicLPFee` in `afterInitialize` (`LPFeeLibrary.sol:48`). For hooks that only use the per-swap override, a code path that forgot `OVERRIDE_FEE_FLAG` would charge **0**. Tools that display `slot0.lpFee` also show 0 for these pools.
  *Suggestion:* call this out in the dynamic-fee guide. `BaseOverrideFee` could also optionally set a non-zero stored fallback fee in `_afterInitialize`.

- **v4-template: the unmodified example hook mines to an address that is already taken on public testnets.** This is expected behavior, not a bug. Confirmed by Dayitva (Uniswap Foundation) on the ETHGlobal Tokyo Discord. HookMiner is deterministic: the same deployer, creation code, constructor arguments and flags always give the same salt and address, so the example hook deployed as generated targets an address someone has already used. Changing any of those gives a new address. `HookMiner.find` skips candidates that already have code (`lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol:36`), but only in the chain state the script runs against.
  *Suggestion:* note in the template README that the example hook's address is already taken on public testnets, and that changing the hook, its constructor arguments or its flags gives a fresh address.

## Bugs Encountered

- **v4-template: broadcast logs for real networks are committed by default.** The `.gitignore` whitelists `/broadcast` and ignores only chain 31337, chain 5 and `dry-run/` (`.gitignore:5-9`). Chain 5 is the retired Goerli testnet. Broadcast logs from Sepolia or mainnet, with deployer addresses and full transaction data, are therefore committed to a public repository unless the developer notices.
  *Suggestion:* ignore `broadcast/` entirely, or at least update the chain IDs.

- **v4-template: `03_Swap.s.sol` sends swap output to an unreachable address.** The swap sets `receiver: address(this)` (`script/03_Swap.s.sol:32`). In a broadcast `forge script`, that is the script contract's address, which has no code on the target chain and no key holder, so on a live network the output tokens would be lost.
  *Suggestion:* send the output to the broadcasting account, e.g. `deployerAddress` from `BaseScript` (the fix we applied) or `msg.sender`.

## Suggestions

- The fixes above, in priority order: (1) broadcast ignore rule, (2) `03_Swap.s.sol` swap receiver, (3) root-relative imports in uniswap-hooks, which break Etherscan verification, (4) `docs/` ignore rule, (5) dynamic-fee `lpFee = 0` documentation, (6) `BaseScript.deployerAddress` in keyless dry runs, (7) `Deployers` token helpers in scripts, (8) a README note that the example hook's address is already taken, (9) CI profile.
