// Number formatting shared by the page and the indexer.
export function fmtNum(v: number, digits = 4): string {
  if (!Number.isFinite(v)) {
    return "–";
  }
  const a = Math.abs(v);
  if (a !== 0 && (a < 1e-3 || a >= 1e7)) {
    return v.toExponential(2);
  }
  return v.toLocaleString("en-US", {
    maximumFractionDigits: a >= 100 ? 2 : digits,
  });
}
