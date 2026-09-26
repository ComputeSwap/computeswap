// Everything the page does against the chain and the API: startup, polling, the previews, and the transactions.
// State lives in lib/store.ts; components only render it and call these.
import { ethers } from "ethers";
import { ABI, decodeError, splitDelta } from "./chain.js";
import {
  type Deployment,
  isLocal,
  LOCAL_RPC,
  poolIdOf,
  poolKeyOf,
} from "./config";
import * as C from "./curve.js";
import { fmtNum } from "./format";
import type { HistoryEntry } from "./server/indexer";
import type { Snapshot } from "./server/state";
import {
  type Contracts,
  now,
  S,
  type Series,
  type SwapPreview,
  set,
  useStore,
} from "./store";
import {
  abs,
  fieldValue,
  fmtDuration,
  NAMES,
  parseAmount,
  short,
  toEth,
  toUsdc,
} from "./ui";

const MIN_PRICE_LIMIT = 4295128740n; // TickMath.MIN_SQRT_PRICE + 1
const MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n; // TickMath.MAX_SQRT_PRICE - 1

declare global {
  interface Window {
    ethereum?: {
      request: (args: {
        method: string;
        params?: unknown[];
      }) => Promise<unknown>;
      on?: (event: string, cb: (...args: unknown[]) => void) => void;
    };
    logCurveApp?: unknown;
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// toast, names
// ---------------------------------------------------------------------------------------------------------------------
let toastTimer: ReturnType<typeof setTimeout> | null = null;
export function toast(msg: string, kind = "", link: string | null = null) {
  if (kind === "err" && !S().debug) {
    return;
  }
  set({ toast: { msg, kind, link } });
  if (toastTimer) {
    clearTimeout(toastTimer);
  }
  if (kind) {
    toastTimer = setTimeout(
      () => set({ toast: null }),
      kind === "err" ? 9000 : 3000,
    );
  }
}

export const nameOf = (addr: string) => {
  const s = S();
  const i = s.signers.findIndex(
    (x) => x.address.toLowerCase() === addr.toLowerCase(),
  );
  if (i >= 0) {
    return NAMES[i] || `account ${i}`;
  }
  return s.me && addr.toLowerCase() === s.me.toLowerCase()
    ? "You"
    : short(addr);
};

export const deadline = () => BigInt(now() + 3600);
export { fmtDuration };

// ---------------------------------------------------------------------------------------------------------------------
// startup and polling
// ---------------------------------------------------------------------------------------------------------------------
let timers: ReturnType<typeof setInterval>[] = [];

export async function init(dep: Deployment) {
  stop();
  const local = isLocal(dep);
  const rpc = dep.rpc || LOCAL_RPC;
  const provider = new ethers.JsonRpcProvider(rpc, Number(dep.chainId), {
    staticNetwork: true,
    polling: false,
    batchMaxCount: local ? 100 : 10,
  });
  const key = poolKeyOf(dep);
  set({ dep, local, provider, key, poolId: poolIdOf(key), signers: [] });
  try {
    await provider.getBlockNumber();
    if (local) {
      set({ signers: (await provider.listAccounts()).slice(0, 10) });
    }
  } catch {
    return toast(
      local
        ? `Cannot reach the chain at ${rpc}: is anvil running?`
        : `Cannot reach ${rpc}.`,
      "err",
    );
  }
  restoreDebugMode();
  restoreHistoryCache();
  if (local) {
    setAccount(0);
  } else {
    bind(provider, null);
  }
  if (window.ethereum?.on) {
    window.ethereum.on(
      "accountsChanged",
      () => !S().local && S().me && connectWallet(),
    );
    window.ethereum.on("chainChanged", () => !S().local && location.reload());
  }
  await scheduleRefresh();
  void loadHistory();
  timers = [
    setInterval(() => void scheduleRefresh(), local ? 1500 : 4000),
    setInterval(() => void loadHistory(), local ? 1500 : 4000),
    setInterval(() => set({ tick: Date.now() }), 1000),
  ];
  window.logCurveApp = { store: useStore, refresh: scheduleRefresh, curve: C };
}

export function stop() {
  for (const t of timers) {
    clearInterval(t);
  }
  timers = [];
}

export function setAccount(i: number) {
  const signer = S().signers[i];
  bind(signer, signer.address);
}

/** Contracts that sign with `runner` (or only read, when `address` is null) */
function bind(runner: ethers.ContractRunner, address: string | null) {
  const dep = S().dep as Deployment;
  const make = (name: keyof Contracts) =>
    new ethers.Contract(dep[name], ABI[name], runner);
  set({
    me: address,
    c: {
      hook: make("hook"),
      router: make("router"),
      usdc: make("usdc"),
      vault: make("vault"),
      weights: make("weights"),
      auction: make("auction"),
    },
  });
}

/** Connects a browser wallet (MetaMask, Rabby, ...) on the deployment's chain, adding the chain if the wallet lacks it. */
export async function connectWallet() {
  const dep = S().dep as Deployment;
  if (!window.ethereum) {
    return toast("No browser wallet found: install MetaMask or Rabby.", "err");
  }
  const chainId = `0x${Number(dep.chainId).toString(16)}`;
  try {
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId }],
      });
    } catch (e) {
      if ((e as { code?: number })?.code !== 4902) {
        throw e; // 4902: the wallet does not know the chain yet
      }
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId,
            chainName: dep.chainName,
            rpcUrls: [dep.rpc],
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            blockExplorerUrls: dep.explorer ? [dep.explorer] : [],
          },
        ],
      });
    }
    const signer = await new ethers.BrowserProvider(
      window.ethereum as ethers.Eip1193Provider,
    ).getSigner();
    bind(signer, await signer.getAddress());
    await scheduleRefresh();
  } catch (e) {
    toast(`Could not connect the wallet: ${decodeError(e)}`, "err");
  }
}

