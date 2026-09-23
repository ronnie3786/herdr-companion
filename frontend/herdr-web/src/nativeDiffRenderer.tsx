import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type { SelectedLineRange } from "@pierre/diffs";
import { SharedDiffRenderer } from "./components/Git/SharedDiffRenderer";
import { selectionAskContext } from "./components/Git/selectionAsk";
import "./nativeDiffRenderer.css";

interface NativeDiffPayload {
  identity: string;
  path: string;
  oldPath: string;
  patch: string;
  plainText: string;
  fontScale: number;
  highlight?: { start: number; end: number; side: "old" | "new" };
}
interface ScrollRequest { line: number; side: "old" | "new"; identity: string }
interface AskTarget {
  context: ReturnType<typeof selectionAskContext>;
  rect: { x: number; y: number; width: number; height: number };
  button: { left: number; top: number };
}

declare global {
  interface Window {
    herdrNativeDiff?: {
      renderJSON(encoded: string): void;
      scrollToLine(request: ScrollRequest): void;
      reportVisibleLines(): void;
    };
  }
}

let updatePayload: ((payload: NativeDiffPayload) => void) | undefined;
let currentPayload: NativeDiffPayload | null = null;
let pendingScroll: ScrollRequest | null = null;

function post(message: unknown) {
  const bridge = (window as unknown as { webkit?: { messageHandlers?: {
    herdrDiffBridge?: { postMessage(message: unknown): void };
  } } }).webkit?.messageHandlers?.herdrDiffBridge;
  bridge?.postMessage(message);
}
function diffHost() { return document.querySelector("diffs-container"); }
function renderedLines() {
  return Array.from(diffHost()?.shadowRoot?.querySelectorAll<HTMLElement>("[data-line]") ?? []);
}
function reportVisibleLines() {
  if (currentPayload === null) return;
  const lines = renderedLines().filter((line) => {
    const rect = line.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < window.innerHeight;
  }).map((line) => ({ side: isDeletion(line) ? "old" : "new", number: Number(line.dataset.line) }))
    .filter((line) => Number.isInteger(line.number) && line.number > 0);
  if (lines.length === 0) return;
  const side = lines[0].side;
  const numbers = lines.filter((line) => line.side === side).map((line) => line.number);
  post({ kind: "visibleLines", identity: currentPayload.identity, path: currentPayload.path,
    side, start: Math.min(...numbers), end: Math.max(...numbers) });
}
function applyPendingScroll() {
  if (pendingScroll === null || pendingScroll.identity !== currentPayload?.identity) return;
  const target = renderedLines().find((line) => lineMatches(line, pendingScroll!));
  if (target === undefined) return;
  pendingScroll = null;
  target.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
  if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    target.animate([{ backgroundColor: "rgba(151,132,255,0.4)" }, { backgroundColor: "transparent" }],
      { duration: 1000, easing: "ease-out" });
  }
  reportVisibleLines();
}

