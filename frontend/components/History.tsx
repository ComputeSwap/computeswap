"use client";
import { nameOf } from "@/lib/app";
import { fmtNum } from "@/lib/format";
import { useStore } from "@/lib/store";

const HISTORY_ROWS = 15;

export default function History() {
  const { history, historyAll, historyLoading, me, signers } = useStore();
  void me;
  void signers; // names depend on the wallet
  if (!history.length) {
    return (
      <p className="muted">
        {historyLoading ? "Loading activity…" : "Nothing yet."}
      </p>
    );
  }
  const shown = historyAll ? history : history.slice(-HISTORY_ROWS);
  const num = (v: number | null | undefined) =>
    v === null || v === undefined ? "–" : fmtNum(v, 4);
  return (
    <div>
      <table>
        <thead>
          <tr>
            <th>Who</th>
            <th>What</th>
            <th>ETH</th>
            <th>USDC</th>
            <th>Price</th>
          </tr>
        </thead>
        <tbody>
          {[...shown].reverse().map((r) => (
            <tr key={`${r.block}:${r.index}`}>
              <td>{r.from ? nameOf(r.from) : ""}</td>
              <td className="what">
                <span className={r.cls || ""}>{r.what}</span>
                {r.sub ? <span className="sub"> {r.sub}</span> : null}
              </td>
              <td>{num(r.eth)}</td>
              <td>{num(r.usdc)}</td>
              <td>{r.price ? `$${fmtNum(r.price, 4)}` : "–"}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {history.length > HISTORY_ROWS ? (
        <button
          type="button"
          className="small ghost more"
          onClick={() => useStore.setState({ historyAll: !historyAll })}
        >
          {historyAll ? "Show latest" : `Show all ${history.length}`}
        </button>
      ) : null}
      {historyLoading ? <p className="muted sub">Syncing activity…</p> : null}
    </div>
  );
}
