import { createHmac, timingSafeEqual } from "node:crypto";

/** True when the request may trigger a sync: Vercel's cron header, or ?key=, matching CRON_SECRET (unset = open). */
export function cronAuthorized(req: Request): boolean {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    return true;
  }
  const header = req.headers.get("authorization");
  const key = new URL(req.url).searchParams.get("key");
  return header === `Bearer ${secret}` || key === secret;
}

/** Verifies Alchemy's HMAC-SHA256 signature over the raw body (header x-alchemy-signature). */
export function alchemySignatureValid(
  raw: string,
  signature: string | null,
): boolean {
  const key = process.env.ALCHEMY_WEBHOOK_SIGNING_KEY;
  if (!key || !signature) {
    return false;
  }
  const expected = createHmac("sha256", key).update(raw, "utf8").digest("hex");
  const a = Buffer.from(expected);
  const b = Buffer.from(signature.toLowerCase());
  return a.length === b.length && timingSafeEqual(a, b);
}
