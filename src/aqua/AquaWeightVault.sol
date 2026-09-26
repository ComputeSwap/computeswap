// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ERC721} from "solady/tokens/ERC721.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";

import {ComputeswapAquaApp} from "./ComputeswapAquaApp.sol";
import {WeightToken} from "../weights/WeightToken.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title AquaWeightVault - LP positions on Aqua as NFTs whose ETH (or USDC) weight can be split off and sold
/// @notice The workaround for weights on Aqua. Aqua keeps a maker's tokens in the maker's own wallet, so a weight
///         sold on a plain strategy could not be enforced: the maker could dock the strategy or move the tokens away
///         at any time. This vault is therefore the maker. It custodies the position's tokens, ships one Aqua
///         strategy per position (maker = this contract, salt = position id), and only the vault can dock it - so
///         it can lock liquidity behind live weights exactly as the Uniswap version does.
///
///         Everything else follows WeightVault:
///           - `mint` opens a position (ships the strategy) and issues an ERC-721 to the LP;
///           - `split` locks `units` of its liquidity until `expiry` and mints `units` WeightTokens for one leg;
///           - `exercise`: until expiry a holder makes the vault withdraw `units` at the current price and take that
///             leg; the NFT owner receives the other leg and the position's fees;
///           - `merge` burns weights the owner holds, `decreaseLiquidity` withdraws unlocked liquidity.
///
///         Aqua strategies are immutable, so withdrawing part of a position means docking its strategy and shipping
///         a new one with the remaining liquidity at the same price (a fresh salt each time). Fees are the Aqua
///         balance beyond the principal implied by the curve, and go to the owner on every change, as in the hook.
///
///         Exercise is guarded by the app's moving-average tick like the hook's. Note that a strategy has a single LP,
///         so the LP can move its own price for free (trading against themselves costs only the fee they earn back);
///         what makes that expensive is arbitrage against the mispriced strategy while the average catches up, not
///         the fee. Replace `_checkOracle` with an external feed if that is not enough for your market.
contract AquaWeightVault is ERC721, ReentrancyGuard {
    error NotOwnerOrApproved();
    error DeadlinePassed();
    error PositionClosed();
    error LiquidityLocked(uint128 free);
    error SeriesStillActive(uint256 seriesId);
    error InvalidSplit();
    error SeriesExpired(uint256 seriesId);
    error OracleDeviation(int24 tick, int24 emaTick);
    error Slippage();

    event PositionMinted(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 strategyHash,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice The position's strategy was docked and (if liquidity remains) a new one shipped
    event Reshipped(uint256 indexed positionId, bytes32 oldStrategyHash, bytes32 newStrategyHash, uint128 liquidity);
    event LiquidityDecreased(
        uint256 indexed positionId, uint128 liquidity, uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1
    );
    event Split(uint256 indexed positionId, uint256 indexed seriesId, uint8 leg, uint128 units, uint64 expiry);
    event Exercised(
        uint256 indexed seriesId, address indexed holder, uint128 units, uint256 legAmount, uint256 otherAmount
    );
    event Merged(uint256 indexed seriesId, uint128 units);
    event Owed(address indexed owner, address indexed token, uint256 amount);
    event Claimed(address indexed owner, address indexed token, address to, uint256 amount);

    struct Position {
        ComputeswapAquaApp.Strategy strategy; // the live strategy; liquidity 0 once the position is closed
        uint32 nonce; // number of times the strategy has been re-shipped (salts)
        uint256 activeSeries; // latest series split from this position (0 = never split)
    }

    struct Series {
        uint256 positionId;
        uint64 expiry;
        uint8 leg; // 0 = token0 (ETH), 1 = token1 (USDC)
        uint128 remaining; // units still locked: split - exercised - merged
    }

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint160 sqrtPriceX96; // the market price the position opens at (an off-market price is arbitraged away)
        uint256 amount0Max;
        uint256 amount1Max;
        uint256 deadline;
    }

    ComputeswapAquaApp public immutable app;
    IAqua public immutable aqua;
    WeightToken public immutable weights;
    /// @notice Largest |tick - moving-average tick| at which weights can be exercised (100 ticks ~ 1% in price)
    uint24 public immutable maxOracleDeviation;

    uint256 public nextPositionId = 1;
    uint256 public nextSeriesId = 1;
    mapping(uint256 positionId => Position) internal _positions;
    mapping(uint256 seriesId => Series) public series;
    /// @notice Exercise payouts that could not be pushed to a position's owner; withdrawn with `claim`
    mapping(address owner => mapping(address token => uint256 amount)) public owed;
    mapping(address token => bool) private _approvedToAqua;

    constructor(ComputeswapAquaApp _app, uint24 _maxOracleDeviation) {
        app = _app;
        aqua = _app.AQUA();
        maxOracleDeviation = _maxOracleDeviation;
        weights = new WeightToken();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Positions
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Opens a position: pulls exactly the curve amounts (rounded up) from msg.sender, ships them as an Aqua
    ///         strategy with the vault as maker, and mints the position's NFT to msg.sender.
    function mint(MintParams calldata m)
        external
        nonReentrant
        returns (uint256 positionId, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > m.deadline) revert DeadlinePassed();
        positionId = nextPositionId++;
        ComputeswapAquaApp.Strategy memory s = ComputeswapAquaApp.Strategy({
            maker: address(this),
            token0: m.token0,
            token1: m.token1,
            fee: m.fee,
            tickLower: m.tickLower,
            tickUpper: m.tickUpper,
            liquidity: m.liquidity,
            sqrtPriceX96: m.sqrtPriceX96,
            salt: _salt(positionId, 0)
        });
        (amount0, amount1) = app.openingAmounts(s); // validates the strategy
        if (amount0 > m.amount0Max || amount1 > m.amount1Max) revert Slippage();

        _pullAndApprove(m.token0, amount0);
        _pullAndApprove(m.token1, amount1);
        bytes32 hash = aqua.ship(address(app), abi.encode(s), _pair(m.token0, m.token1), _amounts(amount0, amount1));

        _positions[positionId] = Position({strategy: s, nonce: 0, activeSeries: 0});
        _mint(msg.sender, positionId);
        emit PositionMinted(positionId, msg.sender, hash, m.tickLower, m.tickUpper, m.liquidity, amount0, amount1);
    }

    /// @notice Withdraws unlocked liquidity (0 = just collect fees) to the position's owner: its principal at the
    ///         current price plus all of the position's fees. Re-ships the remaining liquidity.
    function decreaseLiquidity(
        uint256 positionId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _checkAuthorized(positionId);
        Position storage p = _positions[positionId];
        if (p.strategy.liquidity == 0) revert PositionClosed();
        uint128 free = p.strategy.liquidity - lockedLiquidity(positionId);
        if (liquidity > free) revert LiquidityLocked(free);

        (amount0, amount1, fees0, fees1) = _release(positionId, liquidity);
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();
        address owner = ownerOf(positionId);
        _pay(p.strategy.token0, owner, amount0 + fees0);
        _pay(p.strategy.token1, owner, amount1 + fees1);
        emit LiquidityDecreased(positionId, liquidity, amount0, amount1, fees0, fees1);
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
        if (units == 0 || units > p.strategy.liquidity || leg > 1 || duration == 0) revert InvalidSplit();

        seriesId = nextSeriesId++;
        uint64 expiry = uint64(block.timestamp) + duration;
        series[seriesId] = Series({positionId: positionId, expiry: expiry, leg: leg, remaining: units});
        p.activeSeries = seriesId;

        address owner = ownerOf(positionId);
        weights.createSeries(seriesId, positionId, expiry, leg, _unitDecimals(p.strategy.token1));
        weights.mint(owner, seriesId, units);
        emit Split(positionId, seriesId, leg, units, expiry);
    }

    /// @notice Exercises `units` weights before expiry: withdraws that liquidity at the current price, pays the
    ///         weight's leg to the caller and the other leg (plus the position's fees) to the position's owner.
    /// @param minLegAmount Least amount of the weight's token the caller accepts
    function exercise(uint256 seriesId, uint128 units, uint256 minLegAmount, uint256 deadline)
        external
        nonReentrant
        returns (uint256 legAmount, uint256 otherAmount)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        Series storage s = series[seriesId];
        if (block.timestamp >= s.expiry) revert SeriesExpired(seriesId);
        Position storage p = _positions[s.positionId];
        _checkOracle(p.strategy);

        weights.burn(msg.sender, seriesId, units);
        s.remaining -= units;

        (legAmount, otherAmount) = _distribute(s.positionId, s.leg, units);
        if (legAmount < minLegAmount) revert Slippage();
        emit Exercised(seriesId, msg.sender, units, legAmount, otherAmount);
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
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender][token];
        owed[msg.sender][token] = 0;
        _pay(token, to, amount);
        emit Claimed(msg.sender, token, to, amount);
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

    /// @notice The position's live Aqua strategy (what a taker passes to the app); liquidity 0 once closed
    function strategyOf(uint256 positionId) external view returns (ComputeswapAquaApp.Strategy memory) {
        return _positions[positionId].strategy;
    }

    function strategyHashOf(uint256 positionId) external view returns (bytes32) {
        return keccak256(abi.encode(_positions[positionId].strategy));
    }

    function getPosition(uint256 positionId)
        external
        view
        returns (ComputeswapAquaApp.Strategy memory strategy, uint128 locked, uint256 activeSeries, address owner)
    {
        Position storage p = _positions[positionId];
        return (p.strategy, lockedLiquidity(positionId), p.activeSeries, _ownerOf(positionId));
    }

    /// @notice What the position holds now: principal at the current price (rounded down) and uncollected fees
    function positionAmounts(uint256 positionId)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        ComputeswapAquaApp.Strategy memory s = _positions[positionId].strategy;
        if (s.liquidity == 0) return (0, 0, 0, 0);
        (amount0, amount1) = app.amountsForLiquidity(s, s.liquidity, false);
        (,, fees0, fees1) = _balancesAndFees(s);
    }

    /// @notice What exercising `units` would pay right now (fees excluded), and whether the oracle allows it
    function previewExercise(uint256 seriesId, uint128 units)
        external
        view
        returns (uint256 legAmount, uint256 otherAmount, bool allowed, int24 tick, int24 emaTick)
    {
        Series storage s = series[seriesId];
        ComputeswapAquaApp.Strategy memory strategy = _positions[s.positionId].strategy;
        (uint256 amount0, uint256 amount1) = app.amountsForLiquidity(strategy, units, false);
        (legAmount, otherAmount) = s.leg == 0 ? (amount0, amount1) : (amount1, amount0);
        (tick, emaTick) = app.getOracle(strategy);
        allowed = block.timestamp < s.expiry && _within(tick, emaTick);
    }

    function name() public pure override returns (string memory) {
        return "Computeswap Aqua LP Position";
    }

    function symbol() public pure override returns (string memory) {
        return "CSALP";
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Exercise payout: the weight's leg to the caller; the other leg and all of the position's fees to the owner.
    function _distribute(uint256 positionId, uint8 leg, uint128 units)
        private
        returns (uint256 legAmount, uint256 otherAmount)
    {
        (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) = _release(positionId, units);
        ComputeswapAquaApp.Strategy storage st = _positions[positionId].strategy; // tokens survive the re-ship
        address owner = ownerOf(positionId);
        if (leg == 0) {
            (legAmount, otherAmount) = (amount0, amount1);
            _pay(st.token0, msg.sender, amount0);
            _payOwner(st.token1, owner, amount1 + fees1);
            _payOwner(st.token0, owner, fees0);
        } else {
            (legAmount, otherAmount) = (amount1, amount0);
            _pay(st.token1, msg.sender, amount1);
            _payOwner(st.token0, owner, amount0 + fees0);
            _payOwner(st.token1, owner, fees1);
        }
    }

    struct Release {
        uint160 sqrtPriceX96;
        uint128 remaining;
        uint256 balance0;
        uint256 balance1;
        uint256 fees0;
        uint256 fees1;
        uint256 keep0; // principal the remaining liquidity is re-shipped with
        uint256 keep1;
    }

    /// @dev Takes `units` of liquidity out of the position at the current price: docks its strategy and, if any
    ///      liquidity remains, ships a new one holding exactly that liquidity's principal. Everything else the
    ///      strategy held is released: the withdrawn units' principal and the position's fees (both tokens).
    function _release(uint256 positionId, uint128 units)
        private
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        Position storage p = _positions[positionId];
        ComputeswapAquaApp.Strategy memory s = p.strategy;
        Release memory r = _plan(s, units);
        amount0 = r.balance0 - r.fees0 - r.keep0;
        amount1 = r.balance1 - r.fees1 - r.keep1;
        (fees0, fees1) = (r.fees0, r.fees1);

        bytes32 hash = keccak256(abi.encode(s));
        address[] memory tokens = _pair(s.token0, s.token1);
        aqua.dock(address(app), hash, tokens);
        bytes32 newHash;
        if (r.remaining != 0) {
            s.liquidity = r.remaining;
            s.sqrtPriceX96 = r.sqrtPriceX96;
            s.salt = _salt(positionId, ++p.nonce);
            newHash = aqua.ship(address(app), abi.encode(s), tokens, _amounts(r.keep0, r.keep1));
            p.strategy = s;
        } else {
            // closed: liquidity 0, and the last price kept for readers
            p.strategy.liquidity = 0;
            p.strategy.sqrtPriceX96 = r.sqrtPriceX96;
        }
        emit Reshipped(positionId, hash, newHash, r.remaining);
    }

    /// @dev Splits what the strategy holds into fees, the principal to re-ship and the part to release
    function _plan(ComputeswapAquaApp.Strategy memory s, uint128 units) private view returns (Release memory r) {
        (r.balance0, r.balance1, r.fees0, r.fees1) = _balancesAndFees(s);
        (r.sqrtPriceX96,) = app.currentSqrtPrice(s);
        r.remaining = s.liquidity - units;
        if (r.remaining != 0) {
            (r.keep0, r.keep1) = app.amountsForLiquidity(s, r.remaining, true);
            // never re-ship more than the position holds (rounding can leave the last wei short)
            if (r.keep0 > r.balance0 - r.fees0) r.keep0 = r.balance0 - r.fees0;
            if (r.keep1 > r.balance1 - r.fees1) r.keep1 = r.balance1 - r.fees1;
        }
    }

    /// @dev The strategy's Aqua balances and the part of them beyond the curve's principal (the fees)
    function _balancesAndFees(ComputeswapAquaApp.Strategy memory s)
        private
        view
        returns (uint256 balance0, uint256 balance1, uint256 fees0, uint256 fees1)
    {
        bytes32 hash = keccak256(abi.encode(s));
        (balance0,) = aqua.rawBalances(address(this), address(app), hash, s.token0);
        (balance1,) = aqua.rawBalances(address(this), address(app), hash, s.token1);
        (uint256 principal0, uint256 principal1) = app.amountsForLiquidity(s, s.liquidity, true);
        fees0 = balance0 > principal0 ? balance0 - principal0 : 0;
        fees1 = balance1 > principal1 ? balance1 - principal1 : 0;
    }

    function _checkAuthorized(uint256 positionId) private view {
        if (!_isApprovedOrOwner(msg.sender, positionId)) revert NotOwnerOrApproved();
    }

    function _checkOracle(ComputeswapAquaApp.Strategy memory s) private view {
        (int24 tick, int24 emaTick) = app.getOracle(s);
        if (!_within(tick, emaTick)) revert OracleDeviation(tick, emaTick);
    }

    function _within(int24 tick, int24 emaTick) private view returns (bool) {
        int256 d = int256(tick) - int256(emaTick);
        return (d < 0 ? -d : d) <= int256(uint256(maxOracleDeviation));
    }

    function _salt(uint256 positionId, uint32 nonce) private pure returns (bytes32) {
        return nonce == 0 ? bytes32(positionId) : keccak256(abi.encode(positionId, nonce));
    }

    function _pair(address token0, address token1) private pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
    }

    function _amounts(uint256 amount0, uint256 amount1) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;
    }

    /// @dev Pulls a deposit from the LP and (once per token) lets Aqua pull from the vault when takers buy
    function _pullAndApprove(address token, uint256 amount) private {
        if (amount != 0) SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        if (!_approvedToAqua[token]) {
            _approvedToAqua[token] = true;
            SafeTransferLib.safeApproveWithRetry(token, address(aqua), type(uint256).max);
        }
    }

    function _pay(address token, address to, uint256 amount) private {
        if (amount != 0) SafeTransferLib.safeTransfer(token, to, amount);
    }

    /// @dev Pays a position's owner without letting the owner make the payment (and so the exercise) revert
    function _payOwner(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (!_tryTransfer(token, to, amount)) {
            owed[to][token] += amount;
            emit Owed(to, token, amount);
        }
    }

    /// @dev ERC20 transfer that reports failure instead of reverting
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        return ok && (data.length == 0 ? token.code.length != 0 : data.length >= 32 && abi.decode(data, (bool)));
    }

    function _unitDecimals(address token1) private view returns (uint8) {
        // for the log curve, L is denominated in token1
        try IERC20Decimals(token1).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
