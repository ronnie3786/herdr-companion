import { useEffect, useState } from "react";
import { Columns2, Rows3, WrapText } from "lucide-react";
import type { SharedDiffOverflow, SharedDiffStyle } from "./SharedDiffRenderer";

const STYLE_KEY = "herdr.git.diff-style";
const OVERFLOW_KEY = "herdr.git.diff-overflow";

export function useDiffDisplayPreferences() {
  const [diffStyle, setDiffStyle] = useState<SharedDiffStyle>(() => storedPreference(STYLE_KEY, "unified", ["unified", "split"]));
  const [diffOverflow, setDiffOverflow] = useState<SharedDiffOverflow>(() => storedPreference(OVERFLOW_KEY, "scroll", ["scroll", "wrap"]));
  useEffect(() => persistPreference(STYLE_KEY, diffStyle), [diffStyle]);
  useEffect(() => persistPreference(OVERFLOW_KEY, diffOverflow), [diffOverflow]);
  return { diffStyle, setDiffStyle, diffOverflow, setDiffOverflow };
}

export function DiffDisplayControls({ style, overflow, onStyle, onOverflow }: {
  style: SharedDiffStyle; overflow: SharedDiffOverflow;
  onStyle: (style: SharedDiffStyle) => void; onOverflow: (overflow: SharedDiffOverflow) => void;
}) {
  return <div className="hz-diff-controls" aria-label="Diff display options">
    <div className="hz-diff-segment" role="group" aria-label="Diff layout">
      <button type="button" className={style === "unified" ? "hz-diff-control-active" : ""}
        onClick={() => onStyle("unified")} aria-pressed={style === "unified"} title="Unified diff">
        <Rows3 size={13} aria-hidden /><span>Unified</span>
      </button>
      <button type="button" className={style === "split" ? "hz-diff-control-active" : ""}
        onClick={() => onStyle("split")} aria-pressed={style === "split"} title="Split diff">
        <Columns2 size={13} aria-hidden /><span>Split</span>
      </button>
    </div>
    <button type="button" className={`hz-diff-wrap${overflow === "wrap" ? " hz-diff-control-active" : ""}`}
      onClick={() => onOverflow(overflow === "wrap" ? "scroll" : "wrap")} aria-pressed={overflow === "wrap"}
      title={overflow === "wrap" ? "Disable line wrapping" : "Wrap long lines"}>
      <WrapText size={13} aria-hidden /><span>Wrap</span>
    </button>
  </div>;
}

function storedPreference<T extends string>(key: string, fallback: T, allowed: readonly T[]): T {
  if (typeof window === "undefined") return fallback;
  try {
    const value = window.localStorage.getItem(key);
    return value !== null && allowed.includes(value as T) ? value as T : fallback;
  } catch { return fallback; }
}

function persistPreference(key: string, value: string) {
  if (typeof window === "undefined") return;
  try { window.localStorage.setItem(key, value); } catch {
    // Display preferences remain optional when storage is unavailable.
  }
}
