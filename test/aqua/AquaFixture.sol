// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Aqua} from "@1inch/aqua/Aqua.sol";
import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";

import {LogCurve} from "../../src/curves/LogCurve.sol";
import {ComputeswapAquaApp} from "../../src/aqua/ComputeswapAquaApp.sol";
import {ComputeswapAquaRouter} from "../../src/aqua/ComputeswapAquaRouter.sol";
import {AquaWeightVault} from "../../src/aqua/AquaWeightVault.sol";
import {WeightToken} from "../../src/weights/WeightToken.sol";
import {WeightAuction} from "../../src/weights/WeightAuction.sol";

/// @notice The Aqua stack with the front end's pair: WETH (token0, 18 decimals) / USDC (token1, 6 decimals) on the log
///         curve, 0.3% fee. Prices are in human units (USDC per ETH), as in EthUsdcFixture.
abstract contract AquaFixture is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;
    int24 internal constant SPACING = 10;
    uint24 internal constant FEE = 3000;

    Aqua internal aqua;
    LogCurve internal curve;
    ComputeswapAquaApp internal app;
    ComputeswapAquaRouter internal router;
    AquaWeightVault internal vault;
    WeightToken internal weights;
    WeightAuction internal auction;
    WETH internal weth;
    MockERC20 internal usdc;
    address internal treasury;

    function setUpAqua() internal {
        aqua = new Aqua();
        curve = new LogCurve();
        app = new ComputeswapAquaApp(IAqua(address(aqua)), curve);
        weth = new WETH();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        treasury = makeAddr("treasury");
        vault = new AquaWeightVault(app, 100); // exercise only within 100 ticks (~1%) of the moving average
        weights = vault.weights();
        auction = new WeightAuction(weights, treasury);
        router = new ComputeswapAquaRouter(app, address(weth));
    }

    /// @dev `eth` of WETH and `usdcAmount` of USDC, approved to everything that may pull from `who`
    function fund(address who, uint256 eth, uint256 usdcAmount) internal {
        vm.deal(who, eth + 1 ether);
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        weth.deposit{value: eth}();
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        usdc.approve(address(auction), type(uint256).max);
        // for makers that ship from their own wallet
        weth.approve(address(aqua), type(uint256).max);
        usdc.approve(address(aqua), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // human prices <-> pool units (raw price = human * 1e6 / 1e18)
    // ------------------------------------------------------------------------------------------------------------

    function sqrtPriceX96At(uint256 humanPriceWad) internal pure returns (uint160) {
        return uint160(FullMath.mulDiv(FixedPointMathLib.sqrt(humanPriceWad * WAD), 1 << 96, 1e24));
    }

    /// @dev nearest usable tick to a human price
    function tickAt(uint256 humanPriceWad) internal pure returns (int24) {
        int24 t = TickMath.getTickAtSqrtPrice(sqrtPriceX96At(humanPriceWad));
        int24 down = t >= 0 ? (t / SPACING) * SPACING : ((t - SPACING + 1) / SPACING) * SPACING;
        return t - down >= SPACING / 2 ? down + SPACING : down;
    }

    function sqrtToPriceWad(uint160 s) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(s) * s, 1e30, 1 << 192);
    }

    function priceWadOf(ComputeswapAquaApp.Strategy memory s) internal view returns (uint256) {
        (uint160 sqrtPriceX96,) = app.currentSqrtPrice(s);
        return sqrtToPriceWad(sqrtPriceX96);
    }

    function priceAtTickWad(int24 tick) internal pure returns (uint256) {
        return sqrtToPriceWad(TickMath.getSqrtPriceAtTick(tick));
    }

    // ------------------------------------------------------------------------------------------------------------
    // strategies
    // ------------------------------------------------------------------------------------------------------------

    function strategyFor(
        address maker,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 priceWad,
        bytes32 salt
    ) internal view returns (ComputeswapAquaApp.Strategy memory) {
        return ComputeswapAquaApp.Strategy({
            maker: maker,
            token0: address(weth),
            token1: address(usdc),
            fee: FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            sqrtPriceX96: sqrtPriceX96At(priceWad),
            salt: salt
        });
    }

    /// @dev A maker ships a strategy from their own wallet (the Aqua-native path, no vault)
    function shipAs(address maker, ComputeswapAquaApp.Strategy memory s) internal returns (bytes32 hash) {
        (uint256 amount0, uint256 amount1) = app.openingAmounts(s);
        address[] memory tokens = new address[](2);
        tokens[0] = s.token0;
        tokens[1] = s.token1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;
        vm.prank(maker);
        hash = aqua.ship(address(app), abi.encode(s), tokens, amounts);
    }

    function dockAs(address maker, ComputeswapAquaApp.Strategy memory s) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = s.token0;
        tokens[1] = s.token1;
        vm.prank(maker);
        aqua.dock(address(app), keccak256(abi.encode(s)), tokens);
    }

    function balancesOf(ComputeswapAquaApp.Strategy memory s) internal view returns (uint256 b0, uint256 b1) {
        bytes32 hash = keccak256(abi.encode(s));
        (b0,) = aqua.rawBalances(s.maker, address(app), hash, s.token0);
        (b1,) = aqua.rawBalances(s.maker, address(app), hash, s.token1);
    }

    /// @dev liquidity whose deposit on [tickLower, tickUpper] is worth `usd` (USDC units) at `priceWad`
    function liquidityForValue(int24 tickLower, int24 tickUpper, uint256 usd, uint256 priceWad)
        internal
        view
        returns (uint128)
    {
        uint128 ref = 1e12;
        ComputeswapAquaApp.Strategy memory probe =
            strategyFor(address(this), tickLower, tickUpper, ref, priceWad, bytes32(0));
        (uint256 a0, uint256 a1) = app.openingAmounts(probe);
        return uint128(usd * ref / (a0 * priceWad / 1e30 + a1));
    }

    function mintPosition(address lp, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 priceWad)
        internal
        returns (uint256 positionId, uint256 amount0, uint256 amount1)
    {
        vm.prank(lp);
        (positionId, amount0, amount1) = vault.mint(
            AquaWeightVault.MintParams({
                token0: address(weth),
                token1: address(usdc),
                fee: FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                sqrtPriceX96: sqrtPriceX96At(priceWad),
                amount0Max: type(uint256).max,
                amount1Max: type(uint256).max,
                deadline: block.timestamp
            })
        );
    }

    /// @dev Swap through the router: amountSpecified < 0 is exact input, > 0 exact output (as in v4)
    function swapAs(address trader, ComputeswapAquaApp.Strategy memory s, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        vm.prank(trader);
        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            amountOut = router.swapExactIn(s, zeroForOne, amountIn, 0, trader);
        } else {
            amountOut = uint256(amountSpecified);
            amountIn = router.swapExactOut(s, zeroForOne, amountOut, type(uint256).max, trader);
        }
    }

    /// @dev fixed-point amount as a decimal string with `shown` decimals
    function fmt(uint256 amount, uint256 decimals, uint256 shown) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 frac = (amount % unit) * 10 ** shown / unit;
        string memory f = LibString.toString(frac);
        while (bytes(f).length < shown) f = string.concat("0", f);
        return string.concat(LibString.toString(amount / unit), ".", f);
    }
}
