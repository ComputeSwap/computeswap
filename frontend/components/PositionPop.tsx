"use client";
// A position's pop-over (click its band in the liquidity chart).
import { useEffect, useRef } from "react";
import { fmtDuration, nameOf, openSplit, withdraw } from "@/lib/app";
import { fmtNum } from "@/lib/format";
import { isMe, now, useStore } from "@/lib/store";
import { fEth, fUsdc, toEth, toUsdc } from "@/lib/ui";

export default function PositionPop() {
  const ref = useRef<HTMLDivElement>(null);
  const { pop, positions, series, pool } = useStore();
  useStore((s) => s.tick);
  const pos = pop && positions.find((p) => p.id === pop.id);
  useEffect(() => {
    // a click outside closes it; the liquidity chart manages the pop-over itself
    const onClick = (e: MouseEvent) => {
      const t = e.target as Element | null;
      if (
        ref.current &&
        !ref.current.contains(t) &&
        !t?.closest?.("[data-pop-anchor]")
      ) {
        useStore.setState({ pop: null });
      }
    };
    document.addEventListener("click", onClick);
    return () => document.removeEventListener("click", onClick);
  }, []);
  if (!pop || !pos || !pool.initialized) {
    return null;
  }
  const value = toEth(pos.eth) * pool.price + toUsdc(pos.usdc);
  const s = series.find((x) => x.id === pos.activeSeries);
  const locked = pos.locked > 0n && !!s && s.expiry > now();
  const free = pos.liquidity - pos.locked;
  const left = Math.max(
    8,
    Math.min(pop.x + 10, document.documentElement.clientWidth - 290),
  );
  return (
    <div ref={ref} className="pop" style={{ left, top: pop.y + 10 }}>
      <div className="title">
        Position #{pos.id} · ${fmtNum(pos.pa, 4)} – ${fmtNum(pos.pb, 4)}
      </div>
      <div className="num">
        {fEth(pos.eth)} ETH + {fUsdc(pos.usdc)} USDC{" "}
        <span className="sub">(${fmtNum(value, 2)})</span>
      </div>
      <div className="sub">
        {nameOf(pos.owner)} · fees {fEth(pos.fees0, 5)} ETH +{" "}
        {fUsdc(pos.fees1, 5)} USDC
      </div>
      {locked && s ? (
        <div className="sub">
          {fmtNum((Number(pos.locked) / Number(pos.liquidity)) * 100, 1)}%
          locked by its ETH weight · unlocks in {fmtDuration(s.expiry - now())}
        </div>
      ) : null}
      {isMe(pos.owner) ? (
        <div className="act">
          <button
            type="button"
            className="small"
            disabled={free === 0n}
            onClick={() => {
              useStore.setState({ pop: null });
              void withdraw(pos.id);
            }}
          >
            Withdraw{locked && free > 0n ? " unlocked part" : ""}
          </button>
          <button
            type="button"
            className="small ghost"
            disabled={locked}
            onClick={() => {
              useStore.setState({ pop: null });
              openSplit(pos.id);
            }}
          >
            Sell ETH weight
          </button>
        </div>
      ) : null}
    </div>
  );
}
