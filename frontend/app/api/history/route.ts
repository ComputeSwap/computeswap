// Activity rows after a block, plus the indexer's position. When nobody has synced for a while, the request also
// kicks one bounded sync step after the response is sent, so a visited page keeps its history fresh without a cron.
import { after, NextResponse } from "next/server";
import { history, sync, syncStatus } from "@/lib/server/indexer";

export const dynamic = "force-dynamic";
export const maxDuration = 30;

const STALE_MS = Number(process.env.HISTORY_STALE_MS || 8000);

export async function GET(req: Request) {
  const url = new URL(req.url);
  const afterBlock = Math.max(
    -1,
    Number(url.searchParams.get("after") ?? -1) || -1,
  );
  try {
    const status = await syncStatus();
    const rows = await history(afterBlock);
    const stale =
      !status.syncing &&
      (status.updatedAt == null || Date.now() - status.updatedAt > STALE_MS);
    if (stale) {
      after(() => sync({ timeBudgetMs: 15_000 }).catch(() => {}));
    }
    return NextResponse.json(
      { rows, status },
      { headers: { "cache-control": "no-store" } },
    );
  } catch (e) {
    return NextResponse.json(
      { error: String((e as Error)?.message ?? e) },
      { status: 500 },
    );
  }
}
