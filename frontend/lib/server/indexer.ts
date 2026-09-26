// Indexes the hook's, vault's and auction's events into the database, a bounded amount of work per call.
// A lease on the cursor row keeps concurrent calls (cron, webhook, page) from indexing the same blocks twice.
import { ethers } from "ethers";
import { ABI } from "../chain.js";
import { type ServerConfig, serverConfig } from "./config";
import { asNumber, query } from "./db";
import {
  applyContext,
  emptyContext,
  type HistoryContext,
  historyRow,
} from "./rows";

export type SyncStatus = {
  key: string;
  startBlock: number;
  syncedBlock: number; // every block up to here is in the database
  updatedAt: number | null; // unix ms of the last completed sync step
  syncing: boolean; // a sync call holds the lease right now
  generation: number; // bumps when rows are re-derived, so browsers drop their cached copy
};

export type SyncResult = SyncStatus & {
  latestBlock: number | null;
  blocksIndexed: number;
  eventsIndexed: number;
  skipped?: "locked";
};

const LEASE_SECONDS = 120;
/** jsonb comes back parsed from both drivers, but tolerate a string */
const argsOf = (v: unknown): Record<string, unknown> =>
  typeof v === "string"
    ? (JSON.parse(v) as Record<string, unknown>)
    : (v as Record<string, unknown>);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const json = (v: unknown) =>
  JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x));

function provider(cfg: ServerConfig) {
  return new ethers.JsonRpcProvider(cfg.rpc, Number(cfg.dep.chainId), {
    staticNetwork: true,
    batchMaxCount: 10,
  });
}

async function ensureCursor(cfg: ServerConfig) {
  await query(
    `INSERT INTO sync_cursor (key, synced_block, updated_at) VALUES ($1, $2, to_timestamp(0))
     ON CONFLICT (key) DO NOTHING`,
    [cfg.key, cfg.startBlock - 1],
  );
}

export async function syncStatus(cfg = serverConfig()): Promise<SyncStatus> {
  await ensureCursor(cfg);
  const [row] = await query(
    `SELECT synced_block, updated_at, generation, (locked_until IS NOT NULL AND locked_until > now()) AS syncing
     FROM sync_cursor WHERE key = $1`,
    [cfg.key],
  );
  const updated = row.updated_at
    ? new Date(row.updated_at as string).getTime()
    : 0;
  return {
    key: cfg.key,
    startBlock: cfg.startBlock,
    syncedBlock: Number(row.synced_block),
    updatedAt: updated > 0 ? updated : null,
    syncing: Boolean(row.syncing),
    generation: Number(row.generation ?? 1),
  };
}

/** Rebuilds the row context from what is already indexed (ranges, series, auctions and the last price). */
async function loadContext(cfg: ServerConfig): Promise<HistoryContext> {
  const H = emptyContext();
  const rows = await query(
    `SELECT name, args FROM events WHERE key = $1 AND name IN ('PositionMinted', 'Split', 'AuctionCreated')
     ORDER BY block_number, log_index`,
    [cfg.key],
  );
  for (const r of rows) {
    applyContext(
      H,
      r.name as string,
      r.args as Record<string, unknown>,
      cfg.poolId,
    );
  }
  const [last] = await query(
    `SELECT price FROM events WHERE key = $1 AND price IS NOT NULL ORDER BY block_number DESC, log_index DESC LIMIT 1`,
    [cfg.key],
  );
  H.price = last ? asNumber(last.price) : null;
  return H;
}

/**
 * Indexes new blocks until it catches up or the time budget runs out. Returns without doing anything when another
 * call holds the lease. Safe to call from anywhere, as often as you like.
 */
