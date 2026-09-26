"use client";
import { useStore } from "@/lib/store";

export default function Toast() {
  const t = useStore((s) => s.toast);
  if (!t) {
    return null;
  }
  return (
    <div className={`toast${t.kind === "err" ? " err" : ""}`} role="status">
      {t.msg}
      {t.link ? (
        <>
          {" "}
          <a href={t.link} target="_blank" rel="noopener">
            view
          </a>
        </>
      ) : null}
    </div>
  );
}
