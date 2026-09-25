// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {UnsafeMath} from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ICurve} from "../interfaces/ICurve.sol";
import {CurveSwapMath} from "./CurveSwapMath.sol";

/// @title CurvePool - concentrated liquidity bookkeeping that is independent of the trading function
/// @notice Ticks, tick bitmap, positions and fee growth follow the Uniswap v3/v4 design. The only curve-specific
///         operations - converting liquidity to token amounts and amounts to price moves - go through an ICurve.
///
///         How liquidity is tracked:
///           - a position stores a constant liquidity L for its tick range, whatever the curve;
///           - each initialized tick stores liquidityNet (+L at a lower tick, -L at an upper tick) and
///             liquidityGross (reference count), plus fee growth "outside" the tick;
///           - the pool stores the active liquidity: the sum of L over positions whose range contains the price;
///           - a swap crossing a tick adds (or subtracts) its liquidityNet to the active liquidity.
///         Because each curve's reserves are affine in L with slopes that do not depend on the range, the active
///         liquidity trades exactly like one position of size sum(L); positions with the same range just add up,
///         and overlapping ranges add up where they overlap.
/// @dev Own implementation (MIT) of the algorithms in the Uniswap v3 whitepaper; v4-core's Pool.sol and
///      Position.sol are BUSL-1.1 and are deliberately not used. Differences from v4's pool: no protocol fee,
///      no donate, and swaps are all-or-nothing (see swap).
library CurvePool {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);

    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error TicksMisordered(int24 tickLower, int24 tickUpper);
    error TickLowerOutOfBounds(int24 tickLower);
    error TickUpperOutOfBounds(int24 tickUpper);
    error TickLiquidityOverflow(int24 tick);
    error CannotUpdateEmptyPosition();
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);
    error InvalidFeeForExactOut();
    error SwapNotFullyFilled(int256 amountSpecifiedRemaining);

    struct TickInfo {
        // total liquidity of the positions that reference this tick
        uint128 liquidityGross;
        // liquidity added (removed) when the tick is crossed left to right (right to left)
        int128 liquidityNet;
        // fee growth per unit of liquidity on the other side of this tick (relative meaning only)
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    struct Position {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    struct State {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 lpFee;
        uint128 liquidity;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        mapping(int24 tick => TickInfo) ticks;
        mapping(int16 wordPos => uint256) tickBitmap;
        mapping(bytes32 positionKey => Position) positions;
    }

    function initialize(State storage self, uint160 sqrtPriceX96, uint24 lpFee) internal returns (int24 tick) {
        if (self.sqrtPriceX96 != 0) revert PoolAlreadyInitialized();
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        self.sqrtPriceX96 = sqrtPriceX96;
        self.tick = tick;
        self.lpFee = lpFee;
    }

    function checkPoolInitialized(State storage self) internal view {
        if (self.sqrtPriceX96 == 0) revert PoolNotInitialized();
    }

    // ----------------------------------------------------------------------------------------------------------
    // Liquidity
    // ----------------------------------------------------------------------------------------------------------

    struct ModifyLiquidityParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        int24 tickSpacing;
        bytes32 salt;
    }

    /// @notice Adds or removes liquidity on a range and settles the position's fees.
    /// @return delta Principal token deltas from the owner's point of view (negative = owed to the pool)
    /// @return feeDelta Fees earned by the position since its last update (always >= 0)
    function modifyLiquidity(State storage self, ICurve curve, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta, BalanceDelta feeDelta)
    {
        checkPoolInitialized(self);
        _checkTicks(params.tickLower, params.tickUpper);
        feeDelta = _updateTicksAndPosition(self, params);
        if (params.liquidityDelta != 0) delta = _principalDelta(self, curve, params);
    }

    /// @dev Tick bookkeeping (liquidityGross/Net, bitmap) and the position's fee checkpoint.
    function _updateTicksAndPosition(State storage self, ModifyLiquidityParams memory params)
        private
        returns (BalanceDelta feeDelta)
    {
        int128 liquidityDelta = params.liquidityDelta;
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint128 grossAfterLower;
            uint128 grossAfterUpper;
            (flippedLower, grossAfterLower) = _updateTick(self, params.tickLower, liquidityDelta, false);
            (flippedUpper, grossAfterUpper) = _updateTick(self, params.tickUpper, liquidityDelta, true);

            if (liquidityDelta > 0) {
                uint128 maxLiquidityPerTick = tickSpacingToMaxLiquidityPerTick(params.tickSpacing);
                if (grossAfterLower > maxLiquidityPerTick) revert TickLiquidityOverflow(params.tickLower);
                if (grossAfterUpper > maxLiquidityPerTick) revert TickLiquidityOverflow(params.tickUpper);
            }
            if (flippedLower) self.tickBitmap.flipTick(params.tickLower, params.tickSpacing);
            if (flippedUpper) self.tickBitmap.flipTick(params.tickUpper, params.tickSpacing);
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            getFeeGrowthInside(self, params.tickLower, params.tickUpper);
        Position storage position =
            self.positions[positionKey(params.owner, params.tickLower, params.tickUpper, params.salt)];
        (uint256 feesOwed0, uint256 feesOwed1) =
            _updatePosition(position, liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);
        feeDelta = toBalanceDelta(feesOwed0.toInt128(), feesOwed1.toInt128());

        // clear tick data that is no longer referenced
        if (liquidityDelta < 0) {
            if (flippedLower) delete self.ticks[params.tickLower];
            if (flippedUpper) delete self.ticks[params.tickUpper];
        }
    }

    /// @dev Token amounts for a liquidity change - the only curve-specific part of adding/removing liquidity.
    function _principalDelta(State storage self, ICurve curve, ModifyLiquidityParams memory params)
        private
        returns (BalanceDelta delta)
    {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tick = self.tick;
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);
        if (tick < params.tickLower) {
            // range above the price: all currency0
            delta = toBalanceDelta(_amount0(curve, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidityDelta), 0);
        } else if (tick < params.tickUpper) {
            // price inside the range: x = L(xu(P) - xu(pb)), y = L(yu(P) - yu(pa))
            uint160 sqrtPriceX96 = self.sqrtPriceX96;
            delta = toBalanceDelta(
                _amount0(curve, sqrtPriceX96, sqrtPriceUpperX96, liquidityDelta),
                _amount1(curve, sqrtPriceLowerX96, sqrtPriceX96, liquidityDelta)
            );
            self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
        } else {
            // range below the price: all currency1
            delta = toBalanceDelta(0, _amount1(curve, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidityDelta));
        }
    }

    // ----------------------------------------------------------------------------------------------------------
    // Swap
    // ----------------------------------------------------------------------------------------------------------

    struct SwapParams {
        int256 amountSpecified; // < 0 exact input, > 0 exact output
        int24 tickSpacing;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
    }

    struct SwapResult {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
        uint256 feeGrowthGlobalX128;
    }

    /// @notice Executes a swap against the pool state.
    /// @dev Walks initialized ticks exactly like Uniswap v4, with each step priced by the curve. Unlike v4, the swap
    ///      must be filled completely: a custom-curve hook cannot hand an unfilled remainder back to the
    ///      PoolManager, so reaching the price limit (or running out of liquidity) first reverts.
    /// @return swapDelta Token deltas from the swapper's point of view (negative = paid to the pool)
    function swap(State storage self, ICurve curve, SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, SwapResult memory result)
    {
        checkPoolInitialized(self);
        bool zeroForOne = params.zeroForOne;
        uint24 swapFee = self.lpFee;
        int256 amountSpecifiedRemaining = params.amountSpecified;
        int256 amountCalculated;
        result.sqrtPriceX96 = self.sqrtPriceX96;
        result.tick = self.tick;
        result.liquidity = self.liquidity;

        // a 100% fee makes exact output swaps impossible, since the input is entirely consumed by the fee
        if (swapFee >= CurveSwapMath.MAX_SWAP_FEE && params.amountSpecified > 0) revert InvalidFeeForExactOut();
        if (params.amountSpecified == 0) return (swapDelta, result);

        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= result.sqrtPriceX96) {
                revert PriceLimitAlreadyExceeded(result.sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= result.sqrtPriceX96) {
                revert PriceLimitAlreadyExceeded(result.sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
            }
        }

        StepComputations memory step;
        step.feeGrowthGlobalX128 = zeroForOne ? self.feeGrowthGlobal0X128 : self.feeGrowthGlobal1X128;

        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(result.tick, params.tickSpacing, zeroForOne);
            // the bitmap is not aware of the min/max tick bounds
            if (step.tickNext <= TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
            if (step.tickNext >= TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // swap to the next tick, the price limit, or until the amount runs out - priced by the curve
            (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = CurveSwapMath.computeSwapStep(
                curve,
                result.sqrtPriceX96,
                _target(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                result.liquidity,
                amountSpecifiedRemaining,
                swapFee
            );

            if (params.amountSpecified > 0) {
                amountSpecifiedRemaining -= step.amountOut.toInt256();
                amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                amountCalculated += step.amountOut.toInt256();
            }

            // fees are shared by the active liquidity, pro rata to L - the same rule for every curve
            if (result.liquidity > 0) {
                unchecked {
                    // cannot overflow: feeAmount < 2^128 and Q128 < 2^129
                    step.feeGrowthGlobalX128 +=
                        UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
                }
            }

            if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // reached the next tick: hand liquidity over between ranges
                if (step.initialized) {
                    (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = zeroForOne
                        ? (step.feeGrowthGlobalX128, self.feeGrowthGlobal1X128)
                        : (self.feeGrowthGlobal0X128, step.feeGrowthGlobalX128);
                    int128 liquidityNet =
                        _crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
                    // moving left, liquidityNet is interpreted with the opposite sign
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }
                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }
                unchecked {
                    result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }

        if (amountSpecifiedRemaining != 0) revert SwapNotFullyFilled(amountSpecifiedRemaining);

        self.sqrtPriceX96 = result.sqrtPriceX96;
        self.tick = result.tick;
        if (self.liquidity != result.liquidity) self.liquidity = result.liquidity;
        if (zeroForOne) self.feeGrowthGlobal0X128 = step.feeGrowthGlobalX128;
        else self.feeGrowthGlobal1X128 = step.feeGrowthGlobalX128;

        // "if currency1 is specified"
        if (zeroForOne != (params.amountSpecified < 0)) {
            swapDelta = toBalanceDelta(
                amountCalculated.toInt128(), (params.amountSpecified - amountSpecifiedRemaining).toInt128()
            );
        } else {
            swapDelta = toBalanceDelta(
                (params.amountSpecified - amountSpecifiedRemaining).toInt128(), amountCalculated.toInt128()
            );
        }
    }

    // ----------------------------------------------------------------------------------------------------------
    // Views and helpers
    // ----------------------------------------------------------------------------------------------------------

    function positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    /// @notice All-time fee growth per unit of liquidity inside a tick range
    function getFeeGrowthInside(State storage self, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        TickInfo storage lower = self.ticks[tickLower];
        TickInfo storage upper = self.ticks[tickUpper];
        int24 tickCurrent = self.tick;
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 = lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upper.feeGrowthOutside0X128 - lower.feeGrowthOutside0X128;
                feeGrowthInside1X128 = upper.feeGrowthOutside1X128 - lower.feeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    self.feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    self.feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            }
        }
    }

    /// @notice Max liquidity per tick such that the sum over all ticks cannot overflow uint128
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTick = TickMath.MIN_TICK / tickSpacing;
        if (TickMath.MIN_TICK % tickSpacing != 0) minTick--;
        int24 maxTick = TickMath.MAX_TICK / tickSpacing;
        uint24 numTicks = uint24(maxTick - minTick) + 1;
        return type(uint128).max / numTicks;
    }

    function _checkTicks(int24 tickLower, int24 tickUpper) private pure {
        if (tickLower >= tickUpper) revert TicksMisordered(tickLower, tickUpper);
        if (tickLower < TickMath.MIN_TICK) revert TickLowerOutOfBounds(tickLower);
        if (tickUpper > TickMath.MAX_TICK) revert TickUpperOutOfBounds(tickUpper);
    }

    function _target(bool zeroForOne, uint160 sqrtPriceNextX96, uint160 sqrtPriceLimitX96)
        private
        pure
        returns (uint160)
    {
        if (zeroForOne) return sqrtPriceNextX96 < sqrtPriceLimitX96 ? sqrtPriceLimitX96 : sqrtPriceNextX96;
        return sqrtPriceNextX96 > sqrtPriceLimitX96 ? sqrtPriceLimitX96 : sqrtPriceNextX96;
    }

    /// @dev Signed currency0 delta: adding liquidity rounds the owed amount up, removing rounds the paid amount down.
    function _amount0(ICurve curve, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidityDelta)
        private
        view
        returns (int128)
    {
        return liquidityDelta < 0
            ? curve.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidityDelta), false).toInt128()
            : -curve.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidityDelta), true).toInt128();
    }

    function _amount1(ICurve curve, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidityDelta)
        private
        view
        returns (int128)
    {
        return liquidityDelta < 0
            ? curve.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidityDelta), false).toInt128()
            : -curve.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidityDelta), true).toInt128();
    }

    function _updateTick(State storage self, int24 tick, int128 liquidityDelta, bool upper)
        private
        returns (bool flipped, uint128 liquidityGrossAfter)
    {
        TickInfo storage info = self.ticks[tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, all fee growth before a tick was initialized happened below it
            if (tick <= self.tick) {
                info.feeGrowthOutside0X128 = self.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = self.feeGrowthGlobal1X128;
            }
        }
        info.liquidityGross = liquidityGrossAfter;
        // crossing a lower (upper) tick left to right adds (removes) the position's liquidity
        info.liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;
    }

    function _crossTick(State storage self, int24 tick, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
        private
        returns (int128 liquidityNet)
    {
        TickInfo storage info = self.ticks[tick];
        unchecked {
            info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
            info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        }
        liquidityNet = info.liquidityNet;
    }

    function _updatePosition(
        Position storage position,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) private returns (uint256 feesOwed0, uint256 feesOwed1) {
        uint128 liquidity = position.liquidity;
        if (liquidityDelta == 0) {
            if (liquidity == 0) revert CannotUpdateEmptyPosition();
        } else {
            position.liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        }
        unchecked {
            feesOwed0 =
                FullMath.mulDiv(feeGrowthInside0X128 - position.feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            feesOwed1 =
                FullMath.mulDiv(feeGrowthInside1X128 - position.feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }
        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }
}
