// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";
import {AquaApp} from "@1inch/aqua/AquaApp.sol";
import {IXYCSwapCallback} from "@1inch/aqua-examples/apps/interfaces/IXYCSwapCallback.sol";
import {TransientLockLib} from "@1inch/solidity-utils/contracts/libraries/TransientLock.sol";

import {ComputeswapAquaApp} from "../../src/aqua/ComputeswapAquaApp.sol";
import {AquaFixture} from "./AquaFixture.sol";

/// @dev A taker that does not push the input
contract FreeloadingTaker is IXYCSwapCallback {
    function take(ComputeswapAquaApp app, ComputeswapAquaApp.Strategy calldata s, uint256 amountIn) external {
        app.swapExactIn(s, true, amountIn, 0, address(this), "");
    }

    function xycSwapCallback(address, address, uint256, uint256, address, address, bytes32, bytes calldata)
        external
        pure {}
}

/// @dev A taker that tries to swap again from inside the callback (a nested pull would inflate the balance check)
contract ReenteringTaker is IXYCSwapCallback {
    ComputeswapAquaApp.Strategy internal s;

    function take(ComputeswapAquaApp app, ComputeswapAquaApp.Strategy calldata strategy, uint256 amountIn) external {
        s = strategy;
        app.swapExactIn(strategy, true, amountIn, 0, address(this), "");
    }

    function xycSwapCallback(address, address, uint256 amountIn, uint256, address, address app, bytes32, bytes calldata)
        external
    {
        ComputeswapAquaApp(app).swapExactIn(s, true, amountIn, 0, address(this), "");
    }
}

