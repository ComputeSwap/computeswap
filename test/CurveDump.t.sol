// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ICurve} from "../src/interfaces/ICurve.sol";
import {LogCurve} from "../src/curves/LogCurve.sol";

/// @notice Dumps a curve's outputs on random inputs so python/check_curve.py can verify the rounding rules R1-R5
///         against exact high-precision arithmetic.
/// @dev forge test --match-contract CurveDump   (writes ./reports/<name>_amounts.csv and <name>_next.csv)
abstract contract CurveDump is Test {
    uint256 internal constant N = 2000;
    /// @dev v4 deltas are int128, so the hook never passes amounts of 2^127 or more to a curve
    uint256 internal constant MAX_AMOUNT = uint256(1) << 126;
    ICurve internal curve;

    function name() internal pure virtual returns (string memory);
    function maxAbsTick() internal pure virtual returns (uint256);

    function _r(uint256 i, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(i, salt)));
    }

    /// Prices anywhere in +-maxAbsTick, perturbed inside the tick so they are not only tick-aligned.
    function _price(uint256 i, uint256 salt) internal pure returns (uint160) {
        uint256 m = maxAbsTick();
        int24 tick = int24(int256(_r(i, salt) % (2 * m + 1)) - int256(m));
        uint160 p = TickMath.getSqrtPriceAtTick(tick);
        return p + uint160(_r(i, salt + 1) % (uint256(p) / 20_000 + 1));
    }

    function _liquidity(uint256 i) internal pure returns (uint128) {
        uint256 bits = 1 + _r(i, 99) % 110;
        return uint128(1 + (_r(i, 98) >> (256 - bits)));
    }

    function test_dumpAmounts() public {
        string memory path = string.concat("reports/", name(), "_amounts.csv");
        vm.writeFile(path, "sqrtA,sqrtB,liquidity,amount0Up,amount0Down,amount1Up,amount1Down\n");
        for (uint256 i; i < N; ++i) {
            uint160 a = _price(i, 1);
            uint160 b = i % 4 == 0 ? a + uint160(1 + _r(i, 5) % 1e6) : _price(i, 3);
            uint128 l = _liquidity(i);
            vm.writeLine(
                path,
                string.concat(
                    vm.toString(a),
                    ",",
                    vm.toString(b),
                    ",",
                    vm.toString(l),
                    ",",
                    vm.toString(curve.getAmount0Delta(a, b, l, true)),
                    ",",
                    vm.toString(curve.getAmount0Delta(a, b, l, false)),
                    ",",
                    vm.toString(curve.getAmount1Delta(a, b, l, true)),
                    ",",
                    vm.toString(curve.getAmount1Delta(a, b, l, false))
                )
            );
        }
    }

    function test_dumpNextPrices() public {
        string memory path = string.concat("reports/", name(), "_next.csv");
        vm.writeFile(path, "kind,sqrtP,liquidity,amount,next\n");
        uint160 lo = TickMath.getSqrtPriceAtTick(-int24(int256(maxAbsTick())));
        uint160 hi = TickMath.getSqrtPriceAtTick(int24(int256(maxAbsTick())));
        for (uint256 i; i < N; ++i) {
            uint160 s = _price(i, 11);
            uint128 l = _liquidity(i);
            uint256 kind = i % 4;
            // stay within what the curve holds/absorbs between s and the ends of the sampled price range
            uint256 scale;
            if (kind == 0) scale = curve.getAmount0Delta(lo, s, l, false); // currency0 in: price falls
            else if (kind == 1) scale = curve.getAmount0Delta(s, hi, l, false); // currency0 out: price rises
            else if (kind == 2) scale = curve.getAmount1Delta(s, hi, l, false); // currency1 in: price rises
            else scale = curve.getAmount1Delta(lo, s, l, false); // currency1 out: price falls
            if (scale < 2) continue;
            if (scale > MAX_AMOUNT) scale = MAX_AMOUNT;
            uint256 amount = 1 + _r(i, 13) % (i % 3 == 0 && scale > 2000 ? 1000 : scale / 2);
            uint160 next = kind < 2
                ? curve.getNextSqrtPriceFromAmount0(s, l, amount, kind == 0)
                : curve.getNextSqrtPriceFromAmount1(s, l, amount, kind == 2);
            vm.writeLine(
                path,
                string.concat(
                    vm.toString(kind),
                    ",",
                    vm.toString(s),
                    ",",
                    vm.toString(l),
                    ",",
                    vm.toString(amount),
                    ",",
                    vm.toString(next)
                )
            );
        }
    }
}

contract LogCurveDump is CurveDump {
    function setUp() public {
        curve = new LogCurve();
    }

    function name() internal pure override returns (string memory) {
        return "logcurve";
    }

    function maxAbsTick() internal pure override returns (uint256) {
        return 600_000;
    }
}
