// Front-end for the ETH/USDC pool on the log curve  (x + L/pb) e^(y/L + ln pa) = L.
// Left: add liquidity (with a 50/50 solver), the liquidity chart (click a band for that position's actions), history.
// Right: swap, the curve in reserve space, ETH weights (each with a payoff diagram on demand).
import { ABI, decodeError, ethers, splitDelta } from "./chain.js";
import {
  drawLiquidity,
  drawReserves,
  drawWeightPayoff,
  fmtNum,
} from "./charts.js";
import * as C from "./curve.js";

const LOCAL_RPC = "http://127.0.0.1:8545";
const LOCAL_CHAIN_ID = 31337;
const MIN_PRICE_LIMIT = 4295128740n; // TickMath.MIN_SQRT_PRICE + 1
const MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n; // TickMath.MAX_SQRT_PRICE - 1
const NAMES = [
  "Alice",
  "Bob",
  "Carol",
  "Dave",
  "Erin",
  "Frank",
  "Grace",
  "Heidi",
  "Ivan",
  "Judy",
];
const $ = (id) => document.getElementById(id);

const S = {
  dep: null,
  local: true, // anvil with unlocked accounts; otherwise a public chain and a browser wallet
  provider: null, // reads (and, locally, the unlocked accounts)
  signers: [],
  me: null,
  c: {},
  key: null,
  poolId: null,
  pool: { initialized: false },
  positions: [],
  series: [],
  auctions: [],
  history: [], // every operation on the pool, oldest first, rebuilt from the contracts' events
  historyFrom: 0, // next block to read events from
  historyAll: false, // show every row instead of the latest ones
  hctx: { price: null, ranges: {}, seriesPos: {}, auctions: {} }, // what the event stream has told us so far
  txFrom: new Map(), // tx hash -> sender
  eth: 0n,
  usdc: 0n,
  chainTime: 0,
  chainTimeAt: 0,
  chainBlock: 0,
  busy: false,
  swapReceive: "ETH",
  swapLead: "receive",
  swapPreview: null,
  swapFieldSync: false,
  add: null,
  addGhost: null,
  addActive: false,
  lastEdited: "hi", // which price bound the 50/50 solver keeps
  hits: [],
  hoverId: undefined,
  pop: null, // { id, x, y }
  splitFor: null,
  buyPct: {}, // auction id -> typed share, kept across re-renders
  payoffs: [], // payoff diagrams in the ETH weights list
  openPayoff: new Set(), // rows whose payoff diagram is shown ("a<auction id>" / "s<series id>")
};

// ---------------------------------------------------------------------------------------------------------------------
// formatting
// ---------------------------------------------------------------------------------------------------------------------
const toEth = (wei) => Number(ethers.formatEther(wei));
const toUsdc = (units) => Number(ethers.formatUnits(units, 6));
const fEth = (wei, d = 4) => fmtNum(toEth(wei), d);
const fUsdc = (units, d = 4) => fmtNum(toUsdc(units), d);
const abs = (v) => (v < 0n ? -v : v);
const short = (addr) => addr.slice(0, 6) + "…" + addr.slice(-4);
const nameOf = (addr) => {
  const i = S.signers.findIndex(
    (s) => s.address.toLowerCase() === addr.toLowerCase(),
  );
  if (i >= 0) return NAMES[i] || `account ${i}`;
  return S.me && addr.toLowerCase() === S.me.toLowerCase()
    ? "You"
    : short(addr);
};
const isMe = (addr) =>
  addr && S.me && addr.toLowerCase() === S.me.toLowerCase();
const now = () =>
  S.local
    ? S.chainTime
    : S.chainTime + Math.floor((Date.now() - S.chainTimeAt) / 1000);
const chainBlock = () => S.chainBlock;
const salt = (id) => ethers.toBeHex(id, 32);
const deadline = () => BigInt(now() + 3600);
function fmtDuration(sec) {
  if (sec <= 0) {
    return "0m";
  }
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}

let toastTimer = null;
function toast(msg, kind = "", link = null) {
  const el = $("toast");
  el.textContent = msg;
  if (link) {
    const a = document.createElement("a");
    a.href = link;
    a.target = "_blank";
    a.rel = "noopener";
    a.textContent = "view";
    el.append(" ", a);
  }
  el.className = "toast" + (kind === "err" ? " err" : "");
  clearTimeout(toastTimer);
  if (kind)
    toastTimer = setTimeout(
      () => el.classList.add("hidden"),
      kind === "err" ? 9000 : 3000,
    );
}

// ---------------------------------------------------------------------------------------------------------------------
// chain plumbing
// ---------------------------------------------------------------------------------------------------------------------
async function init() {
  try {
    S.dep = await (
      await fetch("./deployments.json", { cache: "no-store" })
    ).json();
  } catch {
    return toast(
      "deployments.json not found: start anvil and run script/DeployLocal.s.sol (see README)",
      "err",
    );
  }
  S.local = Number(S.dep.chainId) === LOCAL_CHAIN_ID;
  const rpc = S.dep.rpc || LOCAL_RPC;
  S.provider = new ethers.JsonRpcProvider(rpc, Number(S.dep.chainId), {
    staticNetwork: true,
    pollingInterval: S.local ? 1000 : 4000,
  });
  try {
    await S.provider.getBlockNumber();
    if (S.local) S.signers = (await S.provider.listAccounts()).slice(0, 10);
  } catch {
    return toast(
      S.local
        ? `Cannot reach the chain at ${rpc}: is anvil running?`
        : `Cannot reach ${rpc}.`,
      "err",
    );
  }
  $("account").classList.toggle("hidden", !S.local);
  $("connect").classList.toggle("hidden", S.local);
  $("faucet").classList.toggle("hidden", S.local || !S.dep.usdcMintable);
  $("network").textContent = S.local ? "" : S.dep.chainName || "";
  $("account").innerHTML = S.signers
    .map((s, i) => `<option value="${i}">${NAMES[i]}</option>`)
    .join("");
  S.key = {
    currency0: ethers.ZeroAddress,
    currency1: S.dep.usdc,
    fee: S.dep.fee,
    tickSpacing: S.dep.tickSpacing,
    hooks: S.dep.hook,
  };
  S.poolId = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint24", "int24", "address"],
      [
        S.key.currency0,
        S.key.currency1,
        S.key.fee,
        S.key.tickSpacing,
        S.key.hooks,
      ],
    ),
  );
  if (S.local) setAccount(0);
  else bind(S.provider, null); // read-only until a wallet connects
  wire();
  await refresh();
  S.provider.on("block", () => scheduleRefresh());
  setInterval(
    () =>
      syncChainClock()
        .then(renderTimers)
        .catch(() => {}),
    1000,
  );
}

