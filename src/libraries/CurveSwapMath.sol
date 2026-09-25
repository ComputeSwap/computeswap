// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ICurve} from "../interfaces/ICurve.sol";

/// @title CurveSwapMath - one swap step inside a single liquidity range, for any curve
/// @notice Same control flow and fee handling as Uniswap v4's SwapMath.computeSwapStep; the four SqrtPriceMath
///         calls are routed through an ICurve. With test/mocks/ConstantProductCurve the results are identical to v4.
///         Two additions make approximate curves safe:
///           - a curve's next price is clamped to the step target. A curve that widens its results by an error
///             allowance may land a hair past a tick; clamping keeps tick crossing exact and only ever makes the
///             trader pay the remaining input (exact in) or receive less than the target amount (exact out).
///           - a curve that moves the price the wrong way is rejected outright.
library CurveSwapMath {
    /// @notice The swap fee is in hundredths of a bip, so the max is 100%
    uint256 internal constant MAX_SWAP_FEE = 1e6;

    error CurveMovedPriceBackwards(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceNextX96);

    /// @param curve The pool's trading function
    /// @param sqrtPriceCurrentX96 The current price
    /// @param sqrtPriceTargetX96 The price that cannot be exceeded; its side of the current price sets the direction
    /// @param liquidity The active liquidity
    /// @param amountRemaining Remaining input (negative, exact in) or output (positive, exact out)
    /// @param feePips The fee taken from the input, in hundredths of a bip
    function computeSwapStep(
        ICurve curve,
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal view returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        // Reserves are linear in L, so an empty range is crossed for free (v4 returns the same zeros).
        if (liquidity == 0) return (sqrtPriceTargetX96, 0, 0, 0);

        uint256 _feePips = feePips;
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;

        if (amountRemaining < 0) {
            // exact input
            uint256 amountRemainingLessFee =
                FullMath.mulDiv(uint256(-amountRemaining), MAX_SWAP_FEE - _feePips, MAX_SWAP_FEE);
            amountIn = zeroForOne
                ? curve.getAmount0Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true)
                : curve.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true);
            if (amountRemainingLessFee >= amountIn) {
                // `amountIn` is capped by the target price
                sqrtPriceNextX96 = sqrtPriceTargetX96;
                feeAmount = _feePips == MAX_SWAP_FEE
                    ? amountIn // amountIn is always 0 here, as amountRemainingLessFee == 0
                    : FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
            } else {
                // exhaust the remaining amount; the curve moves the price no further than the input pays for
                amountIn = amountRemainingLessFee;
                sqrtPriceNextX96 = zeroForOne
                    ? curve.getNextSqrtPriceFromAmount0(sqrtPriceCurrentX96, liquidity, amountIn, true)
                    : curve.getNextSqrtPriceFromAmount1(sqrtPriceCurrentX96, liquidity, amountIn, true);
                sqrtPriceNextX96 = _bound(sqrtPriceCurrentX96, sqrtPriceTargetX96, sqrtPriceNextX96, zeroForOne);
                // we didn't reach the target, so take the remainder of the maximum input as fee
                unchecked {
                    feeAmount = uint256(-amountRemaining) - amountIn;
                }
            }
            amountOut = zeroForOne
                ? curve.getAmount1Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, false)
                : curve.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false);
        } else {
            // exact output
            amountOut = zeroForOne
                ? curve.getAmount1Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, false)
                : curve.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, false);
            if (uint256(amountRemaining) >= amountOut) {
                // `amountOut` is capped by the target price
                sqrtPriceNextX96 = sqrtPriceTargetX96;
            } else {
                // the curve moves the price at least as far as the requested output requires
                amountOut = uint256(amountRemaining);
                sqrtPriceNextX96 = zeroForOne
                    ? curve.getNextSqrtPriceFromAmount1(sqrtPriceCurrentX96, liquidity, amountOut, false)
                    : curve.getNextSqrtPriceFromAmount0(sqrtPriceCurrentX96, liquidity, amountOut, false);
                sqrtPriceNextX96 = _bound(sqrtPriceCurrentX96, sqrtPriceTargetX96, sqrtPriceNextX96, zeroForOne);
            }
            amountIn = zeroForOne
                ? curve.getAmount0Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true)
                : curve.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
            // `feePips` cannot be `MAX_SWAP_FEE` for exact out
            feeAmount = FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
        }
    }

    /// @dev Keeps the curve's answer between the current price and the step target.
    function _bound(uint160 current, uint160 target, uint160 next, bool zeroForOne) private pure returns (uint160) {
        if (zeroForOne) {
            if (next > current) revert CurveMovedPriceBackwards(current, next);
            return next < target ? target : next;
        }
        if (next < current) revert CurveMovedPriceBackwards(current, next);
        return next > target ? target : next;
    }
}