function App() {
  const [payload, setPayload] = useState<NativeDiffPayload | null>(null);
  const [askTarget, setAskTarget] = useState<AskTarget | null>(null);
  const hostRef = useRef<HTMLElement>(null);

  useEffect(() => {
    updatePayload = (next) => {
      if (currentPayload?.identity !== next.identity) pendingScroll = null;
      currentPayload = next;
      setAskTarget(null);
      setPayload(next);
    };
    // The native host may send immediately in response. Never announce before
    // React has installed the receiver, or the first patch can be lost.
    post({ kind: "bridgeReady" });
    return () => { updatePayload = undefined; };
  }, []);

  const selectedLines = useMemo<SelectedLineRange | null>(() => {
    const highlight = payload?.highlight;
    if (highlight == null) return null;
    const side = highlight.side === "old" ? "deletions" : "additions";
    return { start: highlight.start, end: highlight.end, side, endSide: side };
  }, [payload?.highlight]);

  const onRendered = useCallback((node: HTMLElement) => {
    if (payload === null || currentPayload?.identity !== payload.identity) return;
    if (!node.shadowRoot?.querySelector("[data-line]")) return;
    // This callback runs after real renderer output, including async grammar
    // loading, rather than treating an arbitrary timer as completion.
    post({ kind: "ready", identity: payload.identity });
    requestAnimationFrame(() => { applyPendingScroll(); reportVisibleLines(); });
  }, [payload]);

  useEffect(() => {
    let timer: number | undefined;
    const schedule = () => {
      setAskTarget(null);
      window.clearTimeout(timer);
      timer = window.setTimeout(reportVisibleLines, 80);
    };
    window.addEventListener("scroll", schedule, { passive: true, capture: true });
    window.addEventListener("resize", schedule, { passive: true });
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("scroll", schedule, true);
      window.removeEventListener("resize", schedule);
    };
  }, []);

  useEffect(() => {
    function selectionTarget(): AskTarget | null {
      const container = hostRef.current;
      const host = diffHost();
      const selection = window.getSelection();
      if (container === null || host === null || selection === null || selection.rangeCount === 0) return null;
      let range: Range | null = null;
      if (host.shadowRoot !== null && typeof selection.getComposedRanges === "function") {
        const composed = selection.getComposedRanges({ shadowRoots: [host.shadowRoot] })[0];
        if (composed !== undefined) {
          const live = document.createRange();
          try {
            live.setStart(composed.startContainer, composed.startOffset);
            live.setEnd(composed.endContainer, composed.endOffset);
            range = live;
          } catch { /* Use the standard selection fallback. */ }
        }
      }
      range ??= selection.getRangeAt(0);
      if (range.collapsed || range.toString().trim().length === 0 || !rangeTouches(container, range)) return null;
      const context = selectionAskContext(host, range.toString(), range);
      if (context.code === "" || (context.spans?.length ?? 0) === 0) return null;
      const rectangles = Array.from(range.getClientRects()).filter((rect) => rect.width > 0 && rect.height > 0);
      const visible = rectangles.filter((rect) => rect.bottom > 0 && rect.top < window.innerHeight);
      const bounds = visible[visible.length - 1];
      if (bounds === undefined) return null;
      const left = Math.max(8, Math.min(bounds.left + bounds.width / 2 - 46, window.innerWidth - 100));
      const top = bounds.bottom + 38 < window.innerHeight ? bounds.bottom + 8 : Math.max(8, bounds.top - 38);
      return { context, rect: { x: bounds.x, y: bounds.y, width: Math.max(1, bounds.width), height: Math.max(1, bounds.height) },
        button: { left, top } };
    }
    const evaluate = () => setAskTarget(selectionTarget());
    const contextMenu = (event: MouseEvent) => {
      const target = selectionTarget();
      if (target === null || payload === null) return;
      event.preventDefault();
      postAsk(payload, target);
      setAskTarget(null);
    };
    const selectAll = (event: KeyboardEvent) => {
      const shadow = diffHost()?.shadowRoot;
      if (!event.metaKey || event.key.toLowerCase() !== "a" || shadow == null) return;
      event.preventDefault();
      const range = document.createRange();
      range.selectNodeContents(shadow);
      const selection = window.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
      evaluate();
    };
    document.addEventListener("keydown", selectAll);
    document.addEventListener("selectionchange", evaluate);
    document.addEventListener("pointerup", evaluate);
    document.addEventListener("contextmenu", contextMenu);
    return () => {
      document.removeEventListener("keydown", selectAll);
      document.removeEventListener("selectionchange", evaluate);
      document.removeEventListener("pointerup", evaluate);
      document.removeEventListener("contextmenu", contextMenu);
    };
  }, [payload]);

  if (payload === null) return null;
  return (
    <main ref={hostRef} className="native-diff" data-render-identity={payload.identity}>
      <SharedDiffRenderer file={payload.path} patch={payload.patch} fontScale={payload.fontScale}
        selectedLines={selectedLines} disableWorkerPool onRendered={onRendered} />
      {askTarget !== null ? (
        <button className="native-ask" style={askTarget.button} onPointerDown={(event) => event.preventDefault()}
          onClick={() => { postAsk(payload, askTarget); setAskTarget(null); }}>
          <span aria-hidden="true">✦</span> Ask AI
        </button>
      ) : null}
    </main>
  );
}
function postAsk(payload: NativeDiffPayload, target: AskTarget) {
  post({ kind: "ask", identity: payload.identity, path: payload.path, oldPath: payload.oldPath,
    ...target.context, rect: target.rect });
}
function isDeletion(line: HTMLElement) {
  return line.dataset.lineType === "deletion" || line.dataset.lineType === "change-deletion";
}
function lineMatches(line: HTMLElement, request: ScrollRequest) {
  const primary = Number(line.dataset.line);
  const alternate = Number(line.dataset.altLine);
  return request.side === "old"
    ? (isDeletion(line) && primary === request.line) || (!isDeletion(line) && alternate === request.line)
    : !isDeletion(line) && primary === request.line;
}
function rangeTouches(container: HTMLElement, range: Range) {
  const touches = (node: Node) => container.contains(node)
    || (node.getRootNode() instanceof ShadowRoot && container.contains((node.getRootNode() as ShadowRoot).host));
  return touches(range.startContainer) && touches(range.endContainer);
}
window.herdrNativeDiff = {
  renderJSON(encoded) {
    const bytes = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
    updatePayload?.(JSON.parse(new TextDecoder().decode(bytes)) as NativeDiffPayload);
  },
  scrollToLine(request) { pendingScroll = request; applyPendingScroll(); },
  reportVisibleLines,
};
createRoot(document.getElementById("root")!).render(<App />);
