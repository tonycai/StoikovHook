# CLAUDE.md — StoikovHook

Collaboration rules for every Claude Code session in this repository. Read this file in full before starting work.

## Language Policy

**Everything committed to this repository is written in English.** It must read as natural technical English written by a native speaker, not as a translation from Chinese. This is a global hackathon, and the judges and sponsors read English.

Scope:
- `README.md` and every document under `specs/` and `docs/`
- `CLAUDE.md`, `AI_USAGE.md`, `FEEDBACK.md`
- Code comments and NatSpec
- Git commit messages
- Identifiers: variable, function, event and error names, and revert messages
- Test names and assertion messages
- The demo script, `docs/DEMO_SCRIPT.md`

Style:
- Write the way a native speaker would, and avoid sentence structures carried over from Chinese.
- Use standard industry terms: adverse selection, inventory skew, LVR, tick, liquidity provider (LP).
- Keep sentences short and direct. Avoid long chains of subordinate clauses.
- No machine-translation tone.

Conversations with Tony may be in Chinese. Anything that lands in the repository must be in English.

## Project Context

StoikovHook is a Uniswap v4 hook that sets dynamic swap fees using the Avellaneda–Stoikov market-making model. It is an ETHGlobal Tokyo 2026 entry in the Building from Scratch track, targeting the Uniswap Foundation "Best Uniswap Stack Contribution" prize.

**Submitted on 2026-09-26 at 15:15 JST. The contract code (`src/`), deployment scripts (`script/`) and tests (`test/`) are frozen: do not modify them. Only documentation may change.**

The design spec is `specs/01-design.md`. The implementation must follow it and must not start until Tony has approved the spec.

## Tech Stack

Solidity (version pinned in `foundry.toml`), Foundry, Uniswap v4-core / v4-periphery, hookmate (address constants), and a local anvil fork of Sepolia.

## Hard Constraints

- Compiler settings are pinned in `foundry.toml` and must not depend on environment variables. The CREATE2-mined hook address is derived from the bytecode, so any change to the compiler settings invalidates it.
- `foundry.toml` has one extra profile, `sim`, which runs only the comparison simulation (`FOUNDRY_PROFILE=sim forge test -vv`). It may change test selection and file permissions only; it must never override a compiler setting. After touching `foundry.toml`, check that `forge inspect src/StoikovHook.sol:StoikovHook bytecode` is identical under both profiles.
- The permissions returned by `getHookPermissions()` must exactly match the flags passed to HookMiner. If you change one, update the other and re-mine the address.
- Never use `address(this)` in scripts, because forge rejects it when broadcasting. Use a deployer address variable instead.
- Use private keys only through a Foundry keystore (`--account`). Never put them on the command line, in `.env`, or in any file.
- Never print the actual value of an RPC URL.
- Never use `--resume` to replay broadcast records against a live network.
- The repository is public. Before committing, confirm that `.gitignore` covers `.env*`, `cache/`, `broadcast/` and `out/`.

## Known Environment Issues

- **HookMiner runs out of gas while mining.** Run the deployment script with `--gas-limit 100000000000 --disable-block-gas-limit`.
- **An idle anvil falls behind on timestamps, and swaps revert with `DeadlinePassed`.** Start anvil with `--block-time 1`.
- **In a keyless dry run, `BaseScript.deployerAddress` is forge's default sender, not `--sender`.** It is resolved in the constructor. Take the broadcaster from `msg.sender` inside `run()` and call `vm.startBroadcast(broadcaster)`, as `script/sepolia/DeployDemo.s.sol` does.
- **Etherscan verification fails with `Source "src/base/BaseHook.sol" not found`.** OZ uniswap-hooks imports its own files by root-relative paths (`lib/uniswap-hooks/src/fee/BaseOverrideFee.sol:6`), which the standard JSON input does not cover. Keep the context remapping `lib/uniswap-hooks/:src/=lib/uniswap-hooks/src/` in `remappings.txt`; it does not change the hook's bytecode. The similar `error: file src/base/BaseHook.sol not found` printed by `forge test` is harmless and is not fixed by it.
- **The CREATE2 candidate address is already taken.** `HookMiner.find` already skips addresses that have code and moves on to the next salt (`lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol:36`), so a collision alone is not a reason to act. Consider changing the bytecode only if mining still fails after all candidates are exhausted (`HookMiner.find` gives up after `MAX_LOOP = 160,444` salts, `HookMiner.sol:14`). After any bytecode change, re-mine the address and update the deployment script.

## Working Agreements

- Commit every working intermediate state immediately. Do not batch work into large commits, because judges review the git history.
- For changes to fee calculation, the state machine or fund safety, show Tony the diff and get approval before committing.
- After every task, append an entry to `docs/BUILD_LOG.md`.
- Whenever you hit a Uniswap toolchain issue, log it in `FEEDBACK.md` right away. This is a hard submission requirement for the Uniswap track.
- Back every conclusion with `file:line` evidence. Make no unsupported claims.

### Feature Completion Checklist

When a feature reaches a working state (its tests pass), run these four steps in order. Do not skip any of them.

1. **Update `README.md`**
   - Core Features: mark the feature ✅ Done and remove its 🚧 marker.
   - Repository Guide: add the contract path and key line range for the feature, formatted as `src/StoikovHook.sol:L120-L145 — main fee calculation`. This is a hard requirement for the Uniswap track, because judges use it to verify the integration.
   - If the architecture changed, update the Mermaid diagrams.
   - Describe only what is implemented. Anything unfinished keeps its 🚧 marker.

2. **Append an entry to `docs/BUILD_LOG.md`**
   Use the established format: Goal, Result, Issues, Next. Always record the key numbers: test counts, gas usage and contract addresses.

3. **Log in `FEEDBACK.md` any issue you hit** with the Uniswap toolchain, the documentation or the v4 interfaces.

4. **Commit and push to main**
   ```bash
   git add -A
   git commit -m "<type>: <concise description>"
   git push origin main
   ```
   Commit messages follow Conventional Commits: `feat` / `fix` / `test` / `docs` / `chore` / `refactor`.

### Branching

There is a single maintainer, so commit directly to main. No pull requests and no feature branches.

### Commit Discipline

- One feature per commit. Never bundle several features into one commit.
- Before committing, check that `git status` shows no files starting with `.env` and no `cache/` or `broadcast/` directories.
- Judges review the git history, and a single huge commit will draw scrutiny.
