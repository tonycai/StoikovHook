// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "../base/BaseScript.sol";
import {LiquidityHelpers} from "../base/LiquidityHelpers.sol";

import {StoikovHook, FeeParams, STOIKOV_HOOK_FLAGS, defaultFeeParams} from "../../src/StoikovHook.sol";

/// @notice One-shot demo deployment. It deploys two test tokens and StoikovHook at a mined CREATE2 address,
///         creates a dynamic-fee pool with full-range liquidity, then makes three swaps that show the
///         direction-dependent fee.
///
///         Run with --slow, so that each transaction is sent only after the previous one is mined. Every
///         swap then lands in its own block and opens its own fee window:
///           1. buy 5 token0: pushes the price about 1% (about 100 ticks) above the pool's reference price
///           2. sell 1 token0: next block, price above the reference, the rebalancing side pays the lower fee
///           3. buy 1 token0:  next block, price still above the reference, the imbalancing side pays the higher fee
///
///         Keys are only used through a Foundry keystore (--account); never pass a private key.
contract DeployDemoScript is BaseScript, LiquidityHelpers {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant TOKEN_SUPPLY = 1_000_000e18;
    uint256 internal constant LIQUIDITY_PER_SIDE = 1_000e18;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant PUSH_AMOUNT = 5e18;
    uint256 internal constant PROBE_AMOUNT = 1e18;
    uint256 internal constant DEADLINE_WINDOW = 1 hours;

    /// @dev The broadcasting account. Taken from msg.sender inside run(), which forge sets to --sender.
    ///      BaseScript's `deployerAddress` is resolved in its constructor, where msg.sender is forge's
    ///      default sender unless a wallet flag is given, so it is wrong in keyless dry runs.
    address internal deployer;

    function run() external {
        deployer = msg.sender;
        require(deployer != DEFAULT_SENDER, "DeployDemo: pass --sender (and --account to broadcast)");

        // HookMiner skips candidate addresses that already have code. Mining exceeds the block gas limit, so
        // run with --gas-limit 100000000000 --disable-block-gas-limit (CLAUDE.md, known issues).
        FeeParams memory params = defaultFeeParams();
        (address expectedHook, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, STOIKOV_HOOK_FLAGS, type(StoikovHook).creationCode, abi.encode(poolManager, params)
        );

        vm.startBroadcast(deployer);

        (Currency currency0, Currency currency1) = _deployTokens();
        StoikovHook hook = new StoikovHook{salt: salt}(poolManager, params);
        require(address(hook) == expectedHook, "DeployDemo: hook address mismatch");

        PoolKey memory key =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook)));
        _approve(currency0);
        _approve(currency1);
        _createPoolWithLiquidity(key);

        _swap(key, false, PUSH_AMOUNT);
        _swap(key, true, PROBE_AMOUNT);
        _swap(key, false, PROBE_AMOUNT);

        vm.stopBroadcast();

        console2.log("Deployer:        ", deployer);
        console2.log("StoikovHook:     ", address(hook));
        console2.log("Token0:          ", Currency.unwrap(currency0));
        console2.log("Token1:          ", Currency.unwrap(currency1));
        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _deployTokens() internal returns (Currency currency0, Currency currency1) {
        MockERC20 tokenA = new MockERC20("StoikovHook Demo Token A", "SHDA", 18);
        MockERC20 tokenB = new MockERC20("StoikovHook Demo Token B", "SHDB", 18);
        tokenA.mint(deployer, TOKEN_SUPPLY);
        tokenB.mint(deployer, TOKEN_SUPPLY);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
    }

    /// @dev Permit2 and PositionManager allowances for minting, plus a direct allowance for the swap router.
    function _approve(Currency currency) internal {
        MockERC20 token = MockERC20(Currency.unwrap(currency));
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        token.approve(address(swapRouter), type(uint256).max);
    }

    /// @dev Initializes the pool at price 1 and mints a full-range position in one multicall.
    function _createPoolWithLiquidity(PoolKey memory key) internal {
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            LIQUIDITY_PER_SIDE,
            LIQUIDITY_PER_SIDE
        );
        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            key, tickLower, tickUpper, liquidity, LIQUIDITY_PER_SIDE + 1, LIQUIDITY_PER_SIDE + 1, deployer, ""
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(positionManager.initializePool.selector, key, Constants.SQRT_PRICE_1_1, "");
        calls[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + DEADLINE_WINDOW
        );
        positionManager.multicall(calls);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: deployer,
            deadline: block.timestamp + DEADLINE_WINDOW
        });
    }
}
