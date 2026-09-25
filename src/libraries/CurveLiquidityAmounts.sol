// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ICurve} from "../interfaces/ICurve.sol";

/// @title CurveLiquidityAmounts - convert between liquidity and token amounts for any curve
/// @notice Curve-generic counterpart of Uniswap's LiquidityAmounts. A position on [pa, pb] at price P needs
///             P <= pa:        amount0 = L * (xu(pa) - xu(pb))
///             pa < P < pb:    amount0 = L * (xu(P) - xu(pb)),   amount1 = L * (yu(P) - yu(pa))
///             P >= pb:        amount1 = L * (yu(pb) - yu(pa))
///         so the liquidity a deposit buys is the smaller of amount0 / (unit amount0) and amount1 / (unit amount1).
library CurveLiquidityAmounts {
    /// @dev Probe size for the linear estimate; large enough for precision, small enough not to overflow curves.
    uint128 internal constant PROBE_LIQUIDITY = 1 << 100;

    function getAmountsForLiquidity(
        ICurve curve,
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        bool roundUp
    ) internal view returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (liquidity == 0) return (0, 0);
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = curve.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, roundUp);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = curve.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, roundUp);
            amount1 = curve.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = curve.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, roundUp);
        }
    }

    /// @notice Largest liquidity whose deposit (rounded up, as the pool charges it) fits in amount0 and amount1
    function getLiquidityForAmounts(
        ICurve curve,
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = _solve(curve, true, sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = _solve(curve, true, sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = _solve(curve, false, sqrtPriceAX96, sqrtPriceX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _solve(curve, false, sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    /// @dev Largest L with amount(L, roundUp) <= amount. Amounts are linear in L up to rounding, so: estimate from a
    ///      probe, correct proportionally at full size, then step down until the rounded-up amount fits.
    function _solve(ICurve curve, bool isAmount0, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount)
        private
        view
        returns (uint128)
    {
        if (amount == 0 || sqrtPriceAX96 == sqrtPriceBX96) return 0;
        uint256 maxLiquidity = type(uint128).max;

        uint256 unit = _amount(curve, isAmount0, sqrtPriceAX96, sqrtPriceBX96, PROBE_LIQUIDITY);
        uint256 liquidity = unit == 0 ? maxLiquidity : FullMath.mulDiv(amount, PROBE_LIQUIDITY, unit);
        if (liquidity > maxLiquidity) liquidity = maxLiquidity;

        uint256 needed = _amount(curve, isAmount0, sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity));
        if (needed > amount) {
            liquidity = FullMath.mulDiv(liquidity, amount, needed);
        }
        for (uint256 i; i < 64; ++i) {
            needed = _amount(curve, isAmount0, sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity));
            if (needed <= amount) return uint128(liquidity);
            uint256 step = FullMath.mulDiv(liquidity, needed - amount, needed) + 1;
            liquidity = liquidity > step ? liquidity - step : 0;
        }
        return 0;
    }

    function _amount(ICurve curve, bool isAmount0, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        private
        view
        returns (uint256)
    {
        return isAmount0
            ? curve.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true)
            : curve.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true);
    }
}