let refreshing: Promise<void> | null = null;
let refreshAgain = false;
export function scheduleRefresh(): Promise<void> {
  if (refreshing) {
    refreshAgain = true;
    return refreshing;
  }
  refreshing = refresh()
    .catch((e) => toast(`Refresh failed: ${decodeError(e)}`, "err"))
    .finally(() => {
      refreshing = null;
      if (refreshAgain) {
        refreshAgain = false;
        void scheduleRefresh();
      }
    });
  return refreshing;
}

const big = (v: string) => BigInt(v);

/** Pool state from the server's shared snapshot, then this wallet's balances and weights from the chain. */
async function refresh() {
  const s = S();
  const { provider, me } = s;
  const c = s.c as Contracts;
  if (!provider || !c) {
    return;
  }
  const res = await fetch("/api/state", { cache: "no-store" });
  if (!res.ok) {
    throw new Error(
      (await res.json().catch(() => null))?.error || `state ${res.status}`,
    );
  }
  const snap = (await res.json()) as Snapshot;
  const positions = snap.positions.map((p) => ({
    id: p.id,
    owner: p.owner,
    pa: C.tickToPrice(p.tickLower),
    pb: C.tickToPrice(p.tickUpper),
    liquidity: big(p.liquidity),
    L: Number(p.liquidity) / 1e6,
    locked: big(p.locked),
    activeSeries: p.activeSeries,
    eth: big(p.eth),
    usdc: big(p.usdc),
    fees0: big(p.fees0),
    fees1: big(p.fees1),
  }));
  const auctions = snap.auctions.map((a) => ({
    ...a,
    lot: big(a.lot),
    remaining: big(a.remaining),
    startPrice: big(a.startPrice),
    floorPrice: big(a.floorPrice),
  }));
  const seriesNeed = new Set<number>();
  for (const a of auctions) {
    if (a.remaining > 0n) {
      seriesNeed.add(a.seriesId);
    }
  }
  for (const p of positions) {
    if (p.activeSeries) {
      seriesNeed.add(p.activeSeries);
    }
  }
  const t = snap.chainTime;
  let series: Series[];
  let eth = 0n;
  let usdc = 0n;
  if (me) {
    [eth, usdc] = await Promise.all([
      provider.getBalance(me),
      c.usdc.balanceOf(me) as Promise<bigint>,
    ]);
    // only unexpired series can be held or exercised; the rest are needed only when an auction or lock refers to them
    const candidates = snap.series.filter(
      (x) => x.expiry > t || seriesNeed.has(x.id),
    );
    series = (
      await Promise.all(
        candidates.map(async (x) => {
          const balance = (await c.weights.balanceOf(me, x.id)) as bigint;
          const entry: Series = {
            id: x.id,
            positionId: x.positionId,
            expiry: x.expiry,
            balance,
          };
          if (balance > 0n) {
            const pv = await c.vault.previewExercise(x.id, balance);
            entry.preview = {
              leg: pv.legAmount,
              allowed: pv.allowed,
              tick: Number(pv.tick),
              ema: Number(pv.emaTick),
            };
          }
          return entry;
        }),
      )
    ).filter((x) => x.balance > 0n || seriesNeed.has(x.id));
  } else {
    series = snap.series
      .filter((x) => seriesNeed.has(x.id))
      .map((x) => ({ ...x, balance: 0n }));
  }
  const pool = snap.pool.initialized
    ? {
        initialized: true as const,
        tick: snap.pool.tick as number,
        price: snap.pool.price as number,
      }
    : { initialized: false as const };
  set({
    pool,
    positions,
    auctions,
    series,
    eth,
    usdc,
    chainTime: snap.chainTime,
    chainTimeAt: Date.now(),
    chainBlock: snap.block,
  });
  if (pool.initialized && !S().addHi && !S().addLo) {
    set({ addHi: String(+(2 * pool.price).toPrecision(4)) });
  }
  await updateAddPreview();
  updateSwapPreview();
}

