// Advances the indexer by a bounded amount of work. Called by Vercel's cron, by the webhook, or by hand.
import { NextResponse } from "next/server";
import { cronAuthorized } from "@/lib/server/auth";
import { rederive, sync } from "@/lib/server/indexer";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function GET(req: Request) {
  if (!cronAuthorized(req)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  try {
    if (new URL(req.url).searchParams.has("rederive")) {
      // ?rederive=1 recomputes every stored row's display fields from the raw events
      const r = await rederive();
      return NextResponse.json({ ...(await sync()), rederived: r.rows });
    }
    return NextResponse.json(await sync());
  } catch (e) {
    return NextResponse.json(
      { error: String((e as Error)?.message ?? e) },
      { status: 500 },
    );
  }
}

export const POST = GET;
