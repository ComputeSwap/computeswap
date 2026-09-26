"use client";
// Selling a position's ETH weight: choose the share, expiry and the auction's prices.
import { doSplit, exclusive, updateSplit } from "@/lib/app";
import { fmtNum } from "@/lib/format";
import { useStore } from "@/lib/store";
import { fEth, parseAmount } from "@/lib/ui";
import DecimalInput from "./DecimalInput";
import PayoffCanvas from "./PayoffCanvas";

export default function SplitModal() {
  const s = useStore();
  const set = useStore.setState;
  const pos = s.positions.find((p) => p.id === s.splitFor);
  if (!pos || !s.pool.initialized) {
    return null;
  }
  const share = Math.min(Math.max(parseAmount(s.splitShare) / 100, 0.0001), 1);
  const L = pos.L * share;
  const lines = [
    { value: parseAmount(s.auctionStart), label: "start" },
    { value: parseAmount(s.auctionFloor), label: "floor" },
  ].filter((l) => l.value >= 0);
  return (
    <div
      className="modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="split-title"
    >
      <div className="modal-card">
        <h2 id="split-title">Sell the ETH weight</h2>
        <p className="muted">
          Position #{pos.id} holds <b>{fEth(pos.eth)} ETH</b> now. The buyer can
          take this position's ETH at any time until expiry (more ETH if the
          price falls, none above ${fmtNum(pos.pb, 4)}). You keep the USDC and
          the fees.
        </p>
        <div className="fields">
          <label>
            Share of position (%)
            <DecimalInput
              value={s.splitShare}
              maxDec={4}
              onValue={(v) => {
                set({ splitShare: v });
                updateSplit();
              }}
            />
          </label>
          <label>
            Expires after (days)
            <DecimalInput
              value={s.splitDays}
              maxDec={4}
              onValue={(v) => set({ splitDays: v })}
            />
          </label>
          <label>
            Price drop (min)
            <DecimalInput
              value={s.auctionDrop}
              maxDec={6}
              onValue={(v) => set({ auctionDrop: v })}
            />
          </label>
        </div>
        <PayoffCanvas
          pa={pos.pa}
          pb={pos.pb}
          L={L}
          price={s.pool.price}
          lines={lines}
          className="chart small"
        />
        <div className="fields two">
          <label>
            Start price ($)
            <DecimalInput
              value={s.auctionStart}
              maxDec={12}
              onValue={(v) => set({ auctionStart: v })}
            />
          </label>
          <label>
            Floor price ($)
            <DecimalInput
              value={s.auctionFloor}
              maxDec={12}
              onValue={(v) => set({ auctionFloor: v })}
            />
          </label>
        </div>
        <p className="muted">
          The lot is listed at the start price for one block (you can cancel,
          but no one can buy yet). Then the price falls smoothly to the floor
          and stays there until expiry.
        </p>
        <div className="actions">
          <button
            type="button"
            className="ghost"
            id="split-cancel"
            onClick={() => set({ splitFor: null })}
          >
            Not now
          </button>
          <button type="button" onClick={() => void exclusive(doSplit)}>
            Start auction
          </button>
        </div>
      </div>
    </div>
  );
}
