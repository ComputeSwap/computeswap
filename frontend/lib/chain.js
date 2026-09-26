// Contracts, ABIs and error decoding for the deployment (see script/DeployBase.s.sol).
import { ethers } from "ethers";

export { ethers };

const KEY =
  "tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)";

// every custom error the stack can revert with, so failures show a readable reason
const ERRORS = [
  "error WrappedError(address target, bytes4 selector, bytes reason, bytes details)",
  "error CurrencyNotSettled()",
  "error ManagerLocked()",
  "error SafeCastOverflow()",
  "error TickMisaligned(int24 tick, int24 tickSpacing)",
  "error SwapNotFullyFilled(int256 amountSpecifiedRemaining)",
  "error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96)",
  "error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96)",
  "error TicksMisordered(int24 tickLower, int24 tickUpper)",
  "error TickLowerOutOfBounds(int24 tickLower)",
  "error TickUpperOutOfBounds(int24 tickUpper)",
  "error TickLiquidityOverflow(int24 tick)",
  "error PoolAlreadyInitialized()",
  "error PoolNotInitialized()",
  "error CannotUpdateEmptyPosition()",
  "error CurveMovedPriceBackwards(uint160 current, uint160 next)",
  "error NotEnoughLiquidity()",
  "error InvalidPriceOrLiquidity()",
  "error NotPoolManager()",
  "error WrongHook()",
  "error InvalidCurve()",
  "error PoolNotRegistered()",
  "error DeadlinePassed()",
  "error ZeroLiquidity()",
  "error SlippageExceeded()",
  "error NativeValueNotAccepted()",
  "error InsufficientNativeValue()",
  "error InsufficientPoolReserves()",
  "error NotOwnerOrApproved()",
  "error LiquidityLocked(uint128 free)",
  "error SeriesStillActive(uint256 seriesId)",
  "error InvalidSplit()",
  "error SeriesExpired(uint256 seriesId)",
  "error OracleDeviation(int24 tick, int24 emaTick)",
  "error Slippage()",
  "error NativeValueMismatch()",
  "error InsufficientBalance()",
  "error InsufficientPermission()",
  "error AnnouncementActive()",
  "error InvalidAuction()",
  "error OutlivesWeights()",
  "error NotSeller()",
  "error AuctionClosed()",
  "error TooExpensive(uint256 cost)",
  "error TransferFromFailed()",
  "error TransferFailed()",
  "error ETHTransferFailed()",
  "error MintTooLarge()",
];

