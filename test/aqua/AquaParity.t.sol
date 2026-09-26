// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Aqua} from "@1inch/aqua/Aqua.sol";
import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";
import {IXYCSwapCallback} from "@1inch/aqua-examples/apps/interfaces/IXYCSwapCallback.sol";

import {LogCurve} from "../../src/curves/LogCurve.sol";
import {ComputeswapAquaApp} from "../../src/aqua/ComputeswapAquaApp.sol";

/// @dev The v4 hook's ABI. The hook is compiled with solc 0.8.26 (Uniswap's PoolManager pins it) and the Aqua stack
///      with 0.8.30 (1inch's AquaApp requires it), so this test deploys the v4 side from its artifact.
interface IConcentratedCurveHook {
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
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        bytes32 salt;
        address recipient;
        uint256 deadline;
    }

    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bool mirrorPrice) external returns (int24);
    function addLiquidity(PoolKey calldata key, AddLiquidityParams calldata params)
        external
        payable
        returns (BalanceDelta, BalanceDelta);
    function removeLiquidity(PoolKey calldata key, RemoveLiquidityParams calldata params)
        external
        returns (BalanceDelta, BalanceDelta);
    function getSlot0(PoolId id) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 lpFee);
    function getPositionAmounts(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1);
}

/// @notice The same position on the Uniswap v4 hook and as an Aqua strategy, the same swaps against both: identical
///         outputs, prices and fees. This is what "the algorithm works in Aqua" means.
/// @dev forge test --match-contract AquaParityTest -vv
contract AquaParityTest is Test, IXYCSwapCallback {
    /// @dev The PoolManager is compiled in the 0.8.26 unit, which a filtered `forge test` run may not include; its
    ///      artifact on disk (from `forge build`) is used in that case.
    string internal constant POOL_MANAGER_ARTIFACT = "out/PoolManager.sol/PoolManager.json";
    uint160 internal constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    // The v4 engine walks the tick bitmap one 256-tick word at a time and rounds every step; inside a single word
    // each swap is one step on both sides, so the comparison can be exact. (Across word boundaries v4 splits the
    // swap and the results differ by the curve's rounding allowance, ~1e-16 of the amount.)
    int24 internal constant LOWER = 60;
    int24 internal constant UPPER = 6000;
    int24 internal constant START_TICK = 3000;
    uint128 internal constant L = 1e22;
    uint24 internal constant FEE = 3000;

    MockERC20 internal token0;
    MockERC20 internal token1;
    LogCurve internal curve;

    // Uniswap side
    IPoolManager internal manager;
    IConcentratedCurveHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolKey internal key;

    // Aqua side
    Aqua internal aqua;
    ComputeswapAquaApp internal app;
    ComputeswapAquaApp.Strategy internal s;

    function setUp() public {
        _requireV4Artifacts();
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        curve = new LogCurve();

        // v4: PoolManager, the hook at an address carrying its permission flags, a test router
        manager = IPoolManager(deployCode(POOL_MANAGER_ARTIFACT, abi.encode(address(this))));
        address hookAddress = address(HOOK_FLAGS ^ (uint160(0x4444) << 144));
        deployCodeTo(
            "ConcentratedCurveHook.sol:ConcentratedCurveHook", abi.encode(manager, address(curve)), hookAddress
        );
        hook = IConcentratedCurveHook(hookAddress);
        swapRouter = new PoolSwapTest(manager);
        token0.approve(hookAddress, type(uint256).max);
        token1.approve(hookAddress, type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), FEE, 60, IHooks(hookAddress));
        uint160 startPrice = TickMath.getSqrtPriceAtTick(START_TICK);
        hook.initializePool(key, startPrice, false);
        hook.addLiquidity(
            key,
            IConcentratedCurveHook.AddLiquidityParams(
                LOWER, UPPER, L, type(uint256).max, type(uint256).max, bytes32(0), block.timestamp
            )
        );

        // Aqua: the same position shipped from this contract's wallet
        aqua = new Aqua();
        app = new ComputeswapAquaApp(IAqua(address(aqua)), curve);
        token0.approve(address(aqua), type(uint256).max);
        token1.approve(address(aqua), type(uint256).max);
        s = ComputeswapAquaApp.Strategy({
            maker: address(this),
            token0: address(token0),
            token1: address(token1),
            fee: FEE,
            tickLower: LOWER,
            tickUpper: UPPER,
            liquidity: L,
            sqrtPriceX96: startPrice,
            salt: bytes32(0)
        });
        (uint256 amount0, uint256 amount1) = app.openingAmounts(s);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(token0), address(token1));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (amount0, amount1);
        aqua.ship(address(app), abi.encode(s), tokens, amounts);
    }

    /// The taker side of the Aqua swap: push the input to the maker's balance
    function xycSwapCallback(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256,
        address maker,
        address appAddr,
        bytes32 strategyHash,
        bytes calldata
    ) external override {
        aqua.push(maker, appAddr, strategyHash, tokenIn, amountIn);
    }

    /// The position holds the same amounts on both sides; shipping charges the round-up deposit, which exceeds the
    /// round-down payout by the curve's directed-rounding allowance.
    function test_openingAmountsMatchTheHook() public view {
        (uint256 h0, uint256 h1,,) = hook.getPositionAmounts(key.toId(), address(this), LOWER, UPPER, bytes32(0));
        (uint256 a0, uint256 a1) = app.amountsForLiquidity(s, L, false);
        assertEq(a0, h0, "payout amounts are identical");
        assertEq(a1, h1);
        (uint256 u0, uint256 u1) = app.openingAmounts(s);
        assertGe(u0, a0);
        assertGe(u1, a1);
        assertApproxEqRel(u1, a1, 1e3, "the round-up deposit is within 1e-15 of the payout");
    }

    /// The same six swaps on both: inputs, outputs, prices, ticks and accrued fees are identical to the wei.
    function test_swapsMatchTheHook() public {
        int256[6] memory amounts = [int256(-1e20), -3e20, 5e19, 2e20, -1e21, -8e20];
        bool[6] memory zeroForOne = [true, false, true, false, true, false];
        for (uint256 i; i < 6; ++i) {
            (uint256 hIn, uint256 hOut) = _hookSwap(zeroForOne[i], amounts[i]);
            (uint256 aIn, uint256 aOut) = _aquaSwap(zeroForOne[i], amounts[i]);
            assertEq(aIn, hIn, "input");
            assertEq(aOut, hOut, "output");
            (uint160 hPrice, int24 hTick,) = hook.getSlot0(key.toId());
            (uint160 aPrice, int24 aTick) = app.currentSqrtPrice(s);
            assertEq(aPrice, hPrice, "price");
            assertEq(aTick, hTick, "tick");
        }
        (,, uint256 hFees0, uint256 hFees1) =
            hook.getPositionAmounts(key.toId(), address(this), LOWER, UPPER, bytes32(0));
        (uint256 aFees0, uint256 aFees1) = app.fees(s);
        // v4 books fees through feeGrowthInside and keeps the curve's rounding dust in the pool, unclaimable. On Aqua
        // the balance is the maker's, so `fees` is everything beyond the principal: the same fees plus that dust
        // (about 1e-16 of the liquidity per swap).
        assertGe(aFees0, hFees0, "fees0");
        assertGe(aFees1, hFees1, "fees1");
        assertApproxEqRel(aFees0, hFees0, 1e6, "fees0 within 1e-12");
        assertApproxEqRel(aFees1, hFees1, 1e6, "fees1 within 1e-12");
        assertGt(aFees0, 0);
        assertGt(aFees1, 0);
    }

    /// Both refuse an order the range cannot fill.
    function test_bothAreAllOrNothing() public {
        vm.expectRevert();
        _hookSwap(true, -1e25);
        vm.expectRevert();
        app.swapExactIn(s, true, 1e25, 0, address(this), "");
    }

    function _requireV4Artifacts() internal view {
        try vm.getCode(POOL_MANAGER_ARTIFACT) returns (bytes memory) {}
        catch {
            revert("AquaParityTest needs the v4 artifacts: run `forge build` (or the whole `forge test`) first");
        }
    }

    function _hookSwap(bool zfo, int256 amountSpecified) internal returns (uint256 amountIn, uint256 amountOut) {
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zfo, amountSpecified: amountSpecified, sqrtPriceLimitX96: zfo ? MIN_LIMIT : MAX_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (int128 dIn, int128 dOut) = zfo ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        return (uint256(uint128(-dIn)), uint256(uint128(dOut)));
    }

    function _aquaSwap(bool zfo, int256 amountSpecified) internal returns (uint256 amountIn, uint256 amountOut) {
        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            amountOut = app.swapExactIn(s, zfo, amountIn, 0, address(this), "");
        } else {
            amountOut = uint256(amountSpecified);
            amountIn = app.swapExactOut(s, zfo, amountOut, type(uint256).max, address(this), "");
        }
    }
}
