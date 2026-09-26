// Alchemy Notify posts here on new activity at the hook, vault or auction. The payload is only a signal: the indexer
// reads the logs itself, so any webhook type (address activity or custom GraphQL) works.
import { NextResponse } from "next/server";
import { alchemySignatureValid } from "@/lib/server/auth";
import { sync } from "@/lib/server/indexer";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function POST(req: Request) {
  const raw = await req.text();
  if (!alchemySignatureValid(raw, req.headers.get("x-alchemy-signature"))) {
    return NextResponse.json({ error: "bad signature" }, { status: 401 });
  }
  try {
    const r = await sync({ timeBudgetMs: 20_000 });
    return NextResponse.json({
      ok: true,
      syncedBlock: r.syncedBlock,
      skipped: r.skipped ?? null,
    });
  } catch (e) {
    return NextResponse.json(
      { error: String((e as Error)?.message ?? e) },
      { status: 500 },
    );
  }
}
