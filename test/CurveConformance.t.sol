// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ICurve} from "../src/interfaces/ICurve.sol";
import {LogCurve} from "../src/curves/LogCurve.sol";

/// @notice Properties every ICurve must satisfy before it is bound to a pool. Inherit, return your curve, and set
///         tolerances. Each check is a necessary consequence of rules R1-R5 in ICurve (the exact, high-precision
///         verification of LogCurve lives in python/check_curve.py).
abstract contract CurveConformance is Test {
    ICurve internal curve;

    /// @dev largest |tick| the fuzzer uses (keeps amounts inside uint256 for the curve)
    function maxAbsTick() internal pure virtual returns (int24);
    /// @dev allowed gap between roundUp and roundDown results
    function roundingGap(uint256 amount, uint128 liquidity) internal pure virtual returns (uint256);

    function _price(int256 tickSeed) internal pure virtual returns (uint160) {
        int24 m = maxAbsTick();
        int24 tick = int24(bound(tickSeed, -int256(m), int256(m)));
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function _sortedPrices(int256 seedA, int256 seedB) internal pure returns (uint160 a, uint160 b) {
        a = _price(seedA);
        b = _price(seedB);
        if (a > b) (a, b) = (b, a);
    }

    function _liquidity(uint256 seed) internal pure returns (uint128) {
        return uint128(bound(seed, 1, uint256(1) << 110));
    }

    // R1: roundUp >= roundDown, and they are close
    function testFuzz_amountRounding(int256 sa, int256 sb, uint256 sl) public view {
        (uint160 a, uint160 b) = _sortedPrices(sa, sb);
        uint128 l = _liquidity(sl);
        uint256 up0 = curve.getAmount0Delta(a, b, l, true);
        uint256 down0 = curve.getAmount0Delta(a, b, l, false);
        uint256 up1 = curve.getAmount1Delta(a, b, l, true);
        uint256 down1 = curve.getAmount1Delta(a, b, l, false);
        assertGe(up0, down0);
        assertGe(up1, down1);
        assertLe(up0 - down0, roundingGap(up0, l), "amount0 rounding gap");
        assertLe(up1 - down1, roundingGap(up1, l), "amount1 rounding gap");
        // argument order does not matter
        assertEq(curve.getAmount0Delta(b, a, l, true), up0);
        assertEq(curve.getAmount1Delta(b, a, l, false), down1);
    }

    // amounts over [a, c] are consistent with the sum over [a, b] + [b, c] (the curve is path independent)
    function testFuzz_amountAdditive(int256 sa, int256 sb, int256 sc, uint256 sl) public view {
        uint160[3] memory p = [_price(sa), _price(sb), _price(sc)];
        if (p[0] > p[1]) (p[0], p[1]) = (p[1], p[0]);
        if (p[1] > p[2]) (p[1], p[2]) = (p[2], p[1]);
        if (p[0] > p[1]) (p[0], p[1]) = (p[1], p[0]);
        uint128 l = _liquidity(sl);
        assertLe(
            curve.getAmount0Delta(p[0], p[2], l, false),
            curve.getAmount0Delta(p[0], p[1], l, true) + curve.getAmount0Delta(p[1], p[2], l, true)
        );
        assertGe(
            curve.getAmount0Delta(p[0], p[2], l, true),
            curve.getAmount0Delta(p[0], p[1], l, false) + curve.getAmount0Delta(p[1], p[2], l, false)
        );
        assertLe(
            curve.getAmount1Delta(p[0], p[2], l, false),
            curve.getAmount1Delta(p[0], p[1], l, true) + curve.getAmount1Delta(p[1], p[2], l, true)
        );
        assertGe(
            curve.getAmount1Delta(p[0], p[2], l, true),
            curve.getAmount1Delta(p[0], p[1], l, false) + curve.getAmount1Delta(p[1], p[2], l, false)
        );
    }

    // amounts grow with liquidity and with the width of the range
    function testFuzz_amountMonotonic(int256 sa, int256 sb, int256 sc, uint256 sl, uint256 sl2) public view {
        (uint160 a, uint160 b) = _sortedPrices(sa, sb);
        uint160 c = _price(sc);
        if (c < b) c = b;
        uint128 l = _liquidity(sl);
        uint128 l2 = uint128(bound(sl2, l, uint256(1) << 110));
        assertLe(curve.getAmount0Delta(a, b, l, false), curve.getAmount0Delta(a, c, l2, false));
        assertLe(curve.getAmount1Delta(a, b, l, false), curve.getAmount1Delta(a, c, l2, false));
    }

    // R2: currency0 in -> price falls, and no further than the input pays for
    function testFuzz_nextPrice0_add(int256 ss, uint256 sl, uint256 samt) public view {
        uint160 s = _price(ss);
        uint128 l = _liquidity(sl);
        // stay inside what the curve can absorb down to its minimum price
        uint256 capacity = curve.getAmount0Delta(_price(type(int256).min), s, l, false);
        vm.assume(capacity > 2);
        uint256 amount = bound(samt, 1, capacity / 2 < uint256(1) << 120 ? capacity / 2 : uint256(1) << 120);
        uint160 next = curve.getNextSqrtPriceFromAmount0(s, l, amount, true);
        assertLe(next, s, "price must not rise");
        assertLe(curve.getAmount0Delta(next, s, l, false), amount, "moved further than paid for");
    }

    // R3: currency0 out -> price rises at least far enough to release the output
    function testFuzz_nextPrice0_remove(int256 ss, uint256 sl, uint256 samt) public view {
        uint160 s = _price(ss);
        uint128 l = _liquidity(sl);
        // stay well inside what the curve holds up to its maximum price
        uint256 available = curve.getAmount0Delta(s, _price(type(int256).max), l, false);
        vm.assume(available > 2);
        uint256 amount = bound(samt, 1, available / 2);
        uint160 next = curve.getNextSqrtPriceFromAmount0(s, l, amount, false);
        assertGe(next, s, "price must not fall");
        assertGe(curve.getAmount0Delta(s, next, l, true), amount, "did not move far enough");
    }

    // R4: currency1 in -> price rises, and no further than the input pays for
    function testFuzz_nextPrice1_add(int256 ss, uint256 sl, uint256 samt) public view {
        uint160 s = _price(ss);
        uint128 l = _liquidity(sl);
        uint256 available = curve.getAmount1Delta(s, _price(type(int256).max), l, false);
        vm.assume(available > 2);
        uint256 amount = bound(samt, 1, available / 2);
        uint160 next = curve.getNextSqrtPriceFromAmount1(s, l, amount, true);
        assertGe(next, s, "price must not fall");
        assertLe(curve.getAmount1Delta(s, next, l, false), amount, "moved further than paid for");
    }

    // R5: currency1 out -> price falls at least far enough to release the output
    function testFuzz_nextPrice1_remove(int256 ss, uint256 sl, uint256 samt) public view {
        uint160 s = _price(ss);
        uint128 l = _liquidity(sl);
        uint256 available = curve.getAmount1Delta(_price(type(int256).min), s, l, false);
        vm.assume(available > 2);
        uint256 amount = bound(samt, 1, available / 2);
        uint160 next = curve.getNextSqrtPriceFromAmount1(s, l, amount, false);
        assertLe(next, s, "price must not rise");
        assertGe(curve.getAmount1Delta(next, s, l, true), amount, "did not move far enough");
    }
}

contract LogCurveConformanceTest is CurveConformance {
    function setUp() public {
        curve = new LogCurve();
    }

    /// @dev x = L / P grows like e^(|tick| * 1e-4); +-600000 ticks keeps L / P far inside uint256 for L < 2^110
    function maxAbsTick() internal pure override returns (int24) {
        return 600000;
    }

    /// @dev currency0: a few wei plus 2^-60 relative; currency1: the ln allowance 2L * 16e-18 plus 1 wei
    function roundingGap(uint256 amount, uint128 liquidity) internal pure override returns (uint256) {
        return 4 + (amount >> 60) + (uint256(liquidity) * 32) / 1e18 + 1;
    }
}
