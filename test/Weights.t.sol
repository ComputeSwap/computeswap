// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {ERC6909} from "solady/tokens/ERC6909.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {WeightVault} from "../src/weights/WeightVault.sol";
import {WeightAuction} from "../src/weights/WeightAuction.sol";
import {WeightToken} from "../src/weights/WeightToken.sol";
import {EthUsdcFixture} from "./utils/EthUsdcFixture.sol";

/// @dev A position owner that cannot receive ETH (no receive function)
contract EthRejectingOwner {
    WeightVault internal immutable vault;

    constructor(WeightVault _vault) {
        vault = _vault;
    }

    function claimEthTo(address to) external returns (uint256) {
        return vault.claim(Currency.wrap(address(0)), to);
    }
}

/// @notice Splitting an LP position into an ETH weight, selling it in a Dutch auction, and the three ways it ends:
///         exercised (the buyer takes the ETH leg at the current price), merged back, or expired.
/// @dev forge test --match-contract WeightsTest -vv
contract WeightsTest is EthUsdcFixture {
    address internal lp = makeAddr("lp");
    address internal buyer = makeAddr("buyer");
    address internal trader = makeAddr("trader");

    int24 internal lower;
    int24 internal upper;
    uint128 internal liquidity;
    uint256 internal positionId;

    function setUp() public {
        setUpEthUsdc();
        fund(lp, 1_000 ether, 1_000e6);
        fund(buyer, 1_000 ether, 1_000e6);
        fund(trader, 1_000 ether, 1_000e6);
        lower = tickAt(0.5e18);
        upper = tickAt(2e18);
        liquidity = liquidityForValue(lower, upper, 100e6); // $100 on [0.5, 2] at ETH = $1
        (positionId,,) = mintPosition(lp, lower, upper, liquidity);
    }

    function _split(uint64 duration) internal returns (uint256 seriesId) {
        vm.prank(lp);
        seriesId = vault.split(positionId, liquidity, 0, duration);
    }

    function _auction(uint256 seriesId) internal returns (uint256 auctionId, uint256 legValue) {
        (uint256 eth,,,,) = vault.previewExercise(seriesId, liquidity);
        legValue = eth * priceWad() / 1e30;
        vm.startPrank(lp);
        weights.approve(address(auction), seriesId, liquidity);
        auctionId = auction.create(
            seriesId, liquidity, address(usdc), uint128(legValue * 2), uint128(legValue / 4), 15 minutes
        );
        vm.stopPrank();
    }

    function _priceAfterSixMinutesOfDrop(uint256 auctionId, uint256 startPrice) internal returns (uint256) {
        (, uint64 startBlock,, uint64 dropStart,,,,,,,) = auction.auctions(auctionId);
        vm.roll(uint256(startBlock) + 1);
        assertEq(auction.currentPrice(auctionId), startPrice, "announcement holds the start price");
        vm.warp(dropStart + 6 minutes);
        return auction.currentPrice(auctionId);
    }

    function _pushPriceTo(uint256 targetWad) internal {
        // sell ETH until the price is at the target (approximately), in a few swaps
        for (uint256 i; i < 40 && priceWad() > targetWad; ++i) swapAs(trader, true, -1 ether);
    }

    // ------------------------------------------------------------------------------------------------------------

    /// The example from the brief: ETH weight sold at $1, ETH falls to ~$0.80, the buyer tells the vault to withdraw
    /// and receives the ETH leg (which grew as the price fell); the LP receives the USDC leg.
    function test_splitAuctionExercise() public {
        uint256 seriesId = _split(5 days);
        assertEq(weights.balanceOf(lp, seriesId), liquidity, "LP holds the ETH weight");
        assertEq(vault.lockedLiquidity(positionId), liquidity, "position locked while the weight lives");
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(WeightVault.LiquidityLocked.selector, uint128(0)));
        vault.decreaseLiquidity(positionId, 1, 0, 0, block.timestamp);

        (uint256 auctionId, uint256 legValue) = _auction(seriesId);
        console2.log(string.concat("ETH leg at $1: worth $", fmt(legValue, 6, 4), "; auction starts at 2x, ends at 0.25x"));

        uint256 price = _priceAfterSixMinutesOfDrop(auctionId, legValue * 2);
        assertApproxEqAbs(price, legValue * 2 - (legValue * 2 - legValue / 4) * 6 / 15, 2);
        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(buyer);
        uint256 cost = auction.buy(auctionId, liquidity, type(uint256).max);
        assertEq(usdc.balanceOf(lp) - lpUsdcBefore, cost - auction.quoteProtocolFee(auctionId, liquidity), "proceeds go to the LP");
        assertEq(weights.balanceOf(buyer, seriesId), liquidity);
        console2.log(string.concat("Buyer pays $", fmt(cost, 6, 4), " for the whole ETH weight after the drop starts"));

        // ETH falls to ~$0.80
        _pushPriceTo(0.8e18);
        (uint256 ethNow, uint256 usdcNow,,,) = vault.previewExercise(seriesId, liquidity);
        console2.log(string.concat("ETH = $", fmt(priceWad(), 18, 4), ": ETH leg ", fmt(ethNow, 18, 4), " ETH, USDC leg ", fmt(usdcNow, 6, 4)));

        // right after the move the spot is far from the moving average: exercising now is refused
        vm.prank(buyer);
        vm.expectRevert();
        vault.exercise(seriesId, liquidity, 0, block.timestamp);

        // once the price has held for a while, the buyer exercises
        vm.warp(block.timestamp + 1 hours);
        uint256 buyerEth = buyer.balance;
        uint256 lpUsdc = usdc.balanceOf(lp);
        vm.prank(buyer);
        (uint256 legAmount, uint256 otherAmount) = vault.exercise(seriesId, liquidity, 0, block.timestamp);
        assertEq(buyer.balance - buyerEth, legAmount, "buyer receives the ETH leg");
        assertGe(usdc.balanceOf(lp) - lpUsdc, otherAmount, "LP receives the USDC leg (plus fees)");
        assertEq(legAmount, ethNow, "at the previewed amounts");
        assertEq(otherAmount, usdcNow);
        assertEq(weights.balanceOf(buyer, seriesId), 0, "weights burned");
        assertEq(vault.lockedLiquidity(positionId), 0);
        // x = L(1/P - 1/pb), y = L ln(P/pa) at P ~ 0.8: the ETH leg grew from ~41.9 to ~62.5
        uint256 p = priceWad();
        assertApproxEqRel(legAmount, liquidity * (1e36 / p - 1e36 / priceAtTickWad(upper)) / 1e6, 1e12);
        console2.log(
            string.concat(
                "Exercised at $", fmt(p, 18, 4), ": buyer gets ", fmt(legAmount, 18, 4), " ETH ($",
                fmt(legAmount * p / 1e30, 6, 4), "), LP gets ", fmt(otherAmount, 6, 4), " USDC"
            )
        );
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
        vm.expectRevert(abi.encodeWithSelector(WeightVault.SeriesExpired.selector, seriesId));
        vault.exercise(seriesId, 1, 0, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(WeightToken.SeriesExpired.selector, seriesId));
        weights.transfer(lp, seriesId, 1);

        uint256 lpEth = lp.balance;
        vm.prank(lp);
        vault.decreaseLiquidity(positionId, liquidity, 0, 0, block.timestamp);
        assertGt(lp.balance - lpEth, 41 ether, "the LP withdraws the full position");
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
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(WeightVault.LiquidityLocked.selector, uint128(0)));
        vault.decreaseLiquidity(positionId, 1, 0, 0, block.timestamp);
    }

    /// A buyer cannot inflate the ETH leg by dumping ETH into the pool and exercising in the same block: the spot has
    /// moved away from the moving average, so the exercise reverts.
    function test_flashManipulationBlocked() public {
        uint256 seriesId = _split(5 days);
        vm.prank(lp);
        weights.transfer(buyer, seriesId, liquidity);
        vm.warp(block.timestamp + 1 hours);

        (uint256 fairEth,,,,) = vault.previewExercise(seriesId, liquidity);
        swapAs(buyer, true, -40 ether); // push the price down ~30%
        (uint256 inflatedEth,, bool allowed, int24 tick, int24 emaTick) = vault.previewExercise(seriesId, liquidity);
        assertGt(inflatedEth, fairEth, "the ETH leg would be larger at the pushed price");
        assertFalse(allowed);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(WeightVault.OracleDeviation.selector, tick, emaTick));
        vault.exercise(seriesId, liquidity, 0, block.timestamp);
    }

    /// The other leg follows the position NFT: if the LP sells the NFT, the new owner receives the USDC leg.
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

    /// The LP cannot sell the ETH weight and then block its exercise by moving the NFT to an address that rejects
    /// the owner's payout: the exercise goes through and the unpaid part is credited to the owner.
    function test_ownerCannotBlockExercise() public {
        uint256 seriesId = _split(5 days);
        EthRejectingOwner sink = new EthRejectingOwner(vault);
        vm.startPrank(lp);
        weights.transfer(buyer, seriesId, liquidity);
        vault.transferFrom(lp, address(sink), positionId);
        vm.stopPrank();
        // a round trip leaves the price where it was and fees in both tokens (ETH fees are paid to the owner)
        swapAs(trader, true, -5 ether);
        swapAs(trader, false, -5e6);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(buyer);
        (uint256 legAmount, uint256 otherAmount) = vault.exercise(seriesId, liquidity, 0, block.timestamp);
        assertGt(legAmount, 0);
        assertGe(usdc.balanceOf(address(sink)), otherAmount, "the USDC leg still reaches the owner");
        uint256 ethOwed = vault.owed(address(sink), Currency.wrap(address(0)));
        assertGt(ethOwed, 0, "the ETH fees it cannot receive are credited");

        address payable treasury = payable(makeAddr("treasury"));
        assertEq(sink.claimEthTo(treasury), ethOwed);
        assertEq(treasury.balance, ethOwed);
        assertEq(vault.owed(address(sink), Currency.wrap(address(0))), 0);
    }

    function test_onlyOwnerSplits() public {
        vm.prank(buyer);
        vm.expectRevert(WeightVault.NotOwnerOrApproved.selector);
        vault.split(positionId, liquidity, 0, 5 days);
        uint256 seriesId = _split(5 days);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(WeightVault.SeriesStillActive.selector, seriesId));
        vault.split(positionId, 1, 0, 5 days);
        // a buyer without weights cannot exercise
        vm.prank(buyer);
        vm.expectRevert(ERC6909.InsufficientBalance.selector);
        vault.exercise(seriesId, 1, 0, block.timestamp);
    }
}
