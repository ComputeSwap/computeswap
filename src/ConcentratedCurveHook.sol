// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ICurve} from "./interfaces/ICurve.sol";
import {CurvePool} from "./libraries/CurvePool.sol";
import {CurveLiquidityAmounts} from "./libraries/CurveLiquidityAmounts.sol";

/// @title ConcentratedCurveHook - concentrated liquidity on any pluggable trading function, as a Uniswap v4 hook
/// @notice Architecture:
///           ICurve          - the trading function, in price space (4 pure functions). Swappable per pool.
///           CurveSwapMath   - one swap step inside a range, for any curve (v4's SwapMath, generalized).
///           CurvePool       - ticks, bitmap, positions and fee growth; curve-agnostic.
///           this hook       - v4 plumbing: pool registration, liquidity entry points, custom-curve swaps.
///
///         The trading function is fixed when the hook is deployed (`curve`): every pool the hook creates uses it.
///         (Taking the curve per pool would let anyone create the canonical pool of a pair first, bound to a curve of
///         their choosing.) Pools are created through `initializePool`.
///         Liquidity is added and removed through this hook, never through the PoolManager, and held as ERC-6909
///         claims in the PoolManager. Swaps go through any ordinary v4 router: `beforeSwap` prices the trade on
///         the curve, settles it in claims and returns a delta that no-ops v4's own concentrated-liquidity math.
///
///         Every pool's token balances are tracked separately (`reserves`), so a faulty or malicious curve can
///         only lose the funds of the pool that chose it.
contract ConcentratedCurveHook is IHooks, IUnlockCallback {
    using CurvePool for CurvePool.State;
    using SafeCast for *;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error WrongHook();
    error DynamicFeeNotSupported();
    error InvalidCurve();
    error PoolNotRegistered();
    error InitializeThroughHook();
    error AddLiquidityThroughHook();
    error HookNotImplemented();
    error DeadlinePassed();
    error ZeroLiquidity();
    error SlippageExceeded();
    error NativeValueNotAccepted();
    error InsufficientNativeValue();
    error InsufficientPoolReserves();

    event PoolInitialized(PoolId indexed id, ICurve indexed curve, uint160 sqrtPriceX96, int24 tick, bool mirrorPrice);
    event ModifyLiquidity(
        PoolId indexed id,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        bytes32 salt,
        BalanceDelta principal,
        BalanceDelta fees
    );
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    struct PoolConfig {
        ICurve curve;
        // keep the PoolManager's slot0 price in sync with the curve price (costs a zero-amount v4 swap per swap)
        bool mirrorPrice;
    }

    /// @notice Tokens held for one pool: principal of all its positions plus uncollected fees
    struct Reserves {
        uint128 amount0;
        uint128 amount1;
    }

    /// @notice Exponential moving average of the tick, updated at the start of every swap with the pre-swap tick.
    ///         A price pushed within a block never enters it, and one held for t seconds enters with weight
    ///         1 - e^(-t / ORACLE_TIME_CONSTANT) - so it is a manipulation-resistant reference for "the price".
    struct Oracle {
        int128 emaTickWad; // EMA of the tick, scaled by 1e18
        uint64 updatedAt;
    }

    struct AddLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        bytes32 salt;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity; // 0 only collects fees
        uint256 amount0Min;
        uint256 amount1Min;
        bytes32 salt;
        address recipient;
        uint256 deadline;
    }

    struct CallbackData {
        address sender;
        address recipient;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        bytes32 salt;
        uint256 amount0Limit; // max paid when adding, min received when removing
        uint256 amount1Limit;
        uint256 nativeValue;
    }

    IPoolManager public immutable poolManager;
    /// @notice The trading function of every pool of this hook
    ICurve public immutable curve;

    /// @notice Time constant of the price oracle's moving average
    uint256 public constant ORACLE_TIME_CONSTANT = 10 minutes;

    mapping(PoolId => CurvePool.State) internal _pools;
    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(PoolId => Reserves) public reserves;
    mapping(PoolId => Oracle) internal _oracles;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, ICurve _curve) {
        if (address(_curve).code.length == 0) revert InvalidCurve();
        poolManager = _poolManager;
        curve = _curve;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // pools are created only through initializePool
            afterInitialize: false,
            beforeAddLiquidity: true, // no liquidity inside the PoolManager's own curve
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // the hook prices and settles every swap
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ----------------------------------------------------------------------------------------------------------
    // Pool creation
    // ----------------------------------------------------------------------------------------------------------

    /// @notice Creates a pool on this hook's curve at `sqrtPriceX96`.
    /// @param mirrorPrice Whether to keep the PoolManager's slot0 price equal to the curve price after every swap
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bool mirrorPrice) external returns (int24 tick) {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotSupported();

        PoolId id = key.toId();
        poolConfig[id] = PoolConfig({curve: curve, mirrorPrice: mirrorPrice});
        tick = _pools[id].initialize(sqrtPriceX96, key.fee);
        _oracles[id] = Oracle({emaTickWad: int128(tick) * 1e18, updatedAt: uint64(block.timestamp)});
        // register the pool with v4 at the same price (hooks are not called for the hook's own initialize)
        poolManager.initialize(key, sqrtPriceX96);

        emit PoolInitialized(id, curve, sqrtPriceX96, tick, mirrorPrice);
    }

    // ----------------------------------------------------------------------------------------------------------
    // Liquidity
    // ----------------------------------------------------------------------------------------------------------

    /// @notice Adds `liquidity` on [tickLower, tickUpper] for msg.sender (the position owner).
    ///         Token amounts follow the pool's curve; use getLiquidityForAmounts to size a deposit.
    ///         Fees already earned by the position are paid out (netted against the deposit).
    function addLiquidity(PoolKey calldata key, AddLiquidityParams calldata params)
        external
        payable
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        if (block.timestamp > params.deadline) revert DeadlinePassed();
        if (params.liquidity == 0) revert ZeroLiquidity();
        if (msg.value != 0 && !key.currency0.isAddressZero()) revert NativeValueNotAccepted();

        (callerDelta, feesAccrued) = _unlockModify(
            CallbackData({
                sender: msg.sender,
                recipient: msg.sender,
                key: key,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: uint256(params.liquidity).toInt128(),
                salt: params.salt,
                amount0Limit: params.amount0Max,
                amount1Limit: params.amount1Max,
                nativeValue: msg.value
            })
        );

        if (msg.value != 0) {
            int128 amount0 = callerDelta.amount0();
            uint256 paid = amount0 < 0 ? uint256(uint128(-amount0)) : 0;
            if (msg.value > paid) SafeTransferLib.safeTransferETH(msg.sender, msg.value - paid);
        }
    }

    /// @notice Removes `liquidity` from msg.sender's position and pays out principal plus fees to `recipient`.
    function removeLiquidity(PoolKey calldata key, RemoveLiquidityParams calldata params)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        if (block.timestamp > params.deadline) revert DeadlinePassed();

        (callerDelta, feesAccrued) = _unlockModify(
            CallbackData({
                sender: msg.sender,
                recipient: params.recipient == address(0) ? msg.sender : params.recipient,
                key: key,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: -uint256(params.liquidity).toInt128(),
                salt: params.salt,
                amount0Limit: params.amount0Min,
                amount1Limit: params.amount1Min,
                nativeValue: 0
            })
        );
    }

    function unlockCallback(bytes calldata rawData) external onlyPoolManager returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolId id = data.key.toId();

        (BalanceDelta principal, BalanceDelta fees) = _pools[id].modifyLiquidity(
            _config(id).curve,
            CurvePool.ModifyLiquidityParams({
                owner: data.sender,
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: data.liquidityDelta,
                tickSpacing: data.key.tickSpacing,
                salt: data.salt
            })
        );
        _checkSlippage(principal, data);

        BalanceDelta callerDelta = principal + fees;
        // the pool gains what the caller pays and loses what the caller receives
        _applyReserves(id, -callerDelta.amount0(), -callerDelta.amount1());
        _settleWithCaller(data.key.currency0, callerDelta.amount0(), data);
        _settleWithCaller(data.key.currency1, callerDelta.amount1(), data);

        emit ModifyLiquidity(
            id, data.sender, data.tickLower, data.tickUpper, data.liquidityDelta, data.salt, principal, fees
        );
        return abi.encode(callerDelta, fees);
    }

    // ----------------------------------------------------------------------------------------------------------
    // Swaps
    // ----------------------------------------------------------------------------------------------------------

    /// @notice Prices the swap on the pool's curve and settles it in ERC-6909 claims. The returned delta takes the
    ///         whole specified amount, so the PoolManager's own swap runs with zero and does nothing.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory config = _config(id);
        _updateOracle(id, _pools[id].tick);

        (BalanceDelta swapDelta, CurvePool.SwapResult memory result) = _pools[id].swap(
            config.curve,
            CurvePool.SwapParams({
                // v4 deltas are int128; bounding the request keeps every intermediate amount in range
                amountSpecified: params.amountSpecified.toInt128(),
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );

        // the hook's side of the trade is the negation of the swapper's: +input, -output
        int128 hook0 = -swapDelta.amount0();
        int128 hook1 = -swapDelta.amount1();
        _applyReserves(id, hook0, hook1);
        _settleClaims(key.currency0, hook0);
        _settleClaims(key.currency1, hook1);
        if (config.mirrorPrice) _mirrorPrice(key, result.sqrtPriceX96);

        emit Swap(
            id, sender, swapDelta.amount0(), swapDelta.amount1(), result.sqrtPriceX96, result.liquidity, result.tick
        );

        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        BeforeSwapDelta hookDelta = specifiedIs0 ? toBeforeSwapDelta(hook0, hook1) : toBeforeSwapDelta(hook1, hook0);
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    // ----------------------------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------------------------

    function getSlot0(PoolId id) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 lpFee) {
        CurvePool.State storage pool = _pools[id];
        return (pool.sqrtPriceX96, pool.tick, pool.lpFee);
    }

    function getLiquidity(PoolId id) external view returns (uint128) {
        return _pools[id].liquidity;
    }

    function getFeeGrowthGlobals(PoolId id) external view returns (uint256, uint256) {
        CurvePool.State storage pool = _pools[id];
        return (pool.feeGrowthGlobal0X128, pool.feeGrowthGlobal1X128);
    }

    function getTickInfo(PoolId id, int24 tick) external view returns (CurvePool.TickInfo memory) {
        return _pools[id].ticks[tick];
    }

    function getPosition(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (CurvePool.Position memory)
    {
        return _pools[id].positions[CurvePool.positionKey(owner, tickLower, tickUpper, salt)];
    }

    /// @notice What a position would pay out if fully removed now: principal (rounded down) and uncollected fees
    function getPositionAmounts(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        CurvePool.State storage pool = _pools[id];
        CurvePool.Position memory position =
            pool.positions[CurvePool.positionKey(owner, tickLower, tickUpper, salt)];
        (amount0, amount1) = CurveLiquidityAmounts.getAmountsForLiquidity(
            _config(id).curve,
            pool.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            position.liquidity,
            false
        );
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = pool.getFeeGrowthInside(tickLower, tickUpper);
        unchecked {
            fees0 = FullMath.mulDiv(
                feeGrowthInside0X128 - position.feeGrowthInside0LastX128, position.liquidity, FixedPoint128.Q128
            );
            fees1 = FullMath.mulDiv(
                feeGrowthInside1X128 - position.feeGrowthInside1LastX128, position.liquidity, FixedPoint128.Q128
            );
        }
    }

    /// @notice Current tick and the oracle's moving-average tick (brought up to date without a transaction)
    function getOracle(PoolId id) external view returns (int24 tick, int24 emaTick) {
        tick = _pools[id].tick;
        emaTick = int24(_emaTickWad(_oracles[id], tick) / 1e18);
    }

    /// @notice Token amounts for `liquidity` on [tickLower, tickUpper] at the current price. With roundUp this is
    ///         exactly what addLiquidity charges; without, what removeLiquidity pays (fees excluded).
    function getAmountsForLiquidity(PoolId id, int24 tickLower, int24 tickUpper, uint128 liquidity, bool roundUp)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return CurveLiquidityAmounts.getAmountsForLiquidity(
            _config(id).curve,
            _pools[id].sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity,
            roundUp
        );
    }

    /// @notice Largest liquidity on [tickLower, tickUpper] that can be minted with at most amount0 / amount1
    function getLiquidityForAmounts(PoolId id, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        view
        returns (uint128)
    {
        return CurveLiquidityAmounts.getLiquidityForAmounts(
            _config(id).curve,
            _pools[id].sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    // ----------------------------------------------------------------------------------------------------------
    // Internal
    // ----------------------------------------------------------------------------------------------------------

    function _config(PoolId id) private view returns (PoolConfig memory config) {
        config = poolConfig[id];
        if (address(config.curve) == address(0)) revert PoolNotRegistered();
    }

    function _updateOracle(PoolId id, int24 tick) private {
        Oracle storage oracle = _oracles[id];
        if (oracle.updatedAt == block.timestamp) return;
        oracle.emaTickWad = int128(_emaTickWad(oracle, tick));
        oracle.updatedAt = uint64(block.timestamp);
    }

    /// @dev EMA after the tick has been `tick` since the last update: the old average decays by e^(-dt / tau).
    function _emaTickWad(Oracle memory oracle, int24 tick) private view returns (int256) {
        uint256 dt = block.timestamp - oracle.updatedAt;
        int256 target = int256(tick) * 1e18;
        if (dt == 0) return oracle.emaTickWad;
        if (dt >= 40 * ORACLE_TIME_CONSTANT) return target;
        int256 decay = FixedPointMathLib.expWad(-int256(dt * 1e18 / ORACLE_TIME_CONSTANT));
        return target + (int256(oracle.emaTickWad) - target) * decay / 1e18;
    }

    function _unlockModify(CallbackData memory data) private returns (BalanceDelta, BalanceDelta) {
        return abi.decode(poolManager.unlock(abi.encode(data)), (BalanceDelta, BalanceDelta));
    }

    function _checkSlippage(BalanceDelta principal, CallbackData memory data) private pure {
        int128 amount0 = principal.amount0();
        int128 amount1 = principal.amount1();
        if (data.liquidityDelta > 0) {
            // adding: principal is owed to the pool (<= 0)
            if (uint256(uint128(-amount0)) > data.amount0Limit || uint256(uint128(-amount1)) > data.amount1Limit) {
                revert SlippageExceeded();
            }
        } else if (uint256(uint128(amount0)) < data.amount0Limit || uint256(uint128(amount1)) < data.amount1Limit) {
            // removing: principal is paid to the owner (>= 0)
            revert SlippageExceeded();
        }
    }

    /// @dev Per-pool accounting: a pool can never pay out more than it has received.
    function _applyReserves(PoolId id, int128 delta0, int128 delta1) private {
        Reserves storage r = reserves[id];
        r.amount0 = _addSigned(r.amount0, delta0);
        r.amount1 = _addSigned(r.amount1, delta1);
    }

    function _addSigned(uint128 x, int128 delta) private pure returns (uint128) {
        int256 y = int256(uint256(x)) + delta;
        if (y < 0) revert InsufficientPoolReserves();
        return uint256(y).toUint128();
    }

    /// @dev Positive: the hook is owed tokens and keeps them as claims. Negative: the hook pays by burning claims.
    function _settleClaims(Currency currency, int128 amount) private {
        if (amount > 0) poolManager.mint(address(this), currency.toId(), uint128(amount));
        else if (amount < 0) poolManager.burn(address(this), currency.toId(), uint128(-amount));
    }

    function _settleWithCaller(Currency currency, int128 amount, CallbackData memory data) private {
        if (amount < 0) {
            // the caller pays into the PoolManager; the hook keeps the value as claims
            uint256 owed = uint128(-amount);
            if (currency.isAddressZero()) {
                if (owed > data.nativeValue) revert InsufficientNativeValue();
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), data.sender, address(poolManager), owed);
                poolManager.settle();
            }
            poolManager.mint(address(this), currency.toId(), owed);
        } else if (amount > 0) {
            // the caller is paid out of the hook's claims
            uint256 due = uint128(amount);
            poolManager.burn(address(this), currency.toId(), due);
            poolManager.take(currency, data.recipient, due);
        }
    }

    /// @dev The PoolManager holds no liquidity for this pool, so a 1-wei exact-input swap with our price as the limit
    ///      just walks its slot0 price to ours and settles to a zero delta. Hooks are skipped for our own swaps.
    function _mirrorPrice(PoolKey calldata key, uint160 sqrtPriceX96) private {
        (uint160 managerSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (managerSqrtPriceX96 == sqrtPriceX96) return;
        poolManager.swap(
            key,
            SwapParams({
                zeroForOne: sqrtPriceX96 < managerSqrtPriceX96,
                amountSpecified: -1,
                sqrtPriceLimitX96: sqrtPriceX96
            }),
            ""
        );
    }

    // ----------------------------------------------------------------------------------------------------------
    // Hook callbacks that are not permissioned (never called by the PoolManager)
    // ----------------------------------------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert InitializeThroughHook();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
