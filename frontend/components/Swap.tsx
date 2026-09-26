"use client";
import {
  exclusive,
  executeSwap,
  setSwapReceive,
  updateSwapPreview,
} from "@/lib/app";
import { useStore } from "@/lib/store";
import DecimalInput from "./DecimalInput";

export default function Swap() {
  const s = useStore();
  const recvEth = s.swapReceive === "ETH";
  const payTok = recvEth ? "USDC" : "ETH";
  const recvTok = recvEth ? "ETH" : "USDC";
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        void exclusive(executeSwap);
      }}
    >
      <div className="swap-head">
        <div className="seg">
          {(["ETH", "USDC"] as const).map((t) => (
            <button
              key={t}
              type="button"
              className={s.swapReceive === t ? "on" : ""}
              onClick={() => setSwapReceive(t)}
            >
              Receive {t}
            </button>
          ))}
        </div>
      </div>
      <div className="swap-fields">
        <label>
          Pay <span className="num">{payTok}</span>
          <DecimalInput
            value={s.swapPay}
            maxDec={18}
            placeholder="0"
            onValue={(v) => {
              useStore.setState({ swapPay: v, swapLead: "pay" });
              updateSwapPreview();
            }}
          />
        </label>
        <label>
          Receive <span className="num">{recvTok}</span>
          <DecimalInput
            value={s.swapRecv}
            maxDec={18}
            placeholder="0"
            onValue={(v) => {
              useStore.setState({ swapRecv: v, swapLead: "receive" });
              updateSwapPreview();
            }}
          />
        </label>
      </div>
      <p className="line">
        {s.swapMsg ? (
          <span
            className={s.swapMsg.kind === "bad" ? "bad" : "sub"}
            dangerouslySetInnerHTML={{ __html: s.swapMsg.html }}
          />
        ) : null}
      </p>
      <button type="submit" disabled={!s.pool.initialized}>
        Pay {payTok}
      </button>
    </form>
  );
}
