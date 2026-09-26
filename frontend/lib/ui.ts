// Small helpers shared by the page's components and actions.
import { ethers } from "ethers";
import { fmtNum } from "./format";

export const toEth = (wei: bigint) => Number(ethers.formatEther(wei));
export const toUsdc = (units: bigint) => Number(ethers.formatUnits(units, 6));
export const fEth = (wei: bigint, d = 4) => fmtNum(toEth(wei), d);
export const fUsdc = (units: bigint, d = 4) => fmtNum(toUsdc(units), d);
export const abs = (v: bigint) => (v < 0n ? -v : v);
export const short = (addr: string) => `${addr.slice(0, 6)}…${addr.slice(-4)}`;
export const salt = (id: number) => ethers.toBeHex(id, 32);

export const NAMES = [
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

/** Keeps only digits and one dot, with at most `maxDec` decimals. */
export function filterDecimal(raw: unknown, maxDec?: number | null): string {
  let s = String(raw ?? "").replace(/[^\d.]/g, "");
  const dot = s.indexOf(".");
  if (dot !== -1) {
    s = s.slice(0, dot + 1) + s.slice(dot + 1).replace(/\./g, "");
  }
  if (maxDec != null && dot !== -1) {
    const [a, b] = s.split(".");
    s = `${a}.${b.slice(0, maxDec)}`;
  }
  return s;
}

export function parseAmount(raw: unknown): number {
  const s = String(raw ?? "").trim();
  if (!s || s === ".") {
    return NaN;
  }
  const n = Number(s);
  return Number.isFinite(n) && n >= 0 ? n : NaN;
}

export function fmtDuration(sec: number): string {
  if (sec <= 0) {
    return "0m";
  }
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}

export const fieldValue = (v: number) =>
  Number.isFinite(v) ? String(+v.toPrecision(6)) : "";
