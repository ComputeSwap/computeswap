// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ICurve} from "../src/interfaces/ICurve.sol";
import {CurvePool} from "../src/libraries/CurvePool.sol";
import {HookFixture} from "./utils/HookFixture.sol";

/// @notice The engine's guarantees on a live log-curve pool under random LP / swap activity:
///           - active liquidity always equals the sum of L over positions whose range contains the price;
///           - reserves always cover every position's principal (at the current price) plus its unpaid fees;
///           - LPs on the same range are paid pro rata to L;
///           - everyone can exit, leaving only rounding dust, and the hook's claims equal the pool's reserves.
abstract contract CurveHookInvariants is HookFixture {
    PoolKey internal poolKey;
    PoolId internal id;
    address[4] internal lps;

    struct Pos {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    Pos[] internal book;

    function setUp() public {
        setUpHook();
        poolKey = createPool(3000, 60, SQRT_PRICE_1_1, false);
        id = poolKey.toId();
        lps = [newLp("alice", 1e30), newLp("bob", 1e30), newLp("carol", 1e30), newLp("dave", 1e30)];
    }

    function _add(address lp, int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        lpAdd(lp, poolKey, tickLower, tickUpper, liquidity, bytes32(0));
        book.push(Pos(lp, tickLower, tickUpper, liquidity));
    }

    function _expectedActive() internal view returns (uint128 total) {
        (, int24 tick,) = hook.getSlot0(id);
        for (uint256 i; i < book.length; ++i) {
            if (book[i].tickLower <= tick && tick < book[i].tickUpper) total += book[i].liquidity;
        }
    }

    function _assertSolvent() internal view {
        uint256 owed0;
        uint256 owed1;
        for (uint256 i; i < book.length; ++i) {
            Pos memory p = book[i];
            if (p.liquidity == 0) continue;
            (uint256 x, uint256 y, uint256 f0, uint256 f1) =
                hook.getPositionAmounts(id, p.owner, p.tickLower, p.tickUpper, bytes32(0));
            owed0 += x + f0;
            owed1 += y + f1;
        }
        (uint128 r0, uint128 r1) = hook.reserves(id);
        assertGe(r0, owed0, "reserve0 covers positions and fees");
        assertGe(r1, owed1, "reserve1 covers positions and fees");
    }

    /// @dev What the book can absorb (input) or release (output) in one direction, from position principal only.
    function _capacity(bool zeroForOne, bool exactIn) internal view returns (uint256 total) {
        (uint160 s,,) = hook.getSlot0(id);
        ICurve curve = pooledCurve_();
        for (uint256 i; i < book.length; ++i) {
            Pos memory p = book[i];
            if (p.liquidity == 0) continue;
            uint160 sa = TickMath.getSqrtPriceAtTick(p.tickLower);
            uint160 sb = TickMath.getSqrtPriceAtTick(p.tickUpper);
            if (exactIn) {
                // input needed to push the price through the rest of the range
                if (zeroForOne && s > sa) total += curve.getAmount0Delta(sa, s < sb ? s : sb, p.liquidity, false);
                if (!zeroForOne && s < sb) total += curve.getAmount1Delta(s > sa ? s : sa, sb, p.liquidity, false);
            } else {
                (uint256 x, uint256 y,,) = hook.getPositionAmounts(id, p.owner, p.tickLower, p.tickUpper, bytes32(0));
                total += zeroForOne ? y : x;
            }
        }
    }

    function pooledCurve_() internal view returns (ICurve curve) {
        (curve,) = hook.poolConfig(id);
    }

    /// forge-config: default.fuzz.runs = 100
    function testFuzz_invariants(uint256 seed) public {
        _add(lps[0], TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e21); // backstop

        for (uint256 i; i < 30; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 10;
            if (action < 3) {
                int24 lower = int24(int256((r >> 8) % 400) - 200) * 60;
                int24 upper = lower + int24(int256(1 + (r >> 20) % 100)) * 60;
                address lp = lps[(r >> 100) % 4];
                if (hook.getPosition(id, lp, lower, upper, bytes32(0)).liquidity != 0) continue;
                _add(lp, lower, upper, uint128(1e15 + (r >> 40) % 1e22));
            } else if (action < 4 && book.length > 1) {
                Pos storage p = book[1 + (r >> 8) % (book.length - 1)];
                if (p.liquidity == 0) continue;
                uint128 amount = uint128(1 + (r >> 30) % p.liquidity);
                lpRemove(p.owner, poolKey, p.tickLower, p.tickUpper, amount, bytes32(0));
                p.liquidity -= amount;
            } else {
                bool zeroForOne = (r >> 8) % 2 == 0;
                bool exactIn = (r >> 9) % 2 == 0;
                // all-or-nothing swaps must fit what the book can absorb or release
                uint256 cap = _capacity(zeroForOne, exactIn) / 4;
                if (cap > 3e21) cap = 3e21;
                if (cap == 0) continue;
                int256 amount = int256(1 + (r >> 16) % cap);
                doSwap(poolKey, zeroForOne, exactIn ? -amount : amount);
            }
            assertEq(hook.getLiquidity(id), _expectedActive(), "active liquidity = sum of in-range L");
            _assertSolvent();
        }

        for (uint256 i; i < book.length; ++i) {
            Pos storage p = book[i];
            uint128 onchain = hook.getPosition(id, p.owner, p.tickLower, p.tickUpper, bytes32(0)).liquidity;
            if (onchain == 0) continue;
            lpRemove(p.owner, poolKey, p.tickLower, p.tickUpper, onchain, bytes32(0));
            p.liquidity = 0;
        }
        (uint128 r0, uint128 r1) = hook.reserves(id);
        assertLt(r0, 1e9, "only dust left");
        assertLt(r1, 1e9, "only dust left");
        assertEq(claimBalance(currency0), r0, "claims = reserves");
        assertEq(claimBalance(currency1), r1, "claims = reserves");
    }

    function test_sameRangeProRata() public {
        _add(lps[0], -3000, 3000, 2e21);
        _add(lps[1], -3000, 3000, 6e21);
        doSwap(poolKey, true, -5e20);
        doSwap(poolKey, false, -9e20);
        (uint256 xa, uint256 ya, uint256 fa0, uint256 fa1) = hook.getPositionAmounts(id, lps[0], -3000, 3000, 0);
        (uint256 xb, uint256 yb, uint256 fb0, uint256 fb1) = hook.getPositionAmounts(id, lps[1], -3000, 3000, 0);
        assertApproxEqAbs(xb, 3 * xa, 3 + xa / 1e15);
        assertApproxEqAbs(yb, 3 * ya, 3 + ya / 1e15);
        assertApproxEqAbs(fb0, 3 * fa0, 3);
        assertApproxEqAbs(fb1, 3 * fa1, 3);
    }

    function test_roundTripNoProfit() public {
        _add(lps[0], -6000, 6000, 1e22);
        _add(lps[1], -600, 1200, 3e22);
        BalanceDelta out = doSwap(poolKey, true, -2e21);
        BalanceDelta back = doSwap(poolKey, false, -int256(out.amount1()));
        assertLt(uint256(uint128(back.amount0())), 2e21, "a round trip never profits");
    }
}

contract LogCurveHookInvariants is CurveHookInvariants {}
