// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ConcentratedCurveHook} from "../src/ConcentratedCurveHook.sol";
import {HookFixture} from "./utils/HookFixture.sol";

/// @notice Runs a fixed multi-LP scenario on the log-curve pool and writes every operation and its on-chain result
///         to ./reports/trace.csv. python/reference_model.py replays it with an independent model that has no
///         ticks or liquidityNet at all - it just sums each position's own offset curve - and checks every price,
///         amount and fee against 50-digit arithmetic.
contract LogCurveTrace is HookFixture {
    string internal constant PATH = "reports/trace.csv";
    PoolKey internal logKey;
    PoolId internal id;
    mapping(string => address) internal lp;

    function setUp() public {
        setUpHook();
        logKey = createPool(3000, 60, SQRT_PRICE_1_1, false);
        id = logKey.toId();
        string[6] memory names = ["alice", "bob", "carol", "dave", "erin", "frank"];
        for (uint256 i; i < names.length; ++i) {
            lp[names[i]] = newLp(names[i], 1e30);
        }
    }

    function _tick(int24 t) internal {
        vm.writeLine(PATH, string.concat("tick,", vm.toString(t), ",", vm.toString(TickMath.getSqrtPriceAtTick(t))));
    }

    function _state() internal view returns (string memory) {
        (uint160 s, int24 t,) = hook.getSlot0(id);
        (uint128 r0, uint128 r1) = hook.reserves(id);
        return string.concat(
            vm.toString(s),
            ",",
            vm.toString(t),
            ",",
            vm.toString(hook.getLiquidity(id)),
            ",",
            vm.toString(r0),
            ",",
            vm.toString(r1)
        );
    }

    function _modify(string memory who, int24 tickLower, int24 tickUpper, int128 liquidityDelta) internal {
        _tick(tickLower);
        _tick(tickUpper);
        vm.prank(lp[who]);
        (BalanceDelta callerDelta, BalanceDelta fees) = liquidityDelta > 0
            ? hook.addLiquidity(
                logKey,
                ConcentratedCurveHook.AddLiquidityParams(
                    tickLower,
                    tickUpper,
                    uint128(liquidityDelta),
                    type(uint256).max,
                    type(uint256).max,
                    bytes32(0),
                    block.timestamp
                )
            )
            : hook.removeLiquidity(
                logKey,
                ConcentratedCurveHook.RemoveLiquidityParams(
                    tickLower, tickUpper, uint128(-liquidityDelta), 0, 0, bytes32(0), lp[who], block.timestamp
                )
            );
        vm.writeLine(
            PATH,
            string.concat(
                "modify,",
                who,
                ",",
                vm.toString(tickLower),
                ",",
                vm.toString(tickUpper),
                ",",
                vm.toString(liquidityDelta),
                ",",
                vm.toString(callerDelta.amount0()),
                ",",
                vm.toString(callerDelta.amount1()),
                ",",
                vm.toString(fees.amount0()),
                ",",
                vm.toString(fees.amount1()),
                ",",
                _state()
            )
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        (uint160 before,,) = hook.getSlot0(id);
        BalanceDelta d = doSwap(logKey, zeroForOne, amountSpecified);
        vm.writeLine(
            PATH,
            string.concat(
                "swap,",
                zeroForOne ? "true" : "false",
                ",",
                vm.toString(amountSpecified),
                ",",
                vm.toString(before),
                ",",
                vm.toString(d.amount0()),
                ",",
                vm.toString(d.amount1()),
                ",",
                _state()
            )
        );
    }

    function test_writeTrace() public {
        vm.writeFile(PATH, "");
        vm.writeLine(PATH, string.concat("fee,", vm.toString(uint256(3000))));

        // same range twice, a narrow overlapping range, ranges fully above and below the price
        _modify("alice", -6000, 6000, 1e21);
        _modify("bob", -6000, 6000, 2e21);
        _modify("carol", -1200, 600, 4e21);
        _modify("dave", 1800, 4200, 3e21);
        _modify("erin", -9000, -3000, 25e20);

        _swap(false, -9e20); // exact in currency1: up through 600, 1800
        _swap(false, 2e19); // exact out currency0
        _swap(true, -2e21); // exact in currency0: down through 1800, 600, 0, -1200
        _modify("carol", -1200, 600, -2e21); // carol takes half out (and her fees)
        _swap(true, 4e20); // exact out currency1: into erin's range
        _modify("frank", 0, 3000, 1e21); // new LP above the price
        _swap(false, -2.2e21); // back up through -3000, -1200, 0, 600, 1800
        _swap(true, -3e20);
        _swap(false, 5e19);

        _modify("alice", -6000, 6000, -1e21);
        _modify("bob", -6000, 6000, -2e21);
        _modify("carol", -1200, 600, -2e21);
        _modify("dave", 1800, 4200, -3e21);
        _modify("erin", -9000, -3000, -25e20);
        _modify("frank", 0, 3000, -1e21);
    }
}
