// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";

import {WeightVault} from "../../src/weights/WeightVault.sol";
import {WeightAuction} from "../../src/weights/WeightAuction.sol";
import {WeightToken} from "../../src/weights/WeightToken.sol";
import {HookFixture} from "./HookFixture.sol";

/// @notice The front-end's setup: native ETH (currency0, 18 decimals) / USDC (currency1, 6 decimals) on the log curve,
///         0.3% fee, tick spacing 10, positions held by the WeightVault. Prices are in human units (USDC per ETH).
abstract contract EthUsdcFixture is HookFixture {
    uint256 internal constant WAD = 1e18;
    int24 internal constant SPACING = 10;

    MockERC20 internal usdc;
    PoolKey internal ethKey;
    PoolId internal ethId;
    WeightVault internal vault;
    WeightAuction internal auction;
    WeightToken internal weights;
    address internal treasury;

    function setUpEthUsdc() internal {
        setUpHook();
        treasury = makeAddr("treasury");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        ethKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(usdc)), 3000, SPACING, IHooks(address(hook)));
        ethId = ethKey.toId();
        vault = new WeightVault(hook, 100); // exercise only within 100 ticks (~1%) of the moving average
        weights = vault.weights();
        auction = new WeightAuction(weights, treasury);
        hook.initializePool(ethKey, sqrtPriceX96At(WAD), true); // ETH = $1
    }

    function fund(address who, uint256 eth, uint256 usdcAmount) internal {
        vm.deal(who, eth);
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(auction), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // human prices <-> pool units (raw price = human * 1e6 / 1e18)
    // ------------------------------------------------------------------------------------------------------------

    function sqrtPriceX96At(uint256 humanPriceWad) internal pure returns (uint160) {
        // sqrt(p * 1e-12) * 2^96 = sqrt(p) * 2^96 / 1e6
        return uint160(FullMath.mulDiv(FixedPointMathLib.sqrt(humanPriceWad * WAD), 1 << 96, 1e24));
    }

    /// @dev nearest usable tick to a human price
    function tickAt(uint256 humanPriceWad) internal pure returns (int24) {
        int24 t = TickMath.getTickAtSqrtPrice(sqrtPriceX96At(humanPriceWad));
        int24 down = t >= 0 ? (t / SPACING) * SPACING : ((t - SPACING + 1) / SPACING) * SPACING;
        return t - down >= SPACING / 2 ? down + SPACING : down;
    }

    function priceWad() internal view returns (uint256) {
        (uint160 s,,) = hook.getSlot0(ethId);
        return FullMath.mulDiv(uint256(s) * s, 1e30, 1 << 192);
    }

    function priceAtTickWad(int24 tick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(s * s, 1e30, 1 << 192);
    }

    /// @dev value of (eth wei, usdc units) in USDC units at the current price
    function valueUsdc(uint256 ethAmount, uint256 usdcAmount) internal view returns (uint256) {
        return ethAmount * priceWad() / 1e30 + usdcAmount;
    }

    /// @dev liquidity whose deposit is worth `usd` (USDC units) at the current price
    function liquidityForValue(int24 tickLower, int24 tickUpper, uint256 usd) internal view returns (uint128) {
        uint128 ref = 1e12;
        (uint256 a0, uint256 a1) = hook.getAmountsForLiquidity(ethId, tickLower, tickUpper, ref, false);
        return uint128(usd * ref / valueUsdc(a0, a1));
    }

    function mintPosition(address lp, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 positionId, uint256 eth, uint256 usdcAmount)
    {
        (uint256 a0,) = hook.getAmountsForLiquidity(ethId, tickLower, tickUpper, liquidity, true);
        vm.prank(lp);
        (positionId, eth, usdcAmount) = vault.mint{value: a0}(
            ethKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, block.timestamp
        );
    }

    function swapAs(address trader, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta d) {
        uint256 value;
        if (zeroForOne) {
            // ETH in: send the exact input, or a generous cap for exact output (the router refunds the rest)
            value = amountSpecified < 0 ? uint256(-amountSpecified) : trader.balance;
        }
        vm.prank(trader);
        d = swapRouter.swap{value: value}(
            ethKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev fixed-point amount as a decimal string with `shown` decimals
    function fmt(uint256 amount, uint256 decimals, uint256 shown) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 frac = (amount % unit) * 10 ** shown / unit;
        string memory f = LibString.toString(frac);
        while (bytes(f).length < shown) f = string.concat("0", f);
        return string.concat(LibString.toString(amount / unit), ".", f);
    }

    function fmtSigned(int256 amount, uint256 decimals, uint256 shown) internal pure returns (string memory) {
        return amount < 0
            ? string.concat("-", fmt(uint256(-amount), decimals, shown))
            : string.concat("+", fmt(uint256(amount), decimals, shown));
    }
}