function setAccount(i) {
  bind(S.signers[i], S.signers[i].address);
}

/** Contracts that sign with `runner` (or only read, when `address` is null) */
function bind(runner, address) {
  S.me = address;
  const make = (name) => new ethers.Contract(S.dep[name], ABI[name], runner);
  S.c = {
    hook: make("hook"),
    router: make("router"),
    usdc: make("usdc"),
    vault: make("vault"),
    weights: make("weights"),
    auction: make("auction"),
  };
}

/** Connects a browser wallet (MetaMask, Rabby, ...) on the deployment's chain, adding the chain if the wallet lacks it. */
async function connectWallet() {
  if (!window.ethereum)
    return toast("No browser wallet found: install MetaMask or Rabby.", "err");
  const chainId = "0x" + Number(S.dep.chainId).toString(16);
  try {
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId }],
      });
    } catch (e) {
      if (e?.code !== 4902) throw e; // 4902: the wallet does not know the chain yet
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId,
            chainName: S.dep.chainName,
            rpcUrls: [S.dep.rpc],
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            blockExplorerUrls: S.dep.explorer ? [S.dep.explorer] : [],
          },
        ],
      });
    }
    const signer = await new ethers.BrowserProvider(
      window.ethereum,
    ).getSigner();
    bind(signer, await signer.getAddress());
    $("connect").textContent = short(S.me);
    await scheduleRefresh();
  } catch (e) {
    toast("Could not connect the wallet: " + decodeError(e), "err");
  }
}

let refreshing = null;
let refreshAgain = false;
function scheduleRefresh() {
  if (refreshing) {
    refreshAgain = true;
    return refreshing;
  }
  refreshing = refresh()
    .catch((e) => toast("Refresh failed: " + decodeError(e), "err"))
    .finally(() => {
      refreshing = null;
      if (refreshAgain) {
        refreshAgain = false;
        scheduleRefresh();
      }
    });
  return refreshing;
}

async function syncChainClock() {
  const block = await S.provider.getBlock("latest");
  S.chainTime = block.timestamp;
  S.chainBlock = block.number;
  S.chainTimeAt = Date.now();
  if (S.local) {
    try {
      const pending = await S.provider.send("eth_getBlockByNumber", [
        "pending",
        false,
      ]);
      const pt = parseInt(pending.timestamp, 16);
      const pn = parseInt(pending.number, 16);
      if (Number.isFinite(pt)) S.chainTime = Math.max(S.chainTime, pt);
      if (Number.isFinite(pn)) S.chainBlock = Math.max(S.chainBlock, pn);
    } catch {}
  }
}

async function refresh() {
  const { hook, vault, weights, auction, usdc } = S.c;
  await syncChainClock();
  const block = await S.provider.getBlock("latest");
  [S.eth, S.usdc] = S.me
    ? await Promise.all([S.provider.getBalance(S.me), usdc.balanceOf(S.me)])
    : [0n, 0n];

  const [curve] = await hook.poolConfig(S.poolId);
  S.pool = { initialized: curve !== ethers.ZeroAddress };
  if (S.pool.initialized) {
    const slot0 = await hook.getSlot0(S.poolId);
    S.pool = {
      initialized: true,
      tick: Number(slot0.tick),
      price: C.sqrtPriceToPrice(slot0.sqrtPriceX96),
    };
    if (!$("add-hi").value && !$("add-lo").value)
      $("add-hi").value = String(+(2 * S.pool.price).toPrecision(4));
  }

  // positions are held by the vault (salt = position id)
  const [n, ns, na] = (
    await Promise.all([
      vault.nextPositionId(),
      vault.nextSeriesId(),
      auction.nextAuctionId(),
    ])
  ).map(Number);
  const ids = (count) =>
    Array.from({ length: Math.max(0, count - 1) }, (_, i) => i + 1);
  const loaded = await Promise.all(
    ids(n).map(async (id) => {
      const p = await vault.getPosition(id);
      if (p.liquidity === 0n) return null;
      const a = await hook.getPositionAmounts(
        S.poolId,
        S.dep.vault,
        p.tickLower,
        p.tickUpper,
        salt(id),
      );
      return {
        id,
        owner: p.owner,
        pa: C.tickToPrice(Number(p.tickLower)),
        pb: C.tickToPrice(Number(p.tickUpper)),
        liquidity: p.liquidity,
        L: Number(p.liquidity) / 1e6,
        locked: p.locked,
        activeSeries: Number(p.activeSeries),
        eth: a.amount0,
        usdc: a.amount1,
        fees0: a.fees0,
        fees1: a.fees1,
      };
    }),
  );
  S.positions = loaded.filter(Boolean);

  S.series = await Promise.all(
    ids(ns).map(async (id) => {
      const [s, balance] = await Promise.all([
        vault.series(id),
        S.me ? weights.balanceOf(S.me, id) : 0n,
      ]);
      const entry = {
        id,
        positionId: Number(s.positionId),
        expiry: Number(s.expiry),
        balance,
      };
      if (balance > 0n) {
        const pv = await vault.previewExercise(id, balance);
        entry.preview = {
          leg: pv.legAmount,
          allowed: pv.allowed,
          tick: Number(pv.tick),
          ema: Number(pv.emaTick),
        };
      }
      return entry;
    }),
  );

  S.auctions = await Promise.all(
    ids(na).map(async (id) => {
      const a = await auction.auctions(id);
      return {
        id,
        seller: a.seller,
        startBlock: Number(a.startBlock),
        start: Number(a.start),
        dropStart: Number(a.dropStart),
        end: Number(a.end),
        seriesId: Number(a.seriesId),
        lot: a.lot,
        remaining: a.remaining,
        startPrice: a.startPrice,
        floorPrice: a.floorPrice,
      };
    }),
  );

  await loadHistory(block.number);

  render();
  await updateAddPreview();
  updateSwapPreview();
}

async function send(label, fn) {
  toast(`${label}…`);
  try {
    const receipt = await (await fn()).wait();
    toast(
      `✓ ${label}`,
      "ok",
      S.dep.explorer ? `${S.dep.explorer}/tx/${receipt.hash}` : null,
    );
    await scheduleRefresh();
    return receipt;
  } catch (e) {
    const mined = e?.receipt && e.receipt.status === 0;
    toast(
      `${label} failed: ${mined && !e.data ? "reverted on-chain (the pool moved after the estimate?)" : decodeError(e)}`,
      "err",
    );
    await scheduleRefresh();
    return null;
  }
}

