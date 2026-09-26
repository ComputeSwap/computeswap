"use client";
import { useEffect, useRef } from "react";
import { drawReserves } from "@/lib/charts.js";
import { useStore } from "@/lib/store";
import { useResize } from "./useResize";

export default function ReservesChart() {
  const ref = useRef<HTMLCanvasElement>(null);
  const { positions, pool, swapPreview } = useStore();
  const size = useResize();
  const price = pool.initialized ? pool.price : null;
  const preview = swapPreview?.ok ? swapPreview : null;
  useEffect(() => {
    if (ref.current) {
      drawReserves(ref.current, { positions, price, preview });
    }
  }, [positions, price, preview, size]);
  return <canvas ref={ref} className="chart" />;
}
