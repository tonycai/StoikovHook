# Sepolia Deployment

The demo deployment of StoikovHook on Sepolia (chain ID 11155111). Every number on this page was read back from the chain after the broadcast, and every contract below has an exact-match verified source on Etherscan.

| | |
|---|---|
| Date | 2026-09-26, 12:42:24–12:46:24 JST (blocks 11783638–11783655) |
| Script | [`script/sepolia/DeployDemo.s.sol`](../../script/sepolia/DeployDemo.s.sol), one broadcast with `--slow` |
| Deployer | [`0x7ff0F2944447d75BCd0be09A7c51b0b4800414D9`](https://sepolia.etherscan.io/address/0x7ff0F2944447d75BCd0be09A7c51b0b4800414D9) (nonce 0 → 15) |
| Transactions | 15, all successful, each in its own block |
| Total cost | 5,240,237 gas, **0.00553325 ETH** (≈ 0.0055 ETH) at 0.94–1.11 gwei |

## Contracts

| Contract | Address | Etherscan source |
|---|---|---|
| StoikovHook | [`0x67b97620e35DAf13de266F84cAbC8c8d45755080`](https://sepolia.etherscan.io/address/0x67b97620e35DAf13de266F84cAbC8c8d45755080#code) | ✅ Verified, exact match |
| StoikovHook Demo Token B (SHDB), pool `currency0` | [`0x075CA8DefA53cbB9D9933342B784D13629f7a836`](https://sepolia.etherscan.io/address/0x075CA8DefA53cbB9D9933342B784D13629f7a836#code) | ✅ Verified, exact match |
| StoikovHook Demo Token A (SHDA), pool `currency1` | [`0x8041740E5dee82B7d5C853a722D2DDe593a6a6cf`](https://sepolia.etherscan.io/address/0x8041740E5dee82B7d5C853a722D2DDe593a6a6cf#code) | ✅ Verified, exact match |

The tokens are solmate's `MockERC20` (18 decimals, 1,000,000 minted to the deployer). They are test tokens with no value. The script sorts them by address, so token B is `currency0`.

Uniswap v4 contracts used, all official Sepolia deployments taken from hookmate's `AddressConstants`:

| Contract | Address |
|---|---|
| PoolManager | [`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| PositionManager | [`0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4`](https://sepolia.etherscan.io/address/0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4) |
| V4 swap router | [`0xf13D190e9117920c703d79B5F33732e10049b115`](https://sepolia.etherscan.io/address/0xf13D190e9117920c703d79B5F33732e10049b115) |
| Permit2 | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://sepolia.etherscan.io/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |

## Demo Pool

| Field | Value |
|---|---|
| Pool ID | `0xc9b29abec42bf4b8a52989884f4c29586f80c1659e3c6d045568172ce07c00c8` |
| `currency0` / `currency1` | SHDB / SHDA |
| `fee` | `0x800000` (`DYNAMIC_FEE_FLAG`) |
| `tickSpacing` | 60 |
| `hooks` | StoikovHook |
| Initial price | 1 (tick 0) |
| Liquidity | Full range, 1,000 of each token |

The price below is SHDA per SHDB (token1 per token0). "Price up" means a swap with `zeroForOne = false`: the trader pays SHDA and receives SHDB.

## Checks on the Deployed Hook

| Check | Result |
|---|---|
| Code at the hook address | 9,738 bytes |
| Low 14 bits of the address | `0x1080` = `afterInitialize` + `beforeSwap`, equal to `STOIKOV_HOOK_FLAGS` (`src/StoikovHook.sol:L18`) |
| `poolManager()` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, the official PoolManager |
| Parameters read from the contract | `baseFee` 500, `minFee` 100, `maxFee` 10,000, `refTau` 900: the values of `defaultFeeParams()` |
| Runtime bytecode | Identical to a clean local build (`forge clean && forge build`) after masking the 37 immutable slots |
| Creation code | Identical to the CREATE2 init code in transaction 5 (salt, then creation code, then 384 bytes of constructor arguments) |

## Transactions

| # | Block | Action | Gas | Transaction |
|---|---|---|---|---|
| 1 | 11783638 | Deploy SHDA (`MockERC20`) | 857,709 | [`0x71f6cc47…c93341f6`](https://sepolia.etherscan.io/tx/0x71f6cc47f7f970a671df33ba90c1a5ec0df69c56bdc50732c8b1304ec93341f6) |
| 2 | 11783640 | Deploy SHDB (`MockERC20`) | 857,709 | [`0xab2abb9a…e5954e9c`](https://sepolia.etherscan.io/tx/0xab2abb9a0e6715987a6080c130d865ceab4b0a5f155185c81a76841ae5954e9c) |
| 3 | 11783641 | Mint 1,000,000 SHDA to the deployer | 68,278 | [`0x5c785e8a…c10f5c5f`](https://sepolia.etherscan.io/tx/0x5c785e8ad01049f713496c1e19cbb4da525dd71a58b31c53a047d8a0c10f5c5f) |
| 4 | 11783642 | Mint 1,000,000 SHDB to the deployer | 68,278 | [`0x079c61ad…5fd783c5`](https://sepolia.etherscan.io/tx/0x079c61ada3f236dc90aa6df4e8c2df7015f351d64914c5f1889924605fd783c5) |
| 5 | 11783643 | Deploy StoikovHook through the CREATE2 deployer with the mined salt | 2,179,919 | [`0x819f3df0…c48b887f`](https://sepolia.etherscan.io/tx/0x819f3df00d61c47a3554f5033dbe8d9ccfd6b779400fc57c294aedd7c48b887f) |
| 6 | 11783644 | SHDB: approve Permit2 | 46,402 | [`0x04c53e42…a1ea87ea`](https://sepolia.etherscan.io/tx/0x04c53e42e1e90fc51eca6fa6af3041dac67cadac063dafb3c30c983ea1ea87ea) |
| 7 | 11783645 | Permit2: allow PositionManager to spend SHDB | 47,818 | [`0xdb6d91d7…bd061069`](https://sepolia.etherscan.io/tx/0xdb6d91d74527b49bea5e8409c1b8165342949be09da74c87a72ab66cbd061069) |
| 8 | 11783646 | SHDB: approve the swap router | 46,450 | [`0x138b63ba…0ea29184`](https://sepolia.etherscan.io/tx/0x138b63bad455f9cc90c2d586268ab97aa3f0aa5b3f03c124a96ca3dd0ea29184) |
| 9 | 11783647 | SHDA: approve Permit2 | 46,402 | [`0x2b144884…8439ae91`](https://sepolia.etherscan.io/tx/0x2b14488436054302a13f266efcde3f1b6f80c17ea3eaebafdbdeb4578439ae91) |
| 10 | 11783648 | Permit2: allow PositionManager to spend SHDA | 47,818 | [`0xe8e6d7b5…713092d2`](https://sepolia.etherscan.io/tx/0xe8e6d7b5ef50e24e4d0ab8c1e53be26032d985bc13df662dbff50341713092d2) |
| 11 | 11783649 | SHDA: approve the swap router | 46,450 | [`0xcb813463…b72b945d`](https://sepolia.etherscan.io/tx/0xcb813463db2bd2f8d70f04c69c4b5ca52ee9f9cc7634e48337c4da11b72b945d) |
| 12 | 11783650 | PositionManager `multicall`: initialize the pool at price 1 and mint the full-range position | 521,195 | [`0xb8f97c7d…526755cd`](https://sepolia.etherscan.io/tx/0xb8f97c7d0272d566de587eefde49775ff8350ab69d4f05b1a8e69bd9526755cd) |
| 13 | 11783652 | Swap 5 SHDA for SHDB (price up) | 140,952 | [`0xa653e0f4…d2051fc1`](https://sepolia.etherscan.io/tx/0xa653e0f454b76c7885321bca6c23cbaf02fceffd3fb117b6327f9816d2051fc1) |
| 14 | 11783653 | Swap 1 SHDB for SHDA (price down) | 141,005 | [`0x266a7eaa…e620d0a7`](https://sepolia.etherscan.io/tx/0x266a7eaa4f6f8888b6047174dd66cc1b3d1f2dcd4d60484b0ee3bb47e620d0a7) |
| 15 | 11783655 | Swap 1 SHDA for SHDB (price up) | 123,852 | [`0x316450c5…8903d574`](https://sepolia.etherscan.io/tx/0x316450c5cbe165e81fe51cef36a0a0d44d9d63a1c4514eb86dd18d0b8903d574) |

## Demo Swaps

Each swap is the first swap of its block, so each one opens a fee window. `FeeWindowUpdated` is emitted by the hook; `fee` is the `fee` field of the PoolManager's own `Swap` event, in pips (1 pip = 0.0001%).

| # | Block time (JST) | Swap | Window: tick / reference | σ_h (pips) | Window: price-up fee / price-down fee | `fee` charged | Tick after |
|---|---|---|---|---|---|---|---|
| 13 | 12:45:48 | Price up: 5 SHDA in, 4.9710 SHDB out | 0 / 0 | 333 | 833 / 833 | **833** | 99 |
| 14 | 12:46:00 | Price down: 1 SHDB in, 1.0070 SHDA out | 99 / 1 | 1,968 | 2,949 / 1,987 | **1,987** | 79 |
| 15 | 12:46:24 | Price up: 1 SHDA in, 0.9883 SHDB out | 79 / 3 | 1,933 | 2,799 / 2,067 | **2,799** | 99 |

What the swaps show:

- **Swaps in opposite directions pay different fees.** The price-down swap in transaction 14 paid 1,987 pips (0.1987%). The price-up swap in transaction 15 paid 2,799 pips (0.2799%).
- **Each swap paid its own direction's fee from the window posted in its block.** In both windows the side that pushes the price further from the reference was priced higher: 2,949 vs. 1,987 in block 11783653, and 2,799 vs. 2,067 in block 11783655.
- **The two swaps are in different blocks**, 24 seconds apart, so part of the gap between 1,987 and 2,799 comes from the window changing. The same-window comparison is the pair of fees in each `FeeWindowUpdated` event.
- **Why the fees are well above the 500-pip base fee.** Transaction 13 moved the tick by 99 in one 12-second block. The volatility term σ_h rose from 333 to 1,968 pips, which lifted both fees; the inventory skew then split them.
- **The fees follow the formula.** In block 11783653, q̂ = (99 − 1) / 200 = 0.49, so the fees are 500 + 1,968 × (1 ± 0.5 × 0.49) ≈ 2,950 / 1,986. The contract uses the unrounded reference (`refTickX16`), so this matches the on-chain 2,949 / 1,987 to within 1 pip.
- The pool initialization in transaction 12 also opened a window: σ_h 346 from the initial variance, 846 pips on both sides.

After the demo, `previewFees` returned 2,185 (price up) and 1,663 (price down) at block 11783678 (12:51:00 JST). This view computes the fees a swap would pay in the current block without writing state. Both fees are lower than in block 11783655: 276 seconds had passed with only the 20-tick move of transaction 15, so σ_h had decayed from 1,933 to about 1,425 pips (recomputed from the stored state).

### Swap sizes and the fee cap

The swap sizes were chosen so that no fee hits the 1% cap. The first rehearsal on a Sepolia fork pushed 20 tokens (about 4% in one block), and the price-up fee hit the cap: 10,000 vs. 4,447 pips. That is correct behavior, but a capped fee hides the skew, so the push was cut to 5 tokens (about 1%). This demo therefore does not exercise the cap. Cap behavior is covered by tests:

- `test_extremeVolatility_clampsAtMaxFee` (`test/StoikovHookFees.t.sol:98`)
- `testFuzz_computeFees_withinBoundsForAnyInput` (`test/StoikovHookFees.t.sol:110`, 5,000 runs) and `testFuzz_computeFees_withinBoundsForAnyValidParams` (`test/StoikovHookFees.t.sol:116`, 1,000 runs)
- `testFuzz_swapSequence_feesStayWithinBounds` (`test/StoikovHook.t.sol:218`, 1,000 runs), through the PoolManager

The fork rehearsal with the 5-token push gave 2,945 / 2,010 pips in the second window. The live run gave 2,949 / 1,987. The fees depend on block timestamps, which differ between a fork rehearsal and the live network.

## Source Verification

All three contracts were verified with `forge verify-contract` against the pinned compiler settings in `foundry.toml` (solc 0.8.30, optimizer 7,777 runs, `evm_version` cancun, `bytecode_hash` none). The API key is read from the `ETHERSCAN_API_KEY` environment variable.

```bash
forge verify-contract 0x67b97620e35DAf13de266F84cAbC8c8d45755080 src/StoikovHook.sol:StoikovHook \
  --chain sepolia --watch \
  --constructor-args $(cast abi-encode \
    "constructor(address,(uint24,uint24,uint24,uint64,uint64,uint32,uint32,uint32,uint24,uint24,uint64))" \
    0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 \
    "(500,100,10000,1000000000000000000,500000000000000000,12,300,900,200,1000,1000000000000)")

forge verify-contract 0x8041740E5dee82B7d5C853a722D2DDe593a6a6cf \
  lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20 \
  --chain sepolia --watch \
  --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "StoikovHook Demo Token A" "SHDA" 18)
```

SHDB uses the same command with its own address, `"StoikovHook Demo Token B" "SHDB"` and `--skip-is-verified-check`.

The constructor arguments of the hook are `abi.encode(poolManager, defaultFeeParams())`. The encoding above reproduces, byte for byte, the last 384 bytes of the CREATE2 init code in transaction 5.

Two issues came up:

1. **The first StoikovHook submission failed** with `Source "src/base/BaseHook.sol" not found`. OpenZeppelin uniswap-hooks imports its own files by root-relative paths (for example `lib/uniswap-hooks/src/fee/BaseOverrideFee.sol:6`). `forge build` resolves these on its own, but the standard JSON input sent to Etherscan has no remapping for them. Compiling that input with solc 0.8.30 locally reproduces the same error. The fix is one context-specific remapping in `remappings.txt`, `lib/uniswap-hooks/:src/=lib/uniswap-hooks/src/`, which applies only to imports inside that library. StoikovHook's creation and runtime bytecode are identical before and after the change, under both the default and `sim` profiles. See [`FEEDBACK.md`](../../FEEDBACK.md).
2. **Etherscan first marked SHDB as a "similar match"** to SHDA, because the two tokens share runtime bytecode. That listing showed no constructor arguments. SHDB was resubmitted with `--skip-is-verified-check` and is now an exact match with its own arguments.

## Re-checking on Chain

Anyone can re-check the key facts with `cast`, using their own Sepolia RPC endpoint:

```bash
HOOK=0x67b97620e35DAf13de266F84cAbC8c8d45755080
cast call $HOOK "poolManager()(address)" --rpc-url "$SEPOLIA_RPC_URL"
cast call $HOOK "baseFee()(uint24)" --rpc-url "$SEPOLIA_RPC_URL"
cast receipt 0x266a7eaa4f6f8888b6047174dd66cc1b3d1f2dcd4d60484b0ee3bb47e620d0a7 --rpc-url "$SEPOLIA_RPC_URL"   # swap 14
```

In a receipt, the PoolManager's `Swap` event carries the charged fee as its last data word, and the hook's `FeeWindowUpdated` event carries the tick, the reference tick, σ_h and both fees.