// ---------------------------------------------------------------------------------------------------------------------
// history: the activity table, from the server's index (cached in the browser so repeat visits load at once)
// ---------------------------------------------------------------------------------------------------------------------
const historyStorageKey = () => {
  const dep = S().dep as Deployment;
  return `logCurve-hist:${dep.chainId}:${dep.hook}`;
};

const DEBUG_STORAGE_KEY = "logCurve-debug";

export function setDebug(on: boolean) {
  set({ debug: on });
  try {
    localStorage.setItem(DEBUG_STORAGE_KEY, on ? "1" : "0");
  } catch {}
}

function restoreDebugMode() {
  try {
    if (localStorage.getItem(DEBUG_STORAGE_KEY) === "1") {
      set({ debug: true });
    }
  } catch {}
}

function restoreHistoryCache() {
  try {
    const raw = localStorage.getItem(historyStorageKey());
    if (!raw) {
      return;
    }
    const data = JSON.parse(raw);
    if (data?.v !== 3 || !Array.isArray(data.history)) {
      return;
    }
    set({
      history: data.history,
      historyBlock: Number(data.historyBlock ?? -1),
      historyGen: data.gen ?? null,
    });
  } catch {}
}

function saveHistoryCache() {
  try {
    const s = S();
    localStorage.setItem(
      historyStorageKey(),
      JSON.stringify({
        v: 3,
        gen: s.historyGen,
        historyBlock: s.historyBlock,
        history: s.history.slice(-2000),
      }),
    );
  } catch {}
}

type HistoryResponse = { rows: HistoryEntry[]; status: State["historyStatus"] };

async function fetchHistory(after: number): Promise<HistoryResponse> {
  const res = await fetch(`/api/history?after=${after}`, { cache: "no-store" });
  if (!res.ok) {
    throw new Error(
      (await res.json().catch(() => null))?.error || `history ${res.status}`,
    );
  }
  return (await res.json()) as HistoryResponse;
}

let historyLoad: Promise<void> | null = null;
export function loadHistory(): Promise<void> {
  if (historyLoad) {
    return historyLoad;
  }
  historyLoad = (async () => {
    let { rows, status } = await fetchHistory(S().historyBlock);
    let s = S();
    if (
      s.dep &&
      status &&
      status.key !== `${s.dep.chainId}:${s.dep.hook.toLowerCase()}`
    ) {
      return; // the server points at another deployment
    }
    if (status && s.historyGen !== null && s.historyGen !== status.generation) {
      // the server re-derived its rows: drop the cached copy and load everything again
      set({ history: [], historyBlock: -1 });
      ({ rows, status } = await fetchHistory(-1));
      s = S();
    }
    if (status) {
      set({ historyGen: status.generation });
    }
    if (
      status &&
      status.startBlock - 1 > s.historyBlock &&
      s.history.length === 0
    ) {
      set({ historyBlock: status.startBlock - 1 });
    }
    if (rows.length) {
      const seen = new Set(s.history.map((r) => `${r.block}:${r.index}`));
      const fresh = rows.filter((r) => !seen.has(`${r.block}:${r.index}`));
      set({
        history: [...s.history, ...fresh],
        historyBlock: Math.max(s.historyBlock, rows[rows.length - 1].block),
      });
      if (fresh.length) {
        void scheduleRefresh();
      }
    }
    // "syncing" while the index is still catching up with the chain
    set({
      historyStatus: status,
      historyLoading:
        !!status &&
        (status.syncing || status.syncedBlock < (S().chainBlock || 0) - 5),
    });
    saveHistoryCache();
  })()
    .catch((e) => {
      set({ historyLoading: false });
      if (S().history.length === 0) {
        toast(`History sync failed: ${decodeError(e)}`, "err");
      }
    })
    .finally(() => {
      historyLoad = null;
    });
  return historyLoad;
}
type State = import("./store").State;

// ---------------------------------------------------------------------------------------------------------------------
// transactions
// ---------------------------------------------------------------------------------------------------------------------
type TxResponse = ethers.ContractTransactionResponse;

let txQueue: Promise<unknown> = Promise.resolve();

function enqueueTx<T>(fn: () => Promise<T>): Promise<T> {
  const next = txQueue.then(fn, fn);
  txQueue = next.then(
    () => undefined,
    () => undefined,
  );
  return next;
}

