// Turns a decoded event into one row of the activity table (null for events that are not operations on this pool).
// The context carries what later rows need from earlier ones: the price after each swap, each position's range,
// which position a weight series came from, and each auction's lot.
import { ethers } from "ethers";
import { splitDelta } from "../chain.js";
import * as C from "../curve.js";
import { fmtNum } from "../format";

export type HistoryContext = {
  price: number | null;
  ranges: Record<string, { pa: number; pb: number }>;
  seriesPos: Record<string, number>;
  auctions: Record<string, { seriesId: number; lot: bigint }>;
};

export type HistoryRow = {
  what: string;
  cls?: string;
  sub?: string;
  eth?: number | null;
  usdc?: number | null;
  price?: number | null;
};

export const emptyContext = (): HistoryContext => ({
  price: null,
  ranges: {},
  seriesPos: {},
  auctions: {},
});

const toEth = (wei: bigint) => Number(ethers.formatEther(wei));
const toUsdc = (units: bigint) => Number(ethers.formatUnits(units, 6));
const abs = (v: bigint) => (v < 0n ? -v : v);
const big = (v: unknown) => BigInt(v as string | number | bigint);

/** Feeds the context with what an event changes, without producing a row (used to rebuild the context from the database). */
export function applyContext(
  H: HistoryContext,
  name: string,
  a: Record<string, unknown>,
  poolId: string,
) {
  switch (name) {
    case "PoolInitialized":
    case "Swap":
      if (a.id === poolId) {
        H.price = C.sqrtPriceToPrice(big(a.sqrtPriceX96));
      }
      break;
    case "PositionMinted":
      H.ranges[String(a.positionId)] = {
        pa: C.tickToPrice(Number(a.tickLower)),
        pb: C.tickToPrice(Number(a.tickUpper)),
      };
      break;
    case "Split":
      H.seriesPos[String(a.seriesId)] = Number(a.positionId);
      break;
    case "AuctionCreated":
      H.auctions[String(a.auctionId)] = {
        seriesId: Number(a.seriesId),
        lot: big(a.lot),
      };
      break;
  }
}

/** One history row per event; also updates the context. Events must arrive in chain order. */
export function historyRow(
  H: HistoryContext,
  name: string,
  a: Record<string, unknown>,
  poolId: string,
): HistoryRow | null {
  const pos = (id: unknown) => (id == null ? "" : `#${id}`);
  const range = (id: string | number) =>
    H.ranges[id]
      ? `$${fmtNum(H.ranges[id].pa, 4)}–$${fmtNum(H.ranges[id].pb, 4)}`
      : "";
  // the ETH behind `units` of a position's liquidity, at the price of the moment
  const ethOf = (id: string | number | undefined, units: bigint) => {
    const r = id == null ? null : H.ranges[id];
    return r && H.price
      ? C.reserves({ ...r, L: Number(units) / 1e6 }, H.price).x
      : null;
  };
  applyContext(H, name, a, poolId);
  switch (name) {
    case "PoolInitialized":
      if (a.id !== poolId) {
        return null;
      }
      return { what: "Create pool", price: H.price };
    case "Swap": {
      if (a.id !== poolId) {
        return null;
      }
      const amount0 = big(a.amount0);
      const amount1 = big(a.amount1);
      const buy = amount0 > 0n; // the trader's amounts: + received, - paid
      return {
        what: buy ? "Buy" : "Sell",
        cls: buy ? "buy" : "sell",
        eth: toEth(abs(amount0)),
        usdc: toUsdc(abs(amount1)),
        price: H.price,
      };
    }
    case "PositionMinted": {
      const id = Number(a.positionId);
      return {
        what: "Add liquidity",
        sub: `#${id} ${range(id)}`,
        eth: toEth(big(a.amount0)),
        usdc: toUsdc(big(a.amount1)),
        price: H.price,
      };
    }
    case "LiquidityDecreased": {
      const [p0, p1] = splitDelta(big(a.principal));
      const [f0, f1] = splitDelta(big(a.fees));
      return {
        what: big(a.liquidity) === 0n ? "Collect fees" : "Withdraw",
        sub: `#${a.positionId}`,
        eth: toEth(abs(p0) + abs(f0)),
        usdc: toUsdc(abs(p1) + abs(f1)),
        price: H.price,
      };
    }
    case "Split": {
      const id = Number(a.positionId);
      return {
        what: "Split ETH weight",
        sub: `#${id}`,
        eth: ethOf(id, big(a.units)),
        price: H.price,
      };
    }
    case "AuctionCreated":
      return {
        what: "Open auction",
        sub: `${pos(H.seriesPos[String(a.seriesId)])} · starts at`,
        usdc: toUsdc(big(a.startPrice)),
        price: H.price,
      };
    case "Bought": {
      const auction = H.auctions[String(a.auctionId)];
      const id = auction && H.seriesPos[auction.seriesId];
      const amount = big(a.amount);
      const share = auction
        ? ` · ${fmtNum((Number(amount) / Number(auction.lot)) * 100, 1)}%`
        : "";
      return {
        what: "Buy ETH weight",
        sub: `${pos(id)}${share}`,
        eth: ethOf(id, amount),
        usdc: toUsdc(big(a.cost)),
        price: H.price,
      };
    }
    case "Cancelled": {
      const auction = H.auctions[String(a.auctionId)];
      return {
        what: "Cancel auction",
        sub: auction ? pos(H.seriesPos[auction.seriesId]) : "",
        price: H.price,
      };
    }
    case "Exercised": // the ETH goes to the weight's holder, the USDC to the position's owner
      return {
        what: "Exercise",
        sub: pos(H.seriesPos[String(a.seriesId)]),
        eth: toEth(big(a.legAmount)),
        usdc: toUsdc(big(a.otherAmount)),
        price: H.price,
      };
    case "Merged":
      return {
        what: "Merge weight",
        sub: pos(H.seriesPos[String(a.seriesId)]),
        price: H.price,
      };
    default:
      return null;
  }
}
