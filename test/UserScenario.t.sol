// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {EthUsdcFixture} from "./utils/EthUsdcFixture.sol";

/// @notice The scenario from the brief, on the ETH/USDC log-curve pool at ETH = $1:
///           range1 = [0.25, 4] worth $100, range2 = [0.5, 2] worth $100, then buys and sells.
///         Prints where every step lands and writes ./reports/scenario_trace.csv for python/reference_model.py,
///         which re-derives every number independently.
/// @dev forge test --match-contract UserScenario -vv
contract UserScenarioTest is EthUsdcFixture {
    string internal constant TRACE = "reports/scenario_trace.csv";

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    int24 internal r1Lower;
    int24 internal r1Upper;
    int24 internal r2Lower;
    int24 internal r2Upper;
    uint256 internal id1;
    uint256 internal id2;
    uint128 internal l1;
    uint128 internal l2;

    function setUp() public {
        setUpEthUsdc();
        fund(lp, 1_000 ether, 1_000e6);
        fund(trader, 1_000 ether, 1_000e6);
        r1Lower = tickAt(0.25e18);
        r1Upper = tickAt(4e18);
        r2Lower = tickAt(0.5e18);
        r2Upper = tickAt(2e18);
    }

    // ------------------------------------------------------------------------------------------------------------
    // trace + report helpers
    // ------------------------------------------------------------------------------------------------------------

    function _state() internal view returns (string memory) {
        (uint160 s, int24 t,) = hook.getSlot0(ethId);
        (uint128 r0, uint128 r1) = hook.reserves(ethId);
        return string.concat(
            vm.toString(s), ",", vm.toString(t), ",", vm.toString(hook.getLiquidity(ethId)), ",",
            vm.toString(r0), ",", vm.toString(r1)
        );
    }

    function _traceTicks(int24 a, int24 b) internal {
        vm.writeLine(TRACE, string.concat("tick,", vm.toString(a), ",", vm.toString(TickMath.getSqrtPriceAtTick(a))));
        vm.writeLine(TRACE, string.concat("tick,", vm.toString(b), ",", vm.toString(TickMath.getSqrtPriceAtTick(b))));
    }

    function _traceModify(string memory who, int24 a, int24 b, int256 dl, int256 d0, int256 d1, int256 f0, int256 f1)
        internal
    {
        vm.writeLine(
            TRACE,
            string.concat(
                "modify,", who, ",", vm.toString(a), ",", vm.toString(b), ",", vm.toString(dl), ",",
                vm.toString(d0), ",", vm.toString(d1), ",", vm.toString(f0), ",", vm.toString(f1), ",", _state()
            )
        );
    }

    function _position(string memory label, uint256 positionId) internal view {
        (, int24 a, int24 b, uint128 l,,,) = vault.getPosition(positionId);
        (uint256 x, uint256 y, uint256 f0, uint256 f1) = hook.getPositionAmounts(ethId, address(vault), a, b, bytes32(positionId));
        console2.log(
            string.concat(
                "    ", label, ": ", fmt(x, 18, 4), " ETH + ", fmt(y, 6, 4), " USDC  (value $",
                fmt(valueUsdc(x, y), 6, 2), ", fees ", fmt(f0, 18, 5), " ETH + ", fmt(f1, 6, 5), " USDC, L ", fmt(l, 6, 3), ")"
            )
        );
    }

    function _swap(string memory label, bool zeroForOne, int256 amount) internal {
        (uint160 before,,) = hook.getSlot0(ethId);
        BalanceDelta d = swapAs(trader, zeroForOne, amount);
        vm.writeLine(
            TRACE,
            string.concat(
                "swap,", zeroForOne ? "true" : "false", ",", vm.toString(amount), ",", vm.toString(before), ",",
                vm.toString(d.amount0()), ",", vm.toString(d.amount1()), ",", _state()
            )
        );
        (, int24 tick,) = hook.getSlot0(ethId);
        uint256 activeExpected = (tick >= r1Lower && tick < r1Upper ? l1 : 0) + (tick >= r2Lower && tick < r2Upper ? l2 : 0);
        assertEq(hook.getLiquidity(ethId), activeExpected, "active L = sum of in-range positions");
        console2.log(
            string.concat(
                label, "  trader ETH ", fmtSigned(d.amount0(), 18, 4), ", USDC ", fmtSigned(d.amount1(), 6, 4),
                "  ->  ETH = $", fmt(priceWad(), 18, 6)
            )
        );
        _position("range1 [0.25, 4]", id1);
        _position("range2 [0.5, 2] ", id2);
    }

    // ------------------------------------------------------------------------------------------------------------

    function test_userScenario() public {
        vm.writeFile(TRACE, "");
        vm.writeLine(TRACE, "fee,3000");
        console2.log(
            string.concat(
                "Ranges snap to ticks (spacing 10): range1 [", fmt(priceAtTickWad(r1Lower), 18, 5), ", ",
                fmt(priceAtTickWad(r1Upper), 18, 5), "], range2 [", fmt(priceAtTickWad(r2Lower), 18, 5), ", ",
                fmt(priceAtTickWad(r2Upper), 18, 5), "]"
            )
        );

        // --- two positions worth $100 each at ETH = $1 ---------------------------------------------------------
        l1 = liquidityForValue(r1Lower, r1Upper, 100e6);
        l2 = liquidityForValue(r2Lower, r2Upper, 100e6);
        uint256 e1;
        uint256 u1;
        uint256 e2;
        uint256 u2;
        _traceTicks(r1Lower, r1Upper);
        (id1, e1, u1) = mintPosition(lp, r1Lower, r1Upper, l1);
        _traceModify("range1", r1Lower, r1Upper, int256(uint256(l1)), -int256(e1), -int256(u1), 0, 0);
        _traceTicks(r2Lower, r2Upper);
        (id2, e2, u2) = mintPosition(lp, r2Lower, r2Upper, l2);
        _traceModify("range2", r2Lower, r2Upper, int256(uint256(l2)), -int256(e2), -int256(u2), 0, 0);

        console2.log("Deposits at ETH = $1 (the log curve holds more USDC than ETH at the centre of a range):");
        console2.log(string.concat("  range1: ", fmt(e1, 18, 4), " ETH + ", fmt(u1, 6, 4), " USDC = $", fmt(valueUsdc(e1, u1), 6, 4)));
        console2.log(string.concat("  range2: ", fmt(e2, 18, 4), " ETH + ", fmt(u2, 6, 4), " USDC = $", fmt(valueUsdc(e2, u2), 6, 4)));
        // closed form at P = 1: x = L(1 - 1/pb), y = L ln(1/pa)
        assertApproxEqRel(e1, 35.108e18, 0.005e18, "range1 ETH ~ 35.11");
        assertApproxEqRel(u1, 64.892e6, 0.005e18, "range1 USDC ~ 64.89");
        assertApproxEqRel(e2, 41.906e18, 0.005e18, "range2 ETH ~ 41.91");
        assertApproxEqRel(u2, 58.094e6, 0.005e18, "range2 USDC ~ 58.09");
        assertApproxEqAbs(valueUsdc(e1, u1), 100e6, 2, "worth $100");
        assertApproxEqAbs(valueUsdc(e2, u2), 100e6, 2, "worth $100");
        assertEq(hook.getLiquidity(ethId), l1 + l2);

        // --- buy some, sell some -------------------------------------------------------------------------------
        console2.log("Swaps (0.3% fee):");
        _swap("1. buy 10 ETH (exact out)         ", false, 10 ether);
        _swap("2. sell 25 ETH (exact in)         ", true, -25 ether);
        _swap("3. buy ETH with 30 USDC (exact in)", false, -30e6);
        _swap("4. sell 5 ETH (exact in)          ", true, -5 ether);
        _swap("5. buy 20 ETH (exact out)         ", false, 20 ether);
        _swap("6. sell ETH for 15 USDC (exact out)", true, 15e6);

        // --- everyone leaves ----------------------------------------------------------------------------------
        uint256 lpEth = lp.balance;
        uint256 lpUsdc = usdc.balanceOf(lp);
        vm.prank(lp);
        (BalanceDelta p1, BalanceDelta f1) = vault.decreaseLiquidity(id1, l1, 0, 0, block.timestamp);
        _traceModify("range1", r1Lower, r1Upper, -int256(uint256(l1)), p1.amount0() + f1.amount0(), p1.amount1() + f1.amount1(), f1.amount0(), f1.amount1());
        vm.prank(lp);
        (BalanceDelta p2, BalanceDelta f2) = vault.decreaseLiquidity(id2, l2, 0, 0, block.timestamp);
        _traceModify("range2", r2Lower, r2Upper, -int256(uint256(l2)), p2.amount0() + f2.amount0(), p2.amount1() + f2.amount1(), f2.amount0(), f2.amount1());

        uint256 gotEth = lp.balance - lpEth;
        uint256 gotUsdc = usdc.balanceOf(lp) - lpUsdc;
        console2.log(
            string.concat(
                "LP withdraws both: ", fmt(gotEth, 18, 4), " ETH + ", fmt(gotUsdc, 6, 4), " USDC = $",
                fmt(valueUsdc(gotEth, gotUsdc), 6, 4), " at ETH = $", fmt(priceWad(), 18, 6)
            )
        );
        (uint128 r0, uint128 r1) = hook.reserves(ethId);
        console2.log(string.concat("Dust left in the pool: ", vm.toString(r0), " wei ETH, ", vm.toString(r1), " USDC units"));
        assertLt(r0, 1e6);
        assertLt(r1, 10);
        assertEq(claimBalance(ethKey.currency0), r0);
        assertEq(claimBalance(ethKey.currency1), r1);
    }
}