async function pendingNonce(
  runner: ethers.ContractRunner,
): Promise<number | undefined> {
  const provider =
    "provider" in runner ? runner.provider : null;
  if (!("getAddress" in runner) || !provider) {
    return undefined;
  }
  const address = await (runner as ethers.Signer).getAddress();
  return provider.getTransactionCount(address, "pending");
}

export async function send(
  label: string,
  fn: () => Promise<TxResponse>,
  opts: { refresh?: boolean } = {},
) {
  return enqueueTx(async () => {
    const dep = S().dep as Deployment;
    const refreshAfter = opts.refresh !== false;
    toast(`${label}…`);
    try {
      const receipt = await (await fn()).wait();
      if (!receipt) {
        throw new Error("no receipt");
      }
      toast(
        `✓ ${label}`,
        "ok",
        dep.explorer ? `${dep.explorer}/tx/${receipt.hash}` : null,
      );
      if (refreshAfter) {
        await scheduleRefresh();
        void loadHistory();
      }
      return receipt;
    } catch (e) {
      const err = e as { receipt?: { status: number }; data?: unknown };
      const mined = err?.receipt && err.receipt.status === 0;
      toast(
        `${label} failed: ${mined && !err.data ? "reverted on-chain (the pool moved after the estimate?)" : decodeError(e)}`,
        "err",
      );
      if (refreshAfter) {
        await scheduleRefresh();
      }
      return null;
    }
  });
}

/** Sends a contract call with 30% gas headroom: a swap that lands after another one may walk more ticks. */
export async function call(
  contract: ethers.Contract,
  method: string,
  args: unknown[],
  overrides: Record<string, unknown> = {},
): Promise<TxResponse> {
  const runner = contract.runner as ethers.ContractRunner | null;
  const nonce = runner ? await pendingNonce(runner) : undefined;
  const base =
    nonce === undefined ? overrides : { ...overrides, nonce };
  const estimate = (await contract[method].estimateGas(
    ...args,
    base,
  )) as bigint;
  return contract[method](...args, {
    ...base,
    gasLimit: (estimate * 13n) / 10n + 20_000n,
  });
}

const auctionDropBufferSec = 120n;

async function auctionDropDuration(
  c: Contracts,
  seriesId: bigint | number,
  dropMin: number,
  provider: ethers.Provider,
): Promise<bigint> {
  const expiry = BigInt(await c.weights.expiryOf(seriesId));
  const block = await provider.getBlock("latest");
  const now = BigInt(block?.timestamp ?? 0);
  if (expiry <= now) {
    return 0n;
  }
  const headroom = expiry - now;
  const requested = BigInt(Math.round(dropMin * 60));
  let drop = requested <= headroom ? requested : headroom;
  if (headroom <= auctionDropBufferSec) {
    drop = headroom > 1n ? headroom - 1n : 0n;
  } else if (drop > auctionDropBufferSec) {
    drop -= auctionDropBufferSec;
  }
  return drop > 0n ? drop : 0n;
}

function txReadProvider(c: Contracts, fallback: ethers.Provider) {
  const runner = c.auction.runner;
  return runner && "provider" in runner && runner.provider
    ? runner.provider
    : fallback;
}

export async function ensureUsdcAllowance(spender: string, amount: bigint) {
  const c = S().c as Contracts;
  if ((await c.usdc.allowance(S().me, spender)) >= amount) {
    return true;
  }
  return !!(await send("Approve USDC", () =>
    call(c.usdc, "approve", [spender, ethers.MaxUint256]),
  ));
}

/** Runs one user action at a time; action buttons are disabled while a transaction is pending. */
export async function exclusive(fn: () => Promise<unknown>) {
  if (S().busy) {
    return;
  }
  if (!S().me) {
    return toast("Connect a wallet first.", "err");
  }
  set({ busy: true });
  try {
    await scheduleRefresh();
    await fn();
  } finally {
    set({ busy: false });
  }
}

