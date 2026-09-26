// The page's state. Actions in lib/app.ts read and write it; components subscribe to what they show.
import type { ethers } from "ethers";
import { create } from "zustand";
import type { Deployment, PoolKey } from "./config";
import type { HistoryEntry, SyncStatus } from "./server/indexer";

export type Position = {
  id: number;
  owner: string;
  pa: number;
  pb: number;
  liquidity: bigint;
  L: number;
  locked: bigint;
  activeSeries: number;
  eth: bigint;
  usdc: bigint;
  fees0: bigint;
  fees1: bigint;
};

export type Auction = {
  id: number;
  seller: string;
  startBlock: number;
  start: number;
  dropStart: number;
  end: number;
  seriesId: number;
  lot: bigint;
  remaining: bigint;
  startPrice: bigint;
  floorPrice: bigint;
};

export type Series = {
  id: number;
  positionId: number;
  expiry: number;
  balance: bigint;
  preview?: { leg: bigint; allowed: boolean; tick: number; ema: number };
};

export type Pool =
  | { initialized: false }
  | { initialized: true; tick: number; price: number };

export type SwapPreview = {
  ok: true;
  amountIn: number;
  amountOut: number;
  price: number;
  zeroForOne: boolean;
  exactIn: boolean;
  amount: number;
  key: string;
  [k: string]: unknown;
};

export type Msg = { kind: "ok" | "bad" | "sub"; html: string } | null;

export type Contracts = Record<
  "hook" | "router" | "usdc" | "vault" | "weights" | "auction",
  ethers.Contract
>;

export type State = {
  dep: Deployment | null;
  local: boolean;
  provider: ethers.JsonRpcProvider | null;
  signers: ethers.JsonRpcSigner[];
  me: string | null;
  c: Contracts | null;
  key: PoolKey | null;
  poolId: string | null;
  pool: Pool;
  positions: Position[];
  series: Series[]; // live auctions' and locked positions' series, plus the ones you hold
  auctions: Auction[];
  history: HistoryEntry[];
  historyBlock: number; // the last block whose rows are in `history`
  historyGen: number | null; // the server's row generation the cached rows came from
  historyStatus: SyncStatus | null;
  historyAll: boolean;
  historyLoading: boolean;
  eth: bigint;
  usdc: bigint;
  chainTime: number;
  chainTimeAt: number;
  chainBlock: number;
  busy: boolean;
  tick: number; // bumps every second so timers re-render
  // add liquidity
  addValue: string;
  addLo: string;
  addHi: string;
  add5050: boolean;
  addMsg: Msg;
  addInvalid: string | null;
  addReady: {
    tl: number;
    tu: number;
    liquidity: bigint;
    amount0: bigint;
    amount1: bigint;
  } | null;
  addGhost: { id: string; pa: number; pb: number; L: number } | null;
  addActive: boolean;
  lastEdited: "lo" | "hi";
  // swap
  swapReceive: "ETH" | "USDC";
  swapLead: "pay" | "receive";
  swapPay: string;
  swapRecv: string;
  swapMsg: Msg;
  swapPreview: SwapPreview | null;
  // liquidity chart
  hoverId: number | string | undefined;
  pop: { id: number; x: number; y: number } | null;
  // selling the ETH weight
  splitFor: number | null;
  splitShare: string;
  splitDays: string;
  auctionDrop: string;
  auctionStart: string;
  auctionFloor: string;
  // weights
  buyPct: Record<number, string>;
  openPayoff: Set<string>;
  toast: { msg: string; kind: string; link: string | null } | null;
  debug: boolean;
};

export const useStore = create<State>(() => ({
  dep: null,
  local: true,
  provider: null,
  signers: [],
  me: null,
  c: null,
  key: null,
  poolId: null,
  pool: { initialized: false },
  positions: [],
  series: [],
  auctions: [],
  history: [],
  historyBlock: -1,
  historyGen: null,
  historyStatus: null,
  historyAll: false,
  historyLoading: true,
  eth: 0n,
  usdc: 0n,
  chainTime: 0,
  chainTimeAt: 0,
  chainBlock: 0,
  busy: false,
  tick: 0,
  addValue: "100",
  addLo: "",
  addHi: "",
  add5050: true,
  addMsg: null,
  addInvalid: null,
  addReady: null,
  addGhost: null,
  addActive: false,
  lastEdited: "hi",
  swapReceive: "ETH",
  swapLead: "receive",
  swapPay: "",
  swapRecv: "",
  swapMsg: null,
  swapPreview: null,
  hoverId: undefined,
  pop: null,
  splitFor: null,
  splitShare: "100",
  splitDays: "30",
  auctionDrop: "15",
  auctionStart: "",
  auctionFloor: "",
  buyPct: {},
  openPayoff: new Set(),
  toast: null,
  debug: false,
}));

export const S = () => useStore.getState();
export const set = useStore.setState;

/** Chain time now: on anvil the chain's clock; on a public chain the last block's time plus the wall clock since. */
export const now = () => {
  const s = S();
  return s.local
    ? s.chainTime
    : s.chainTime + Math.floor((Date.now() - s.chainTimeAt) / 1000);
};

export const isMe = (addr: string | null | undefined) =>
  !!addr && !!S().me && addr.toLowerCase() === (S().me as string).toLowerCase();
