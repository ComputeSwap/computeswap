"use client";
import { useEffect, useState } from "react";

/** A value that changes on every window resize, so canvases redraw at their new size. */
export function useResize() {
  const [n, setN] = useState(0);
  useEffect(() => {
    const on = () => setN((x) => x + 1);
    window.addEventListener("resize", on);
    return () => window.removeEventListener("resize", on);
  }, []);
  return n;
}
