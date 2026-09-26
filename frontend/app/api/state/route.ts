// The shared pool snapshot. Cached at the edge for a couple of seconds so visitors share one set of contract reads.
import { NextResponse } from "next/server";
import { poolState } from "@/lib/server/state";

export const dynamic = "force-dynamic";
export const maxDuration = 30;

export async function GET() {
  try {
    const s = await poolState();
    return NextResponse.json(s, {
      headers: {
        "cache-control": s.local
          ? "no-store"
          : "public, s-maxage=2, stale-while-revalidate=4",
      },
    });
  } catch (e) {
    return NextResponse.json(
      { error: String((e as Error)?.message ?? e) },
      { status: 502 },
    );
  }
}
