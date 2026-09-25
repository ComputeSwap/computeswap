// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ConcentratedCurveHook} from "../src/ConcentratedCurveHook.sol";
import {HookFixture} from "./utils/HookFixture.sol";
import {ConstantProductCurve} from "./mocks/ConstantProductCurve.sol";

/// @notice Differential test of the engine: the hook running ConstantProductCurve must reproduce a vanilla
///         Uniswap v4 pool bit-for-bit - every liquidity delta, fee payout, swap delta, price, tick, active liquidity
///         and fee-growth accumulator. Any bookkeeping bug in CurvePool/CurveSwapMath shows up here.
contract ConstantProductParityTest is HookFixture {
    using StateLibrary for *;

    PoolKey internal vanillaKey;
    PoolKey internal hookedKey;

    struct Pos {
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint128 liquidity;
    }

    Pos[] internal positions;

    function setUp() public {
        setUpHookWith(new ConstantProductCurve());
        vanillaKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(vanillaKey, SQRT_PRICE_1_1);
        hookedKey = createPool(3000, 60, SQRT_PRICE_1_1, false);
    }

    function _modify(int24 tickLower, int24 tickUpper, int128 liquidityDelta, bytes32 salt) internal {
        BalanceDelta vanilla = modifyLiquidityRouter.modifyLiquidity(
            vanillaKey, ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, salt), ZERO_BYTES
        );
        BalanceDelta hooked = liquidityDelta > 0
            ? lpAdd(address(this), hookedKey, tickLower, tickUpper, uint128(liquidityDelta), salt)
            : lpRemove(address(this), hookedKey, tickLower, tickUpper, uint128(-liquidityDelta), salt);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(vanilla), "liquidity delta differs from v4");
        _assertSameState();
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        BalanceDelta vanilla = doSwap(vanillaKey, zeroForOne, amountSpecified);
        BalanceDelta hooked = doSwap(hookedKey, zeroForOne, amountSpecified);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(vanilla), "swap delta differs from v4");
        _assertSameState();
    }

    function _assertSameState() internal view {
        (uint160 vPrice, int24 vTick,,) = manager.getSlot0(vanillaKey.toId());
        (uint160 hPrice, int24 hTick,) = hook.getSlot0(hookedKey.toId());
        assertEq(hPrice, vPrice, "price");
        assertEq(hTick, vTick, "tick");
        assertEq(hook.getLiquidity(hookedKey.toId()), manager.getLiquidity(vanillaKey.toId()), "active liquidity");
        (uint256 v0, uint256 v1) = manager.getFeeGrowthGlobals(vanillaKey.toId());
        (uint256 h0, uint256 h1) = hook.getFeeGrowthGlobals(hookedKey.toId());
        assertEq(h0, v0, "fee growth 0");
        assertEq(h1, v1, "fee growth 1");
    }

    function test_parity_scenario() public {
        // wide backstop + overlapping, in-range, above-range and below-range positions
        _modify(-887220, 887220, 1e20, bytes32(0));
        _modify(-600, 600, 5e20, bytes32(0));
        _modify(-120, 1200, 3e20, bytes32(uint256(1)));
        _modify(600, 1800, 2e20, bytes32(0));
        _modify(-1800, -600, 4e20, bytes32(0));

        // swaps in every mode, crossing ticks both ways
        _swap(true, -3e19);
        _swap(false, 5e19);
        _swap(true, 2e19);
        _swap(false, -8e19);
        _swap(true, -1e20);
        _swap(false, 4e19);
        _swap(true, -1);
        _swap(false, 1);

        // partial and full removals (principal + fees)
        _modify(-600, 600, -2e20, bytes32(0));
        _swap(false, -6e19);
        _modify(-120, 1200, -3e20, bytes32(uint256(1)));
        _modify(600, 1800, -2e20, bytes32(0));
        _modify(-1800, -600, -4e20, bytes32(0));
        _modify(-600, 600, -3e20, bytes32(0));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_parity_randomSequence(uint256 seed) public {
        // deep backstop so every bounded swap fills completely (the hook does not do partial fills)
        _modify(-887220, 887220, 1e24, bytes32(0));
        positions.push(Pos(-887220, 887220, bytes32(0), 1e24));

        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 10;
            if (action < 3) {
                int24 lower = int24(int256((r >> 8) % 200) - 100) * 60;
                int24 width = int24(int256(1 + (r >> 20) % 80)) * 60;
                uint128 liquidity = uint128(1e15 + (r >> 40) % 1e22);
                bytes32 salt = bytes32((r >> 100) % 3);
                _modify(lower, lower + width, int128(liquidity), salt);
                positions.push(Pos(lower, lower + width, salt, liquidity));
            } else if (action < 4 && positions.length > 1) {
                uint256 idx = 1 + (r >> 8) % (positions.length - 1);
                Pos storage p = positions[idx];
                if (p.liquidity == 0) continue;
                uint128 amount = uint128(1 + (r >> 30) % p.liquidity);
                _modify(p.tickLower, p.tickUpper, -int128(amount), p.salt);
                p.liquidity -= amount;
            } else {
                bool zeroForOne = (r >> 8) % 2 == 0;
                bool exactIn = (r >> 9) % 2 == 0;
                int256 amount = int256(1 + (r >> 16) % 5e21);
                _swap(zeroForOne, exactIn ? -amount : amount);
            }
        }
    }
}
