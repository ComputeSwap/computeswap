// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ConcentratedCurveHook} from "../src/ConcentratedCurveHook.sol";
import {CurvePool} from "../src/libraries/CurvePool.sol";
import {ICurve} from "../src/interfaces/ICurve.sol";
import {HookFixture} from "./utils/HookFixture.sol";

/// @notice End-to-end behaviour of the hook running the log curve  (x + L/pb) * e^(y/L + ln pa) = L.
contract LogCurveHookTest is HookFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant WAD = 1e18;

    PoolKey internal logKey; // fee 0.3%, tick spacing 60, PoolManager price mirrored
    PoolId internal id;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;

    struct Pos {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    Pos[] internal book;

    function setUp() public {
        setUpHook();
        logKey = createPool(3000, 60, SQRT_PRICE_1_1, true);
        id = logKey.toId();
        alice = newLp("alice", 1e30);
        bob = newLp("bob", 1e30);
        carol = newLp("carol", 1e30);
        dave = newLp("dave", 1e30);
    }

    // ------------------------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------------------------

    function _add(address lp, int24 tickLower, int24 tickUpper, uint128 liquidity) internal returns (BalanceDelta d) {
        d = lpAdd(lp, logKey, tickLower, tickUpper, liquidity, bytes32(0));
        book.push(Pos(lp, tickLower, tickUpper, liquidity));
    }

    function _price() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,) = hook.getSlot0(id);
    }

    /// @dev Sum of L over positions whose range contains the current tick - what the pool must report as active.
    function _expectedActiveLiquidity() internal view returns (uint128 total) {
        (, int24 tick) = _price();
        for (uint256 i; i < book.length; ++i) {
            if (book[i].tickLower <= tick && tick < book[i].tickUpper) total += book[i].liquidity;
        }
    }

    /// @dev Closed form of a position at the current price, computed independently of LogCurveMath:
    ///      x = L * (1/Pc - 1/pb),  y = L * ln(Pc / pa),  Pc = clamp(P, pa, pb).
    function _closedForm(uint128 liquidity, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 x, uint256 y)
    {
        (uint160 s,) = _price();
        uint160 sa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(tickUpper);
        uint160 sc = s < sa ? sa : (s > sb ? sb : s);
        x = FullMath.mulDiv(FullMath.mulDiv(liquidity, Q96, sc), Q96, sc)
            - FullMath.mulDiv(FullMath.mulDiv(liquidity, Q96, sb), Q96, sb);
        int256 lnRatio = FixedPointMathLib.lnWad(int256(FullMath.mulDiv(sc, WAD, sa))); // ln(sc/sa) in wad
        y = FullMath.mulDiv(2 * uint256(liquidity), uint256(lnRatio), WAD);
    }

    function _assertPositionsFollowCurve() internal view {
        for (uint256 i; i < book.length; ++i) {
            Pos memory p = book[i];
            if (p.liquidity == 0) continue;
            (uint256 x, uint256 y,,) = hook.getPositionAmounts(id, p.owner, p.tickLower, p.tickUpper, bytes32(0));
            (uint256 cx, uint256 cy) = _closedForm(p.liquidity, p.tickLower, p.tickUpper);
            assertApproxEqAbs(x, cx, 4 + cx / 1e24, "x = L(1/P - 1/pb)");
            assertApproxEqAbs(y, cy, 4 + (uint256(p.liquidity) * 60) / 1e18, "y = L ln(P/pa)");
        }
    }

    /// @dev Solvency: the pool's reserves cover every position's principal (at the current price) plus its fees.
    function _assertSolvent() internal view {
        uint256 owed0;
        uint256 owed1;
        for (uint256 i; i < book.length; ++i) {
            Pos memory p = book[i];
            // a fully removed position has been paid its fees; a re-opened range has its own entry
            if (p.liquidity == 0) continue;
            (uint256 x, uint256 y, uint256 f0, uint256 f1) =
                hook.getPositionAmounts(id, p.owner, p.tickLower, p.tickUpper, bytes32(0));
            owed0 += x + f0;
            owed1 += y + f1;
        }
        (uint128 r0, uint128 r1) = hook.reserves(id);
        assertGe(r0, owed0, "reserve0 covers positions");
        assertGe(r1, owed1, "reserve1 covers positions");
    }

    function _principalTotals() internal view returns (uint256 total0, uint256 total1) {
        for (uint256 i; i < book.length; ++i) {
            Pos memory p = book[i];
            if (p.liquidity == 0) continue;
            (uint256 x, uint256 y,,) = hook.getPositionAmounts(id, p.owner, p.tickLower, p.tickUpper, bytes32(0));
            total0 += x;
            total1 += y;
        }
    }

    function _removeAll() internal {
        for (uint256 i; i < book.length; ++i) {
            Pos storage p = book[i];
            CurvePool.Position memory onchain = hook.getPosition(id, p.owner, p.tickLower, p.tickUpper, bytes32(0));
            if (onchain.liquidity == 0) continue;
            lpRemove(p.owner, logKey, p.tickLower, p.tickUpper, onchain.liquidity, bytes32(0));
            p.liquidity = 0;
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // the curve and its liquidity
    // ------------------------------------------------------------------------------------------------------------

    /// Deposits follow x = L(1/P - 1/pb), y = L ln(P/pa): at P = 1 on [-6000, 6000] that is
    /// x = L(1 - 1.0001^-6000) and y = 6000 * ln(1.0001) * L.
    function test_deposit_followsCurve() public {
        uint128 l = 1e21;
        BalanceDelta d = _add(alice, -6000, 6000, l);
        uint256 x = uint256(uint128(-d.amount0()));
        uint256 y = uint256(uint128(-d.amount1()));
        (uint256 cx, uint256 cy) = _closedForm(l, -6000, 6000);
        assertApproxEqAbs(x, cx, 4);
        assertApproxEqAbs(y, cy, 64 * uint256(l) / 1e18);
        // tick-exact form of the log side: ln(1/pa) = 6000 * ln(1.0001)
        assertApproxEqRel(y, uint256(l) * 6000 * 99995000333308 / 1e18, 1e6); // 1e-12 relative
        assertGe(x, cx, "deposit rounds up");
    }

    /// The user's trading function holds for a position at any price in its range:
    ///     (x + L/pb) * e^(y/L + ln pa) = L     <=>    (x/L + 1/pb) * e^(y/L) * pa = 1
    function test_invariant_userTradingFunction() public {
        uint128 l = 1e22;
        _add(alice, -6000, 6000, l);
        doSwap(logKey, true, -3e20);
        doSwap(logKey, false, 7e20);
        doSwap(logKey, true, 1e20);

        (uint256 x, uint256 y,,) = hook.getPositionAmounts(id, alice, -6000, 6000, bytes32(0));
        uint160 sa = TickMath.getSqrtPriceAtTick(-6000);
        uint160 sb = TickMath.getSqrtPriceAtTick(6000);
        uint256 invPb = FullMath.mulDiv(FullMath.mulDiv(WAD, Q96, sb), Q96, sb); // 1/pb in wad
        uint256 pa = FullMath.mulDiv(FullMath.mulDiv(WAD, sa, Q96), sa, Q96); // pa in wad
        uint256 a = x * WAD / l + invPb;
        uint256 b = uint256(FixedPointMathLib.expWad(int256(y * WAD / l)));
        uint256 k = FullMath.mulDiv(FullMath.mulDiv(a, b, WAD), pa, WAD);
        assertApproxEqRel(k, WAD, 1e9, "(x/L + 1/pb) e^(y/L) pa = 1"); // 1e-9
    }

    /// Two LPs on the same range are one position of size L_A + L_B: they pay, earn and withdraw pro rata.
    function test_sameRange_isProRata() public {
        BalanceDelta da = _add(alice, -6000, 6000, 1e21);
        BalanceDelta db = _add(bob, -6000, 6000, 3e21);
        assertApproxEqAbs(int256(db.amount0()), 3 * int256(da.amount0()), 3);
        assertApproxEqAbs(int256(db.amount1()), 3 * int256(da.amount1()), 3 + 3 * 64e3);
        assertEq(hook.getLiquidity(id), 4e21);

        doSwap(logKey, true, -2e20);
        doSwap(logKey, false, -5e20);
        doSwap(logKey, true, 1e20);
        _assertPositionsFollowCurve();

        (,, uint256 fa0, uint256 fa1) = hook.getPositionAmounts(id, alice, -6000, 6000, bytes32(0));
        (,, uint256 fb0, uint256 fb1) = hook.getPositionAmounts(id, bob, -6000, 6000, bytes32(0));
        assertGt(fa0, 0);
        assertGt(fa1, 0);
        assertApproxEqAbs(fb0, 3 * fa0, 3, "fees0 pro rata");
        assertApproxEqAbs(fb1, 3 * fa1, 3, "fees1 pro rata");

        BalanceDelta wa = lpRemove(alice, logKey, -6000, 6000, 1e21, bytes32(0));
        BalanceDelta wb = lpRemove(bob, logKey, -6000, 6000, 3e21, bytes32(0));
        assertApproxEqAbs(int256(wb.amount0()), 3 * int256(wa.amount0()), 6);
        assertApproxEqAbs(int256(wb.amount1()), 3 * int256(wa.amount1()), 6 + 3 * 64e3);
    }

    /// Overlapping and disjoint ranges: the active liquidity is always the sum of L over the ranges containing the
    /// price, and every position keeps following its own offset curve as swaps cross tick boundaries.
    function test_differentRanges_activeLiquidityTracksPrice() public {
        _add(alice, -6000, 6000, 1e21); // wide
        _add(carol, -600, 1200, 5e21); // narrow, around the price
        _add(dave, 1800, 4200, 2e21); // above the price: all currency0
        _add(bob, -4200, -1800, 3e21); // below the price: all currency1
        assertEq(hook.getLiquidity(id), 6e21);

        // push the price up through 1200 (carol leaves), 1800 (dave joins), 4200 (dave leaves).
        // currency1 needed: L_active * d(ln P) = 6e21*0.12 + 1e21*0.06 + 3e21*0.24 + ... per segment
        int256[3] memory upMoves = [int256(-8e20), -5e20, -3e20];
        for (uint256 i; i < upMoves.length; ++i) {
            doSwap(logKey, false, upMoves[i]);
            assertEq(hook.getLiquidity(id), _expectedActiveLiquidity(), "active L after up-move");
            _assertPositionsFollowCurve();
            _assertSolvent();
        }
        (, int24 tickUp) = _price();
        assertGt(tickUp, 4200, "crossed every upper range");

        // and back down through all of them into bob's range (currency0 needed: L_active * d(1/P) per segment)
        int256[5] memory downMoves = [int256(-4e20), -5e20, -6e20, -4e20, -5e20];
        for (uint256 i; i < downMoves.length; ++i) {
            doSwap(logKey, true, downMoves[i]);
            assertEq(hook.getLiquidity(id), _expectedActiveLiquidity(), "active L after down-move");
            _assertPositionsFollowCurve();
            _assertSolvent();
        }
        (, int24 tickDown) = _price();
        assertLt(tickDown, -1800, "entered bob's range");

        _removeAll();
        (uint128 r0, uint128 r1) = hook.reserves(id);
        assertLt(r0, 1e9, "only rounding dust is left");
        assertLt(r1, 1e9, "only rounding dust is left");
        assertEq(claimBalance(currency0), r0, "claims match reserves");
        assertEq(claimBalance(currency1), r1, "claims match reserves");
    }

    // ------------------------------------------------------------------------------------------------------------
    // swaps
    // ------------------------------------------------------------------------------------------------------------

    /// Inside one range: dx in  ->  dy_out = L ln(1 + P dx / L);  dy in  ->  dx_out = (L / P)(1 - e^(-dy / L))
    function test_swap_closedForms() public {
        PoolKey memory k0 = createPool(0, 60, SQRT_PRICE_1_1, false); // no fee
        uint128 l = 1e22;
        lpAdd(alice, k0, -6000, 6000, l, bytes32(0));

        // currency0 in at P = 1
        uint256 dx = 1e20;
        BalanceDelta d = doSwap(k0, true, -int256(dx));
        uint256 yOut = uint256(uint128(d.amount1()));
        uint256 expected = FullMath.mulDiv(l, uint256(FixedPointMathLib.lnWad(int256(WAD + dx * WAD / l))), WAD);
        assertLe(yOut, expected + 1, "never pays more than the curve");
        assertApproxEqRel(yOut, expected, 1e4, "L ln(1 + P dx / L)"); // 1e-14

        // currency1 in at the new price
        (uint160 s,,) = hook.getSlot0(k0.toId());
        uint256 dy = 3e20;
        d = doSwap(k0, false, -int256(dy));
        uint256 xOut = uint256(uint128(d.amount0()));
        uint256 lOverP = FullMath.mulDiv(FullMath.mulDiv(l, Q96, s), Q96, s);
        uint256 oneMinusExp = WAD - uint256(FixedPointMathLib.expWad(-int256(dy * WAD / l)));
        expected = FullMath.mulDiv(lOverP, oneMinusExp, WAD);
        assertApproxEqRel(xOut, expected, 1e4, "(L/P)(1 - e^(-dy/L))");
    }

    /// Exact output gives exactly what was asked, and costs at least what exact input would.
    function test_swap_exactOutput() public {
        _add(alice, -6000, 6000, 1e22);
        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        BalanceDelta d = doSwap(logKey, true, int256(5e19)); // want 5e19 currency1 out
        assertEq(d.amount1(), 5e19);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore, 5e19);
        uint256 paid = uint256(uint128(-d.amount0()));
        assertGt(paid, 5e19, "price ~1 plus fee");
        _assertSolvent();
    }

    /// No free lunch: a round trip through the pool (fee 0) cannot end with more than it started with.
    function test_swap_roundTripLoses() public {
        PoolKey memory k0 = createPool(0, 60, SQRT_PRICE_1_1, false);
        lpAdd(alice, k0, -887220, 887220, 1e22, bytes32(0));
        lpAdd(bob, k0, -600, 600, 5e22, bytes32(0));
        uint256 amountIn = 7e21;
        BalanceDelta out = doSwap(k0, true, -int256(amountIn));
        BalanceDelta back = doSwap(k0, false, -int256(out.amount1()));
        assertLe(uint256(uint128(back.amount0())), amountIn, "round trip gained currency0");
        // and the rounding kept by the pool is tiny: < 1e-15 of the trade
        assertApproxEqRel(uint256(uint128(back.amount0())), amountIn, 1e3);
    }

    /// A swap is filled completely or not at all (the PoolManager's price is not the curve's price, so a remainder
    /// cannot be handed back to it). A price limit therefore acts as a slippage bound.
    function test_swap_priceLimitReverts() public {
        _add(alice, -600, 600, 1e21);
        (uint160 s,) = _price();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e21, sqrtPriceLimitX96: s - s / 100});
        vm.expectRevert();
        swapRouter.swap(logKey, params, PoolSwapTest.TestSettings(false, false), ZERO_BYTES);

        // running out of liquidity also reverts instead of partially filling
        vm.expectRevert();
        doSwap(logKey, true, -1e30);
    }

    /// With mirroring on, the PoolManager's slot0 (read by quoters, UIs, oracles) tracks the curve price.
    function test_mirrorPrice() public {
        _add(alice, -6000, 6000, 1e22);
        doSwap(logKey, true, -4e20);
        (uint160 hookPrice, int24 hookTick) = _price();
        (uint160 pmPrice, int24 pmTick,,) = manager.getSlot0(id);
        assertEq(pmPrice, hookPrice);
        assertEq(pmTick, hookTick);
        doSwap(logKey, false, 9e20);
        (hookPrice,) = _price();
        (pmPrice,,,) = manager.getSlot0(id);
        assertEq(pmPrice, hookPrice);

        // without mirroring the PoolManager keeps its initial price
        PoolKey memory k2 = createPool(500, 10, SQRT_PRICE_1_1, false);
        lpAdd(alice, k2, -6000, 6000, 1e22, bytes32(0));
        doSwap(k2, true, -4e20);
        (pmPrice,,,) = manager.getSlot0(k2.toId());
        assertEq(pmPrice, SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // fees, native currency, isolation, access control
    // ------------------------------------------------------------------------------------------------------------

    /// Fees go only to in-range liquidity, pro rata to L, and are paid out on the next modification.
    function test_fees_onlyInRange() public {
        _add(alice, -600, 600, 1e21); // in range
        _add(dave, 1800, 4200, 1e21); // out of range
        doSwap(logKey, true, -1e19);
        doSwap(logKey, false, -1e19);
        (,, uint256 fa0, uint256 fa1) = hook.getPositionAmounts(id, alice, -600, 600, bytes32(0));
        (,, uint256 fd0, uint256 fd1) = hook.getPositionAmounts(id, dave, 1800, 4200, bytes32(0));
        assertApproxEqAbs(fa0, 3e16, 1, "0.3% of 1e19");
        assertApproxEqAbs(fa1, 3e16, 1);
        assertEq(fd0 + fd1, 0, "out-of-range liquidity earns nothing");

        // poke (remove 0) pays fees out
        uint256 before0 = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        BalanceDelta d = lpRemove(alice, logKey, -600, 600, 0, bytes32(0));
        assertEq(uint256(uint128(d.amount0())), fa0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(alice) - before0, fa0);
    }

    function test_nativeCurrency() public {
        PoolKey memory k = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 60, IHooks(address(hook)));
        hook.initializePool(k, SQRT_PRICE_1_1, true);
        vm.deal(alice, 100 ether);

        vm.prank(alice);
        (BalanceDelta d,) = hook.addLiquidity{value: 50 ether}(
            k,
            ConcentratedCurveHook.AddLiquidityParams(
                -6000, 6000, 1e19, type(uint256).max, type(uint256).max, bytes32(0), block.timestamp
            )
        );
        uint256 paid = uint256(uint128(-d.amount0()));
        assertEq(alice.balance, 100 ether - paid, "unused ETH refunded");

        // swap ETH in through the router
        swapRouter.swap{value: 1 ether}(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings(false, false),
            ZERO_BYTES
        );
        uint256 before = alice.balance;
        lpRemove(alice, k, -6000, 6000, 1e19, bytes32(0));
        assertGt(alice.balance - before, paid, "gets principal plus swapped-in ETH");
    }

    /// Each pool's balances are separate: a pool can never pay out another pool's tokens.
    function test_reservesAreIsolatedPerPool() public {
        PoolKey memory cp = createPool(500, 10, SQRT_PRICE_1_1, false); // a second log pool
        lpAdd(alice, cp, -600, 600, 1e21, bytes32(0));
        _add(bob, -600, 600, 1e21);
        (uint128 cp0, uint128 cp1) = hook.reserves(cp.toId());
        doSwap(logKey, true, -1e19);
        doSwap(logKey, false, 3e19);
        (uint128 cp0After, uint128 cp1After) = hook.reserves(cp.toId());
        assertEq(cp0After, cp0);
        assertEq(cp1After, cp1);
        (uint128 lg0, uint128 lg1) = hook.reserves(id);
        assertEq(claimBalance(currency0), uint256(cp0) + lg0);
        assertEq(claimBalance(currency1), uint256(cp1) + lg1);
    }

    /// Every pool of the hook runs the curve fixed at deployment: nobody can create a pool on a curve of their own.
    function test_curveFixedAtDeployment() public {
        assertEq(address(hook.curve()), address(logCurve));
        (ICurve bound,) = hook.poolConfig(id);
        assertEq(address(bound), address(logCurve));
        vm.expectRevert(ConcentratedCurveHook.InvalidCurve.selector);
        new ConcentratedCurveHook(manager, ICurve(makeAddr("not a curve")));
    }

    function test_accessControl() public {
        // pools can only be created through the hook
        PoolKey memory k = PoolKey(currency0, currency1, 100, 1, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        // liquidity cannot be added to the PoolManager's own curve
        _add(alice, -600, 600, 1e18);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(logKey, ModifyLiquidityParams(-600, 600, 1e18, 0), ZERO_BYTES);
        // callbacks are PoolManager-only
        vm.expectRevert(ConcentratedCurveHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), logKey, SwapParams(true, -1, MIN_PRICE_LIMIT), ZERO_BYTES);
        vm.expectRevert(ConcentratedCurveHook.NotPoolManager.selector);
        hook.unlockCallback("");
        // a logKey must name this hook, and a pool cannot be re-initialized (its curve is fixed)
        vm.expectRevert(ConcentratedCurveHook.WrongHook.selector);
        hook.initializePool(PoolKey(currency0, currency1, 100, 1, IHooks(address(0))), SQRT_PRICE_1_1, false);
        vm.expectRevert(CurvePool.PoolAlreadyInitialized.selector);
        hook.initializePool(logKey, SQRT_PRICE_1_1, false);
        // slippage bounds are enforced
        vm.prank(alice);
        vm.expectRevert(ConcentratedCurveHook.SlippageExceeded.selector);
        hook.addLiquidity(
            logKey, ConcentratedCurveHook.AddLiquidityParams(-600, 600, 1e18, 1, 1, bytes32(0), block.timestamp)
        );
    }

    /// getLiquidityForAmounts returns the largest L whose deposit fits the budget.
    function test_liquidityForAmounts() public {
        _add(alice, -6000, 6000, 1e21);
        doSwap(logKey, true, -1e20);
        uint256 budget0 = 3e20;
        uint256 budget1 = 2e20;
        uint128 l = hook.getLiquidityForAmounts(id, -1200, 2400, budget0, budget1);
        BalanceDelta d = lpAdd(bob, logKey, -1200, 2400, l, bytes32(0));
        uint256 used0 = uint256(uint128(-d.amount0()));
        uint256 used1 = uint256(uint128(-d.amount1()));
        assertLe(used0, budget0);
        assertLe(used1, budget1);
        // one of the two budgets is (almost) fully used
        assertTrue(used0 * 1e9 >= budget0 * (1e9 - 1) || used1 * 1e9 >= budget1 * (1e9 - 1), "budget used");
    }

    // ------------------------------------------------------------------------------------------------------------
    // invariants under random activity
    // ------------------------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_solvency(uint256 seed) public {
        address[4] memory lps = [alice, bob, carol, dave];
        _add(alice, -887220, 887220, 1e21); // backstop so every bounded swap fills

        for (uint256 i; i < 30; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 10;
            if (action < 3) {
                int24 lower = int24(int256((r >> 8) % 400) - 200) * 60;
                int24 width = int24(int256(1 + (r >> 20) % 100)) * 60;
                uint128 l = uint128(1e15 + (r >> 40) % 1e22);
                address lp = lps[(r >> 100) % 4];
                // one position per (owner, range) in the book: skip duplicates to keep bookkeeping simple
                if (hook.getPosition(id, lp, lower, lower + width, bytes32(0)).liquidity != 0) continue;
                _add(lp, lower, lower + width, l);
            } else if (action < 4 && book.length > 1) {
                Pos storage p = book[1 + (r >> 8) % (book.length - 1)];
                if (p.liquidity == 0) continue;
                uint128 amount = uint128(1 + (r >> 30) % p.liquidity);
                lpRemove(p.owner, logKey, p.tickLower, p.tickUpper, amount, bytes32(0));
                p.liquidity -= amount;
            } else {
                bool zeroForOne = (r >> 8) % 2 == 0;
                bool exactIn = (r >> 9) % 2 == 0;
                uint256 cap = 3e21;
                if (!exactIn) {
                    // an exact output must exist in the positions (the swap is all-or-nothing); reserves also
                    // hold fees, which swaps cannot release
                    (uint256 principal0, uint256 principal1) = _principalTotals();
                    cap = (zeroForOne ? principal1 : principal0) / 4;
                    if (cap > 3e20) cap = 3e20;
                    if (cap == 0) continue;
                }
                int256 amount = int256(1 + (r >> 16) % cap);
                doSwap(logKey, zeroForOne, exactIn ? -amount : amount);
            }
            assertEq(hook.getLiquidity(id), _expectedActiveLiquidity(), "active liquidity");
            _assertSolvent();
        }
        _assertPositionsFollowCurve();

        // everyone can leave; only dust remains and claims always equal reserves
        _removeAll();
        (uint128 r0, uint128 r1) = hook.reserves(id);
        assertLt(r0, 1e9);
        assertLt(r1, 1e9);
        assertEq(claimBalance(currency0), r0);
        assertEq(claimBalance(currency1), r1);
    }
}
