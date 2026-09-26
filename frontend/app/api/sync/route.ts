// Advances the indexer by a bounded amount of work. Called by Vercel's cron, by the webhook, or by hand.
import { NextResponse } from "next/server";
import { cronAuthorized } from "@/lib/server/auth";
import { sync } from "@/lib/server/indexer";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function GET(req: Request) {
  if (!cronAuthorized(req)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  try {
    return NextResponse.json(await sync());
  } catch (e) {
    return NextResponse.json(
      { error: String((e as Error)?.message ?? e) },
      { status: 500 },
    );
  }
}

export const POST = GET;
