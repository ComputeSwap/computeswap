// One `query` over either Neon (DATABASE_URL, on Vercel) or an embedded PGlite database (local development).

import type { PGlite } from "@electric-sql/pglite";
import { neon } from "@neondatabase/serverless";

type Row = Record<string, unknown>;
type Query = (text: string, params?: unknown[]) => Promise<Row[]>;

const g = globalThis as unknown as { __logCurveDb?: Promise<Query> };

async function open(): Promise<Query> {
  const url = process.env.DATABASE_URL || process.env.POSTGRES_URL;
  let query: Query;
  if (url) {
    const sql = neon(url);
    query = async (text, params = []) =>
      (await sql.query(text, params)) as Row[];
  } else {
    const { PGlite } = await import("@electric-sql/pglite");
    const dir = process.env.PGLITE_DIR || ".pglite";
    const db: PGlite = await PGlite.create(dir);
    query = async (text, params = []) =>
      (await db.query(text, params)).rows as Row[];
  }
  await migrate(query);
  return query;
}

async function migrate(query: Query) {
  await query(`CREATE TABLE IF NOT EXISTS sync_cursor (
    key text PRIMARY KEY,
    synced_block bigint NOT NULL,
    locked_until timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now()
  )`);
  await query(
    `ALTER TABLE sync_cursor ADD COLUMN IF NOT EXISTS generation integer NOT NULL DEFAULT 1`,
  );
  await query(`CREATE TABLE IF NOT EXISTS events (
    key text NOT NULL,
    block_number bigint NOT NULL,
    log_index integer NOT NULL,
    tx_hash text NOT NULL,
    tx_from text,
    address text NOT NULL,
    name text NOT NULL,
    args jsonb NOT NULL,
    what text,
    cls text,
    sub text,
    eth double precision,
    usdc double precision,
    price double precision,
    PRIMARY KEY (key, block_number, log_index)
  )`);
}

/** Runs one SQL statement and returns its rows. The connection is opened once per process. */
export async function query(
  text: string,
  params: unknown[] = [],
): Promise<Row[]> {
  if (!g.__logCurveDb) {
    g.__logCurveDb = open().catch((e) => {
      g.__logCurveDb = undefined;
      throw e;
    });
  }
  return (await g.__logCurveDb)(text, params);
}

export const asNumber = (v: unknown) => (v == null ? null : Number(v));