export async function sync(
  opts: { timeBudgetMs?: number } = {},
): Promise<SyncResult> {
  const cfg = serverConfig();
  const started = Date.now();
  const budget = opts.timeBudgetMs ?? cfg.timeBudgetMs;
  await ensureCursor(cfg);
  const [lease] = await query(
    `UPDATE sync_cursor SET locked_until = now() + ($2 || ' seconds')::interval
     WHERE key = $1 AND (locked_until IS NULL OR locked_until < now()) RETURNING synced_block`,
    [cfg.key, String(LEASE_SECONDS)],
  );
  if (!lease) {
    const status = await syncStatus(cfg);
    return {
      ...status,
      latestBlock: null,
      blocksIndexed: 0,
      eventsIndexed: 0,
      skipped: "locked",
    };
  }
  let synced = Number(lease.synced_block);
  const from0 = synced + 1;
  let events = 0;
  let latest: number | null = null;
  try {
    const rpc = provider(cfg);
    const ifaces: Record<string, ethers.Interface> = {
      [cfg.dep.hook.toLowerCase()]: new ethers.Interface(ABI.hook),
      [cfg.dep.vault.toLowerCase()]: new ethers.Interface(ABI.vault),
      [cfg.dep.auction.toLowerCase()]: new ethers.Interface(ABI.auction),
    };
    const addresses = [cfg.dep.hook, cfg.dep.vault, cfg.dep.auction];
    latest = (await rpc.getBlockNumber()) - cfg.confirmations;
    const H = await loadContext(cfg);
    const senders = new Map<string, string | null>();
    let chunks = 0;
    // at least one chunk per call, then as many as the time budget allows
    while (synced < latest && (chunks === 0 || Date.now() - started < budget)) {
      chunks++;
      const from = synced + 1;
      const to = Math.min(latest, from + cfg.logChunk - 1);
      const logs = await rpc.getLogs({
        address: addresses,
        fromBlock: from,
        toBlock: to,
      });
      logs.sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
      const hashes = [...new Set(logs.map((l) => l.transactionHash))].filter(
        (h) => !senders.has(h),
      );
      for (let i = 0; i < hashes.length; i += 10) {
        const chunk = hashes.slice(i, i + 10);
        const txs = await Promise.all(chunk.map((h) => rpc.getTransaction(h)));
        chunk.forEach((h, j) => senders.set(h, txs[j]?.from ?? null));
      }
      for (const log of logs) {
        let ev: ethers.LogDescription | null = null;
        try {
          ev = ifaces[log.address.toLowerCase()]?.parseLog(log) ?? null;
        } catch {}
        if (!ev) {
          continue;
        }
        const args = JSON.parse(json(ev.args.toObject())) as Record<
          string,
          unknown
        >;
        const row = historyRow(H, ev.name, args, cfg.poolId);
        await query(
          `INSERT INTO events (key, block_number, log_index, tx_hash, tx_from, address, name, args, what, cls, sub, eth, usdc, price)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
           ON CONFLICT (key, block_number, log_index) DO NOTHING`,
          [
            cfg.key,
            log.blockNumber,
            log.index,
            log.transactionHash,
            senders.get(log.transactionHash) ?? null,
            log.address.toLowerCase(),
            ev.name,
            json(args),
            row?.what ?? null,
            row?.cls ?? null,
            row?.sub ?? null,
            row?.eth ?? null,
            row?.usdc ?? null,
            row?.price ?? null,
          ],
        );
        events++;
      }
      synced = to;
      await query(
        `UPDATE sync_cursor SET synced_block = $2, updated_at = now(), locked_until = now() + ($3 || ' seconds')::interval
         WHERE key = $1`,
        [cfg.key, synced, String(LEASE_SECONDS)],
      );
      if (cfg.pauseMs && synced < latest) {
        await sleep(cfg.pauseMs);
      }
    }
    if (synced >= latest) {
      // caught up: mark the moment even when no block was new
      await query(`UPDATE sync_cursor SET updated_at = now() WHERE key = $1`, [
        cfg.key,
      ]);
    }
  } finally {
    await query(`UPDATE sync_cursor SET locked_until = NULL WHERE key = $1`, [
      cfg.key,
    ]);
  }
  const status = await syncStatus(cfg);
  return {
    ...status,
    latestBlock: latest,
    blocksIndexed: Math.max(0, synced - from0 + 1),
    eventsIndexed: events,
  };
}

/**
 * Recomputes every row's display fields from the stored event arguments, replaying the whole history in order.
 * Use it after a change to the row logic, or if rows were derived with incomplete context.
 */
export async function rederive(
  cfg = serverConfig(),
): Promise<{ rows: number }> {
  const rows = await query(
    `SELECT block_number, log_index, name, args FROM events WHERE key = $1 ORDER BY block_number, log_index`,
    [cfg.key],
  );
  const H = emptyContext();
  for (const r of rows) {
    const row = historyRow(H, r.name as string, argsOf(r.args), cfg.poolId);
    await query(
      `UPDATE events SET what = $4, cls = $5, sub = $6, eth = $7, usdc = $8, price = $9
       WHERE key = $1 AND block_number = $2 AND log_index = $3`,
      [
        cfg.key,
        r.block_number,
        r.log_index,
        row?.what ?? null,
        row?.cls ?? null,
        row?.sub ?? null,
        row?.eth ?? null,
        row?.usdc ?? null,
        row?.price ?? null,
      ],
    );
  }
  await query(
    `UPDATE sync_cursor SET generation = generation + 1 WHERE key = $1`,
    [cfg.key],
  );
  return { rows: rows.length };
}

export type HistoryEntry = {
  block: number;
  index: number;
  tx: string;
  from: string | null;
  what: string;
  cls: string | null;
  sub: string | null;
  eth: number | null;
  usdc: number | null;
  price: number | null;
};

/** Activity rows in chain order, from blocks after `after` up to the synced block. */
export async function history(
  after: number,
  limit = 5000,
  cfg = serverConfig(),
): Promise<HistoryEntry[]> {
  const rows = await query(
    `SELECT e.block_number, e.log_index, e.tx_hash, e.tx_from, e.what, e.cls, e.sub, e.eth, e.usdc, e.price
     FROM events e JOIN sync_cursor c ON c.key = e.key
     WHERE e.key = $1 AND e.what IS NOT NULL AND e.block_number > $2 AND e.block_number <= c.synced_block
     ORDER BY e.block_number, e.log_index LIMIT $3`,
    [cfg.key, after, limit],
  );
  return rows.map((r) => ({
    block: Number(r.block_number),
    index: Number(r.log_index),
    tx: r.tx_hash as string,
    from: (r.tx_from as string) ?? null,
    what: r.what as string,
    cls: (r.cls as string) ?? null,
    sub: (r.sub as string) ?? null,
    eth: asNumber(r.eth),
    usdc: asNumber(r.usdc),
    price: asNumber(r.price),
  }));
}
