// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

/// @notice The liquidity provider in the simulation. It holds tokens and mints full-range positions
///         through the v4 PositionManager.
contract SimLiquidityProvider {
    using EasyPosm for IPositionManager;

    IPositionManager internal immutable positionManager;
    IPermit2 internal immutable permit2;

    constructor(IPositionManager positionManager_, IPermit2 permit2_) {
        positionManager = positionManager_;
        permit2 = permit2_;
    }

    /// @notice Mints a full-range position in an initialized pool and returns the tokens deposited.
    function mintFullRange(PoolKey calldata key, uint160 sqrtPriceX96, uint128 liquidity)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        _approve(key.currency0);
        _approve(key.currency1);

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 max0, uint256 max1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        (, BalanceDelta delta) = positionManager.mint(
            key, tickLower, tickUpper, liquidity, max0 + 1, max1 + 1, address(this), block.timestamp + 1, ""
        );
        amount0 = uint256(int256(-delta.amount0()));
        amount1 = uint256(int256(-delta.amount1()));
    }

    function _approve(Currency currency) internal {
        address token = Currency.unwrap(currency);
        MockERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }
}
