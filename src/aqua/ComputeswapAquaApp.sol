// SPDX-License-Identifier: LicenseRef-Degensoft-Aqua-Source-1.1
pragma solidity ^0.8.30;

// Powered by Aqua - (c) Degensoft Ltd 2025. This contract extends 1inch's AquaApp base contract (lib/aqua) and is
// therefore published under the Aqua Source License 1.1; see lib/aqua/LICENSES/Aqua-Source-1.1.txt.
// Computeswap additions (c) 2026, first published 2026-09-26.

import {AquaApp} from "@1inch/aqua/AquaApp.sol";
import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";
import {IXYCSwapCallback} from "@1inch/aqua-examples/apps/interfaces/IXYCSwapCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ICurve} from "../interfaces/ICurve.sol";
import {CurveSwapMath} from "../libraries/CurveSwapMath.sol";
import {CurveLiquidityAmounts} from "../libraries/CurveLiquidityAmounts.sol";

/// @title ComputeswapAquaApp - the Computeswap trading function as a 1inch Aqua app
/// @notice One Aqua strategy is one concentrated-liquidity position on the log curve: liquidity `L` on the price range
///         [tickLower, tickUpper], holding x(P) = L (1/P - 1/pb) of token0 and y(P) = L ln(P / pa) of token1. Aqua
///         keeps the balances (in the maker's wallet, as virtual balances); this app keeps the one number Aqua
///         cannot derive from balances once fees have accrued - the position's price - and prices every swap with
///         the same `CurveSwapMath` step the Uniswap v4 hook uses inside one tick range.
///
///         How this maps onto the Uniswap version:
///           - a pool with many positions becomes many strategies, one per position, each with its own price. What
///             the v4 tick machinery does on-chain (aggregating ranges that contain the price) the 1inch router does
///             off-chain by splitting an order across strategies. Ticks, bitmap and fee growth are not needed;
///           - fees are taken on the input, exactly as in the hook, and land in the maker's Aqua balance. The balance
///             minus the principal implied by (L, P) is the position's uncollected fees (`fees`);
///           - swaps are all-or-nothing: an order the range cannot fill reverts with `InsufficientLiquidity`.
///
///         Strategies are immutable (Aqua's rule): to change L or the range, the maker docks and ships a new one. The
///         price is the only mutable state; it is initialised lazily from `Strategy.sqrtPriceX96` at the first swap.
///         Every strategy also carries the hook's manipulation-resistant moving-average tick (`getOracle`), which the
///         AquaWeightVault uses to guard the exercise of ETH weights.
contract ComputeswapAquaApp is AquaApp {
    using SafeCast for uint256;

    error InvalidCurve();
    error InvalidStrategy();
    error ZeroAmount();
    /// @notice The range could not fill the whole order (swaps are all-or-nothing)
    error InsufficientLiquidity(uint256 filled, uint256 requested);
    error InsufficientOutputAmount(uint256 amountOut, uint256 amountOutMin);
    error ExcessiveInputAmount(uint256 amountIn, uint256 amountInMax);
    /// @notice The maker's Aqua balance is below what the curve says the position holds
    error InsufficientMakerBalance(address token, uint256 balance, uint256 needed);

    event Swap(
        address indexed maker,
        bytes32 indexed strategyHash,
        address indexed taker,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint160 sqrtPriceX96,
        int24 tick
    );

    /// @notice A position: the immutable parameters Aqua hashes. `sqrtPriceX96` is the opening price; the amounts
    ///         to ship with it are `openingAmounts(strategy)`.
    struct Strategy {
        address maker; // required by Aqua: makes the hash unique per maker
        address token0;
        address token1;
        uint24 fee; // hundredths of a bip on the input, as in Uniswap (3000 = 0.3%)
        int24 tickLower; // pa
        int24 tickUpper; // pb
        uint128 liquidity; // L, denominated in token1 (see LogCurveMath)
        uint160 sqrtPriceX96; // opening price, within [pa, pb]
        bytes32 salt; // several positions with the same parameters
    }

    /// @notice Per-strategy mutable state: the price, and the moving-average tick of the hook's oracle
    struct State {
        uint160 sqrtPriceX96;
        int24 tick;
        uint64 updatedAt;
        bool initialized;
        int128 emaTickWad;
    }

    /// @notice Time constant of the price oracle's moving average (same as the hook)
    uint256 public constant ORACLE_TIME_CONSTANT = 10 minutes;

    /// @notice The trading function of every strategy of this app
    ICurve public immutable CURVE;

    mapping(address maker => mapping(bytes32 strategyHash => State)) internal _states;

    constructor(IAqua aqua, ICurve curve) AquaApp(aqua) {
        if (address(curve).code.length == 0) revert InvalidCurve();
        CURVE = curve;
    }

    // ----------------------------------------------------------------------------------------------------------
    // Swaps (Aqua's callback pattern: pull the output, let the taker push the input, check the push)
    // ----------------------------------------------------------------------------------------------------------

    /// @notice Sells exactly `amountIn` of one token for the other. The caller must implement IXYCSwapCallback and
    ///         push `amountIn` of the input token to the maker's balance of this strategy inside the callback.
    function swapExactIn(
        Strategy calldata strategy,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        bytes calldata takerData
    ) external nonReentrantStrategy(strategy.maker, keccak256(abi.encode(strategy))) returns (uint256 amountOut) {
        bytes32 hash = keccak256(abi.encode(strategy));
        (, amountOut) = _swap(strategy, hash, zeroForOne, -amountIn.toInt256());
        if (amountOut < amountOutMin) revert InsufficientOutputAmount(amountOut, amountOutMin);
        _settle(strategy, hash, zeroForOne, amountIn, amountOut, to, takerData);
    }

    /// @notice Buys exactly `amountOut` of one token with the other; the callback must push `amountIn`.
    function swapExactOut(
        Strategy calldata strategy,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMax,
        address to,
        bytes calldata takerData
    ) external nonReentrantStrategy(strategy.maker, keccak256(abi.encode(strategy))) returns (uint256 amountIn) {
        bytes32 hash = keccak256(abi.encode(strategy));
        (amountIn,) = _swap(strategy, hash, zeroForOne, amountOut.toInt256());
        if (amountIn > amountInMax) revert ExcessiveInputAmount(amountIn, amountInMax);
        _settle(strategy, hash, zeroForOne, amountIn, amountOut, to, takerData);
    }

    // ----------------------------------------------------------------------------------------------------------
    // Quotes and views
    // ----------------------------------------------------------------------------------------------------------

    function strategyHash(Strategy calldata strategy) external pure returns (bytes32) {
        return keccak256(abi.encode(strategy));
    }

    /// @notice Output of an exact-input swap at the current price (reverts if the range cannot fill it)
    function quoteExactIn(Strategy calldata strategy, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        (, amountOut,) = _step(strategy, zeroForOne, -amountIn.toInt256());
    }

    /// @notice Input of an exact-output swap at the current price (reverts if the range cannot fill it)
    function quoteExactOut(Strategy calldata strategy, bool zeroForOne, uint256 amountOut)
        external
        view
        returns (uint256 amountIn)
    {
        (amountIn,,) = _step(strategy, zeroForOne, amountOut.toInt256());
    }

    /// @notice The strategy's current price (its opening price until the first swap)
    function currentSqrtPrice(Strategy calldata strategy) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return _peek(strategy, _states[strategy.maker][keccak256(abi.encode(strategy))]);
    }

    /// @notice Current tick and the moving-average tick (brought up to date without a transaction)
    function getOracle(Strategy calldata strategy) external view returns (int24 tick, int24 emaTick) {
        State storage st = _states[strategy.maker][keccak256(abi.encode(strategy))];
        (, tick) = _peek(strategy, st);
        emaTick = st.initialized ? int24(_emaTickWad(st, tick) / 1e18) : tick;
    }

    function getState(address maker, bytes32 hash) external view returns (State memory) {
        return _states[maker][hash];
    }

    /// @notice Token amounts `liquidity` on the strategy's range holds at its current price. With roundUp this is
    ///         what a maker has to back; without, what the position pays out.
    function amountsForLiquidity(Strategy calldata strategy, uint128 liquidity, bool roundUp)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,) = _peek(strategy, _states[strategy.maker][keccak256(abi.encode(strategy))]);
        return _amounts(strategy, sqrtPriceX96, liquidity, roundUp);
    }

    /// @notice The balances a maker must ship with `strategy`: its principal at the opening price, rounded up
    function openingAmounts(Strategy calldata strategy) external view returns (uint256 amount0, uint256 amount1) {
        _validate(strategy);
        return _amounts(strategy, strategy.sqrtPriceX96, strategy.liquidity, true);
    }

    /// @notice Largest liquidity on [tickLower, tickUpper] at `sqrtPriceX96` that at most amount0 / amount1 back
    function liquidityForAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) external view returns (uint128) {
        return CurveLiquidityAmounts.getLiquidityForAmounts(
            CURVE,
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    /// @notice Uncollected fees: what the maker's Aqua balances hold beyond the position's principal
    function fees(Strategy calldata strategy) external view returns (uint256 fees0, uint256 fees1) {
        bytes32 hash = keccak256(abi.encode(strategy));
        (uint160 sqrtPriceX96,) = _peek(strategy, _states[strategy.maker][hash]);
        (uint256 principal0, uint256 principal1) = _amounts(strategy, sqrtPriceX96, strategy.liquidity, true);
        (uint256 balance0,) = AQUA.rawBalances(strategy.maker, address(this), hash, strategy.token0);
        (uint256 balance1,) = AQUA.rawBalances(strategy.maker, address(this), hash, strategy.token1);
        fees0 = balance0 > principal0 ? balance0 - principal0 : 0;
        fees1 = balance1 > principal1 ? balance1 - principal1 : 0;
    }

    // ----------------------------------------------------------------------------------------------------------
    // Internal
    // ----------------------------------------------------------------------------------------------------------

    /// @dev Prices the order on the curve, all-or-nothing, and moves the strategy's price.
    function _swap(Strategy calldata s, bytes32 hash, bool zeroForOne, int256 amountSpecified)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        State storage st = _states[s.maker][hash];
        (uint160 sqrtPriceX96, int24 tick) = _load(s, st);
        _updateOracle(st, tick);

        uint160 sqrtPriceNextX96;
        (amountIn, amountOut, sqrtPriceNextX96) = _compute(s, sqrtPriceX96, zeroForOne, amountSpecified);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceNextX96);
        st.sqrtPriceX96 = sqrtPriceNextX96;
        st.tick = tick;
        emit Swap(s.maker, hash, msg.sender, zeroForOne, amountIn, amountOut, sqrtPriceNextX96, tick);
    }

    /// @dev Settles with Aqua: the output leaves the maker's wallet now, the input arrives through the taker's
    ///      callback and is verified against the maker's balance (safe under nonReentrantStrategy).
    function _settle(
        Strategy calldata s,
        bytes32 hash,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        bytes calldata takerData
    ) private {
        (address tokenIn, address tokenOut) = zeroForOne ? (s.token0, s.token1) : (s.token1, s.token0);
        uint256 expectedBalanceIn = _pull(s.maker, hash, tokenIn, tokenOut, amountOut, to) + amountIn;
        _callback(s.maker, hash, tokenIn, tokenOut, amountIn, amountOut, takerData);
        _safeCheckAquaPush(s.maker, hash, tokenIn, expectedBalanceIn);
    }

    /// @dev Pays the output out of the maker's wallet; returns the maker's balance of the input token before the swap
    function _pull(address maker, bytes32 hash, address tokenIn, address tokenOut, uint256 amountOut, address to)
        private
        returns (uint256 balanceIn)
    {
        // reverts unless both tokens belong to a live (shipped, not docked) strategy
        uint256 balanceOut;
        (balanceIn, balanceOut) = AQUA.safeBalances(maker, address(this), hash, tokenIn, tokenOut);
        if (amountOut > balanceOut) revert InsufficientMakerBalance(tokenOut, balanceOut, amountOut);
        AQUA.pull(maker, hash, tokenOut, amountOut, to);
    }

    function _callback(
        address maker,
        bytes32 hash,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata takerData
    ) private {
        IXYCSwapCallback(msg.sender)
            .xycSwapCallback(tokenIn, tokenOut, amountIn, amountOut, maker, address(this), hash, takerData);
    }

    /// @dev One CurveSwapMath step across the whole range: the same math the hook runs inside one tick range.
    function _compute(Strategy calldata s, uint160 sqrtPriceX96, bool zeroForOne, int256 amountSpecified)
        private
        view
        returns (uint256 amountIn, uint256 amountOut, uint160 sqrtPriceNextX96)
    {
        if (amountSpecified == 0) revert ZeroAmount();
        uint160 target = TickMath.getSqrtPriceAtTick(zeroForOne ? s.tickLower : s.tickUpper);
        uint256 stepIn;
        uint256 feeAmount;
        (sqrtPriceNextX96, stepIn, amountOut, feeAmount) =
            CurveSwapMath.computeSwapStep(CURVE, sqrtPriceX96, target, s.liquidity, amountSpecified, s.fee);
        amountIn = stepIn + feeAmount;
        if (amountSpecified < 0) {
            uint256 requested = uint256(-amountSpecified);
            if (amountIn != requested) revert InsufficientLiquidity(amountIn, requested);
        } else if (amountOut != uint256(amountSpecified)) {
            revert InsufficientLiquidity(amountOut, uint256(amountSpecified));
        }
    }

    function _step(Strategy calldata s, bool zeroForOne, int256 amountSpecified)
        private
        view
        returns (uint256 amountIn, uint256 amountOut, uint160 sqrtPriceNextX96)
    {
        (uint160 sqrtPriceX96,) = _peek(s, _states[s.maker][keccak256(abi.encode(s))]);
        return _compute(s, sqrtPriceX96, zeroForOne, amountSpecified);
    }

    function _amounts(Strategy calldata s, uint160 sqrtPriceX96, uint128 liquidity, bool roundUp)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return CurveLiquidityAmounts.getAmountsForLiquidity(
            CURVE,
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(s.tickLower),
            TickMath.getSqrtPriceAtTick(s.tickUpper),
            liquidity,
            roundUp
        );
    }

    /// @dev Current price and tick; initialises the state from the strategy at the first swap.
    function _load(Strategy calldata s, State storage st) private returns (uint160, int24) {
        if (st.initialized) return (st.sqrtPriceX96, st.tick);
        _validate(s);
        int24 tick = TickMath.getTickAtSqrtPrice(s.sqrtPriceX96);
        st.initialized = true;
        st.sqrtPriceX96 = s.sqrtPriceX96;
        st.tick = tick;
        st.emaTickWad = int128(int256(tick) * 1e18);
        st.updatedAt = uint64(block.timestamp);
        return (s.sqrtPriceX96, tick);
    }

    function _peek(Strategy calldata s, State storage st) private view returns (uint160, int24) {
        if (st.initialized) return (st.sqrtPriceX96, st.tick);
        _validate(s);
        return (s.sqrtPriceX96, TickMath.getTickAtSqrtPrice(s.sqrtPriceX96));
    }

    function _validate(Strategy calldata s) private pure {
        if (s.maker == address(0) || s.token0 == s.token1 || s.liquidity == 0) revert InvalidStrategy();
        if (s.fee >= CurveSwapMath.MAX_SWAP_FEE) revert InvalidStrategy();
        if (s.tickLower >= s.tickUpper || s.tickLower < TickMath.MIN_TICK || s.tickUpper > TickMath.MAX_TICK) {
            revert InvalidStrategy();
        }
        if (
            s.sqrtPriceX96 < TickMath.getSqrtPriceAtTick(s.tickLower)
                || s.sqrtPriceX96 > TickMath.getSqrtPriceAtTick(s.tickUpper)
        ) revert InvalidStrategy();
    }

    function _updateOracle(State storage st, int24 tick) private {
        if (st.updatedAt == block.timestamp) return;
        st.emaTickWad = int128(_emaTickWad(st, tick));
        st.updatedAt = uint64(block.timestamp);
    }

    /// @dev EMA after the tick has been `tick` since the last update: the old average decays by e^(-dt / tau).
    function _emaTickWad(State storage st, int24 tick) private view returns (int256) {
        uint256 dt = block.timestamp - st.updatedAt;
        int256 target = int256(tick) * 1e18;
        if (dt == 0) return st.emaTickWad;
        if (dt >= 40 * ORACLE_TIME_CONSTANT) return target;
        int256 decay = FixedPointMathLib.expWad(-int256(dt * 1e18 / ORACLE_TIME_CONSTANT));
        return target + (int256(st.emaTickWad) - target) * decay / 1e18;
    }
}
