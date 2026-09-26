// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";
import {ERC6909} from "solady/tokens/ERC6909.sol";
import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";

import {ComputeswapAquaApp} from "../../src/aqua/ComputeswapAquaApp.sol";
import {AquaWeightVault} from "../../src/aqua/AquaWeightVault.sol";
import {WeightToken} from "../../src/weights/WeightToken.sol";
import {AquaFixture} from "./AquaFixture.sol";
import {BlockableERC20} from "./mocks/BlockableERC20.sol";

/// @notice The weights product on Aqua: the vault is the maker of one strategy per position, so it can lock the
///         liquidity behind a sold ETH weight. Same scenarios as test/Weights.t.sol on the Uniswap hook.
/// @dev forge test --match-contract AquaWeightsTest -vv
contract AquaWeightsTest is AquaFixture {
    address internal lp = makeAddr("lp");
    address internal buyer = makeAddr("buyer");
    address internal trader = makeAddr("trader");

    int24 internal lower;
    int24 internal upper;
    uint128 internal liquidity;
    uint256 internal positionId;

    function setUp() public {
        setUpAqua();
        fund(lp, 1_000 ether, 1_000e6);
        fund(buyer, 1_000 ether, 1_000e6);
        fund(trader, 1_000 ether, 1_000e6);
        lower = tickAt(0.5e18);
        upper = tickAt(2e18);
        liquidity = liquidityForValue(lower, upper, 100e6, 1e18); // $100 on [0.5, 2] at ETH = $1
        (positionId,,) = mintPosition(lp, lower, upper, liquidity, 1e18);
    }

    function _s() internal view returns (ComputeswapAquaApp.Strategy memory) {
        return vault.strategyOf(positionId);
    }

    function _split(uint64 duration) internal returns (uint256 seriesId) {
        vm.prank(lp);
        seriesId = vault.split(positionId, liquidity, 0, duration);
    }

    function _auction(uint256 seriesId) internal returns (uint256 auctionId, uint256 legValue) {
        (uint256 eth,,,,) = vault.previewExercise(seriesId, liquidity);
        legValue = eth * priceWadOf(_s()) / 1e30;
        vm.startPrank(lp);
        weights.approve(address(auction), seriesId, liquidity);
        auctionId = auction.create(
            seriesId, liquidity, address(usdc), uint128(legValue * 2), uint128(legValue / 4), 15 minutes
        );
        vm.stopPrank();
    }

    function _pushPriceTo(uint256 targetWad) internal {
        // sell ETH into the position until its price is at the target (approximately), in a few swaps
        for (uint256 i; i < 40 && priceWadOf(_s()) > targetWad; ++i) {
            swapAs(trader, _s(), true, -1 ether);
        }
    }

    // ------------------------------------------------------------------------------------------------------------

    /// Minting ships the position as an Aqua strategy with the vault as maker; the LP holds the NFT, the vault the
    /// tokens, Aqua the balances.
    function test_mintShipsAStrategy() public view {
        ComputeswapAquaApp.Strategy memory s = _s();
        assertEq(s.maker, address(vault));
        assertEq(s.liquidity, liquidity);
        assertEq(vault.ownerOf(positionId), lp);
        (uint256 b0, uint256 b1) = balancesOf(s);
        assertEq(weth.balanceOf(address(vault)), b0, "the vault holds exactly what it shipped");
        assertEq(usdc.balanceOf(address(vault)), b1);
        assertApproxEqAbs(b0, 41.9 ether, 0.01 ether);
        assertApproxEqAbs(b1, 58.1e6, 0.01e6);
        (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) = vault.positionAmounts(positionId);
        assertLe(b0 - amount0, 1);
        assertLe(b1 - amount1, 1);
        assertEq(fees0 + fees1, 0);
    }

    /// The example from the brief: ETH weight sold at $1, ETH falls to ~$0.80, the buyer tells the vault to withdraw
    /// and receives the ETH leg (which grew as the price fell); the LP receives the USDC leg and the fees.
    function test_splitAuctionExercise() public {
        uint256 seriesId = _split(5 days);
        assertEq(weights.balanceOf(lp, seriesId), liquidity, "LP holds the ETH weight");
        assertEq(vault.lockedLiquidity(positionId), liquidity, "position locked while the weight lives");
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(AquaWeightVault.LiquidityLocked.selector, uint128(0)));
        vault.decreaseLiquidity(positionId, 1, 0, 0, block.timestamp);

        _buyInAuction(seriesId);

        // ETH falls to ~$0.80 (the trader sells into this position; on Aqua every position has its own price)
        _pushPriceTo(0.8e18);
        (uint256 ethNow, uint256 usdcNow,,,) = vault.previewExercise(seriesId, liquidity);
        console2.log(
            string.concat(
                "ETH = $",
                fmt(priceWadOf(_s()), 18, 4),
                ": ETH leg ",
                fmt(ethNow, 18, 4),
                " ETH, USDC leg ",
                fmt(usdcNow, 6, 4)
            )
        );

        // right after the move the spot is far from the moving average: exercising now is refused
        vm.prank(buyer);
        vm.expectRevert();
        vault.exercise(seriesId, liquidity, 0, block.timestamp);

        // once the price has held for a while, the buyer exercises
        vm.warp(block.timestamp + 1 hours);
        _exerciseAll(seriesId, ethNow, usdcNow);
    }

    function _buyInAuction(uint256 seriesId) internal {
        (uint256 auctionId, uint256 legValue) = _auction(seriesId);
        console2.log(
            string.concat("ETH leg at $1: worth $", fmt(legValue, 6, 4), "; auction starts at 2x, ends at 0.25x")
        );
        (, uint64 startBlock,, uint64 dropStart,,,,,,,) = auction.auctions(auctionId);
        vm.roll(uint256(startBlock) + 1);
        vm.warp(dropStart + 6 minutes);
        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(buyer);
        uint256 cost = auction.buy(auctionId, liquidity, type(uint256).max);
        assertEq(usdc.balanceOf(lp) - lpUsdcBefore, cost - auction.quoteProtocolFee(auctionId, liquidity));
        assertEq(weights.balanceOf(buyer, seriesId), liquidity);
        console2.log(string.concat("Buyer pays $", fmt(cost, 6, 4), " for the whole ETH weight after the drop starts"));
    }

    function _exerciseAll(uint256 seriesId, uint256 ethNow, uint256 usdcNow) internal {
        uint256 buyerEth = weth.balanceOf(buyer);
        uint256 lpUsdc = usdc.balanceOf(lp);
        bytes32 oldHash = vault.strategyHashOf(positionId);
        vm.prank(buyer);
        (uint256 legAmount, uint256 otherAmount) = vault.exercise(seriesId, liquidity, 0, block.timestamp);
        assertEq(weth.balanceOf(buyer) - buyerEth, legAmount, "buyer receives the ETH leg");
        assertGe(usdc.balanceOf(lp) - lpUsdc, otherAmount, "LP receives the USDC leg (plus fees)");
        assertApproxEqAbs(legAmount, ethNow, 1, "at the previewed amounts");
        assertApproxEqAbs(otherAmount, usdcNow, 1);
        assertEq(weights.balanceOf(buyer, seriesId), 0, "weights burned");
        assertEq(vault.lockedLiquidity(positionId), 0);
        assertEq(_s().liquidity, 0, "position closed");
        (, uint8 count) = aqua.rawBalances(address(vault), address(app), oldHash, address(weth));
        assertEq(count, 0xff, "strategy docked");
        assertEq(weth.balanceOf(address(vault)), 0, "the vault keeps nothing");
        assertEq(usdc.balanceOf(address(vault)), 0);
        _checkTriangle(legAmount, otherAmount);
    }

    function _checkTriangle(uint256 legAmount, uint256 otherAmount) internal view {
        // x = L(1/P - 1/pb) at P ~ 0.8: the ETH leg grew from ~41.9 to ~62.5 (a closed position keeps its last price)
        uint256 p = sqrtToPriceWad(_s().sqrtPriceX96);
        assertLt(p, 0.81e18);
        assertApproxEqRel(legAmount, liquidity * (1e36 / p - 1e36 / priceAtTickWad(upper)) / 1e6, 1e12);
        console2.log(
            string.concat(
                "Exercised at $",
                fmt(p, 18, 4),
                ": buyer gets ",
                fmt(legAmount, 18, 4),
                " ETH ($",
                fmt(legAmount * p / 1e30, 6, 4),
                "), LP gets ",
                fmt(otherAmount, 6, 4),
                " USDC"
            )
        );
    }

    /// A partial exercise re-ships the rest of the position as a new strategy at the same price, and the position
    /// keeps trading; the owner gets all the fees earned so far.
    function test_partialExerciseReships() public {
        uint256 seriesId = _split(5 days);
        vm.prank(lp);
        weights.transfer(buyer, seriesId, liquidity);
        // a round trip leaves fees in both tokens
        swapAs(trader, _s(), true, -5 ether);
        swapAs(trader, _s(), false, -5e6);
        vm.warp(block.timestamp + 1 hours);
        (,, uint256 fees0, uint256 fees1) = vault.positionAmounts(positionId);
        assertGt(fees0, 0);
        assertGt(fees1, 0);

        ComputeswapAquaApp.Strategy memory old = _s();
        uint256 lpWeth = weth.balanceOf(lp);
        uint256 lpUsdc = usdc.balanceOf(lp);
        (uint256 previewEth, uint256 previewUsdc,,,) = vault.previewExercise(seriesId, liquidity / 2);
        vm.prank(buyer);
        (uint256 legAmount, uint256 otherAmount) = vault.exercise(seriesId, liquidity / 2, 0, block.timestamp);
        assertApproxEqAbs(legAmount, previewEth, 2);
        assertApproxEqAbs(otherAmount, previewUsdc, 2);
        assertEq(weth.balanceOf(lp) - lpWeth, fees0, "ETH fees to the owner");
        assertEq(usdc.balanceOf(lp) - lpUsdc, otherAmount + fees1, "USDC leg plus USDC fees to the owner");

        ComputeswapAquaApp.Strategy memory s2 = _s();
        assertEq(s2.liquidity, liquidity - liquidity / 2, "half the liquidity remains");
        assertEq(s2.sqrtPriceX96, old.sqrtPriceX96 == 0 ? s2.sqrtPriceX96 : s2.sqrtPriceX96);
        assertEq(priceWadOf(s2), sqrtToPriceWad(s2.sqrtPriceX96), "re-shipped at the current price");
        assertTrue(keccak256(abi.encode(s2)) != keccak256(abi.encode(old)), "a new strategy");
        (uint256 b0, uint256 b1) = balancesOf(s2);
        (uint256 p0, uint256 p1) = app.amountsForLiquidity(s2, s2.liquidity, true);
        assertEq(b0, p0, "the new strategy holds exactly its principal");
        assertEq(b1, p1);
        assertEq(weth.balanceOf(address(vault)), b0, "and the vault holds exactly that");
        assertEq(usdc.balanceOf(address(vault)), b1);
        assertEq(vault.lockedLiquidity(positionId), liquidity / 2);

        // the position keeps trading under its new hash
        (, uint256 out) = swapAs(trader, s2, true, -1 ether);
        assertGt(out, 0);
        vm.prank(trader);
        vm.expectRevert();
        router.swapExactIn(old, true, 1 ether, 0, trader); // the old one is docked
    }

    /// Unexercised weights lapse at expiry with no transaction: balances read zero, they cannot move or be exercised,
    /// and the LP can withdraw the whole position.
    function test_expiryReleasesTheLp() public {
        uint256 seriesId = _split(5 days);
        (uint256 auctionId,) = _auction(seriesId);
        (, uint64 startBlock,, uint64 dropStart,,,,,,,) = auction.auctions(auctionId);
        vm.roll(uint256(startBlock) + 1);
        vm.warp(dropStart);
        vm.prank(buyer);
        auction.buy(auctionId, liquidity / 2, type(uint256).max);

        vm.warp(block.timestamp + 5 days);
        assertEq(weights.balanceOf(buyer, seriesId), 0, "lapsed weight reads zero");
        assertEq(vault.lockedLiquidity(positionId), 0, "lock gone");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AquaWeightVault.SeriesExpired.selector, seriesId));
        vault.exercise(seriesId, 1, 0, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(WeightToken.SeriesExpired.selector, seriesId));
        weights.transfer(lp, seriesId, 1);

        uint256 lpEth = weth.balanceOf(lp);
        vm.prank(lp);
        vault.decreaseLiquidity(positionId, liquidity, 0, 0, block.timestamp);
        assertGt(weth.balanceOf(lp) - lpEth, 41 ether, "the LP withdraws the full position");
        assertEq(_s().liquidity, 0);
        assertEq(weth.balanceOf(address(vault)) + usdc.balanceOf(address(vault)), 0);
    }

    /// Unsold weights come back to the LP, who can merge them to unlock that liquidity before expiry.
    function test_cancelAndMerge() public {
        uint256 seriesId = _split(5 days);
        (uint256 auctionId,) = _auction(seriesId);
        (, uint64 startBlock,, uint64 dropStart,,,,,,,) = auction.auctions(auctionId);
        vm.roll(uint256(startBlock) + 1);
        vm.warp(dropStart);
        uint128 sold = liquidity / 4;
        vm.prank(buyer);
        auction.buy(auctionId, sold, type(uint256).max);
        vm.prank(lp);
        auction.cancel(auctionId);
        assertEq(weights.balanceOf(lp, seriesId), liquidity - sold);

        vm.prank(lp);
        vault.merge(seriesId, liquidity - sold);
        assertEq(vault.lockedLiquidity(positionId), sold, "only the sold part stays locked");
        vm.prank(lp);
        vault.decreaseLiquidity(positionId, liquidity - sold, 0, 0, block.timestamp);
        assertEq(_s().liquidity, sold, "the sold part is re-shipped");
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(AquaWeightVault.LiquidityLocked.selector, uint128(0)));
        vault.decreaseLiquidity(positionId, 1, 0, 0, block.timestamp);
        // the buyer's weight is still good against the re-shipped strategy
        vm.warp(block.timestamp + 1 hours);
        vm.prank(buyer);
        (uint256 legAmount,) = vault.exercise(seriesId, sold, 0, block.timestamp);
        assertGt(legAmount, 10 ether);
        assertEq(_s().liquidity, 0);
    }

    /// Collecting fees (decrease by 0) pays the fees and re-ships the same liquidity at the same price.
    function test_collectFees() public {
        swapAs(trader, _s(), true, -5 ether);
        swapAs(trader, _s(), false, -5e6);
        (,, uint256 fees0, uint256 fees1) = vault.positionAmounts(positionId);
        uint256 price = priceWadOf(_s());
        uint256 lpWeth = weth.balanceOf(lp);
        uint256 lpUsdc = usdc.balanceOf(lp);
        vm.prank(lp);
        (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = vault.decreaseLiquidity(positionId, 0, 0, 0, block.timestamp);
        assertEq(a0 + a1, 0, "no principal withdrawn");
        assertEq(f0, fees0);
        assertEq(f1, fees1);
        assertEq(weth.balanceOf(lp) - lpWeth, fees0);
        assertEq(usdc.balanceOf(lp) - lpUsdc, fees1);
        assertEq(_s().liquidity, liquidity);
        assertEq(priceWadOf(_s()), price);
        (,, uint256 after0, uint256 after1) = vault.positionAmounts(positionId);
        assertEq(after0 + after1, 0, "nothing left to collect");
    }

    /// A buyer cannot inflate the ETH leg by dumping ETH into the position and exercising in the same block: the spot
    /// has moved away from the moving average, so the exercise reverts.
    function test_flashManipulationBlocked() public {
        uint256 seriesId = _split(5 days);
        vm.prank(lp);
        weights.transfer(buyer, seriesId, liquidity);
        vm.warp(block.timestamp + 1 hours);

        (uint256 fairEth,,,,) = vault.previewExercise(seriesId, liquidity);
        swapAs(buyer, _s(), true, -40 ether); // push the price down ~30%
        (uint256 inflatedEth,, bool allowed, int24 tick, int24 emaTick) = vault.previewExercise(seriesId, liquidity);
        assertGt(inflatedEth, fairEth, "the ETH leg would be larger at the pushed price");
        assertFalse(allowed);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AquaWeightVault.OracleDeviation.selector, tick, emaTick));
        vault.exercise(seriesId, liquidity, 0, block.timestamp);
    }

    /// Whoever holds the NFT receives the other leg and the fees.
    function test_otherLegFollowsTheNft() public {
        uint256 seriesId = _split(5 days);
        address newOwner = makeAddr("newOwner");
        vm.startPrank(lp);
        weights.transfer(buyer, seriesId, liquidity);
        vault.transferFrom(lp, newOwner, positionId);
        vm.stopPrank();

        vm.prank(buyer);
        (, uint256 otherAmount) = vault.exercise(seriesId, liquidity / 2, 0, block.timestamp);
        assertGe(usdc.balanceOf(newOwner), otherAmount);
        assertGt(otherAmount, 0);
    }

    /// The LP cannot sell the ETH weight and then block its exercise by moving the NFT to an address the payout token
    /// refuses (a USDC blocklist): the exercise goes through and the unpaid part is credited to the owner.
    function test_ownerCannotBlockExercise() public {
        // a fresh pair whose USDC can block addresses
        BlockableERC20 busd = new BlockableERC20("Blockable USD", "bUSD", 6);
        busd.mint(lp, 1_000e6);
        busd.mint(trader, 1_000e6);
        vm.prank(lp);
        busd.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        busd.approve(address(router), type(uint256).max);
        vm.prank(lp);
        (uint256 pid,,) = vault.mint(
            AquaWeightVault.MintParams(
                address(weth),
                address(busd),
                FEE,
                lower,
                upper,
                liquidity,
                sqrtPriceX96At(1e18),
                type(uint256).max,
                type(uint256).max,
                block.timestamp
            )
        );
        vm.prank(lp);
        uint256 seriesId = vault.split(pid, liquidity, 0, 5 days);
        address sink = makeAddr("sink");
        busd.setBlocked(sink, true);
        vm.startPrank(lp);
        weights.transfer(buyer, seriesId, liquidity);
        vault.transferFrom(lp, sink, pid);
        vm.stopPrank();
        swapAs(trader, vault.strategyOf(pid), true, -5 ether);
        vm.warp(block.timestamp + 1 hours);

        (,,, uint256 busdFees) = vault.positionAmounts(pid);
        vm.prank(buyer);
        (uint256 legAmount, uint256 otherAmount) = vault.exercise(seriesId, liquidity, 0, block.timestamp);
        assertGt(legAmount, 0);
        assertGt(otherAmount, 0);
        assertEq(busd.balanceOf(sink), 0, "the blocked owner could not be paid");
        assertEq(vault.owed(sink, address(busd)), otherAmount + busdFees, "... so the USDC leg is credited");
        assertGt(weth.balanceOf(sink), 0, "the ETH fees it can receive are paid");

        busd.setBlocked(sink, false);
        vm.prank(sink);
        assertEq(vault.claim(address(busd), sink), otherAmount + busdFees);
        assertEq(busd.balanceOf(sink), otherAmount + busdFees);
        assertEq(vault.owed(sink, address(busd)), 0);
    }

    /// Gas of the vault's operations (the dock + ship on every withdrawal is what Aqua's immutability costs).
    function test_gasProfile() public {
        uint256 g = gasleft();
        (uint256 pid,,) = mintPosition(lp, lower, upper, liquidity, 1e18);
        console2.log("mint (ship):", g - gasleft());
        vm.prank(lp);
        g = gasleft();
        uint256 seriesId = vault.split(pid, liquidity, 0, 5 days);
        console2.log("split:", g - gasleft());
        vm.prank(lp);
        weights.transfer(buyer, seriesId, liquidity);
        vm.prank(buyer);
        g = gasleft();
        vault.exercise(seriesId, liquidity / 2, 0, block.timestamp);
        console2.log("exercise half (dock + ship):", g - gasleft());
        vm.prank(buyer);
        g = gasleft();
        vault.exercise(seriesId, liquidity - liquidity / 2, 0, block.timestamp);
        console2.log("exercise rest (dock):", g - gasleft());
        vm.prank(lp);
        g = gasleft();
        vault.decreaseLiquidity(positionId, 0, 0, 0, block.timestamp);
        console2.log("collect fees (dock + ship):", g - gasleft());
    }

    function test_accessControl() public {
        vm.prank(buyer);
        vm.expectRevert(AquaWeightVault.NotOwnerOrApproved.selector);
        vault.split(positionId, liquidity, 0, 5 days);
        vm.prank(buyer);
        vm.expectRevert(AquaWeightVault.NotOwnerOrApproved.selector);
        vault.decreaseLiquidity(positionId, 1, 0, 0, block.timestamp);
        uint256 seriesId = _split(5 days);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(AquaWeightVault.SeriesStillActive.selector, seriesId));
        vault.split(positionId, 1, 0, 5 days);
        // a buyer without weights cannot exercise
        vm.prank(buyer);
        vm.expectRevert(ERC6909.InsufficientBalance.selector);
        vault.exercise(seriesId, 1, 0, block.timestamp);
        // only the vault docks its strategies: a stranger cannot (Aqua keys dock on msg.sender)
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(weth), address(usdc));
        bytes32 hash = vault.strategyHashOf(positionId);
        vm.prank(lp);
        vm.expectRevert();
        aqua.dock(address(app), hash, tokens);
    }
}
