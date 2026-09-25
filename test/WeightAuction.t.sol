// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {WeightAuction} from "../src/weights/WeightAuction.sol";
import {WeightToken} from "../src/weights/WeightToken.sol";
import {EthUsdcFixture} from "./utils/EthUsdcFixture.sol";

/// @dev forge test --match-contract WeightAuctionTest -vv
contract WeightAuctionTest is EthUsdcFixture {
    address internal lp = makeAddr("lp");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");

    int24 internal lower;
    int24 internal upper;
    uint128 internal liquidity;
    uint256 internal positionId;

    uint128 internal startPrice;
    uint128 internal floorPrice;

    function setUp() public {
        setUpEthUsdc();
        fund(lp, 1_000 ether, 1_000e6);
        fund(buyer, 1_000 ether, 1_000e6);
        fund(buyer2, 1_000 ether, 1_000e6);
        lower = tickAt(0.5e18);
        upper = tickAt(2e18);
        liquidity = liquidityForValue(lower, upper, 100e6);
        (positionId,,) = mintPosition(lp, lower, upper, liquidity);
        startPrice = 100e6;
        floorPrice = 25e6;
    }

    function _series() internal returns (uint256 seriesId) {
        vm.prank(lp);
        seriesId = vault.split(positionId, liquidity, 0, 1 days);
    }

    function _open(uint256 seriesId, uint128 lot) internal returns (uint256 auctionId) {
        vm.startPrank(lp);
        weights.approve(address(auction), seriesId, lot);
        auctionId = auction.create(seriesId, lot, address(usdc), startPrice, floorPrice, 5 minutes, 15 minutes);
        vm.stopPrank();
    }

    function _openDefault() internal returns (uint256 seriesId, uint256 auctionId) {
        seriesId = _series();
        auctionId = _open(seriesId, liquidity);
    }

    function _remaining(uint256 auctionId) internal view returns (uint128) {
        (,,,,,,, uint128 remaining,,) = auction.auctions(auctionId);
        return remaining;
    }

    function _warpDrop(uint256 auctionId) internal {
        (,, uint64 dropStart,,,,,,,) = auction.auctions(auctionId);
        vm.warp(dropStart);
    }

    // ------------------------------------------------------------------------------------------------ create

    function test_create_storesPhasesAndEscrowsWeights() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        uint64 t0 = uint64(block.timestamp);
        (
            address seller,
            uint64 start,
            uint64 dropStart,
            uint64 end,
            ,
            uint256 storedSeries,
            uint128 lot,
            uint128 remaining,
            uint128 storedStart,
            uint128 storedFloor
        ) = auction.auctions(auctionId);
        assertEq(seller, lp);
        assertEq(start, t0);
        assertEq(dropStart, t0 + 5 minutes);
        assertEq(end, t0 + 20 minutes);
        assertEq(storedSeries, seriesId);
        assertEq(lot, liquidity);
        assertEq(remaining, liquidity);
        assertEq(storedStart, startPrice);
        assertEq(storedFloor, floorPrice);
        assertEq(weights.balanceOf(address(auction), seriesId), liquidity);
        assertEq(weights.balanceOf(lp, seriesId), 0);
        assertEq(auction.nextAuctionId(), 2);
    }

    function test_create_revertsInvalidAuction() public {
        uint256 seriesId = _series();
        vm.startPrank(lp);
        weights.approve(address(auction), seriesId, liquidity);
        vm.expectRevert(WeightAuction.InvalidAuction.selector);
        auction.create(seriesId, 0, address(usdc), startPrice, floorPrice, 5 minutes, 15 minutes);
        vm.expectRevert(WeightAuction.InvalidAuction.selector);
        auction.create(seriesId, liquidity, address(usdc), startPrice, floorPrice, 0, 15 minutes);
        vm.expectRevert(WeightAuction.InvalidAuction.selector);
        auction.create(seriesId, liquidity, address(usdc), startPrice, floorPrice, 5 minutes, 0);
        vm.expectRevert(WeightAuction.InvalidAuction.selector);
        auction.create(seriesId, liquidity, address(usdc), floorPrice - 1, floorPrice, 5 minutes, 15 minutes);
        vm.stopPrank();
    }

    function test_create_revertsOutlivesWeights() public {
        vm.prank(lp);
        uint256 seriesId = vault.split(positionId, liquidity, 0, 45 minutes);
        vm.startPrank(lp);
        weights.approve(address(auction), seriesId, liquidity);
        vm.expectRevert(WeightAuction.OutlivesWeights.selector);
        auction.create(seriesId, liquidity, address(usdc), startPrice, floorPrice, 30 minutes, 31 minutes);
        vm.stopPrank();
    }

    function test_create_allowsEqualStartAndFloor() public {
        uint256 seriesId = _series();
        vm.startPrank(lp);
        weights.approve(address(auction), seriesId, liquidity);
        uint256 auctionId = auction.create(seriesId, liquidity, address(usdc), 50e6, 50e6, 1 minutes, 1 minutes);
        vm.stopPrank();
        assertEq(auction.currentPrice(auctionId), 50e6);
    }

    // ------------------------------------------------------------------------------------------------ currentPrice / quote

    function test_currentPrice_phases() public {
        (, uint256 auctionId) = _openDefault();
        (,, uint64 dropStart, uint64 end,,,,,,) = auction.auctions(auctionId);
        assertEq(auction.currentPrice(auctionId), startPrice);
        vm.warp(dropStart);
        assertEq(auction.currentPrice(auctionId), startPrice);
        vm.warp(dropStart + 7 minutes + 30 seconds);
        assertEq(auction.currentPrice(auctionId), 62_500_000);
        vm.warp(end);
        assertEq(auction.currentPrice(auctionId), floorPrice);
        vm.warp(end + 1 days);
        assertEq(auction.currentPrice(auctionId), floorPrice);
    }

    function test_quote_roundsUp() public {
        (, uint256 auctionId) = _openDefault();
        uint128 amount = liquidity / 3;
        uint256 quoted = auction.quote(auctionId, amount);
        uint256 naive = auction.currentPrice(auctionId) * amount / liquidity;
        assertGe(quoted, naive);
        assertLe(quoted, naive + 1);
    }

    // ------------------------------------------------------------------------------------------------ buy

    function test_buy_revertsDuringAnnouncement() public {
        (, uint256 auctionId) = _openDefault();
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.AnnouncementActive.selector);
        auction.buy(auctionId, liquidity / 2, type(uint256).max);
    }

    function test_buy_afterDropStarts_chargesCurrentPrice() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        _warpDrop(auctionId);
        uint128 amount = liquidity / 2;
        uint256 expected = auction.quote(auctionId, amount);
        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(buyer);
        uint256 cost = auction.buy(auctionId, amount, type(uint256).max);
        assertEq(cost, expected);
        assertEq(usdc.balanceOf(lp) - lpBefore, cost);
        assertEq(weights.balanceOf(buyer, seriesId), amount);
        assertEq(_remaining(auctionId), liquidity - amount);
    }

    function test_buy_priceFallsBetweenBuys() public {
        (, uint256 auctionId) = _openDefault();
        (,, uint64 dropStart,,,,,,,) = auction.auctions(auctionId);
        vm.warp(dropStart);
        vm.prank(buyer);
        uint256 first = auction.buy(auctionId, liquidity / 4, type(uint256).max);
        vm.warp(dropStart + 10 minutes);
        vm.prank(buyer2);
        uint256 second = auction.buy(auctionId, liquidity / 4, type(uint256).max);
        assertLt(second, first);
    }

    function test_buy_atFloor_chargesFloorPrice() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        (,,, uint64 end,,,,,,) = auction.auctions(auctionId);
        vm.warp(end + 1 hours);
        uint128 amount = liquidity / 4;
        uint256 expected = uint256(floorPrice) * amount / liquidity;
        vm.prank(buyer);
        assertEq(auction.buy(auctionId, amount, type(uint256).max), expected);
        assertEq(weights.balanceOf(buyer, seriesId), amount);
    }

    function test_buy_multiplePartialFills() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        _warpDrop(auctionId);
        uint128 first = liquidity / 4;
        uint128 second = liquidity / 2;
        vm.prank(buyer);
        auction.buy(auctionId, first, type(uint256).max);
        vm.prank(buyer2);
        auction.buy(auctionId, second, type(uint256).max);
        assertEq(weights.balanceOf(buyer, seriesId), first);
        assertEq(weights.balanceOf(buyer2, seriesId), second);
        assertEq(_remaining(auctionId), liquidity - first - second);
    }

    function test_buy_drainsRemaining() public {
        (, uint256 auctionId) = _openDefault();
        _warpDrop(auctionId);
        vm.prank(buyer);
        auction.buy(auctionId, liquidity, type(uint256).max);
        assertEq(_remaining(auctionId), 0);
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.AuctionClosed.selector);
        auction.buy(auctionId, 1, type(uint256).max);
    }

    function test_buy_revertsZeroAmount() public {
        (, uint256 auctionId) = _openDefault();
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.AuctionClosed.selector);
        auction.buy(auctionId, 0, type(uint256).max);
    }

    function test_buy_revertsTooMuch() public {
        (, uint256 auctionId) = _openDefault();
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.AuctionClosed.selector);
        auction.buy(auctionId, liquidity + 1, type(uint256).max);
    }

    function test_buy_revertsTooExpensive() public {
        (, uint256 auctionId) = _openDefault();
        _warpDrop(auctionId);
        uint256 maxCost = auction.quote(auctionId, liquidity / 2) - 1;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(WeightAuction.TooExpensive.selector, maxCost + 1));
        auction.buy(auctionId, liquidity / 2, maxCost);
    }

    function test_buy_revertsAfterWeightExpiry() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        vm.warp(block.timestamp + 1 days + 1);
        assertTrue(weights.isExpired(seriesId));
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.AuctionClosed.selector);
        auction.buy(auctionId, 1, type(uint256).max);
    }

    function test_buy_sellerCanBuyOwnAuction() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        _warpDrop(auctionId);
        vm.prank(lp);
        auction.buy(auctionId, liquidity / 10, type(uint256).max);
        assertEq(weights.balanceOf(lp, seriesId), liquidity / 10);
    }

    // ------------------------------------------------------------------------------------------------ cancel

    function test_cancel_duringAnnouncement_returnsAll() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        vm.prank(lp);
        auction.cancel(auctionId);
        assertEq(weights.balanceOf(lp, seriesId), liquidity);
        assertEq(weights.balanceOf(address(auction), seriesId), 0);
        assertEq(_remaining(auctionId), 0);
    }

    function test_cancel_duringDrop_returnsUnsold() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        (,, uint64 dropStart,,,,,,,) = auction.auctions(auctionId);
        vm.warp(dropStart + 1 minutes);
        vm.prank(lp);
        auction.cancel(auctionId);
        assertEq(weights.balanceOf(lp, seriesId), liquidity);
    }

    function test_cancel_atFloor_returnsUnsold() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        (,,, uint64 end,,,,,,) = auction.auctions(auctionId);
        vm.warp(end + 1 hours);
        vm.prank(lp);
        auction.cancel(auctionId);
        assertEq(weights.balanceOf(lp, seriesId), liquidity);
    }

    function test_cancel_afterPartialBuy_returnsRemainder() public {
        (uint256 seriesId, uint256 auctionId) = _openDefault();
        _warpDrop(auctionId);
        uint128 sold = liquidity / 3;
        vm.prank(buyer);
        auction.buy(auctionId, sold, type(uint256).max);
        vm.prank(lp);
        auction.cancel(auctionId);
        assertEq(weights.balanceOf(lp, seriesId), liquidity - sold);
        assertEq(weights.balanceOf(buyer, seriesId), sold);
        assertEq(_remaining(auctionId), 0);
    }

    function test_cancel_revertsWhenSoldOut() public {
        (, uint256 auctionId) = _openDefault();
        _warpDrop(auctionId);
        vm.prank(buyer);
        auction.buy(auctionId, liquidity, type(uint256).max);
        vm.prank(lp);
        vm.expectRevert(WeightAuction.AuctionClosed.selector);
        auction.cancel(auctionId);
    }

    function test_cancel_revertsNotSeller() public {
        (, uint256 auctionId) = _openDefault();
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.NotSeller.selector);
        auction.cancel(auctionId);
    }

    function test_cancel_afterWeightExpiry_closesWithoutTransfer() public {
        (, uint256 auctionId) = _openDefault();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(lp);
        auction.cancel(auctionId);
        assertEq(_remaining(auctionId), 0);
    }

    function test_cancel_thenBuyReverts() public {
        (, uint256 auctionId) = _openDefault();
        vm.prank(lp);
        auction.cancel(auctionId);
        _warpDrop(auctionId);
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.AuctionClosed.selector);
        auction.buy(auctionId, 1, type(uint256).max);
    }

    function test_buy_revertsUnknownAuction() public {
        vm.prank(buyer);
        vm.expectRevert(WeightAuction.InvalidAuction.selector);
        auction.buy(999, 1, type(uint256).max);
    }

    function test_cancel_revertsTwice() public {
        (, uint256 auctionId) = _openDefault();
        vm.startPrank(lp);
        auction.cancel(auctionId);
        vm.expectRevert(WeightAuction.AuctionClosed.selector);
        auction.cancel(auctionId);
        vm.stopPrank();
    }
}