export const ABI = {
  hook: [
    `function initializePool(${KEY} key, uint160 sqrtPriceX96, bool mirrorPrice) returns (int24)`,
    "function getSlot0(bytes32 id) view returns (uint160 sqrtPriceX96, int24 tick, uint24 lpFee)",
    "function getLiquidity(bytes32 id) view returns (uint128)",
    "function reserves(bytes32 id) view returns (uint128 amount0, uint128 amount1)",
    "function poolConfig(bytes32 id) view returns (address curve, bool mirrorPrice)",
    "function getOracle(bytes32 id) view returns (int24 tick, int24 emaTick)",
    "function getAmountsForLiquidity(bytes32 id, int24 tickLower, int24 tickUpper, uint128 liquidity, bool roundUp) view returns (uint256 amount0, uint256 amount1)",
    "function getLiquidityForAmounts(bytes32 id, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) view returns (uint128)",
    "function getPositionAmounts(bytes32 id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt) view returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)",
    "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)",
    "event PoolInitialized(bytes32 indexed id, address indexed curve, uint160 sqrtPriceX96, int24 tick, bool mirrorPrice)",
    ...ERRORS,
  ],
  router: [
    `function swap(${KEY} key, tuple(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, tuple(bool takeClaims, bool settleUsingBurn) testSettings, bytes hookData) payable returns (int256 delta)`,
    ...ERRORS,
  ],
  usdc: [
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function mint(address to, uint256 amount)",
  ],
  vault: [
    `function mint(${KEY} key, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0Max, uint256 amount1Max, uint256 deadline) payable returns (uint256 positionId, uint256 amount0, uint256 amount1)`,
    "function decreaseLiquidity(uint256 positionId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min, uint256 deadline) returns (int256 principal, int256 fees)",
    "function split(uint256 positionId, uint128 units, uint8 leg, uint64 duration) returns (uint256 seriesId)",
    "function exercise(uint256 seriesId, uint128 units, uint256 minLegAmount, uint256 deadline) returns (uint256 legAmount, uint256 otherAmount)",
    "function merge(uint256 seriesId, uint128 units)",
    "function lockedLiquidity(uint256 positionId) view returns (uint128)",
    `function getPosition(uint256 positionId) view returns (${KEY} key, int24 tickLower, int24 tickUpper, uint128 liquidity, uint128 locked, uint256 activeSeries, address owner)`,
    "function previewExercise(uint256 seriesId, uint128 units) view returns (uint256 legAmount, uint256 otherAmount, bool allowed, int24 tick, int24 emaTick)",
    "function series(uint256 seriesId) view returns (uint256 positionId, uint64 expiry, uint8 leg, uint128 remaining)",
    "function nextPositionId() view returns (uint256)",
    "function nextSeriesId() view returns (uint256)",
    "function maxOracleDeviation() view returns (uint24)",
    "event PositionMinted(uint256 indexed positionId, address indexed owner, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1)",
    "event Split(uint256 indexed positionId, uint256 indexed seriesId, uint8 leg, uint128 units, uint64 expiry)",
    "event Exercised(uint256 indexed seriesId, address indexed holder, uint128 units, uint256 legAmount, uint256 otherAmount)",
    "event LiquidityDecreased(uint256 indexed positionId, uint128 liquidity, int256 principal, int256 fees)",
    "event Merged(uint256 indexed seriesId, uint128 units)",
    ...ERRORS,
  ],
  weights: [
    "function balanceOf(address owner, uint256 id) view returns (uint256)",
    "function allowance(address owner, address spender, uint256 id) view returns (uint256)",
    "function approve(address spender, uint256 id, uint256 amount) returns (bool)",
    "function transfer(address to, uint256 id, uint256 amount) returns (bool)",
    "function isExpired(uint256 id) view returns (bool)",
    ...ERRORS,
  ],
  auction: [
    "function create(uint256 seriesId, uint128 lot, address payToken, uint128 startPrice, uint128 floorPrice, uint64 dropDuration) returns (uint256 auctionId)",
    "function buy(uint256 auctionId, uint128 amount, uint256 maxCost) returns (uint256 cost)",
    "function cancel(uint256 auctionId)",
    "function currentPrice(uint256 auctionId) view returns (uint256)",
    "function quote(uint256 auctionId, uint128 amount) view returns (uint256)",
    "function quoteProtocolFee(uint256 auctionId, uint128 amount) view returns (uint256)",
    "function treasury() view returns (address)",
    "function SELLER_PREMIUM_FEE_BPS() view returns (uint256)",
    "function auctions(uint256 auctionId) view returns (address seller, uint64 startBlock, uint64 start, uint64 dropStart, uint64 end, address payToken, uint256 seriesId, uint128 lot, uint128 remaining, uint128 startPrice, uint128 floorPrice)",
    "function nextAuctionId() view returns (uint256)",
    "event AuctionCreated(uint256 indexed auctionId, address indexed seller, uint256 indexed seriesId, uint128 lot, address payToken, uint128 startPrice, uint128 floorPrice, uint64 start, uint64 startBlock, uint64 dropStart, uint64 end)",
    "event Bought(uint256 indexed auctionId, address indexed buyer, uint128 amount, uint256 cost, uint256 protocolFee)",
    "event Cancelled(uint256 indexed auctionId, uint128 returned)",
    ...ERRORS,
  ],
};

const errorInterface = new ethers.Interface(ERRORS);

