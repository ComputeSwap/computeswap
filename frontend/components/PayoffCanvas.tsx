"use client";
// The payoff of an ETH weight at each ETH price, with optional horizontal marker lines.
import { useEffect, useRef } from "react";
import { drawWeightPayoff } from "@/lib/charts.js";
import { useResize } from "./useResize";

type Line = { value: number; label: string };

export default function PayoffCanvas({
  pa,
  pb,
  L,
  price,
  lines,
  className = "payoff",
}: {
  pa: number;
  pb: number;
  L: number;
  price: number;
  lines: Line[];
  className?: string;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const size = useResize();
  const key = JSON.stringify(lines);
  useEffect(() => {
    if (ref.current) {
      drawWeightPayoff(ref.current, {
        pa,
        pb,
        L,
        price,
        lines: JSON.parse(key),
      });
    }
  }, [pa, pb, L, price, key, size]);
  return <canvas ref={ref} className={className} />;
}
