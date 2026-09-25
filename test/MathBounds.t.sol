// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Dumps solady lnWad/expWad outputs over the input ranges LogCurveMath uses, so that
///         python/check_math_bounds.py can measure their true error against 60-digit arithmetic.
///         The measured bounds justify the rounding allowances in LogCurveMath.
/// @dev Run with: forge test --match-contract MathBoundsDump -vv  (writes ./reports/*.csv)
contract MathBoundsDump is Test {
    uint256 internal constant N = 6000;

    function _rand(uint256 i, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(i, salt)));
    }

    /// lnWad is evaluated on raw sqrtPriceX96 values in [MIN_SQRT_PRICE, MAX_SQRT_PRICE] ~ [2^32, 2^160].
    function test_dumpLnWad() public {
        string memory path = "reports/lnwad_samples.csv";
        vm.writeFile(path, "x,lnWad\n");
        for (uint256 i; i < N; ++i) {
            uint256 r = _rand(i, 1);
            uint256 k = 32 + (r % 128); // bit length
            uint256 x = (uint256(1) << k) | (_rand(i, 2) >> (256 - k));
            if (i % 10 == 0) x = uint256(1) << k; // exact powers of two
            if (i % 10 == 1) x = (uint256(1) << k) - 1;
            int256 y = FixedPointMathLib.lnWad(int256(x));
            vm.writeLine(path, string.concat(vm.toString(x), ",", vm.toString(y)));
        }
    }

    /// expWad is evaluated on exponents z = a / (2L) in WAD; swaps use |z| well below 40e18.
    function test_dumpExpWad() public {
        string memory path = "reports/expwad_samples.csv";
        vm.writeFile(path, "z,expWad\n");
        for (uint256 i; i < N; ++i) {
            uint256 r = _rand(i, 3);
            int256 z;
            uint256 bucket = i % 6;
            if (bucket == 0) z = int256(r % 1e6); // tiny positive
            else if (bucket == 1) z = -int256(r % 1e6); // tiny negative
            else if (bucket == 2) z = int256(r % 1e18) - 5e17; // |z| < 0.5
            else if (bucket == 3) z = int256(r % 40e18) - 20e18; // |z| < 20
            else if (bucket == 4) z = int256(r % 130e18); // large positive
            else z = -int256(r % 41e18); // large negative
            int256 y = FixedPointMathLib.expWad(z);
            vm.writeLine(path, string.concat(vm.toString(z), ",", vm.toString(y)));
        }
    }
}
