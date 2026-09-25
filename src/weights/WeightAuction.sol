// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WeightToken} from "./WeightToken.sol";

/// @title WeightAuction - Dutch auctions of WeightTokens
/// @notice The seller escrows a lot of weights. During the creation block the price stays at `startPrice`
///         (announcement; cancel still allowed). Then it falls linearly from `startPrice` to `floorPrice` over
///         `dropDuration`, and stays at `floorPrice` until the weights expire. During the drop and floor phases anyone
///         can buy any part of what is left at the current price. A protocol fee applies to the seller's premium above
///         the floor. The seller can cancel and take back the unsold part at any time. Weights keep all their rights
///         once sold (see WeightVault).
contract WeightAuction is ReentrancyGuard {
    error InvalidAuction();
    error OutlivesWeights();
    error NotSeller();
    error AnnouncementActive();
    error AuctionClosed();
    error TooExpensive(uint256 cost);

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        uint256 indexed seriesId,
        uint128 lot,
        address payToken,
        uint128 startPrice,
        uint128 floorPrice,
        uint64 start,
        uint64 startBlock,
        uint64 dropStart,
        uint64 end
    );
    event Bought(
        uint256 indexed auctionId, address indexed buyer, uint128 amount, uint256 cost, uint256 protocolFee
    );
    event Cancelled(uint256 indexed auctionId, uint128 returned);

    struct Auction {
        address seller;
        uint64 startBlock;
        uint64 start;
        uint64 dropStart;
        uint64 end;
        address payToken;
        uint256 seriesId;
        uint128 lot;
        uint128 remaining;
        uint128 startPrice;
        uint128 floorPrice;
    }

    uint256 public constant SELLER_PREMIUM_FEE_BPS = 500;

    WeightToken public immutable weights;
    address public immutable treasury;
    uint256 public nextAuctionId = 1;
    mapping(uint256 auctionId => Auction) public auctions;

    constructor(WeightToken _weights, address _treasury) {
        if (_treasury == address(0)) revert InvalidAuction();
        weights = _weights;
        treasury = _treasury;
    }

    function create(
        uint256 seriesId,
        uint128 lot,
        address payToken,
        uint128 startPrice,
        uint128 floorPrice,
        uint64 dropDuration
    ) external nonReentrant returns (uint256 auctionId) {
        if (lot == 0 || dropDuration == 0 || startPrice < floorPrice) revert InvalidAuction();
        uint64 start = uint64(block.timestamp);
        uint64 dropStart = start;
        uint64 end = start + dropDuration;
        if (end > weights.expiryOf(seriesId)) revert OutlivesWeights();

        auctionId = nextAuctionId++;
        auctions[auctionId] = Auction({
            seller: msg.sender,
            startBlock: uint64(block.number),
            start: start,
            dropStart: dropStart,
            end: end,
            payToken: payToken,
            seriesId: seriesId,
            lot: lot,
            remaining: lot,
            startPrice: startPrice,
            floorPrice: floorPrice
        });
        weights.transferFrom(msg.sender, address(this), seriesId, lot);
        emit AuctionCreated(
            auctionId,
            msg.sender,
            seriesId,
            lot,
            payToken,
            startPrice,
            floorPrice,
            start,
            uint64(block.number),
            dropStart,
            end
        );
    }

    function currentPrice(uint256 auctionId) public view returns (uint256) {
        Auction storage a = auctions[auctionId];
        if (a.lot == 0) revert InvalidAuction();
        if (block.number <= a.startBlock) return a.startPrice;
        if (block.timestamp >= a.end) return a.floorPrice;
        uint256 drop = uint256(a.startPrice - a.floorPrice) * (block.timestamp - a.dropStart) / (a.end - a.dropStart);
        return a.startPrice - drop;
    }

    function quote(uint256 auctionId, uint128 amount) public view returns (uint256) {
        return FixedPointMathLib.mulDivUp(currentPrice(auctionId), amount, auctions[auctionId].lot);
    }

    function quoteProtocolFee(uint256 auctionId, uint128 amount) public view returns (uint256) {
        Auction storage a = auctions[auctionId];
        if (a.lot == 0) revert InvalidAuction();
        uint256 cost = quote(auctionId, amount);
        uint256 floorCost = FixedPointMathLib.mulDivUp(a.floorPrice, amount, a.lot);
        if (cost <= floorCost) return 0;
        return (cost - floorCost) * SELLER_PREMIUM_FEE_BPS / 10_000;
    }

    function buy(uint256 auctionId, uint128 amount, uint256 maxCost) external nonReentrant returns (uint256 cost) {
        Auction storage a = auctions[auctionId];
        if (a.lot == 0) revert InvalidAuction();
        if (amount == 0 || amount > a.remaining || weights.isExpired(a.seriesId)) revert AuctionClosed();
        if (block.number <= a.startBlock) revert AnnouncementActive();
        cost = quote(auctionId, amount);
        if (cost > maxCost) revert TooExpensive(cost);
        uint256 protocolFee = quoteProtocolFee(auctionId, amount);
        a.remaining -= amount;
        SafeTransferLib.safeTransferFrom(a.payToken, msg.sender, a.seller, cost - protocolFee);
        if (protocolFee != 0) SafeTransferLib.safeTransferFrom(a.payToken, msg.sender, treasury, protocolFee);
        weights.transfer(msg.sender, a.seriesId, amount);
        emit Bought(auctionId, msg.sender, amount, cost, protocolFee);
    }

    function cancel(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.lot == 0) revert InvalidAuction();
        if (msg.sender != a.seller) revert NotSeller();
        if (a.remaining == 0) revert AuctionClosed();
        uint128 amount = a.remaining;
        a.remaining = 0;
        if (amount != 0 && !weights.isExpired(a.seriesId)) weights.transfer(a.seller, a.seriesId, amount);
        emit Cancelled(auctionId, amount);
    }
}
