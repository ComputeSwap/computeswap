// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ICurve} from "../interfaces/ICurve.sol";
import {LogCurveMath} from "../libraries/LogCurveMath.sol";

/// @title LogCurve - concentrated liquidity on (x + L/pb) * e^(y/L + ln pa) = L
/// @notice Unit reserves xu = 1/P, yu = ln P (see LogCurveMath). Currency1 is the "logarithmic" side: a position
///         holds L * ln(P / pa) of it. If the asset you want on that side sorts as currency0, deploy the mirrored
///         curve (xu = -ln P, yu = P) instead - the engine does not care which one it runs.
contract LogCurve is ICurve {
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint256)
    {
        return LogCurveMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, roundUp);
    }

    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint256)
    {
        return LogCurveMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, roundUp);
    }

    function getNextSqrtPriceFromAmount0(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        external
        pure
        returns (uint160)
    {
        return LogCurveMath.getNextSqrtPriceFromAmount0(sqrtPX96, liquidity, amount, add);
    }

    function getNextSqrtPriceFromAmount1(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        external
        pure
        returns (uint160)
    {
        return LogCurveMath.getNextSqrtPriceFromAmount1(sqrtPX96, liquidity, amount, add);
    }
}
