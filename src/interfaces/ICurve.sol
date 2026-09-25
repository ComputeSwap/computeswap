// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ICurve - a pluggable trading function for concentrated liquidity
/// @notice A curve is written in *price space*. One unit of liquidity (L = 1) holds
///             xu(P) of currency0 and yu(P) of currency1
///         when the marginal price is P (currency1 per currency0), where xu is strictly decreasing, yu is
///         strictly increasing and dyu = -P * dxu (the curve's marginal price really is P).
///
///         A position with liquidity L on the range [pa, pb] is that unit curve scaled by L and translated by
///         the offsets (L * xu(pb), L * yu(pa)) - the same construction Uniswap v3 applies to x * y = L^2:
///             x(P) = L * (xu(P) - xu(pb)),   y(P) = L * (yu(P) - yu(pa)),   pa <= P <= pb.
///
///         Within a range, dx = L * xu'(P) dP and dy = L * yu'(P) dP depend on the range only through L, so
///         positions with different ranges aggregate by summing L. The engine (ticks, liquidityNet, fee growth)
///         is therefore identical for every curve; a curve only answers the four questions below, which are
///         exactly the four functions of Uniswap's SqrtPriceMath.
///
///         Examples (unit curve -> reserves):
///           x * y = 1                    xu = 1/sqrt(P),                 yu = sqrt(P)           (Uniswap v3)
///           x * e^y = 1                  xu = 1/P,                       yu = ln(P)             (LogCurve)
///           2^-x + 2^-y = 1              xu = log2(1 + 1/P),             yu = log2(1 + P)
///           (x-v)^2 + (y-v)^2 = v^2      xu = v(1 - P/sqrt(1+P^2)),      yu = v(1 - 1/sqrt(1+P^2))
///
/// @dev Prices are Uniswap sqrtPriceX96 values so that ticks, price limits and events keep their usual meaning
///      for every curve. Implementations must be deterministic and must not depend on mutable state: the curve
///      bound to a pool can never change while it holds liquidity. The two prices passed to the amount functions
///      may come in either order.
///
///      Rounding rules. The hook's solvency relies on them; "exact" means the real-valued solution:
///        (R1) getAmount{0,1}Delta: roundUp -> result >= exact, !roundUp -> result <= exact.
///        (R2) getNextSqrtPriceFromAmount0(add = true)  -> result >= exact  (price falls, but not too far)
///        (R3) getNextSqrtPriceFromAmount0(add = false) -> result >= exact  (price rises at least far enough)
///        (R4) getNextSqrtPriceFromAmount1(add = true)  -> result <= exact  (price rises, but not too far)
///        (R5) getNextSqrtPriceFromAmount1(add = false) -> result <= exact  (price falls at least far enough)
///      Curves built on approximate math (ln, exp, ...) meet these by widening results by their error bound.
///      Liquidity is always non-zero when the next-price functions are called by the engine, and amounts are below
///      2^127 (v4 deltas are int128). A curve may revert when asked for more than it can hold or absorb; the engine
///      only asks for moves up to the next initialized tick, so that only happens when a swap cannot be filled.
interface ICurve {
    /// @notice Currency0 held by `liquidity` between two prices: L * |xu(A) - xu(B)|
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        external
        view
        returns (uint256 amount0);

    /// @notice Currency1 held by `liquidity` between two prices: L * |yu(B) - yu(A)|
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        external
        view
        returns (uint256 amount1);

    /// @notice Price after `amount` of currency0 is added to (add = true) or removed from the reserves
    function getNextSqrtPriceFromAmount0(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        external
        view
        returns (uint160 sqrtQX96);

    /// @notice Price after `amount` of currency1 is added to (add = true) or removed from the reserves
    function getNextSqrtPriceFromAmount1(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        external
        view
        returns (uint160 sqrtQX96);
}
