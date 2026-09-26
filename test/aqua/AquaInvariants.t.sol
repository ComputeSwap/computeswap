// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ComputeswapAquaApp} from "../../src/aqua/ComputeswapAquaApp.sol";
import {AquaFixture} from "./AquaFixture.sol";

/// @notice Random trading against vault positions, then everyone exits: Aqua balances always cover the principal,
///         the vault's real inventory always equals the sum of its strategies' virtual balances, and closing every
///         position leaves the vault empty.
/// @dev forge test --match-contract AquaInvariantsTest
contract AquaInvariantsTest is AquaFixture {
    address internal trader = makeAddr("trader");
    address[3] internal lps;
    uint256[3] internal ids;

    function setUp() public {
        setUpAqua();
        fund(trader, 1_000_000 ether, 1_000_000_000e6);
        for (uint256 i; i < 3; ++i) {
            lps[i] = makeAddr(string.concat("lp", vm.toString(i)));
            fund(lps[i], 100_000 ether, 100_000_000e6);
        }
        (ids[0],,) = mintPosition(
            lps[0], tickAt(0.25e18), tickAt(4e18), liquidityForValue(tickAt(0.25e18), tickAt(4e18), 1_000e6, 1e18), 1e18
        );
        (ids[1],,) = mintPosition(
            lps[1], tickAt(0.5e18), tickAt(2e18), liquidityForValue(tickAt(0.5e18), tickAt(2e18), 1_000e6, 1e18), 1e18
        );
        (ids[2],,) = mintPosition(
            lps[2],
            tickAt(0.9e18),
            tickAt(1.1e18),
            liquidityForValue(tickAt(0.9e18), tickAt(1.1e18), 1_000e6, 1e18),
            1e18
        );
    }

    function testFuzz_invariants(uint256 seed) public {
        for (uint256 step; step < 30; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 which = r % 3;
            ComputeswapAquaApp.Strategy memory s = vault.strategyOf(ids[which]);
            bool zeroForOne = (r >> 8) & 1 == 1;
            bool exactIn = (r >> 9) & 1 == 1;
            // sizes up to the position's value, so that most trades fill and some hit the range edge
            uint256 size = zeroForOne == exactIn ? 1 + (r >> 16) % 1_500 ether : 1 + (r >> 16) % 1_500e6;
            int256 amountSpecified = exactIn ? -int256(size) : int256(size);
            // execute only what the range can fill (the router reverts otherwise)
            bool fills;
            if (exactIn) {
                try app.quoteExactIn(s, zeroForOne, size) returns (uint256) {
                    fills = true;
                } catch {}
            } else {
                try app.quoteExactOut(s, zeroForOne, size) returns (uint256) {
                    fills = true;
                } catch {}
            }
            if (fills) swapAs(trader, s, zeroForOne, amountSpecified);
            if ((r >> 40) % 5 == 0) {
                // an LP collects fees or withdraws a part (re-shipping the rest)
                uint128 part = uint128(((r >> 48) % 3) * s.liquidity / 5);
                vm.prank(lps[which]);
                vault.decreaseLiquidity(ids[which], part, 0, 0, block.timestamp);
                if (vault.strategyOf(ids[which]).liquidity == 0) {
                    (ids[which],,) = mintPosition(lps[which], s.tickLower, s.tickUpper, s.liquidity, priceWadOf(s));
                }
            }
            _checkInvariants();
        }
        // everyone exits
        for (uint256 i; i < 3; ++i) {
            uint128 l = vault.strategyOf(ids[i]).liquidity;
            vm.prank(lps[i]);
            vault.decreaseLiquidity(ids[i], l, 0, 0, block.timestamp);
        }
        assertEq(weth.balanceOf(address(vault)), 0, "the vault is empty once every position is closed");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function _checkInvariants() internal view {
        uint256 sum0;
        uint256 sum1;
        for (uint256 i; i < 3; ++i) {
            ComputeswapAquaApp.Strategy memory s = vault.strategyOf(ids[i]);
            if (s.liquidity == 0) continue;
            (uint256 b0, uint256 b1) = balancesOf(s);
            (uint256 p0, uint256 p1) = app.amountsForLiquidity(s, s.liquidity, false);
            assertGe(b0, p0, "balance covers the principal (token0)");
            assertGe(b1, p1, "balance covers the principal (token1)");
            sum0 += b0;
            sum1 += b1;
        }
        assertEq(weth.balanceOf(address(vault)), sum0, "real inventory = virtual balances");
        assertEq(usdc.balanceOf(address(vault)), sum1);
    }
}
