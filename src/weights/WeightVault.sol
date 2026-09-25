// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC721} from "solady/tokens/ERC721.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ConcentratedCurveHook} from "../ConcentratedCurveHook.sol";
import {WeightToken} from "./WeightToken.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title WeightVault - LP positions as NFTs whose ETH (or USDC) weight can be split off and sold
/// @notice A position with liquidity L on [pa, pb] holds two weights: x(P) of currency0 and y(P) of currency1.
///
///         - `mint` opens a position through the hook; the vault owns it in the hook and issues an ERC-721 to the LP.
///         - `split` locks `units` of its liquidity until `expiry` and mints `units` WeightTokens for one leg
///           (ETH by default) to the owner, who can sell them - e.g. in WeightAuction.
///         - `exercise`: until expiry, a weight holder can make the vault withdraw `units` of liquidity at the current
///           price. They receive that leg (the ETH, x(P) per unit); the position's owner receives the other leg and
///           the position's fees. The weights are burned.
///         - `merge`: the owner can burn weights it holds (e.g. unsold ones) to unlock that liquidity early.
///         - At expiry nothing needs to happen: unexercised weights lapse (read as zero), the lock disappears, and the
///           owner can withdraw everything with `decreaseLiquidity`.
///
///         Exercise happens at the pool's current price, which the exerciser could otherwise push with a flash swap to
///         enlarge the ETH leg. So it is only allowed while the current tick is within `maxOracleDeviation` ticks of
///         the hook's moving-average tick, which a same-block move does not affect.
///
///         The owner's share of an exercise is pushed, but a failed push (an owner contract that rejects ETH, a
///         blacklisted USDC address) is credited to `owed` instead of reverting, so an LP cannot sell a weight and then
///         make it impossible to exercise.
contract WeightVault is ERC721, ReentrancyGuard {
    error NotOwnerOrApproved();
    error LiquidityLocked(uint128 free);
    error SeriesStillActive(uint256 seriesId);
    error InvalidSplit();
    error SeriesExpired(uint256 seriesId);
    error OracleDeviation(int24 tick, int24 emaTick);
    error Slippage();
    error NativeValueMismatch();
    error UnexpectedSender();

    event PositionMinted(
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event LiquidityDecreased(uint256 indexed positionId, uint128 liquidity, BalanceDelta principal, BalanceDelta fees);
    event Split(uint256 indexed positionId, uint256 indexed seriesId, uint8 leg, uint128 units, uint64 expiry);
    event Exercised(
        uint256 indexed seriesId, address indexed holder, uint128 units, uint256 legAmount, uint256 otherAmount
    );
    event Merged(uint256 indexed seriesId, uint128 units);
    event Owed(address indexed owner, Currency indexed currency, uint256 amount);
    event Claimed(address indexed owner, Currency indexed currency, address to, uint256 amount);

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 activeSeries; // latest series split from this position (0 = never split)
    }

    struct Series {
        uint256 positionId;
        uint64 expiry;
        uint8 leg; // 0 = currency0 (ETH), 1 = currency1 (USDC)
        uint128 remaining; // units still locked: split - exercised - merged
    }

    ConcentratedCurveHook public immutable hook;
    WeightToken public immutable weights;
    /// @notice Largest |tick - moving-average tick| at which weights can be exercised (100 ticks ~ 1% in price)
    uint24 public immutable maxOracleDeviation;
    address private immutable poolManager;

    uint256 public nextPositionId = 1;
    uint256 public nextSeriesId = 1;
    mapping(uint256 positionId => Position) internal _positions;
    mapping(uint256 seriesId => Series) public series;
    /// @notice Exercise payouts that could not be pushed to a position's owner; withdrawn with `claim`
    mapping(address owner => mapping(Currency currency => uint256 amount)) public owed;
    mapping(address token => bool) private _approvedToHook;

    constructor(ConcentratedCurveHook _hook, uint24 _maxOracleDeviation) {
        hook = _hook;
        poolManager = address(_hook.poolManager());
        maxOracleDeviation = _maxOracleDeviation;
        weights = new WeightToken();
    }

    /// @dev ETH arrives from the hook (unused deposit) and the PoolManager (withdrawals paid to the vault)
    receive() external payable {
        if (msg.sender != address(hook) && msg.sender != poolManager) revert UnexpectedSender();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Positions
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Opens a position with `liquidity` on [tickLower, tickUpper] and mints its NFT to msg.sender.
    ///         Charges exactly the curve amounts (rounded up); send ETH >= amount0 when currency0 is native.
    function mint(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 positionId, uint256 amount0, uint256 amount1) {
        (amount0, amount1) = hook.getAmountsForLiquidity(key.toId(), tickLower, tickUpper, liquidity, true);
        if (amount0 > amount0Max || amount1 > amount1Max) revert Slippage();

        positionId = nextPositionId++;
        _positions[positionId] =
            Position({key: key, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, activeSeries: 0});
        _mint(msg.sender, positionId);

        bool native = key.currency0.isAddressZero();
        if (native ? msg.value < amount0 : msg.value != 0) revert NativeValueMismatch();
        if (!native) _pullAndApprove(key.currency0, amount0);
        _pullAndApprove(key.currency1, amount1);

        hook.addLiquidity{value: native ? amount0 : 0}(
            key,
            ConcentratedCurveHook.AddLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amount0Max: amount0,
                amount1Max: amount1,
                salt: bytes32(positionId),
                deadline: deadline
            })
        );
        if (native && msg.value > amount0) SafeTransferLib.safeTransferETH(msg.sender, msg.value - amount0);
        emit PositionMinted(positionId, msg.sender, tickLower, tickUpper, liquidity, amount0, amount1);
    }

    /// @notice Withdraws unlocked liquidity (0 = just collect fees) to the position's owner.
    function decreaseLiquidity(
        uint256 positionId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (BalanceDelta principal, BalanceDelta fees) {
        _checkAuthorized(positionId);
        Position storage p = _positions[positionId];
        uint128 free = p.liquidity - lockedLiquidity(positionId);
        if (liquidity > free) revert LiquidityLocked(free);
        p.liquidity -= liquidity;

        BalanceDelta total;
        (total, fees) = hook.removeLiquidity(
            p.key,
            ConcentratedCurveHook.RemoveLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                salt: bytes32(positionId),
                recipient: ownerOf(positionId),
                deadline: deadline
            })
        );
        principal = total - fees;
        emit LiquidityDecreased(positionId, liquidity, principal, fees);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Weights
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Splits one leg off `units` of the position's liquidity: locks them for `duration` and mints `units`
    ///         WeightTokens of that leg to the owner. One series per position may be live at a time.
    function split(uint256 positionId, uint128 units, uint8 leg, uint64 duration)
        external
        nonReentrant
        returns (uint256 seriesId)
    {
        _checkAuthorized(positionId);
        Position storage p = _positions[positionId];
        if (lockedLiquidity(positionId) != 0) revert SeriesStillActive(p.activeSeries);
        if (units == 0 || units > p.liquidity || leg > 1 || duration == 0) revert InvalidSplit();

        seriesId = nextSeriesId++;
        uint64 expiry = uint64(block.timestamp) + duration;
        series[seriesId] = Series({positionId: positionId, expiry: expiry, leg: leg, remaining: units});
        p.activeSeries = seriesId;

        address owner = ownerOf(positionId);
        weights.createSeries(seriesId, positionId, expiry, leg, _unitDecimals(p.key));
        weights.mint(owner, seriesId, units);
        emit Split(positionId, seriesId, leg, units, expiry);
    }

    /// @notice Exercises `units` weights before expiry: withdraws that liquidity at the current price, pays the
    ///         weight's leg to the caller and the other leg (plus the position's fees) to the position's owner.
    /// @param minLegAmount Least amount of the weight's currency the caller accepts
    function exercise(uint256 seriesId, uint128 units, uint256 minLegAmount, uint256 deadline)
        external
        nonReentrant
        returns (uint256 legAmount, uint256 otherAmount)
    {
        Series storage s = series[seriesId];
        if (block.timestamp >= s.expiry) revert SeriesExpired(seriesId);
        Position storage p = _positions[s.positionId];
        _checkOracle(p.key);

        weights.burn(msg.sender, seriesId, units);
        s.remaining -= units;
        p.liquidity -= units;

        (BalanceDelta total, BalanceDelta fees) = hook.removeLiquidity(
            p.key,
            ConcentratedCurveHook.RemoveLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidity: units,
                amount0Min: 0,
                amount1Min: 0,
                salt: bytes32(s.positionId),
                recipient: address(this),
                deadline: deadline
            })
        );
        (legAmount, otherAmount) = _distribute(p.key, s.leg, ownerOf(s.positionId), total - fees, fees);
        if (legAmount < minLegAmount) revert Slippage();
        emit Exercised(seriesId, msg.sender, units, legAmount, otherAmount);
    }

    /// @dev Exercise payout: the weight's leg to the caller; the other leg and all of the position's fees to the owner.
    function _distribute(PoolKey storage key, uint8 leg, address owner, BalanceDelta principal, BalanceDelta fees)
        private
        returns (uint256 legAmount, uint256 otherAmount)
    {
        uint256 principal0 = uint128(principal.amount0());
        uint256 principal1 = uint128(principal.amount1());
        (legAmount, otherAmount) = leg == 0 ? (principal0, principal1) : (principal1, principal0);
        (Currency legCurrency, Currency otherCurrency) =
            leg == 0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 legFees, int128 otherFees) =
            leg == 0 ? (fees.amount0(), fees.amount1()) : (fees.amount1(), fees.amount0());
        _pay(legCurrency, msg.sender, legAmount);
        _payOwner(otherCurrency, owner, otherAmount + uint128(otherFees));
        _payOwner(legCurrency, owner, uint128(legFees));
    }

    /// @notice The position's owner burns weights it holds (e.g. unsold ones) to unlock that liquidity early.
    function merge(uint256 seriesId, uint128 units) external nonReentrant {
        Series storage s = series[seriesId];
        _checkAuthorized(s.positionId);
        if (block.timestamp >= s.expiry) revert SeriesExpired(seriesId); // nothing is locked any more
        weights.burn(msg.sender, seriesId, units);
        s.remaining -= units;
        emit Merged(seriesId, units);
    }

    /// @notice Withdraws exercise payouts that could not be pushed to msg.sender as a position owner
    function claim(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender][currency];
        owed[msg.sender][currency] = 0;
        _pay(currency, to, amount);
        emit Claimed(msg.sender, currency, to, amount);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Liquidity that cannot be withdrawn because live weights may still claim it (0 once they expire)
    function lockedLiquidity(uint256 positionId) public view returns (uint128) {
        uint256 s = _positions[positionId].activeSeries;
        if (s == 0) return 0;
        Series storage ser = series[s];
        return block.timestamp < ser.expiry ? ser.remaining : 0;
    }

    function getPosition(uint256 positionId)
        external
        view
        returns (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint128 locked,
            uint256 activeSeries,
            address owner
        )
    {
        Position storage p = _positions[positionId];
        return (
            p.key, p.tickLower, p.tickUpper, p.liquidity, lockedLiquidity(positionId), p.activeSeries, _ownerOf(positionId)
        );
    }

    /// @notice What exercising `units` would pay right now (fees excluded), and whether the oracle allows it
    function previewExercise(uint256 seriesId, uint128 units)
        external
        view
        returns (uint256 legAmount, uint256 otherAmount, bool allowed, int24 tick, int24 emaTick)
    {
        Series storage s = series[seriesId];
        Position storage p = _positions[s.positionId];
        (uint256 amount0, uint256 amount1) =
            hook.getAmountsForLiquidity(p.key.toId(), p.tickLower, p.tickUpper, units, false);
        (legAmount, otherAmount) = s.leg == 0 ? (amount0, amount1) : (amount1, amount0);
        (tick, emaTick) = hook.getOracle(p.key.toId());
        allowed = block.timestamp < s.expiry && _within(tick, emaTick);
    }

    function name() public pure override returns (string memory) {
        return "Log Curve LP Position";
    }

    function symbol() public pure override returns (string memory) {
        return "LCLP";
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------------------

    function _checkAuthorized(uint256 positionId) private view {
        if (!_isApprovedOrOwner(msg.sender, positionId)) revert NotOwnerOrApproved();
    }

    function _checkOracle(PoolKey storage key) private view {
        (int24 tick, int24 emaTick) = hook.getOracle(key.toId());
        if (!_within(tick, emaTick)) revert OracleDeviation(tick, emaTick);
    }

    function _within(int24 tick, int24 emaTick) private view returns (bool) {
        int256 d = int256(tick) - int256(emaTick);
        return (d < 0 ? -d : d) <= int256(uint256(maxOracleDeviation));
    }

    function _pullAndApprove(Currency currency, uint256 amount) private {
        address token = Currency.unwrap(currency);
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        if (!_approvedToHook[token]) {
            // the hook pulls deposits from the vault
            _approvedToHook[token] = true;
            SafeTransferLib.safeApproveWithRetry(token, address(hook), type(uint256).max);
        }
    }

    function _pay(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) SafeTransferLib.safeTransferETH(to, amount);
        else SafeTransferLib.safeTransfer(Currency.unwrap(currency), to, amount);
    }

    /// @dev Pays a position's owner without letting the owner make the payment (and so the exercise) revert
    function _payOwner(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        bool ok = currency.isAddressZero()
            ? SafeTransferLib.trySafeTransferETH(to, amount, SafeTransferLib.GAS_STIPEND_NO_GRIEF)
            : _tryTransfer(Currency.unwrap(currency), to, amount);
        if (!ok) {
            owed[to][currency] += amount;
            emit Owed(to, currency, amount);
        }
    }

    /// @dev ERC20 transfer that reports failure instead of reverting
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        return ok && (data.length == 0 ? token.code.length != 0 : data.length >= 32 && abi.decode(data, (bool)));
    }

    function _unitDecimals(PoolKey storage key) private view returns (uint8) {
        // for the log curve, L is denominated in currency1 (never native: native ETH always sorts first)
        try IERC20Decimals(Currency.unwrap(key.currency1)).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
