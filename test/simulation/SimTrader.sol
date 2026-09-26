// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice A trader account in the simulation. It holds tokens and swaps through PoolSwapTest,
///         which supports price limits.
contract SimTrader {
    PoolSwapTest internal immutable router;

    constructor(PoolSwapTest router_, Currency currency0, Currency currency1) {
        router = router_;
        MockERC20(Currency.unwrap(currency0)).approve(address(router_), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router_), type(uint256).max);
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta)
    {
        return router.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
