"use client";
import { setDebug } from "@/lib/app";
import { useStore } from "@/lib/store";

export default function DebugToggle() {
  const debug = useStore((s) => s.debug);
  return (
    <button
      type="button"
      className={`debug-toggle small ghost${debug ? " on" : ""}`}
      aria-pressed={debug}
      onClick={() => setDebug(!debug)}
    >
      Debug
    </button>
  );
}