/** Sends a contract call with 30% gas headroom: a swap that lands after another one may walk more ticks. */
async function call(contract, method, args, overrides = {}) {
  const estimate = await contract[method].estimateGas(...args, overrides);
  return contract[method](...args, {
    ...overrides,
    gasLimit: (estimate * 13n) / 10n + 20_000n,
  });
}

async function ensureUsdcAllowance(spender, amount) {
  if ((await S.c.usdc.allowance(S.me, spender)) >= amount) return true;
  return !!(await send("Approve USDC", () =>
    call(S.c.usdc, "approve", [spender, ethers.MaxUint256]),
  ));
}

/** Runs one user action at a time; action buttons are disabled while a transaction is pending. */
async function exclusive(fn) {
  if (S.busy) return;
  if (!S.me) return toast("Connect a wallet first.", "err");
  S.busy = true;
  document.body.classList.add("busy");
  try {
    await scheduleRefresh();
    await fn();
  } finally {
    S.busy = false;
    document.body.classList.remove("busy");
  }
}

const parseLogs = (receipt, contract, name) =>
  receipt.logs
    .map((l) => {
      try {
        return contract.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((ev) => ev && ev.name === name);

// ---------------------------------------------------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------------------------------------------------
function render() {
  const p = S.pool;
  $("balances").textContent = S.me
    ? `${fEth(S.eth, S.local ? 2 : 4)} ETH · ${fUsdc(S.usdc, 2)} USDC`
    : "";
  $("price").textContent = p.initialized ? `$${fmtNum(p.price, 4)}` : "";
  $("add-form").classList.toggle("hidden", !p.initialized);
  $("swap-button").disabled = !p.initialized;
  renderWeights();
  renderHistory();
  renderPop();
  drawCharts();
}

function drawCharts() {
  const price = S.pool.initialized ? S.pool.price : null;
  const preview = S.swapPreview && S.swapPreview.ok ? S.swapPreview : null;
  drawReserves($("res-chart"), { positions: S.positions, price, preview });
  S.hits = drawLiquidity($("liq-chart"), {
    positions: S.positions,
    price,
    previewPrice: preview ? preview.price : null,
    ghost: S.addActive ? S.addGhost : null,
    hoverId: S.hoverId,
  });
}

function auctionAnnounced(a, block = chainBlock()) {
  return block <= a.startBlock;
}

function auctionPrice(a, t = now(), block = chainBlock()) {
  if (auctionAnnounced(a, block)) return toUsdc(a.startPrice);
  if (t >= a.end) return toUsdc(a.floorPrice);
  const f = (t - a.dropStart) / (a.end - a.dropStart);
  return (
    toUsdc(a.startPrice) - (toUsdc(a.startPrice) - toUsdc(a.floorPrice)) * f
  );
}

function renderWeights() {
  const t = now();
  const seriesOf = (id) => S.series.find((s) => s.id === id);
  const live = S.auctions.filter(
    (a) => a.remaining > 0n && seriesOf(a.seriesId)?.expiry > t,
  );
  const held = S.series.filter((s) => s.balance > 0n && s.expiry > t);
  $("weights-section").classList.toggle("hidden", !live.length && !held.length);
  const rows = [];
  S.payoffs = []; // one payoff diagram per row: { pa, pb, L, auction? }
  const chart = (key, pos, units, auction) => {
    if (!pos || !S.openPayoff.has(key)) return "";
    S.payoffs.push({ pa: pos.pa, pb: pos.pb, L: Number(units) / 1e6, auction });
    return `<canvas class="payoff" data-payoff="${S.payoffs.length - 1}"></canvas>`;
  };
  const toggle = (key) =>
    `<button class="small ghost${S.openPayoff.has(key) ? " on" : ""}" data-act="payoff" data-key="${key}">Payoff diagram</button>`;
  for (const a of live) {
    const s = seriesOf(a.seriesId);
    const pos = S.positions.find((p) => p.id === s.positionId);
    const ethNow = pos
      ? C.reserves({ ...pos, L: Number(a.remaining) / 1e6 }, S.pool.price).x
      : 0;
    const announced = auctionAnnounced(a);
    const act =
      toggle(`a${a.id}`) +
      (isMe(a.seller)
        ? `<button class="small ghost" data-act="cancel" data-auction="${a.id}">Cancel</button>`
        : announced
          ? ""
          : `<input type="number" data-auction="${a.id}" value="${S.buyPct[a.id] ?? 100}" min="1" max="100" aria-label="Share to buy (%)" /> %
           <button class="small" data-act="buy" data-auction="${a.id}">Buy</button>`);
    rows.push(`<div class="witem"><div class="item">
      <div>For sale: position #${s.positionId}${pos ? ` <span class="sub">$${fmtNum(pos.pa, 4)}–$${fmtNum(pos.pb, 4)}</span>` : ""}<br>
        <span class="num">${fmtNum(ethNow, 4)} ETH now · <b data-auction-price="${a.id}"></b></span>
        <span class="sub" data-auction-ends="${a.id}"></span></div>
      <div class="act">${act}</div></div>${chart(`a${a.id}`, pos, a.remaining, a)}</div>`);
  }
  for (const s of held) {
    const pv = s.preview;
    const pos = S.positions.find((p) => p.id === s.positionId);
    const owner = pos && isMe(pos.owner);
    const devPct = (1.0001 ** (pv.tick - pv.ema) - 1) * 100;
    const wait =
      pv.allowed || owner
        ? ""
        : `<br><span class="sub">Price is ${fmtNum(Math.abs(devPct), 1)}% off its 10-min average: exercise opens when it settles.</span>`;
    const act =
      toggle(`s${s.id}`) +
      (owner
        ? `<button class="small ghost" data-act="merge" data-series="${s.id}">Merge back</button>`
        : `<button class="small" data-act="exercise" data-series="${s.id}" ${pv.allowed ? "" : "disabled"}>Exercise</button>`);
    rows.push(`<div class="witem"><div class="item">
      <div>${owner ? "Unsold weight" : "Your weight"}: position #${s.positionId}${pos ? ` <span class="sub">$${fmtNum(pos.pa, 4)}–$${fmtNum(pos.pb, 4)}</span>` : ""}<br>
        <span class="num">${owner ? "" : "you get "}<b>${fEth(pv.leg)} ETH</b> ($${fmtNum(toEth(pv.leg) * S.pool.price, 2)})</span>
        <span class="sub">· expires in <span data-expiry="${s.expiry}"></span></span>${wait}</div>
      <div class="act">${act}</div></div>${chart(`s${s.id}`, pos, s.balance)}</div>`);
  }
  $("weights").innerHTML = rows.join("");
  renderTimers();
}

/** Draws each weight's payoff; an auction's diagram also shows what the lot costs right now. */
function drawPayoffs() {
  document.querySelectorAll("canvas[data-payoff]").forEach((canvas) => {
    const p = S.payoffs[Number(canvas.dataset.payoff)];
    const lines = p.auction
      ? [
          {
            value:
              (auctionPrice(p.auction) * Number(p.auction.remaining)) /
              Number(p.auction.lot),
            label: "auction price",
          },
        ]
      : [];
    drawWeightPayoff(canvas, {
      pa: p.pa,
      pb: p.pb,
      L: p.L,
      price: S.pool.price,
      lines,
    });
  });
}

function renderTimers() {
  const t = now();
  document
    .querySelectorAll("[data-expiry]")
    .forEach(
      (el) => (el.textContent = fmtDuration(Number(el.dataset.expiry) - t)),
    );
  for (const a of S.auctions) {
    const priceEl = document.querySelector(`[data-auction-price="${a.id}"]`);
    if (priceEl) {
      const lotPrice =
        (auctionPrice(a, t) * Number(a.remaining)) / Number(a.lot);
      priceEl.textContent = auctionAnnounced(a)
        ? `listed at $${fmtNum(lotPrice, 2)}`
        : `$${fmtNum(lotPrice, 2)}`;
    }
    const endEl = document.querySelector(`[data-auction-ends="${a.id}"]`);
    const floor = (toUsdc(a.floorPrice) * Number(a.remaining)) / Number(a.lot);
    if (endEl) {
      endEl.textContent = auctionAnnounced(a)
        ? "· announced · drops next block"
        : t < a.end
          ? `· falling for ${fmtDuration(a.end - t)} · floor $${fmtNum(floor, 2)}`
          : `· at floor $${fmtNum(floor, 2)}`;
    }
  }
  drawPayoffs();
}

// ---------------------------------------------------------------------------------------------------------------------
// history: every operation on the pool, read from the hook's, vault's and auction's events (so it survives reloads)
// ---------------------------------------------------------------------------------------------------------------------
const LOG_CHUNK = 10_000; // public RPCs cap the block range of one eth_getLogs
async function loadHistory(latest) {
  const from = Math.max(S.historyFrom, Number(S.dep.startBlock || 0));
  if (latest < from) return;
  const ranges = [];
  for (let b = from; b <= latest; b += LOG_CHUNK)
    ranges.push([b, Math.min(latest, b + LOG_CHUNK - 1)]);
  const logs = [];
  for (let i = 0; i < ranges.length; i += 4) {
    const batch = await Promise.all(
      ranges.slice(i, i + 4).map(([fromBlock, toBlock]) =>
        S.provider.getLogs({
          address: [S.dep.hook, S.dep.vault, S.dep.auction],
          fromBlock,
          toBlock,
        }),
      ),
    );
    logs.push(...batch.flat());
  }
  S.historyFrom = latest + 1;
  const ifaceOf = {
    [S.dep.hook.toLowerCase()]: S.c.hook.interface,
    [S.dep.vault.toLowerCase()]: S.c.vault.interface,
    [S.dep.auction.toLowerCase()]: S.c.auction.interface,
  };
  for (const log of logs) {
    let ev = null;
    try {
      ev = ifaceOf[log.address.toLowerCase()].parseLog(log);
    } catch {}
    const row = ev && historyRow(ev);
    if (row) S.history.push({ ...row, tx: log.transactionHash });
  }
  // who sent each transaction
  const unknown = [
    ...new Set(S.history.map((r) => r.tx).filter((h) => !S.txFrom.has(h))),
  ];
  const txs = await Promise.all(
    unknown.map((h) => S.provider.getTransaction(h)),
  );
  unknown.forEach((h, i) => S.txFrom.set(h, txs[i]?.from));
}

/** One history row per event (null for events that are not operations on this pool). Events arrive in chain order. */
function historyRow(ev) {
  const H = S.hctx;
  const a = ev.args;
  const range = (id) =>
    H.ranges[id]
      ? `$${fmtNum(H.ranges[id].pa, 4)}–$${fmtNum(H.ranges[id].pb, 4)}`
      : "";
  // the ETH behind `units` of a position's liquidity, at the price of the moment
  const ethOf = (id, units) => {
    const r = H.ranges[id];
    return r && H.price
      ? C.reserves({ ...r, L: Number(units) / 1e6 }, H.price).x
      : null;
  };
  switch (ev.name) {
    case "PoolInitialized":
      if (a.id !== S.poolId) return null;
      H.price = C.sqrtPriceToPrice(a.sqrtPriceX96);
      return { what: "Create pool", price: H.price };
    case "Swap": {
      if (a.id !== S.poolId) return null;
      H.price = C.sqrtPriceToPrice(a.sqrtPriceX96);
      const buy = a.amount0 > 0n; // the trader's amounts: + received, - paid
      return {
        what: buy ? "Buy" : "Sell",
        cls: buy ? "buy" : "sell",
        eth: toEth(abs(a.amount0)),
        usdc: toUsdc(abs(a.amount1)),
        price: H.price,
      };
    }
    case "PositionMinted": {
      const id = Number(a.positionId);
      H.ranges[id] = {
        pa: C.tickToPrice(Number(a.tickLower)),
        pb: C.tickToPrice(Number(a.tickUpper)),
      };
      return {
        what: "Add liquidity",
        sub: `#${id} ${range(id)}`,
        eth: toEth(a.amount0),
        usdc: toUsdc(a.amount1),
        price: H.price,
      };
    }
    case "LiquidityDecreased": {
      const [p0, p1] = splitDelta(a.principal);
      const [f0, f1] = splitDelta(a.fees);
      return {
        what: a.liquidity === 0n ? "Collect fees" : "Withdraw",
        sub: `#${a.positionId}`,
        eth: toEth(abs(p0) + abs(f0)),
        usdc: toUsdc(abs(p1) + abs(f1)),
        price: H.price,
      };
    }
    case "Split": {
      const id = Number(a.positionId);
      H.seriesPos[Number(a.seriesId)] = id;
      return {
        what: "Split ETH weight",
        sub: `#${id}`,
        eth: ethOf(id, a.units),
        price: H.price,
      };
    }
    case "AuctionCreated": {
      H.auctions[Number(a.auctionId)] = {
        seriesId: Number(a.seriesId),
        lot: a.lot,
      };
      return {
        what: "Open auction",
        sub: `#${H.seriesPos[Number(a.seriesId)]} · starts at`,
        usdc: toUsdc(a.startPrice),
        price: H.price,
      };
    }
    case "Bought": {
      const auction = H.auctions[Number(a.auctionId)];
      const id = auction && H.seriesPos[auction.seriesId];
      const share = auction
        ? ` · ${fmtNum((Number(a.amount) / Number(auction.lot)) * 100, 1)}%`
        : "";
      return {
        what: "Buy ETH weight",
        sub: `#${id}${share}`,
        eth: ethOf(id, a.amount),
        usdc: toUsdc(a.cost),
        price: H.price,
      };
    }
    case "Cancelled": {
      const auction = H.auctions[Number(a.auctionId)];
      return {
        what: "Cancel auction",
        sub: auction ? `#${H.seriesPos[auction.seriesId]}` : "",
        price: H.price,
      };
    }
    case "Exercised": // the ETH goes to the weight's holder, the USDC to the position's owner
      return {
        what: "Exercise",
        sub: `#${H.seriesPos[Number(a.seriesId)]}`,
        eth: toEth(a.legAmount),
        usdc: toUsdc(a.otherAmount),
        price: H.price,
      };
    case "Merged":
      return {
        what: "Merge weight",
        sub: `#${H.seriesPos[Number(a.seriesId)]}`,
        price: H.price,
      };
    default:
      return null;
  }
}

const HISTORY_ROWS = 15;
function renderHistory() {
  if (!S.history.length) {
    $("history").innerHTML = `<p class="muted">Nothing yet.</p>`;
    return;
  }
  const shown = S.historyAll ? S.history : S.history.slice(-HISTORY_ROWS);
  const num = (v) => (v === null || v === undefined ? "–" : fmtNum(v, 4));
  const rows = [...shown].reverse().map((r) => {
    const who = S.txFrom.get(r.tx);
    return `<tr>
      <td>${who ? nameOf(who) : ""}</td>
      <td class="what"><span class="${r.cls || ""}">${r.what}</span>${r.sub ? ` <span class="sub">${r.sub}</span>` : ""}</td>
      <td>${num(r.eth)}</td><td>${num(r.usdc)}</td><td>${r.price ? "$" + fmtNum(r.price, 4) : "–"}</td></tr>`;
  });
  const more =
    S.history.length > HISTORY_ROWS
      ? `<button type="button" class="small ghost more" id="history-more">${S.historyAll ? "Show latest" : `Show all ${S.history.length}`}</button>`
      : "";
  $("history").innerHTML =
    `<table><thead><tr><th>Who</th><th>What</th><th>ETH</th><th>USDC</th><th>Price</th></tr></thead>` +
    `<tbody>${rows.join("")}</tbody></table>${more}`;
}

// ---------------------------------------------------------------------------------------------------------------------
// a position's pop-over (click its band in the liquidity chart)
// ---------------------------------------------------------------------------------------------------------------------
function renderPop() {
  const el = $("pos-pop");
  const pos = S.pop && S.positions.find((p) => p.id === S.pop.id);
  if (!pos) {
    S.pop = null;
    el.classList.add("hidden");
    return;
  }
  const value = toEth(pos.eth) * S.pool.price + toUsdc(pos.usdc);
  const series = S.series.find((s) => s.id === pos.activeSeries);
  const locked = pos.locked > 0n && series && series.expiry > now();
  const free = pos.liquidity - pos.locked;
  el.innerHTML = `
    <div class="title">Position #${pos.id} · $${fmtNum(pos.pa, 4)} – $${fmtNum(pos.pb, 4)}</div>
    <div class="num">${fEth(pos.eth)} ETH + ${fUsdc(pos.usdc)} USDC <span class="sub">($${fmtNum(value, 2)})</span></div>
    <div class="sub">${nameOf(pos.owner)} · fees ${fEth(pos.fees0, 5)} ETH + ${fUsdc(pos.fees1, 5)} USDC</div>
    ${locked ? `<div class="sub">${fmtNum((Number(pos.locked) / Number(pos.liquidity)) * 100, 1)}% locked by its ETH weight · unlocks in <span data-expiry="${series.expiry}"></span></div>` : ""}
    ${
      isMe(pos.owner)
        ? `<div class="act">
            <button class="small" data-act="withdraw" ${free === 0n ? "disabled" : ""}>Withdraw${locked && free > 0n ? " unlocked part" : ""}</button>
            <button class="small ghost" data-act="split" ${locked ? "disabled" : ""}>Sell ETH weight</button>
          </div>`
        : ""
    }`;
  el.style.left = `${Math.max(8, Math.min(S.pop.x + 10, document.documentElement.clientWidth - 290))}px`;
  el.style.top = `${S.pop.y + 10}px`;
  el.classList.remove("hidden");
  renderTimers();
}

function closePop() {
  if (!S.pop) return;
  S.pop = null;
  renderPop();
}

// ---------------------------------------------------------------------------------------------------------------------
// add liquidity
// ---------------------------------------------------------------------------------------------------------------------
const setField = (id, v) =>
  ($(id).value = isFinite(v) ? String(+v.toPrecision(6)) : "");

let addSeq = 0;
async function updateAddPreview() {
  const seq = ++addSeq;
  const out = $("add-preview");
  ["add-value", "add-lo", "add-hi"].forEach((id) =>
    $(id).classList.remove("invalid"),
  );
  const fail = (msg, field) => {
    if (seq !== addSeq) return;
    if (field) $(field).classList.add("invalid");
    out.innerHTML = `<span class="bad">${msg}</span>`;
    drawCharts();
  };
  S.add = null;
  S.addGhost = null;
  $("add-button").disabled = true; // until the inputs describe a valid deposit
  if (!S.pool.initialized) return drawCharts();
  const P = S.pool.price;
  const spacing = S.dep.tickSpacing;
  const value = Number($("add-value").value);
  let lo = Number($("add-lo").value);
  let hi = Number($("add-hi").value);
  let tl;
  let tu;
  if ($("add-5050").checked) {
    // keep the bound the user typed; solve the other so the deposit is half ETH, half USDC at today's price
    // (solved from the snapped tick, so snapping only moves the split by the other bound's rounding)
    if (S.lastEdited === "hi") {
      if (!(hi > 0)) return fail("The max price must be above $0.", "add-hi");
      if (!(hi > P))
        return fail(
          `For a 50/50 split the max price must be above today's $${fmtNum(P, 4)}.`,
          "add-hi",
        );
      tu = C.priceToTick(hi, spacing);
      lo = C.lowerFor5050(P, C.tickToPrice(tu));
      tl = C.priceToTick(lo, spacing);
      setField("add-lo", lo);
    } else {
      if (!(lo > 0)) return fail("The min price must be above $0.", "add-lo");
      if (!isFinite(C.upperFor5050(P, lo))) {
        return fail(
          `For a 50/50 split the min price must be between $${fmtNum(P / Math.E, 4)} and $${fmtNum(P, 4)}.`,
          "add-lo",
        );
      }
      tl = C.priceToTick(lo, spacing);
      hi = C.upperFor5050(P, C.tickToPrice(tl));
      tu = C.priceToTick(hi, spacing);
      setField("add-hi", hi);
    }
  } else {
    if (!(lo > 0)) return fail("The min price must be above $0.", "add-lo");
    if (!(hi > 0)) return fail("The max price must be above $0.", "add-hi");
    if (!(hi > lo))
      return fail("The max price must be above the min price.", "add-hi");
    tl = C.priceToTick(lo, spacing);
    tu = C.priceToTick(hi, spacing);
  }
  $("add-hi").min = String(lo); // the spinner never steps the max below the min
  if (tl >= tu)
    return fail("The range is narrower than one tick: widen it.", "add-hi");
  if (!(value > 0)) return fail("Enter an amount above $0.", "add-value");
  const pa = C.tickToPrice(tl);
  const pb = C.tickToPrice(tu);
  const liquidity = BigInt(Math.floor((value / C.valuePerL(pa, pb, P)) * 1e6));
  if (liquidity <= 0n) return fail("That buys no liquidity on this range.");
  try {
    const [amount0, amount1] = await S.c.hook.getAmountsForLiquidity(
      S.poolId,
      tl,
      tu,
      liquidity,
      true,
    );
    if (seq !== addSeq) return;
    S.add = { tl, tu, liquidity, amount0, amount1 };
    S.addGhost = { id: "new", pa, pb, L: Number(liquidity) / 1e6 };
    const ethUsd = toEth(amount0) * P;
    const share = ethUsd / (ethUsd + toUsdc(amount1));
    out.innerHTML =
      `<b>${fEth(amount0)} ETH</b> <span class="sub">($${fmtNum(ethUsd, 2)})</span> + <b>${fUsdc(amount1)} USDC</b>` +
      ($("add-5050").checked
        ? ""
        : ` <span class="sub">· ${Math.round(share * 100)}% ETH, 50/50 at $${fmtNum(C.fiftyFiftyPrice(pa, pb), 4)}</span>`);
    $("add-button").disabled = false;
  } catch (e) {
    return fail(decodeError(e));
  }
  drawCharts();
}

async function executeAdd() {
  await updateAddPreview();
  if (!S.add) return;
  const { tl, tu, liquidity, amount0, amount1 } = S.add;
  const max0 = amount0 + amount0 / 1000n + 1n; // 0.1% headroom if the price moves before inclusion
  const max1 = amount1 + amount1 / 1000n + 1n;
  if (!(await ensureUsdcAllowance(S.dep.vault, max1))) return;
  const receipt = await send("Add liquidity", () =>
    call(
      S.c.vault,
      "mint",
      [S.key, tl, tu, liquidity, max0, max1, deadline()],
      { value: max0 },
    ),
  );
  const ev = receipt && parseLogs(receipt, S.c.vault, "PositionMinted");
  if (ev) openSplit(Number(ev.args.positionId));
}

// ---------------------------------------------------------------------------------------------------------------------
// selling the ETH weight (pop-up after adding liquidity, or from a position's pop-over)
// ---------------------------------------------------------------------------------------------------------------------
function splitShare() {
  return Math.min(Math.max(Number($("split-share").value) / 100, 0.0001), 1);
}

function openSplit(positionId) {
  const pos = S.positions.find((p) => p.id === positionId);
  if (!pos) return;
  S.splitFor = positionId;
  $("split-share").value = 100;
  $("split-intro").innerHTML =
    `Position #${positionId} holds <b>${fEth(pos.eth)} ETH</b> now. The buyer can take this position's ETH at any time ` +
    `until expiry (more ETH if the price falls, none above $${fmtNum(pos.pb, 4)}). You keep the USDC and the fees.`;
  $("split-modal").classList.remove("hidden"); // visible first, so the chart has a size to draw into
  updateSplit(true);
}

function updateSplit(resetPrices) {
  const pos = S.positions.find((p) => p.id === S.splitFor);
  if (!pos) return;
  const L = pos.L * splitShare();
  if (resetPrices) {
    // start at the most the weight can ever pay (its value at pa), fall to what exercising pays today
    $("auction-start").value = (L * (1 - pos.pa / pos.pb)).toFixed(2);
    $("auction-floor").value = C.ethLegValue(
      { ...pos, L },
      S.pool.price,
    ).toFixed(2);
  }
  const lines = [
    { value: Number($("auction-start").value), label: "start" },
    { value: Number($("auction-floor").value), label: "floor" },
  ].filter((l) => l.value >= 0);
  drawWeightPayoff($("payoff-chart"), {
    pa: pos.pa,
    pb: pos.pb,
    L,
    price: S.pool.price,
    lines,
  });
}

async function doSplit() {
  const pos = S.positions.find((p) => p.id === S.splitFor);
  if (!pos) return;
  const units =
    (pos.liquidity * BigInt(Math.round(splitShare() * 10000))) / 10000n;
  const minutes = Number($("split-minutes").value);
  const dropMin = Number($("auction-drop").value);
  const startPrice = Number($("auction-start").value);
  const floorPrice = Number($("auction-floor").value);
  if (!(Number($("split-share").value) > 0))
    return toast("Choose a share of the position above 0%.", "err");
  if (!(minutes > 0) || !(dropMin > 0)) {
    return toast("Expiry and price drop must both be above 0.", "err");
  }
  if (dropMin > minutes) {
    return toast(
      "The price drop must finish before the weight expires.",
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
  $("split-modal").classList.add("hidden");
  const receipt = await send("Split off the ETH weight", () =>
    call(S.c.vault, "split", [pos.id, units, 0, duration]),
  );
  const ev = receipt && parseLogs(receipt, S.c.vault, "Split");
  if (!ev) return;
  const seriesId = ev.args.seriesId;
  const start = ethers.parseUnits(
    Number($("auction-start").value).toFixed(6),
    6,
  );
  const floor = ethers.parseUnits(
    Number($("auction-floor").value).toFixed(6),
    6,
  );
  if (
    !(await send("Approve the weight", () =>
      call(S.c.weights, "approve", [S.dep.auction, seriesId, units]),
    ))
  )
    return;
  await send("Start auction", () =>
    call(S.c.auction, "create", [
      seriesId,
      units,
      S.dep.usdc,
      start,
      floor,
      BigInt(Math.round(dropMin * 60)),
    ]),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// swaps: pay / receive fields; receive token toggle; last-edited field is exact in or exact out
// ---------------------------------------------------------------------------------------------------------------------
const settings = { takeClaims: false, settleUsingBurn: false };

function syncSwapUnits() {
  const recvEth = S.swapReceive === "ETH";
  $("swap-pay-unit").textContent = recvEth ? "USDC" : "ETH";
  $("swap-receive-unit").textContent = recvEth ? "ETH" : "USDC";
}

function swapShape() {
  const recvEth = S.swapReceive === "ETH";
  const payToken = recvEth ? "USDC" : "ETH";
  const receiveToken = recvEth ? "ETH" : "USDC";
  const leadPay = S.swapLead === "pay";
  return {
    zeroForOne: !recvEth,
    exactIn: leadPay,
    inToken: payToken,
    outToken: receiveToken,
    amountToken: leadPay ? payToken : receiveToken,
  };
}

function swapTypedAmount() {
  const el = S.swapLead === "pay" ? $("swap-pay") : $("swap-receive");
  return Number(el.value);
}

function fmtSwapField(token, n) {
  if (!(n > 0)) return "";
  return token === "ETH" ? String(+n.toPrecision(8)) : String(+n.toPrecision(6));
}

function setSwapFields(pay, receive) {
  S.swapFieldSync = true;
  $("swap-pay").value = pay;
  $("swap-receive").value = receive;
  S.swapFieldSync = false;
}

function showQuote(shape, amountIn, amountOut, priceAfter) {
  const ethAmt = shape.zeroForOne ? amountIn : amountOut;
  const usdcAmt = shape.zeroForOne ? amountOut : amountIn;
  $("swap-preview").innerHTML =
    `<span class="sub">avg $${fmtNum(usdcAmt / ethAmt, 4)} · price → $${fmtNum(priceAfter, 4)}</span>`;
}

let quoteTimer = null;
function updateSwapPreview() {
  const shape = swapShape();
  const amount = swapTypedAmount();
  S.swapPreview = null;
  clearTimeout(quoteTimer);
  if (!S.pool.initialized || !(amount > 0)) {
    $("swap-preview").innerHTML = "";
    if (!(amount > 0)) setSwapFields("", "");
    return drawCharts();
  }
  const sim = C.simulateSwap(
    S.positions,
    S.pool.price,
    shape.zeroForOne,
    shape.exactIn,
    amount,
  );
  if (!sim.ok) {
    $("swap-preview").innerHTML = `<span class="bad">${sim.reason}</span>`;
    return drawCharts();
  }
  setSwapFields(
    fmtSwapField(shape.inToken, sim.amountIn),
    fmtSwapField(shape.outToken, sim.amountOut),
  );
  const key = `${S.swapReceive}|${S.swapLead}|${amount}`;
  S.swapPreview = {
    ...sim,
    zeroForOne: shape.zeroForOne,
    exactIn: shape.exactIn,
    amount,
    key,
  };
  showQuote(shape, sim.amountIn, sim.amountOut, sim.price);
  drawCharts();
  quoteTimer = setTimeout(async () => {
    const q = await quoteOnChain(shape, amount, sim);
    if (!q || S.swapPreview?.key !== key) return;
    const [e, u] = [toEth(abs(q.eth)), toUsdc(abs(q.usdc))];
    const amountIn = shape.zeroForOne ? e : u;
    const amountOut = shape.zeroForOne ? u : e;
    setSwapFields(
      fmtSwapField(shape.inToken, amountIn),
      fmtSwapField(shape.outToken, amountOut),
    );
    showQuote(shape, amountIn, amountOut, sim.price);
  }, 250);
}

function swapArgs(shape, amount, sim) {
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
  if (shape.zeroForOne)
    value = shape.exactIn
      ? amountRaw
      : ethers.parseEther((sim.amountIn * 1.02 + 1e-9).toFixed(18));
  const maxUsdcIn = shape.zeroForOne
    ? 0n
    : ethers.parseUnits((sim.amountIn * 1.02 + 1).toFixed(6), 6);
  return { params, value, maxUsdcIn };
}

async function quoteOnChain(shape, amount, sim) {
  if (!S.me) return null;
  const { params, value, maxUsdcIn } = swapArgs(shape, amount, sim);
  if (
    !shape.zeroForOne &&
    (await S.c.usdc.allowance(S.me, S.dep.router)) < maxUsdcIn
  )
    return null;
  try {
    const [d0, d1] = splitDelta(
      await S.c.router.swap.staticCall(S.key, params, settings, "0x", {
        value,
      }),
    );
    return { eth: d0, usdc: d1 };
  } catch {
    return null;
  }
}

async function executeSwap() {
  const shape = swapShape();
  const amount = swapTypedAmount();
  const sim = C.simulateSwap(
    S.positions,
    S.pool.price,
    shape.zeroForOne,
    shape.exactIn,
    amount,
  );
  if (!sim.ok) return toast(sim.reason, "err");
  const { params, value, maxUsdcIn } = swapArgs(shape, amount, sim);
  if (
    !shape.zeroForOne &&
    !(await ensureUsdcAllowance(S.dep.router, maxUsdcIn))
  )
    return;
  const payAmt = fmtNum(sim.amountIn, shape.inToken === "ETH" ? 6 : 4);
  const recvAmt = fmtNum(sim.amountOut, shape.outToken === "ETH" ? 6 : 4);
  const label = `Pay ${payAmt} ${shape.inToken} for ${recvAmt} ${shape.outToken}`;
  const receipt = await send(label, () =>
    call(S.c.router, "swap", [S.key, params, settings, "0x"], { value }),
  );
  if (receipt) {
    setSwapFields("", "");
    updateSwapPreview();
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// events
// ---------------------------------------------------------------------------------------------------------------------
function wire() {
  $("connect").addEventListener("click", connectWallet);
  if (window.ethereum?.on) {
    window.ethereum.on(
      "accountsChanged",
      () => !S.local && S.me && connectWallet(),
    );
    window.ethereum.on("chainChanged", () => !S.local && location.reload());
  }
  $("faucet").addEventListener("click", () =>
    exclusive(() =>
      send("Mint 10,000 test USDC", () =>
        call(S.c.usdc, "mint", [S.me, 10_000n * 10n ** 6n]),
      ),
    ),
  );
  $("account").addEventListener("change", async (e) => {
    setAccount(Number(e.target.value));
    closePop();
    await scheduleRefresh();
  });
  document.querySelectorAll("input[type=number]").forEach((el) => {
    el.min = el.min || "0";
    el.addEventListener("keydown", (e) => {
      if (["-", "+", "e", "E"].includes(e.key)) e.preventDefault();
    });
  });

  // add liquidity
  let addTimer = null;
  const addChanged = () => {
    clearTimeout(addTimer);
    addTimer = setTimeout(updateAddPreview, 150);
  };
  $("add-lo").addEventListener(
    "input",
    () => ((S.lastEdited = "lo"), addChanged()),
  );
  $("add-hi").addEventListener(
    "input",
    () => ((S.lastEdited = "hi"), addChanged()),
  );
  $("add-value").addEventListener("input", addChanged);
  $("add-5050").addEventListener("change", addChanged);
  $("add-form").addEventListener("submit", (e) => {
    e.preventDefault();
    exclusive(executeAdd);
  });
  const addForm = $("add-form");
  const setAddActive = (on) => {
    if (S.addActive !== on) {
      S.addActive = on;
      drawCharts();
    }
  };
  addForm.addEventListener("mouseenter", () => setAddActive(true));
  addForm.addEventListener("mouseleave", () =>
    setAddActive(addForm.contains(document.activeElement)),
  );
  addForm.addEventListener("focusin", () => setAddActive(true));
  addForm.addEventListener("focusout", () =>
    setTimeout(
      () =>
        setAddActive(
          addForm.matches(":hover") || addForm.contains(document.activeElement),
        ),
      0,
    ),
  );

  // liquidity chart: hover highlights a position, click opens its pop-over
  const liq = $("liq-chart");
  const hitAt = (e) =>
    S.hits.find(
      (r) =>
        e.offsetX >= r.x0 &&
        e.offsetX <= r.x1 &&
        e.offsetY >= r.y0 &&
        e.offsetY <= r.y1,
    );
  liq.addEventListener("mousemove", (e) => {
    const id = hitAt(e)?.id;
    if (id !== S.hoverId) {
      S.hoverId = id;
      drawCharts();
    }
  });
  liq.addEventListener("mouseleave", () => {
    if (S.hoverId !== undefined) {
      S.hoverId = undefined;
      drawCharts();
    }
  });
  liq.addEventListener("click", (e) => {
    e.stopPropagation();
    const hit = hitAt(e);
    S.pop = hit ? { id: hit.id, x: e.pageX, y: e.pageY } : null;
    renderPop();
  });
  document.addEventListener("click", (e) => {
    if (!$("pos-pop").contains(e.target)) closePop();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    closePop();
    $("split-modal").classList.add("hidden");
  });
  $("pos-pop").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-act]");
    if (!b || !S.pop) return;
    const pos = S.positions.find((p) => p.id === S.pop.id);
    closePop();
    if (b.dataset.act === "split") return openSplit(pos.id);
    exclusive(() =>
      send(`Withdraw position #${pos.id}`, () =>
        call(S.c.vault, "decreaseLiquidity", [
          pos.id,
          pos.liquidity - pos.locked,
          0,
          0,
          deadline(),
        ]),
      ),
    );
  });

  // selling the ETH weight
  $("split-share").addEventListener("input", () => updateSplit(true));
  $("auction-start").addEventListener("input", () => updateSplit(false));
  $("auction-floor").addEventListener("input", () => updateSplit(false));
  $("split-cancel").addEventListener("click", () =>
    $("split-modal").classList.add("hidden"),
  );
  $("split-auction").addEventListener("click", () => exclusive(doSplit));

  // weights: buy / cancel auctions, exercise / merge weights
  $("weights").addEventListener("input", (e) => {
    if (e.target.dataset.auction)
      S.buyPct[e.target.dataset.auction] = e.target.value;
  });
  $("weights").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-act]");
    if (!b) return;
    if (b.dataset.act === "payoff") {
      const key = b.dataset.key;
      S.openPayoff.has(key) ? S.openPayoff.delete(key) : S.openPayoff.add(key);
      return renderWeights();
    }
    exclusive(() => weightAction(b));
  });
  $("history").addEventListener("click", (e) => {
    if (e.target.id !== "history-more") return;
    S.historyAll = !S.historyAll;
    renderHistory();
  });

  async function weightAction(b) {
    if (b.dataset.act === "exercise" || b.dataset.act === "merge") {
      const s = S.series.find((x) => x.id === Number(b.dataset.series));
      if (b.dataset.act === "merge")
        return send("Merge the weight back", () =>
          call(S.c.vault, "merge", [s.id, s.balance]),
        );
      const minLeg = s.preview.leg - s.preview.leg / 200n; // accept 0.5% less if the price moves before inclusion
      return send("Exercise", () =>
        call(S.c.vault, "exercise", [s.id, s.balance, minLeg, deadline()]),
      );
    }
    const a = S.auctions.find((x) => x.id === Number(b.dataset.auction));
    if (b.dataset.act === "cancel")
      return send("Cancel auction", () => call(S.c.auction, "cancel", [a.id]));
    // the share comes from state: the refresh that precedes every action re-renders this list
    const share = Math.min(Math.max(Number(S.buyPct[a.id] ?? 100), 0.01), 100);
    const amount = (a.remaining * BigInt(Math.round(share * 100))) / 10000n;
    const cost = await S.c.auction.quote(a.id, amount);
    const maxCost = cost + cost / 100n + 1n; // the price only falls, so this is generous
    if (!(await ensureUsdcAllowance(S.dep.auction, maxCost))) return;
    await send(`Buy ${fmtNum(share, 2)}% of the weight`, () =>
      call(S.c.auction, "buy", [a.id, amount, maxCost]),
    );
  }

  syncSwapUnits();
  $("swap-receive-token").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b?.dataset.receive) return;
    $("swap-receive-token")
      .querySelectorAll("button")
      .forEach((x) => x.classList.toggle("on", x === b));
    S.swapReceive = b.dataset.receive;
    syncSwapUnits();
    setSwapFields("", "");
    updateSwapPreview();
  });
  $("swap-pay").addEventListener("input", () => {
    if (S.swapFieldSync) return;
    S.swapLead = "pay";
    updateSwapPreview();
  });
  $("swap-receive").addEventListener("input", () => {
    if (S.swapFieldSync) return;
    S.swapLead = "receive";
    updateSwapPreview();
  });
  $("swap-form").addEventListener("submit", (e) => {
    e.preventDefault();
    exclusive(executeSwap);
  });
  window.addEventListener("resize", () => {
    drawCharts();
    drawPayoffs();
  });
}

window.logCurveApp = { state: S, refresh: scheduleRefresh, curve: C };
init();