/// @notice The Computeswap trading function as an Aqua app, on the Aqua-native path: a maker ships a position from
///         their own wallet, takers fill it, the maker docks. No vault, no weights.
/// @dev forge test --match-contract AquaAppTest -vv
contract AquaAppTest is AquaFixture {
    address internal alice = makeAddr("alice"); // maker
    address internal trader = makeAddr("trader");

    int24 internal lower;
    int24 internal upper;
    uint128 internal liquidity;
    ComputeswapAquaApp.Strategy internal s;

    function setUp() public {
        setUpAqua();
        fund(alice, 1_000 ether, 1_000_000e6);
        fund(trader, 1_000 ether, 1_000_000e6);
        lower = tickAt(0.5e18);
        upper = tickAt(2e18);
        liquidity = liquidityForValue(lower, upper, 100e6, 1e18); // $100 on [0.5, 2] at ETH = $1
        s = strategyFor(alice, lower, upper, liquidity, 1e18, bytes32(0));
        shipAs(alice, s);
    }

    /// The shipped balances are the position's reserves: x = L(1/P - 1/pb), y = L ln(P/pa). This is the $100 range-2
    /// position of the README: 41.90 ETH + 58.10 USDC.
    function test_openingAmountsFollowTheCurve() public view {
        (uint256 b0, uint256 b1) = balancesOf(s);
        uint256 p = 1e18;
        uint256 pb = priceAtTickWad(upper);
        uint256 pa = priceAtTickWad(lower);
        // x in wei: L (USDC units) * (1/P - 1/pb) with prices in USDC per ETH -> * 1e18 / 1e6 ... = L * 1e12 * (1e18/p - 1e18/pb) / 1e18
        uint256 x = uint256(liquidity) * 1e12 * (1e36 / p - 1e36 / pb) / 1e18;
        uint256 y = FullMath.mulDiv(liquidity, uint256(FixedPointMathLib.lnWad(int256(p * WAD / pa))), WAD);
        assertApproxEqRel(b0, x, 1e12, "ETH weight");
        assertApproxEqRel(b1, y, 1e12, "USDC weight");
        assertApproxEqAbs(b0, 41.9 ether, 0.01 ether);
        assertApproxEqAbs(b1, 58.1e6, 0.01e6);
        assertEq(weth.balanceOf(alice), 1_000 ether, "shipping moves no tokens");
        console2.log(string.concat("shipped ", fmt(b0, 18, 4), " ETH + ", fmt(b1, 6, 4), " USDC as virtual balances"));
    }

    /// Selling ETH into the position pays L ln(1 + P dx (1 - fee) / L) of USDC, straight from the maker's wallet;
    /// the ETH (fee included) lands in the maker's wallet and the strategy's balance.
    function test_swapExactIn_closedForm() public {
        uint256 dx = 1 ether;
        uint256 aliceUsdc = usdc.balanceOf(alice);
        (uint256 b0, uint256 b1) = balancesOf(s);

        uint256 quoted = app.quoteExactIn(s, true, dx);
        (, uint256 out) = swapAs(trader, s, true, -int256(dx));
        assertEq(out, quoted, "the quote is the execution");
        _checkClosedFormOut(dx, out);

        assertEq(usdc.balanceOf(trader), 1_000_000e6 + out, "trader receives the USDC");
        assertEq(aliceUsdc - usdc.balanceOf(alice), out, "paid out of the maker's wallet");
        assertEq(weth.balanceOf(alice), 1_000 ether + dx, "the ETH, fee included, lands in the maker's wallet");
        (uint256 a0, uint256 a1) = balancesOf(s);
        assertEq(a0, b0 + dx);
        assertEq(a1, b1 - out);
        _checkFees(dx);
        console2.log(string.concat("sell 1 ETH -> ", fmt(out, 6, 4), " USDC"));
    }

    function _checkClosedFormOut(uint256 dx, uint256 out) internal view {
        // P = 1 USDC/ETH = 1e-12 in raw units; dx in wei; L in USDC units
        uint256 dxNet = dx * (1e6 - FEE) / 1e6;
        int256 arg = int256(WAD + FullMath.mulDiv(dxNet, 1e6 * WAD, uint256(liquidity) * 1e18));
        uint256 expected = FullMath.mulDiv(liquidity, uint256(FixedPointMathLib.lnWad(arg)), WAD);
        assertLe(out, expected + 1, "never pays more than the curve");
        assertApproxEqRel(out, expected, 1e8, "L ln(1 + P dx / L)");
    }

    function _checkFees(uint256 dx) internal view {
        (uint256 fees0, uint256 fees1) = app.fees(s);
        assertApproxEqAbs(fees0, dx * FEE / 1e6, 2, "the fee is the balance beyond the principal");
        assertEq(fees1, 0);
    }

    /// Buying ETH with USDC pays (L/P)(1 - e^(-dy (1 - fee) / L)) of ETH.
    function test_swapUsdcIn_closedForm() public {
        uint256 dy = 3e6;
        (uint160 sqrtP,) = app.currentSqrtPrice(s);
        uint256 quoted = app.quoteExactIn(s, false, dy);
        (, uint256 out) = swapAs(trader, s, false, -int256(dy));
        assertEq(out, quoted);
        uint256 dyNet = dy * (1e6 - FEE) / 1e6;
        uint256 lOverP = FullMath.mulDiv(FullMath.mulDiv(liquidity, Q96, sqrtP), Q96, sqrtP);
        uint256 oneMinusExp = WAD - uint256(FixedPointMathLib.expWad(-int256(dyNet * WAD / liquidity)));
        uint256 expected = FullMath.mulDiv(lOverP, oneMinusExp, WAD);
        assertLe(out, expected + 1);
        assertApproxEqRel(out, expected, 1e8, "(L/P)(1 - e^(-dy/L))");
    }

    /// Exact output in both directions: exactly the amount asked, costing at least the exact-input price.
    function test_swapExactOut() public {
        uint256 want = 5e6;
        uint256 quotedIn = app.quoteExactOut(s, true, want);
        uint256 traderUsdc = usdc.balanceOf(trader);
        uint256 traderWeth = weth.balanceOf(trader);
        (uint256 paid, uint256 got) = swapAs(trader, s, true, int256(want));
        assertEq(got, want);
        assertEq(paid, quotedIn);
        assertEq(usdc.balanceOf(trader) - traderUsdc, want);
        assertEq(traderWeth - weth.balanceOf(trader), paid);
        assertGt(paid, want * 1e12, "~1 ETH per USDC plus fee and impact");

        uint256 wantEth = 2 ether;
        (paid, got) = swapAs(trader, s, false, int256(wantEth));
        assertEq(got, wantEth);
        // the first trade pushed the price below $1, so 2 ETH cost a little less than 2 USDC
        assertGt(paid, 1.85e6);
        assertLt(paid, 2e6);
    }

    /// The router wraps ETH for takers who pay in ETH, and refunds the unused part of an exact-output cap.
    function test_routerTakesNativeEth() public {
        address eve = makeAddr("eve");
        vm.deal(eve, 10 ether);
        vm.prank(eve);
        uint256 out = router.swapExactIn{value: 1 ether}(s, true, 1 ether, 0, eve);
        assertGt(out, 0);
        assertEq(eve.balance, 9 ether);
        assertEq(usdc.balanceOf(eve), out);

        vm.prank(eve);
        uint256 paid = router.swapExactOut{value: 3 ether}(s, true, 1e6, 3 ether, eve);
        assertLt(paid, 3 ether);
        assertEq(eve.balance, 9 ether - paid, "the unused cap comes back as ETH");
        assertEq(weth.balanceOf(address(router)), 0, "the router keeps nothing");
    }

    /// A swap the range cannot fill reverts: the position holds ~58 USDC, so it cannot pay 100 USDC.
    function test_allOrNothing() public {
        vm.prank(trader);
        vm.expectRevert(); // InsufficientLiquidity(filled, requested)
        router.swapExactIn(s, true, 1_000 ether, 0, trader);

        vm.prank(trader);
        vm.expectRevert();
        router.swapExactOut(s, true, 100e6, type(uint256).max, trader);

        // drain the USDC: the price lands on pa and the position is all ETH (a unit of rounding dust may stay)
        (, uint256 y) = app.amountsForLiquidity(s, liquidity, false);
        (uint256 paid,) = swapAs(trader, s, true, int256(y));
        assertGt(paid, 0);
        (, uint256 left) = balancesOf(s);
        assertLe(left, 2, "all USDC sold");
        assertApproxEqRel(priceWadOf(s), priceAtTickWad(lower), 1e12, "price at the floor of the range");
        // nothing more can be sold into it, but ETH can be bought back out of it
        vm.prank(trader);
        vm.expectRevert();
        router.swapExactIn(s, true, 1, 0, trader);
        (, uint256 ethOut) = swapAs(trader, s, false, -int256(1e6));
        assertGt(ethOut, 0);
    }

    /// No free lunch: a round trip cannot end with more than it started with (fees make it strictly worse).
    function test_roundTripLoses() public {
        uint256 amountIn = 7 ether;
        (, uint256 out) = swapAs(trader, s, true, -int256(amountIn));
        (, uint256 back) = swapAs(trader, s, false, -int256(out));
        assertLt(back, amountIn);
        assertGt(back, amountIn * 99 / 100, "two 0.3% fees and a small impact");
    }

    /// The maker's Aqua balances never fall below the position's principal on the curve.
    function test_balancesCoverPrincipal() public {
        int256[6] memory trades = [int256(-10 ether), 25e6, -30e6, 5 ether, -20 ether, 15 ether];
        bool[6] memory dirs = [true, true, false, false, true, false];
        for (uint256 i; i < 6; ++i) {
            swapAs(trader, s, dirs[i], trades[i]);
            (uint256 b0, uint256 b1) = balancesOf(s);
            (uint256 p0, uint256 p1) = app.amountsForLiquidity(s, liquidity, true);
            assertGe(b0, p0, "ETH balance covers the principal");
            assertGe(b1, p1, "USDC balance covers the principal");
        }
        (uint256 f0, uint256 f1) = app.fees(s);
        assertGt(f0, 0);
        assertGt(f1, 0);
    }

    /// Docking ends the strategy: nothing moves (the tokens were in alice's wallet all along) and swaps revert.
    function test_dockStopsSwaps() public {
        swapAs(trader, s, true, -1 ether);
        uint256 w = weth.balanceOf(alice);
        uint256 u = usdc.balanceOf(alice);
        dockAs(alice, s);
        assertEq(weth.balanceOf(alice), w);
        assertEq(usdc.balanceOf(alice), u);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAqua.SafeBalancesForTokenNotInActiveStrategy.selector,
                alice,
                address(app),
                keccak256(abi.encode(s)),
                address(weth)
            )
        );
        router.swapExactIn(s, true, 1 ether, 0, trader);
        // the same strategy can never be shipped again (Aqua's immutability), a new salt can
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(weth), address(usdc));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAqua.StrategiesMustBeImmutable.selector, address(app), keccak256(abi.encode(s)))
        );
        aqua.ship(address(app), abi.encode(s), tokens, new uint256[](2));
        ComputeswapAquaApp.Strategy memory s2 = strategyFor(alice, lower, upper, liquidity, 1e18, bytes32(uint256(1)));
        shipAs(alice, s2);
        swapAs(trader, s2, true, -1 ether);
    }

    /// A strategy that was never shipped, or whose parameters are inconsistent, cannot be traded.
    function test_rejectsUnshippedAndInvalid() public {
        ComputeswapAquaApp.Strategy memory ghost =
            strategyFor(alice, lower, upper, liquidity, 1e18, bytes32(uint256(7)));
        vm.prank(trader);
        vm.expectRevert();
        router.swapExactIn(ghost, true, 1 ether, 0, trader);

        ComputeswapAquaApp.Strategy memory bad = strategyFor(alice, lower, upper, liquidity, 3e18, bytes32(uint256(8)));
        vm.expectRevert(ComputeswapAquaApp.InvalidStrategy.selector);
        app.openingAmounts(bad); // opening price outside the range
        bad = strategyFor(alice, upper, lower, liquidity, 1e18, bytes32(uint256(9)));
        vm.expectRevert(ComputeswapAquaApp.InvalidStrategy.selector);
        app.openingAmounts(bad);
    }

    /// A taker that takes the output and does not push the input is caught by the post-callback balance check.
    function test_takerMustPush() public {
        FreeloadingTaker thief = new FreeloadingTaker();
        vm.expectRevert(
            abi.encodeWithSelector(
                AquaApp.MissingTakerAquaPush.selector, address(weth), balance0(), balance0() + 1 ether
            )
        );
        thief.take(app, s, 1 ether);
    }

    /// A nested swap from inside the callback is blocked by the per-strategy transient lock.
    function test_noReentrancy() public {
        ReenteringTaker attacker = new ReenteringTaker();
        vm.expectRevert(TransientLockLib.UnexpectedLock.selector);
        attacker.take(app, s, 1 ether);
    }

    /// The moving-average tick behaves like the hook's: a move in the same block does not enter it, and it converges
    /// to a held price with time constant 10 minutes.
    function test_oracle() public {
        (int24 tick0, int24 ema0) = app.getOracle(s);
        assertEq(tick0, ema0, "starts at the opening tick");
        swapAs(trader, s, true, -20 ether); // a ~20% move
        (int24 tick1, int24 ema1) = app.getOracle(s);
        assertLt(tick1, tick0 - 1000);
        assertEq(ema1, ema0, "same block: the average has not moved");
        vm.warp(block.timestamp + 10 minutes);
        (, int24 ema2) = app.getOracle(s);
        int256 expected = int256(tick1) + (int256(tick0) - int256(tick1)) * 367879 / 1000000; // e^-1
        assertApproxEqAbs(ema2, expected, 2, "one time constant later: 63% of the way");
        vm.warp(block.timestamp + 2 hours);
        (, int24 ema3) = app.getOracle(s);
        assertApproxEqAbs(ema3, tick1, 1, "fully converged");
    }

    /// Different makers, same parameters: different strategies, each priced on its own.
    function test_strategiesAreIndependent() public {
        address bob = makeAddr("bob");
        fund(bob, 1_000 ether, 1_000_000e6);
        ComputeswapAquaApp.Strategy memory sb = strategyFor(bob, lower, upper, liquidity, 1e18, bytes32(0));
        shipAs(bob, sb);
        swapAs(trader, s, true, -10 ether);
        assertLt(priceWadOf(s), 0.95e18);
        assertEq(priceWadOf(sb), priceWadOf(strategyFor(bob, lower, upper, liquidity, 1e18, bytes32(0))));
        assertApproxEqRel(priceWadOf(sb), 1e18, 1e12, "bob's position is untouched");
        // an arbitrageur buys cheap ETH from alice's strategy and sells it to bob's
        (, uint256 eth) = swapAs(trader, s, false, -int256(5e6));
        (, uint256 back) = swapAs(trader, sb, true, -int256(eth));
        assertGt(back, 5e6, "the price gap is worth more than two fees");
    }

    /// Gas of a warm swap, through the router and straight from a taker contract.
    function test_gasProfile() public {
        swapAs(trader, s, true, -1 ether); // warm the storage
        vm.prank(trader);
        uint256 g = gasleft();
        router.swapExactIn(s, true, 1 ether, 0, trader);
        uint256 viaRouter = g - gasleft();
        vm.prank(trader);
        g = gasleft();
        router.swapExactOut(s, false, 0.5 ether, type(uint256).max, trader);
        uint256 exactOut = g - gasleft();
        console2.log("swapExactIn via router (warm):", viaRouter);
        console2.log("swapExactOut via router (warm):", exactOut);
    }

    function balance0() internal view returns (uint256 b0) {
        (b0,) = balancesOf(s);
    }
}
