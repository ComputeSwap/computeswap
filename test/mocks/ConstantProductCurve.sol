// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ICurve} from "../../src/interfaces/ICurve.sol";

/// @title ConstantProductCurve - x * y = L^2, exactly as Uniswap v3/v4 prices it
/// @notice Unit reserves xu = 1/sqrt(P), yu = sqrt(P). Delegates to v4-core's SqrtPriceMath, so a pool using this
///         curve must reproduce a vanilla v4 pool bit-for-bit. Test-only: the control that validates the engine
///         (ConstantProductParity.t.sol); the product ships only the log curve.
contract ConstantProductCurve is ICurve {
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint256)
    {
        return SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, roundUp);
    }

    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint256)
    {
        return SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, roundUp);
    }

    function getNextSqrtPriceFromAmount0(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        external
        pure
        returns (uint160)
    {
        return SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amount, add);
    }

    function getNextSqrtPriceFromAmount1(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        external
        pure
        returns (uint160)
    {
        return SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amount, add);
    }
}
