// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookFixture} from "./utils/HookFixture.sol";

/// @notice Rough gas comparison of one swap (router included): vanilla v4 vs the hook with the log curve.
/// @dev forge test --match-contract GasComparison -vv
contract GasComparison is HookFixture {
    PoolKey internal vanilla;
    PoolKey internal lg;
    PoolKey internal lgMirror;

    function setUp() public {
        setUpHook();
        vanilla = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(vanilla, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(vanilla, ModifyLiquidityParams(-6000, 6000, 1e22, 0), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(vanilla, ModifyLiquidityParams(-600, 600, 1e22, 0), ZERO_BYTES);

        lg = createPool(500, 60, SQRT_PRICE_1_1, false);
        lgMirror = createPool(100, 60, SQRT_PRICE_1_1, true);
        PoolKey[2] memory keys = [lg, lgMirror];
        for (uint256 i; i < 2; ++i) {
            lpAdd(address(this), keys[i], -6000, 6000, 1e22, bytes32(0));
            lpAdd(address(this), keys[i], -600, 600, 1e22, bytes32(0));
        }
        // warm up every pool once so the measured swaps are steady-state
        doSwap(vanilla, true, -1e15);
        doSwap(lg, true, -1e15);
        doSwap(lgMirror, true, -1e15);
    }

    function _measure(PoolKey memory k, int256 amount) internal returns (uint256 used) {
        uint256 g = gasleft();
        doSwap(k, true, amount);
        used = g - gasleft();
    }

    function test_gas_swapWithinRange() public {
        emit log_named_uint("vanilla v4          ", _measure(vanilla, -1e18));
        emit log_named_uint("hook + log curve    ", _measure(lg, -1e18));
        emit log_named_uint("hook + log + mirror ", _measure(lgMirror, -1e18));
    }

    function test_gas_swapCrossingTick() public {
        emit log_named_uint("vanilla v4          ", _measure(vanilla, -2e21));
        emit log_named_uint("hook + log curve    ", _measure(lg, -2e21));
        emit log_named_uint("hook + log + mirror ", _measure(lgMirror, -2e21));
    }
}
