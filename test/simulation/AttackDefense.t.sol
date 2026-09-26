// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {StoikovHookFixture} from "../utils/StoikovHookFixture.sol";
import {StoikovHookNoCache} from "./StoikovHookNoCache.sol";

import {STOIKOV_HOOK_FLAGS, defaultFeeParams} from "../../src/StoikovHook.sol";

/// @notice The same-block round-trip attack (spec §5.4) against StoikovHook with and without the per-block
///         fee cache. It writes docs/simulation/attack_defense.csv for the README figure:
///
///   FOUNDRY_PROFILE=sim forge test --match-contract AttackDefenseTest -vv
///
///         Sequence, identical for both pools: in block N, push the price up with a 1-token buy. In block
///         N+1, the attacker sells 2 tokens (the discounted rebalancing direction), pushing the price back
///         through the reference, then buys 5 tokens. The question is which fee that large buy pays.
contract AttackDefenseTest is StoikovHookFixture {
    using PoolIdLibrary for PoolKey;

    string internal constant ATTACK_CSV = "docs/simulation/attack_defense.csv";

    PoolKey internal noCacheKey;

    function setUp() public override {
        super.setUp();
        address where = address(STOIKOV_HOOK_FLAGS ^ (0x7777 << 144));
        deployCodeTo("StoikovHookNoCache.sol:StoikovHookNoCache", abi.encode(poolManager, defaultFeeParams()), where);
        noCacheKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(where));
        _initializeWithFullRangeLiquidity(noCacheKey);
    }

    function test_attackDefense() public {
        vm.writeFile(ATTACK_CSV, "variant,step,block,zero_for_one,amount_in_tokens,fee_pips\n");

        // Block N: push the price up in both pools.
        _record("with_cache", "push_price_up", hookedKey, false, 1);
        _record("without_cache", "push_price_up", noCacheKey, false, 1);
        _nextBlock(BLOCK_TIME);

        // Block N+1: the fees posted at window open, for reference.
        (uint24 feeUp, uint24 feeDown) = hook.previewFees(hookedKey);
        vm.writeLine(ATTACK_CSV, string.concat("with_cache,window_open_fee_up,N+1,,,", vm.toString(feeUp)));
        vm.writeLine(ATTACK_CSV, string.concat("with_cache,window_open_fee_down,N+1,,,", vm.toString(feeDown)));

        // The attack: a discounted sell through the reference, then a large buy.
        _record("with_cache", "round_trip_sell", hookedKey, true, 2);
        uint24 withCache = _record("with_cache", "large_buy", hookedKey, false, 5);
        _record("without_cache", "round_trip_sell", noCacheKey, true, 2);
        uint24 withoutCache = _record("without_cache", "large_buy", noCacheKey, false, 5);

        console2.log("Large buy after a same-block round trip, fee in pips:");
        console2.log("  with the per-block cache:   ", withCache);
        console2.log("  without the cache (mutant): ", withoutCache);

        // Harness checks: the cache holds the window-open fee; without it the attack lowers the fee.
        assertEq(withCache, feeUp, "with the cache, the large buy pays the window-open price-up fee");
        assertLt(withoutCache, withCache, "without the cache, the round trip lowers the fee");
    }

    /// @dev Swaps `tokens` whole tokens in `key`'s pool, appends a CSV row, and returns the fee charged.
    function _record(string memory variant, string memory step, PoolKey memory key, bool zeroForOne, uint256 tokens)
        internal
        returns (uint24 fee)
    {
        PoolId id = key.toId();
        vm.recordLogs();
        _swap(key, zeroForOne, tokens * 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(poolManager) && logs[i].topics[0] == IPoolManager.Swap.selector
                    && logs[i].topics[1] == PoolId.unwrap(id)
            ) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        string memory blockLabel = keccak256(bytes(step)) == keccak256("push_price_up") ? "N" : "N+1";
        vm.writeLine(
            ATTACK_CSV,
            string.concat(
                variant,
                ",",
                step,
                ",",
                blockLabel,
                ",",
                zeroForOne ? "true" : "false",
                ",",
                vm.toString(tokens),
                ",",
                vm.toString(fee)
            )
        );
    }
}
