// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {UnsafeMath} from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LogCurveMath - the trading function (x + L/pb) * e^(y/L + ln pa) = L
/// @notice Unit form (L = 1):  (x + 1/pb) * e^(y + 1 + ln pa) = e,  i.e.  y = ln(1 / (x + 1/pb)) - ln(pa).
///         In price space (P = currency1 per currency0):
///             unit reserves      xu(P) = 1/P,              yu(P) = ln P
///             position [pa,pb]   x(P)  = L * (1/P - 1/pb), y(P)  = L * ln(P / pa)
///         Inside one liquidity range swaps have closed forms:
///             currency0 in (dx):  1/P' = 1/P + dx/L    ->  dy_out = L * ln(1 + P * dx / L)
///             currency1 in (dy):  ln P' = ln P + dy/L  ->  dx_out = (L / P) * (1 - e^(-dy / L))
///         L is denominated in currency1: the currency1 a range absorbs per unit of ln(P), so every 1% price move
///         inside a range trades ~0.01 * L of value, at any price level.
///
///         Precision: the currency0 side is rational and computed to Q96 precision with directed rounding. The
///         currency1 side needs ln/exp (solady lnWad/expWad, ~1e-18 accurate). Each such result is widened by an
///         allowance of ~4x the worst error measured in python/check_math_bounds.py, so rounding always favours
///         the pool. This costs traders about L * 1e-17 of currency1 per swap step.
library LogCurveMath {
    using SafeCast for uint256;

    error InvalidPrice();
    error InvalidPriceOrLiquidity();
    error NotEnoughLiquidity();

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant WAD = 1e18;

    /// @dev Allowance per lnWad call, in wad units. Measured worst case: 1.05.
    int256 internal constant LN_ERR = 4;
    /// @dev Allowance per expWad call: (g >> EXP_REL_SHIFT) + EXP_ABS_ERR. Measured: |error| <= 1 wad unit for
    ///      outputs up to 100 WAD, and relative error <= 2^-65 above that.
    uint256 internal constant EXP_REL_SHIFT = 60;
    uint256 internal constant EXP_ABS_ERR = 4;
    /// @dev Exponents (amount / 2L) beyond which the sqrt price leaves the uint160 range in either direction:
    ///      e^120 > 2^172 and 2^160 * e^-90 < 2^31 < MIN_SQRT_PRICE.
    uint256 internal constant SATURATE_UP = 120;
    uint256 internal constant SATURATE_DOWN = 90;

    /// @notice L * (1/Pa - 1/Pb) = L * 2^192 * (b - a)(b + a) / (a^2 * b^2), with a, b the sqrt prices
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceAX96 == 0) revert InvalidPrice();
        if (liquidity == 0 || sqrtPriceAX96 == sqrtPriceBX96) return 0;

        uint256 a = sqrtPriceAX96;
        uint256 b = sqrtPriceBX96;
        // t = L * 2^96 * (b^2 - a^2) / b^2  (< 2^225)
        uint256 t = _mulDiv(uint256(liquidity) << 96, b - a, b, roundUp);
        t = _mulDiv(t, a + b, b, roundUp);
        // amount0 = t * 2^96 / a^2
        if (a <= type(uint128).max) {
            amount0 = _mulDiv(t, Q96, a * a, roundUp);
        } else {
            t = _mulDiv(t, Q96, a, roundUp);
            amount0 = roundUp ? UnsafeMath.divRoundingUp(t, a) : t / a;
        }
    }

    /// @notice L * ln(Pb / Pa) = 2L * ln(b / a)
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceAX96 == 0) revert InvalidPrice();
        if (liquidity == 0 || sqrtPriceAX96 == sqrtPriceBX96) return 0;

        // lnWad(v) = ln(v / 1e18) in wad, so the difference is ln(b / a) in wad. lnWad is monotonic, so it is >= 0.
        int256 lnRatio = FixedPointMathLib.lnWad(int256(uint256(sqrtPriceBX96)))
            - FixedPointMathLib.lnWad(int256(uint256(sqrtPriceAX96)));
        uint256 twoL = uint256(liquidity) << 1;
        if (roundUp) return FullMath.mulDivRoundingUp(twoL, uint256(lnRatio + 2 * LN_ERR), WAD);
        lnRatio -= 2 * LN_ERR;
        return lnRatio <= 0 ? 0 : FullMath.mulDiv(twoL, uint256(lnRatio), WAD);
    }

    /// @notice Price after adding/removing currency0: 1/P' = 1/P +- amount/L, i.e. s' = s * sqrt(ratio) with
    ///             ratio = L / (L +- amount * P) = X / (X +- amount),   X = L / P (the virtual currency0 reserve).
    ///         Always rounds the price up (R2, R3).
    /// @dev The ratio is formed from whichever pair holds the larger integers - (X, amount) in currency0 when P <= 1,
    ///      (L, amount * P) in currency1 when P > 1 - so rounding them to whole units costs less than one wei.
    function getNextSqrtPriceFromAmount0(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (amount == 0) return sqrtPX96;
        if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        uint256 s = sqrtPX96;

        // price up <=> ratio up: round X up / value down when adding, X down / value up when removing
        uint256 num;
        uint256 den;
        if (s <= Q96) {
            // X = L * 2^192 / s^2 >= L
            num = add ? FullMath.mulDivRoundingUp(liquidity, Q192, s * s) : FullMath.mulDiv(liquidity, Q192, s * s);
            if (add) {
                den = num + amount;
            } else {
                if (amount >= num) revert NotEnoughLiquidity();
                den = num - amount;
            }
        } else {
            num = liquidity;
            uint256 value = _valueOf(amount, s, !add);
            if (add) {
                den = num + value;
            } else {
                if (value >= num) revert NotEnoughLiquidity();
                den = num - value;
            }
        }
        uint256 next = _mulSqrtRatioUp(s, num, den);
        // adding moves the price down; rounding up can at most leave it where it was
        if (add && next > s) next = s;
        return next.toUint160();
    }

    /// @notice Price after adding/removing currency1: ln P' = ln P +- amount/L, i.e. s' = s * e^(+-amount / 2L).
    ///         Always rounds the price down (R4, R5). Saturates at type(uint160).max (adding) or 0 (removing) when
    ///         the move leaves the representable range; callers clamp to their target price.
    function getNextSqrtPriceFromAmount1(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (amount == 0) return sqrtPX96;
        if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        uint256 twoL = uint256(liquidity) << 1;

        if (add) {
            if (amount / twoL >= SATURATE_UP) return type(uint160).max;
            // round the exponent and exp() down
            uint256 g = _expDown(int256(FullMath.mulDiv(amount, WAD, twoL)));
            if (g > FullMath.mulDiv(type(uint160).max, WAD, sqrtPX96)) return type(uint160).max;
            uint256 next = FullMath.mulDiv(sqrtPX96, g, WAD);
            // the allowance can push a dust-sized move below the start; the price never moves backwards
            return next < sqrtPX96 ? sqrtPX96 : uint160(next);
        } else {
            if (amount / twoL >= SATURATE_DOWN) return 0;
            // s / e^z with the exponent and exp() rounded up: keeps full relative precision for large moves
            uint256 g = _expUp(FullMath.mulDivRoundingUp(amount, WAD, twoL));
            return uint160(FullMath.mulDiv(sqrtPX96, WAD, g)); // g >= WAD, so <= sqrtPX96
        }
    }

    /// @dev expWad(z) minus its error allowance, floored at zero: a lower bound on e^z in wad.
    function _expDown(int256 z) private pure returns (uint256 g) {
        g = uint256(FixedPointMathLib.expWad(z));
        uint256 err = (g >> EXP_REL_SHIFT) + EXP_ABS_ERR;
        g = g > err ? g - err : 0;
    }

    /// @dev expWad(z) plus its error allowance: an upper bound on e^z in wad (z >= 0).
    function _expUp(uint256 z) private pure returns (uint256 g) {
        g = uint256(FixedPointMathLib.expWad(int256(z)));
        g += (g >> EXP_REL_SHIFT) + EXP_ABS_ERR;
    }

    /// @dev amount * P = amount * s^2 / 2^192 in currency1, with a single rounding (s > 2^96 here).
    function _valueOf(uint256 amount, uint256 s, bool roundUp) private pure returns (uint256) {
        if (s <= type(uint128).max) return _mulDiv(amount, s * s, Q192, roundUp);
        // s^2 does not fit: pre-scale by 2^32, which costs < 2^-96 relative precision for s > 2^128
        return _mulDiv(_mulDiv(amount, s, 1 << 32, roundUp), s, 1 << 160, roundUp);
    }

    /// @dev ceil(s * sqrt(num / den)) keeping ~126 significant bits in the root, however extreme the ratio: the
    ///      ratio is scaled by an even power of two to ~2^254 before the square root, then unscaled.
    function _mulSqrtRatioUp(uint256 s, uint256 num, uint256 den) private pure returns (uint256) {
        uint256 bitsNum = FixedPointMathLib.log2(num);
        uint256 bitsDen = FixedPointMathLib.log2(den);
        uint256 shift = 254 + bitsDen > bitsNum ? (254 + bitsDen - bitsNum) & ~uint256(1) : 0;
        // split the shift so neither operand of the 512-bit mulDiv overflows
        uint256 shiftNum = shift <= 255 - bitsNum ? shift : 255 - bitsNum;
        uint256 scaled = FullMath.mulDivRoundingUp(num << shiftNum, uint256(1) << (shift - shiftNum), den);
        return FullMath.mulDivRoundingUp(s, _sqrtUp(scaled), uint256(1) << (shift / 2));
    }

    function _sqrtUp(uint256 x) private pure returns (uint256 r) {
        r = FixedPointMathLib.sqrt(x);
        if (r * r < x) ++r;
    }

    function _mulDiv(uint256 a, uint256 b, uint256 d, bool roundUp) private pure returns (uint256) {
        return roundUp ? FullMath.mulDivRoundingUp(a, b, d) : FullMath.mulDiv(a, b, d);
    }
}
