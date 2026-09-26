"use client";
// The page: starts the app once, then lays out the two columns. State comes from lib/store.ts.
import { useEffect } from "react";
import { init, stop } from "@/lib/app";
import type { Deployment } from "@/lib/config";
import { useStore } from "@/lib/store";
import AddLiquidity from "./AddLiquidity";
import DebugToggle from "./DebugToggle";
import Header from "./Header";
import History from "./History";
import LiquidityChart from "./LiquidityChart";
import PositionPop from "./PositionPop";
import ReservesChart from "./ReservesChart";
import SplitModal from "./SplitModal";
import Swap from "./Swap";
import Toast from "./Toast";
import Weights from "./Weights";

export default function App({ dep }: { dep: Deployment | null }) {
  const busy = useStore((s) => s.busy);
  useEffect(() => {
    if (!dep) {
      return;
    }
    void init(dep);
    return stop;
  }, [dep]);
  useEffect(() => {
    document.body.classList.toggle("busy", busy);
  }, [busy]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        useStore.setState({ pop: null, splitFor: null });
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
  if (!dep) {
    return (
      <p className="muted" style={{ padding: 24 }}>
        deployments.json not found: start anvil and run script/DeployLocal.s.sol
        (see README)
      </p>
    );
  }
  return (
    <>
      <Header />
      <main className="cols">
        <section>
          <h2>Add liquidity</h2>
          <AddLiquidity />
          <LiquidityChart />
          <h2>History</h2>
          <History />
        </section>
        <section>
          <h2>Swap</h2>
          <Swap />
          <ReservesChart />
          <Weights />
        </section>
      </main>
      <PositionPop />
      <SplitModal />
      <DebugToggle />
      <Toast />
    </>
  );
}
