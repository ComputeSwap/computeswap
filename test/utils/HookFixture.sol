// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConcentratedCurveHook} from "../../src/ConcentratedCurveHook.sol";
import {ICurve} from "../../src/interfaces/ICurve.sol";
import {LogCurve} from "../../src/curves/LogCurve.sol";

/// @notice PoolManager + routers + tokens + the hook at an address that encodes its permissions.
abstract contract HookFixture is Deployers {
    ConcentratedCurveHook internal hook;
    LogCurve internal logCurve;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev The hook on the log curve
    function setUpHook() internal {
        setUpHookWith(ICurve(address(0)));
    }

    /// @dev The hook bound to `curve` (the log curve when zero)
    function setUpHookWith(ICurve curve) internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        logCurve = new LogCurve();
        ICurve bound = address(curve) == address(0) ? ICurve(address(logCurve)) : curve;
        address hookAddress = address(HOOK_FLAGS ^ (uint160(0x4444) << 144));
        deployCodeTo("ConcentratedCurveHook.sol:ConcentratedCurveHook", abi.encode(manager, bound), hookAddress);
        hook = ConcentratedCurveHook(hookAddress);
        approveHook(address(this));
    }

    function approveHook(address who) internal {
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function newLp(string memory name, uint256 amountEach) internal returns (address lp) {
        lp = makeAddr(name);
        MockERC20(Currency.unwrap(currency0)).transfer(lp, amountEach);
        MockERC20(Currency.unwrap(currency1)).transfer(lp, amountEach);
        approveHook(lp);
    }

    function createPool(uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96, bool mirrorPrice)
        internal
        returns (PoolKey memory k)
    {
        k = PoolKey(currency0, currency1, fee, tickSpacing, IHooks(address(hook)));
        hook.initializePool(k, sqrtPriceX96, mirrorPrice);
    }

    function lpAdd(address lp, PoolKey memory k, int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt)
        internal
        returns (BalanceDelta callerDelta)
    {
        vm.prank(lp);
        (callerDelta,) = hook.addLiquidity(
            k,
            ConcentratedCurveHook.AddLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amount0Max: type(uint256).max,
                amount1Max: type(uint256).max,
                salt: salt,
                deadline: block.timestamp
            })
        );
    }

    function lpRemove(address lp, PoolKey memory k, int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt)
        internal
        returns (BalanceDelta callerDelta)
    {
        vm.prank(lp);
        (callerDelta,) = hook.removeLiquidity(
            k,
            ConcentratedCurveHook.RemoveLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                salt: salt,
                recipient: lp,
                deadline: block.timestamp
            })
        );
    }

    /// @dev Swap through v4's test router with no price limit (the whole amount must fill).
    function doSwap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function claimBalance(Currency currency) internal view returns (uint256) {
        return manager.balanceOf(address(hook), currency.toId());
    }
}