// what each revert means for the person using the page
const FRIENDLY = {
  DeadlinePassed: "The transaction was mined after its deadline. Try again.",
  SlippageExceeded:
    "The price moved before your transaction was mined, by more than the allowed slippage. Try again.",
  Slippage:
    "The price moved before your transaction was mined, by more than the allowed slippage. Try again.",
  SwapNotFullyFilled:
    "The pool doesn't have enough liquidity to fill this swap.",
  NotEnoughLiquidity:
    "The pool doesn't have enough liquidity to fill this swap.",
  PriceLimitAlreadyExceeded:
    "The price is already past the swap's price limit.",
  OracleDeviation:
    "The price moved too fast: exercising opens once it is within about 1% of its 10-minute average.",
  LiquidityLocked:
    "Part of this position is locked by its sold ETH weight until the weight expires.",
  SeriesExpired: "This ETH weight has expired.",
  SeriesStillActive: "This position already has a live ETH weight.",
  InvalidSplit:
    "Choose a share of the position above 0% and an expiry above 0.",
  AnnouncementActive:
    "The auction hasn't started yet. Wait until the price begins to fall.",
  AuctionClosed: "This auction is closed: sold out, cancelled or expired.",
  TooExpensive: "The auction price is above your limit.",
  OutlivesWeights: "The auction must end before the weight expires.",
  InvalidAuction:
    "The start price must be at least the floor price, and the auction must last some time.",
  NotSeller: "Only the seller can cancel this auction.",
  NotOwnerOrApproved: "Only the position's owner can do this.",
  InsufficientBalance: "Not enough balance.",
  TransferFromFailed:
    "A token transfer failed: check your balance and approval.",
  TransferFailed: "A token transfer failed.",
  ETHTransferFailed: "An ETH transfer failed.",
  InsufficientNativeValue: "Not enough ETH was sent with the transaction.",
  NativeValueMismatch: "Not enough ETH was sent with the transaction.",
  PoolAlreadyInitialized: "The pool already exists.",
  PoolNotRegistered: "This pool doesn't exist on the hook.",
  TickLowerOutOfBounds: "The min price is outside what the pool supports.",
  TickUpperOutOfBounds: "The max price is outside what the pool supports.",
  ZeroLiquidity: "The amount is too small to add any liquidity.",
  MintTooLarge: "At most 100,000 test USDC per mint.",
};

/** Readable reason for a failed call, unwrapping the PoolManager's WrappedError around hook reverts. */
export function decodeError(err) {
  if (err?.code === "ACTION_REJECTED" || err?.info?.error?.code === 4001) {
    return "You rejected the request in your wallet.";
  }
  if (err?.code === "INSUFFICIENT_FUNDS") {
    return "Not enough ETH for this transaction and its gas.";
  }
  const msg = `${err?.shortMessage || ""} ${err?.message || ""}`.toLowerCase();
  if (msg.includes("nonce too low")) {
    return "Your wallet's transaction counter is out of date. Wait a few seconds and try again, or reset the account in MetaMask (Settings → Advanced → Clear activity tab data).";
  }
  const data = findRevertData(err);
  if (data) {
    return describe(data);
  }
  return err?.shortMessage || err?.reason || err?.message || String(err);
}

function describe(data) {
  if (!data || data === "0x") {
    return "reverted without a reason";
  }
  try {
    const parsed = errorInterface.parseError(data);
    if (parsed.name === "WrappedError") {
      return describe(parsed.args.reason);
    }
    const args = parsed.args.map((a) => a.toString()).join(", ");
    const raw = `${parsed.name}(${args})`;
    return FRIENDLY[parsed.name] ? `${FRIENDLY[parsed.name]} [${raw}]` : raw;
  } catch {
    try {
      return (
        "Error: " +
        ethers.AbiCoder.defaultAbiCoder().decode(
          ["string"],
          `0x${data.slice(10)}`,
        )[0]
      );
    } catch {
      return `reverted with data ${data.slice(0, 74)}`;
    }
  }
}

function findRevertData(err) {
  const seen = new Set();
  const stack = [err];
  while (stack.length) {
    const e = stack.pop();
    if (!e || typeof e !== "object" || seen.has(e)) {
      continue;
    }
    seen.add(e);
    if (
      typeof e.data === "string" &&
      e.data.startsWith("0x") &&
      e.data.length >= 10
    ) {
      return e.data;
    }
    for (const k of ["error", "info", "data", "cause"]) {
      if (e[k] && typeof e[k] === "object") {
        stack.push(e[k]);
      }
    }
  }
  return null;
}

/** BalanceDelta (int256) -> [amount0, amount1] */
export function splitDelta(delta) {
  const d = BigInt(delta);
  const a0 = BigInt.asIntN(128, d >> 128n);
  const a1 = BigInt.asIntN(128, d);
  return [a0, a1];
}
