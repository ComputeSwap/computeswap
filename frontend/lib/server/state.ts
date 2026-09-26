// The pool's shared state (price, positions, auctions, weight series) read once per block for all visitors.
// Per-visitor data (balances, held weights, allowances) stays in the browser.
import { ethers } from "ethers";
import { ABI } from "../chain.js";
import * as C from "../curve.js";
import { type ServerConfig, serverConfig } from "./config";

export type Snapshot = {
  block: number;
  chainTime: number;
  local: boolean;
  pool: {
    initialized: boolean;
    tick?: number;
    price?: number;
    sqrtPriceX96?: string;
  };
  positions: {
    id: number;
    owner: string;
    tickLower: number;
    tickUpper: number;
    liquidity: string;
    locked: string;
    activeSeries: number;
    eth: string;
    usdc: string;
    fees0: string;
    fees1: string;
  }[];
  auctions: {
    id: number;
    seller: string;
    startBlock: number;
    start: number;
    dropStart: number;
    end: number;
    seriesId: number;
    lot: string;
    remaining: string;
    startPrice: string;
    floorPrice: string;
  }[];
  series: { id: number; positionId: number; expiry: number }[];
  nextSeriesId: number;
};

type Cache = {
  rpc: string;
  key: string;
  last?: { block: number; at: number; snapshot: Snapshot; promise?: undefined };
  inflight?: Promise<Snapshot>;
  seriesMeta: Map<number, { positionId: number; expiry: number }>; // immutable once created
  closedAuctions: Set<number>; // remaining reached 0: final
  deadPositions: Set<number>; // liquidity reached 0: final
};

const g = globalThis as unknown as { __logCurveState?: Cache };
const salt = (id: number) => ethers.toBeHex(id, 32);
const ids = (count: number) =>
  Array.from({ length: Math.max(0, count - 1) }, (_, i) => i + 1);

function cache(cfg: ServerConfig): Cache {
  if (
    !g.__logCurveState ||
    g.__logCurveState.key !== cfg.key ||
    g.__logCurveState.rpc !== cfg.rpc
  ) {
    g.__logCurveState = {
      rpc: cfg.rpc,
      key: cfg.key,
      seriesMeta: new Map(),
      closedAuctions: new Set(),
      deadPositions: new Set(),
    };
  }
  return g.__logCurveState;
}

async function read(cfg: ServerConfig, c: Cache): Promise<Snapshot> {
  const rpc = new ethers.JsonRpcProvider(cfg.rpc, Number(cfg.dep.chainId), {
    staticNetwork: true,
    batchMaxCount: 10,
  });
  const hook = new ethers.Contract(cfg.dep.hook, ABI.hook, rpc);
  const vault = new ethers.Contract(cfg.dep.vault, ABI.vault, rpc);
  const auction = new ethers.Contract(cfg.dep.auction, ABI.auction, rpc);

  const block = await rpc.getBlock("latest");
  if (!block) {
    throw new Error("no latest block");
  }
  let chainTime = block.timestamp;
  let blockNumber = block.number;
  if (cfg.local) {
    // anvil: the pending block carries the warped clock
    try {
      const pending = await rpc.send("eth_getBlockByNumber", [
        "pending",
        false,
      ]);
      chainTime = Math.max(chainTime, parseInt(pending.timestamp, 16) || 0);
      blockNumber = Math.max(blockNumber, parseInt(pending.number, 16) || 0);
    } catch {}
  }
  if (c.last && c.last.block === blockNumber) {
    return c.last.snapshot;
  }

  const [curve] = await hook.poolConfig(cfg.poolId);
  let pool: Snapshot["pool"] = { initialized: curve !== ethers.ZeroAddress };
  if (pool.initialized) {
    const slot0 = await hook.getSlot0(cfg.poolId);
    pool = {
      initialized: true,
      tick: Number(slot0.tick),
      price: C.sqrtPriceToPrice(slot0.sqrtPriceX96),
      sqrtPriceX96: slot0.sqrtPriceX96.toString(),
    };
  }

  const [n, ns, na] = (
    await Promise.all([
      vault.nextPositionId(),
      vault.nextSeriesId(),
      auction.nextAuctionId(),
    ])
  ).map(Number);

  const positions = (
    await Promise.all(
      ids(n)
        .filter((id) => !c.deadPositions.has(id))
        .map(async (id) => {
          const p = await vault.getPosition(id);
          if (p.liquidity === 0n) {
            c.deadPositions.add(id);
            return null;
          }
          const a = await hook.getPositionAmounts(
            cfg.poolId,
            cfg.dep.vault,
            p.tickLower,
            p.tickUpper,
            salt(id),
          );
          return {
            id,
            owner: p.owner as string,
            tickLower: Number(p.tickLower),
            tickUpper: Number(p.tickUpper),
            liquidity: p.liquidity.toString(),
            locked: p.locked.toString(),
            activeSeries: Number(p.activeSeries),
            eth: a.amount0.toString(),
            usdc: a.amount1.toString(),
            fees0: a.fees0.toString(),
            fees1: a.fees1.toString(),
          };
        }),
    )
  ).filter((p) => p !== null);

  const auctions = (
    await Promise.all(
      ids(na)
        .filter((id) => !c.closedAuctions.has(id))
        .map(async (id) => {
          const a = await auction.auctions(id);
          if (a.remaining === 0n) {
            c.closedAuctions.add(id);
            return null;
          }
          return {
            id,
            seller: a.seller as string,
            startBlock: Number(a.startBlock),
            start: Number(a.start),
            dropStart: Number(a.dropStart),
            end: Number(a.end),
            seriesId: Number(a.seriesId),
            lot: a.lot.toString(),
            remaining: a.remaining.toString(),
            startPrice: a.startPrice.toString(),
            floorPrice: a.floorPrice.toString(),
          };
        }),
    )
  ).filter((a) => a !== null);

  const missing = ids(ns).filter((id) => !c.seriesMeta.has(id));
  for (let i = 0; i < missing.length; i += 10) {
    await Promise.all(
      missing.slice(i, i + 10).map(async (id) => {
        const s = await vault.series(id);
        c.seriesMeta.set(id, {
          positionId: Number(s.positionId),
          expiry: Number(s.expiry),
        });
      }),
    );
  }
  const series = ids(ns).map((id) => ({
    id,
    ...(c.seriesMeta.get(id) as { positionId: number; expiry: number }),
  }));

  const snapshot: Snapshot = {
    block: blockNumber,
    chainTime,
    local: cfg.local,
    pool,
    positions,
    auctions,
    series,
    nextSeriesId: ns,
  };
  c.last = { block: blockNumber, at: Date.now(), snapshot };
  return snapshot;
}

/** The current snapshot; concurrent callers share one read, and a snapshot is reused while the block is unchanged. */
export async function poolState(): Promise<Snapshot> {
  const cfg = serverConfig();
  const c = cache(cfg);
  if (!c.inflight) {
    c.inflight = read(cfg, c).finally(() => {
      c.inflight = undefined;
    });
  }
  return c.inflight;
}
