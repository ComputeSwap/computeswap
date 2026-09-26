"use client";
import { addChanged, exclusive, executeAdd } from "@/lib/app";
import { useStore } from "@/lib/store";
import DecimalInput from "./DecimalInput";

export default function AddLiquidity() {
  const s = useStore();
  const set = useStore.setState;
  const setActive = (on: boolean) => {
    if (useStore.getState().addActive !== on) {
      set({ addActive: on });
    }
  };
  if (!s.pool.initialized) {
    return null;
  }
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        void exclusive(executeAdd);
      }}
      onMouseEnter={() => setActive(true)}
      onMouseLeave={(e) =>
        setActive(e.currentTarget.contains(document.activeElement))
      }
      onFocus={() => setActive(true)}
      onBlur={(e) => {
        const form = e.currentTarget;
        setTimeout(
          () =>
            setActive(
              form.matches(":hover") || form.contains(document.activeElement),
            ),
          0,
        );
      }}
    >
      <div className="fields">
        <label>
          Amount ($)
          <DecimalInput
            value={s.addValue}
            maxDec={6}
            className={s.addInvalid === "addValue" ? "invalid" : ""}
            onValue={(v) => {
              set({ addValue: v });
              addChanged();
            }}
          />
        </label>
        <label>
          Min price
          <DecimalInput
            value={s.addLo}
            maxDec={12}
            className={s.addInvalid === "addLo" ? "invalid" : ""}
            onValue={(v) => {
              set({ addLo: v, lastEdited: "lo" });
              addChanged();
            }}
          />
        </label>
        <label>
          Max price
          <DecimalInput
            value={s.addHi}
            maxDec={12}
            className={s.addInvalid === "addHi" ? "invalid" : ""}
            onValue={(v) => {
              set({ addHi: v, lastEdited: "hi" });
              addChanged();
            }}
          />
        </label>
      </div>
      <label className="check">
        <input
          type="checkbox"
          checked={s.add5050}
          onChange={(e) => {
            set({ add5050: e.target.checked });
            addChanged();
          }}
        />{" "}
        50 / 50 split: set one price, the other follows
      </label>
      <p className="line">
        {s.addMsg ? (
          <span
            className={s.addMsg.kind === "bad" ? "bad" : ""}
            dangerouslySetInnerHTML={{ __html: s.addMsg.html }}
          />
        ) : null}
      </p>
      <button type="submit" disabled={!s.addReady}>
        Add liquidity
      </button>
    </form>
  );
}