const parseLogs = (
  receipt: ethers.ContractTransactionReceipt,
  contract: ethers.Contract,
  name: string,
) =>
  receipt.logs
    .map((l) => {
      try {
        return contract.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((ev) => ev && ev.name === name);

export function faucet() {
  const c = S().c as Contracts;
  return exclusive(() =>
    send("Mint 10,000 test USDC", () =>
      call(c.usdc, "mint", [S().me, 10_000n * 10n ** 6n]),
    ),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// auctions
// ---------------------------------------------------------------------------------------------------------------------
export function auctionAnnounced(
  a: { startBlock: number },
  block = S().chainBlock,
) {
  return block <= a.startBlock;
}

export function auctionPrice(
  a: {
    startBlock: number;
    end: number;
    dropStart: number;
    startPrice: bigint;
    floorPrice: bigint;
  },
  t = now(),
  block = S().chainBlock,
) {
  if (auctionAnnounced(a, block)) {
    return toUsdc(a.startPrice);
  }
  if (t >= a.end) {
    return toUsdc(a.floorPrice);
  }
  const f = (t - a.dropStart) / (a.end - a.dropStart);
  return (
    toUsdc(a.startPrice) - (toUsdc(a.startPrice) - toUsdc(a.floorPrice)) * f
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// add liquidity
// ---------------------------------------------------------------------------------------------------------------------
let addSeq = 0;
let addTimer: ReturnType<typeof setTimeout> | null = null;
export function addChanged() {
  if (addTimer) {
    clearTimeout(addTimer);
  }
  addTimer = setTimeout(() => void updateAddPreview(), 150);
}

export async function updateAddPreview() {
  const seq = ++addSeq;
  const s = S();
  const fail = (msg: string, field: string | null = null) => {
    if (seq !== addSeq) {
      return;
    }
    set({ addMsg: { kind: "bad", html: msg }, addInvalid: field });
  };
  set({ addReady: null, addGhost: null, addMsg: null, addInvalid: null }); // until the inputs describe a valid deposit
  if (!s.pool.initialized) {
    return;
  }
  const P = s.pool.price;
  const spacing = (s.dep as Deployment).tickSpacing;
  const value = parseAmount(s.addValue);
  let lo = parseAmount(s.addLo);
  let hi = parseAmount(s.addHi);
  let tl: number;
  let tu: number;
  if (s.add5050) {
    // keep the bound the user typed; solve the other so the deposit is half ETH, half USDC at today's price
    // (solved from the snapped tick, so snapping only moves the split by the other bound's rounding)
    if (s.lastEdited === "hi") {
      if (!(hi > 0)) {
        return fail("The max price must be above $0.", "addHi");
      }
      if (!(hi > P)) {
        return fail(
          `For a 50/50 split the max price must be above today's $${fmtNum(P, 4)}.`,
          "addHi",
        );
      }
      tu = C.priceToTick(hi, spacing);
      lo = C.lowerFor5050(P, C.tickToPrice(tu));
      tl = C.priceToTick(lo, spacing);
      set({ addLo: fieldValue(lo) });
    } else {
      if (!(lo > 0)) {
        return fail("The min price must be above $0.", "addLo");
      }
      if (!Number.isFinite(C.upperFor5050(P, lo))) {
        return fail(
          `For a 50/50 split the min price must be between $${fmtNum(P / Math.E, 4)} and $${fmtNum(P, 4)}.`,
          "addLo",
        );
      }
      tl = C.priceToTick(lo, spacing);
      hi = C.upperFor5050(P, C.tickToPrice(tl));
      tu = C.priceToTick(hi, spacing);
      set({ addHi: fieldValue(hi) });
    }
  } else {
    if (!(lo > 0)) {
      return fail("The min price must be above $0.", "addLo");
    }
    if (!(hi > 0)) {
      return fail("The max price must be above $0.", "addHi");
    }
    if (!(hi > lo)) {
      return fail("The max price must be above the min price.", "addHi");
    }
    tl = C.priceToTick(lo, spacing);
    tu = C.priceToTick(hi, spacing);
  }
  if (tl >= tu) {
    return fail("The range is narrower than one tick: widen it.", "addHi");
  }
  if (!(value > 0)) {
    return fail("Enter an amount above $0.", "addValue");
  }
  const pa = C.tickToPrice(tl);
  const pb = C.tickToPrice(tu);
  const liquidity = BigInt(Math.floor((value / C.valuePerL(pa, pb, P)) * 1e6));
  if (liquidity <= 0n) {
    return fail("That buys no liquidity on this range.");
  }
  try {
    const [amount0, amount1] = (await (
      s.c as Contracts
    ).hook.getAmountsForLiquidity(s.poolId, tl, tu, liquidity, true)) as [
      bigint,
      bigint,
    ];
    if (seq !== addSeq) {
      return;
    }
    const ethUsd = toEth(amount0) * P;
    const share = ethUsd / (ethUsd + toUsdc(amount1));
    set({
      addReady: { tl, tu, liquidity, amount0, amount1 },
      addGhost: { id: "new", pa, pb, L: Number(liquidity) / 1e6 },
      addMsg: {
        kind: "ok",
        html:
          `<b>${fmtNum(toEth(amount0))} ETH</b> <span class="sub">($${fmtNum(ethUsd, 2)})</span> + <b>${fmtNum(toUsdc(amount1))} USDC</b>` +
          (s.add5050
            ? ""
            : ` <span class="sub">· ${Math.round(share * 100)}% ETH, 50/50 at $${fmtNum(C.fiftyFiftyPrice(pa, pb), 4)}</span>`),
      },
    });
  } catch (e) {
    return fail(decodeError(e));
  }
}

export async function executeAdd() {
  await updateAddPreview();
  const s = S();
  if (!s.addReady) {
    return;
  }
  const c = s.c as Contracts;
  const dep = s.dep as Deployment;
  const { tl, tu, liquidity, amount0, amount1 } = s.addReady;
  const max0 = amount0 + amount0 / 1000n + 1n; // 0.1% headroom if the price moves before inclusion
  const max1 = amount1 + amount1 / 1000n + 1n;
  if (!(await ensureUsdcAllowance(dep.vault, max1))) {
    return;
  }
  const receipt = await send("Add liquidity", () =>
    call(c.vault, "mint", [s.key, tl, tu, liquidity, max0, max1, deadline()], {
      value: max0,
    }),
  );
  const ev = receipt && parseLogs(receipt, c.vault, "PositionMinted");
  if (ev) {
    openSplit(Number(ev.args.positionId));
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// selling the ETH weight (pop-up after adding liquidity, or from a position's pop-over)
// ---------------------------------------------------------------------------------------------------------------------
export function splitShare() {
  return Math.min(Math.max(parseAmount(S().splitShare) / 100, 0.0001), 1);
}

export function openSplit(positionId: number) {
  const pos = S().positions.find((p) => p.id === positionId);
  if (!pos) {
    return;
  }
  set({ splitFor: positionId, splitShare: "100" });
  updateSplit();
}

/** Resets the start and floor prices to the share of the position being sold. */
export function updateSplit() {
  const s = S();
  const pos = s.positions.find((p) => p.id === s.splitFor);
  if (!pos || !s.pool.initialized) {
    return;
  }
  const L = pos.L * splitShare();
  // start at the most the weight can ever pay (its value at pa), fall to what exercising pays today
  set({
    auctionStart: (L * (1 - pos.pa / pos.pb)).toFixed(2),
    auctionFloor: C.ethLegValue({ ...pos, L }, s.pool.price).toFixed(2),
  });
}

export async function doSplit() {
  const s = S();
  const pos = s.positions.find((p) => p.id === s.splitFor);
  if (!pos) {
    return;
  }
  const c = s.c as Contracts;
  const dep = s.dep as Deployment;
  const units =
    (pos.liquidity * BigInt(Math.round(splitShare() * 10000))) / 10000n;
  const minutes = parseAmount(s.splitMinutes);
  const dropMin = parseAmount(s.auctionDrop);
  const startPrice = parseAmount(s.auctionStart);
  const floorPrice = parseAmount(s.auctionFloor);
  if (!(parseAmount(s.splitShare) > 0)) {
    return toast("Choose a share of the position above 0%.", "err");
  }
  if (!(minutes > 0) || !(dropMin > 0)) {
    return toast("Expiry and price drop must both be above 0.", "err");
  }
  if (dropMin >= minutes) {
    return toast(
      "The price drop must finish before the weight expires: use a shorter drop or a longer expiry.",
      "err",
    );
  }
  if (!(startPrice > 0) || !(floorPrice >= 0) || floorPrice > startPrice) {
    return toast(
      "The start price must be above 0 and at least the floor price.",
      "err",
    );
  }
  const duration = BigInt(Math.round(minutes * 60));
  set({ splitFor: null });
  const receipt = await send(
    "Split off the ETH weight",
    () => call(c.vault, "split", [pos.id, units, 0, duration]),
    { refresh: false },
  );
  const ev = receipt && parseLogs(receipt, c.vault, "Split");
  if (!ev) {
    return;
  }
  const seriesId = ev.args.seriesId;
  const start = ethers.parseUnits(startPrice.toFixed(6), 6);
  const floor = ethers.parseUnits(floorPrice.toFixed(6), 6);
  if (
    !(await send(
      "Approve the weight",
      () => call(c.weights, "approve", [dep.auction, seriesId, units]),
      { refresh: false },
    ))
  ) {
    return;
  }
  const readProvider = txReadProvider(c, s.provider as ethers.Provider);
  await send("Start auction", async () => {
    const dropSec = await auctionDropDuration(
      c,
      seriesId,
      dropMin,
      readProvider,
    );
    if (dropSec <= 0n) {
      throw new Error(
        "Not enough time left before the weight expires: use a longer expiry or a shorter price drop.",
      );
    }
    return call(c.auction, "create", [
      seriesId,
      units,
      dep.usdc,
      start,
      floor,
      dropSec,
    ]);
  });
}

// ---------------------------------------------------------------------------------------------------------------------
// position actions (from the pop-over) and weight actions (from the ETH weights list)
// ---------------------------------------------------------------------------------------------------------------------
export function withdraw(positionId: number) {
  const pos = S().positions.find((p) => p.id === positionId);
  if (!pos) {
    return;
  }
  const c = S().c as Contracts;
  return exclusive(() =>
    send(`Withdraw position #${pos.id}`, () =>
      call(c.vault, "decreaseLiquidity", [
        pos.id,
        pos.liquidity - pos.locked,
        0,
        0,
        deadline(),
      ]),
    ),
  );
}

export function weightAction(
  act: "exercise" | "merge" | "cancel" | "buy",
  id: number,
) {
  return exclusive(async () => {
    const s = S();
    const c = s.c as Contracts;
    const dep = s.dep as Deployment;
    if (act === "exercise" || act === "merge") {
      const x = s.series.find((y) => y.id === id);
      if (!x) {
        return;
      }
      if (act === "merge") {
        return send("Merge the weight back", () =>
          call(c.vault, "merge", [x.id, x.balance]),
        );
      }
      const leg = x.preview?.leg ?? 0n;
      const minLeg = leg - leg / 200n; // accept 0.5% less if the price moves before inclusion
      return send("Exercise", () =>
        call(c.vault, "exercise", [x.id, x.balance, minLeg, deadline()]),
      );
    }
    const a = s.auctions.find((y) => y.id === id);
    if (!a) {
      return;
    }
    if (act === "cancel") {
      return send("Cancel auction", () => call(c.auction, "cancel", [a.id]));
    }
    // the share comes from state: the refresh that precedes every action re-renders this list
    const share = Math.min(
      Math.max(parseAmount(s.buyPct[a.id] ?? 100), 0.01),
      100,
    );
    const amount = (a.remaining * BigInt(Math.round(share * 100))) / 10000n;
    const cost = (await c.auction.quote(a.id, amount)) as bigint;
    const maxCost = cost + cost / 100n + 1n; // the price only falls, so this is generous
    if (!(await ensureUsdcAllowance(dep.auction, maxCost))) {
      return;
    }
    await send(`Buy ${fmtNum(share, 2)}% of the weight`, () =>
      call(c.auction, "buy", [a.id, amount, maxCost]),
    );
  });
}

// ---------------------------------------------------------------------------------------------------------------------
// swaps: pay / receive fields; receive token toggle; last-edited field is exact in or exact out
// ---------------------------------------------------------------------------------------------------------------------
const settings = { takeClaims: false, settleUsingBurn: false };
type Sim = { amountIn: number; amountOut: number; price: number; fee: number };
type SimResult = { ok: false; reason: string } | ({ ok: true } & Sim);
const simulate = (
  zeroForOne: boolean,
  exactIn: boolean,
  amount: number,
): SimResult => {
  const s = S();
  return C.simulateSwap(
    s.positions,
    s.pool.initialized ? s.pool.price : 0,
    zeroForOne,
    exactIn,
    amount,
  ) as SimResult;
};

export function swapShape() {
  const s = S();
  const recvEth = s.swapReceive === "ETH";
  const payToken = recvEth ? "USDC" : "ETH";
  const receiveToken = recvEth ? "ETH" : "USDC";
  const leadPay = s.swapLead === "pay";
  return {
    zeroForOne: !recvEth,
    exactIn: leadPay,
    inToken: payToken,
    outToken: receiveToken,
    amountToken: leadPay ? payToken : receiveToken,
  };
}
type Shape = ReturnType<typeof swapShape>;

function swapTypedAmount() {
  const s = S();
  return parseAmount(s.swapLead === "pay" ? s.swapPay : s.swapRecv);
}

function fmtSwapField(token: string, n: number) {
  if (!(n > 0)) {
    return "";
  }
  return token === "ETH"
    ? String(+n.toPrecision(8))
    : String(+n.toPrecision(6));
}

function showQuote(
  shape: Shape,
  amountIn: number,
  amountOut: number,
  priceAfter: number,
) {
  const ethAmt = shape.zeroForOne ? amountIn : amountOut;
  const usdcAmt = shape.zeroForOne ? amountOut : amountIn;
  set({
    swapMsg: {
      kind: "sub",
      html: `avg $${fmtNum(usdcAmt / ethAmt, 4)} · price → $${fmtNum(priceAfter, 4)}`,
    },
  });
}

let quoteTimer: ReturnType<typeof setTimeout> | null = null;
export function updateSwapPreview() {
  const s = S();
  const shape = swapShape();
  const amount = swapTypedAmount();
  set({ swapPreview: null });
  if (quoteTimer) {
    clearTimeout(quoteTimer);
  }
  if (!s.pool.initialized || !(amount > 0)) {
    set({ swapMsg: null });
    if (!(amount > 0)) {
      set(s.swapLead === "pay" ? { swapRecv: "" } : { swapPay: "" });
    }
    return;
  }
  const sim = simulate(shape.zeroForOne, shape.exactIn, amount);
  if (!sim.ok) {
    set({ swapMsg: { kind: "bad", html: sim.reason } });
    return;
  }
  set({
    swapPay: fmtSwapField(shape.inToken, sim.amountIn),
    swapRecv: fmtSwapField(shape.outToken, sim.amountOut),
  });
  const key = `${s.swapReceive}|${s.swapLead}|${amount}`;
  set({
    swapPreview: {
      ...sim,
      zeroForOne: shape.zeroForOne,
      exactIn: shape.exactIn,
      amount,
      key,
    } as SwapPreview,
  });
  showQuote(shape, sim.amountIn, sim.amountOut, sim.price);
  quoteTimer = setTimeout(async () => {
    const q = await quoteOnChain(shape, amount, sim);
    if (!q || S().swapPreview?.key !== key) {
      return;
    }
    const [e, u] = [toEth(abs(q.eth)), toUsdc(abs(q.usdc))];
    const amountIn = shape.zeroForOne ? e : u;
    const amountOut = shape.zeroForOne ? u : e;
    set({
      swapPay: fmtSwapField(shape.inToken, amountIn),
      swapRecv: fmtSwapField(shape.outToken, amountOut),
    });
    showQuote(shape, amountIn, amountOut, sim.price);
  }, 250);
}

function swapArgs(shape: Shape, amount: number, sim: Sim) {
  const amountRaw =
    shape.amountToken === "ETH"
      ? ethers.parseEther(amount.toFixed(18))
      : ethers.parseUnits(amount.toFixed(6), 6);
  const params = {
    zeroForOne: shape.zeroForOne,
    amountSpecified: shape.exactIn ? -amountRaw : amountRaw,
    sqrtPriceLimitX96: shape.zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
  };
  let value = 0n;
  if (shape.zeroForOne) {
    value = shape.exactIn
      ? amountRaw
      : ethers.parseEther((sim.amountIn * 1.02 + 1e-9).toFixed(18));
  }
  const maxUsdcIn = shape.zeroForOne
    ? 0n
    : ethers.parseUnits((sim.amountIn * 1.02 + 1).toFixed(6), 6);
  return { params, value, maxUsdcIn };
}

async function quoteOnChain(shape: Shape, amount: number, sim: Sim) {
  const s = S();
  if (!s.me) {
    return null;
  }
  const c = s.c as Contracts;
  const dep = s.dep as Deployment;
  const { params, value, maxUsdcIn } = swapArgs(shape, amount, sim);
  if (
    !shape.zeroForOne &&
    (await c.usdc.allowance(s.me, dep.router)) < maxUsdcIn
  ) {
    return null;
  }
  try {
    const [d0, d1] = splitDelta(
      await c.router.swap.staticCall(s.key, params, settings, "0x", { value }),
    );
    return { eth: d0, usdc: d1 };
  } catch {
    return null;
  }
}

export async function executeSwap() {
  const s = S();
  if (!s.pool.initialized) {
    return;
  }
  const c = s.c as Contracts;
  const dep = s.dep as Deployment;
  const shape = swapShape();
  const amount = swapTypedAmount();
  const sim = simulate(shape.zeroForOne, shape.exactIn, amount);
  if (!sim.ok) {
    return toast(sim.reason, "err");
  }
  const { params, value, maxUsdcIn } = swapArgs(shape, amount, sim);
  if (
    !shape.zeroForOne &&
    !(await ensureUsdcAllowance(dep.router, maxUsdcIn))
  ) {
    return;
  }
  const payAmt = fmtNum(sim.amountIn, shape.inToken === "ETH" ? 6 : 4);
  const recvAmt = fmtNum(sim.amountOut, shape.outToken === "ETH" ? 6 : 4);
  const label = `Pay ${payAmt} ${shape.inToken} for ${recvAmt} ${shape.outToken}`;
  const receipt = await send(label, () =>
    call(c.router, "swap", [s.key, params, settings, "0x"], { value }),
  );
  if (receipt) {
    set({ swapPay: "", swapRecv: "" });
    updateSwapPreview();
  }
}

export function setSwapReceive(token: "ETH" | "USDC") {
  set({ swapReceive: token, swapPay: "", swapRecv: "" });
  updateSwapPreview();
}
