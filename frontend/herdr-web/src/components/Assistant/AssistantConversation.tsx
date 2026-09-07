import "./assistant.css";
import "../Pi/pi.css";
import { useEffect, useRef, useState, useSyncExternalStore, type CSSProperties } from "react";
import { X, Sparkles } from "lucide-react";
import { MarkdownText } from "../Pi/MarkdownBlocks";
import { isTerminalRunStatus } from "../../api/agentRuns";
import type { AssistantContextItem } from "../../api/assistant";
import type { AssistantSession } from "./AssistantSession";

export function AssistantConversation({ session, title, style, onClose, additionalContext }: {
  additionalContext?: AssistantContextItem;
  session: AssistantSession; title: string; style?: CSSProperties; onClose: () => void;
}) {
  const state = useSyncExternalStore(session.subscribe, session.snapshot);
  const [handoff, setHandoff] = useState(false);
  const [extra, setExtra] = useState("");
  const input = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    const prior = document.activeElement;
    input.current?.focus();
    return () => { if (prior instanceof HTMLElement && prior.isConnected) prior.focus(); };
  }, []);
  useEffect(() => { void session.prepare(); }, [session]);
  const latest = state.turns[state.turns.length - 1];
  return <section className="hz-inline-ask" style={style} role="dialog" aria-label="Ask Herdr" onKeyDown={(e) => { if (e.key === "Escape") onClose(); }}>
    <header className="hz-inline-ask-header">
      <Sparkles size={14} aria-hidden />
      <div className="hz-inline-ask-heading"><strong>Ask Herdr</strong><span>{title}</span></div>
      <button className="hz-inline-ask-close" onClick={onClose} aria-label="Close question"><X size={14} /></button>
    </header>
    {additionalContext && additionalContext.text !== state.context.items.find((item) => item.id === additionalContext.id)?.text &&
      <div className="hz-inline-ask-selection">This question has earlier context. <button disabled={state.busy || !!state.pending}
        onClick={() => session.addContext(additionalContext)}>Use current selection</button></div>}
    <details className="hz-inline-ask-selection">
      <summary>Context · {state.context.items.length} items</summary>
      {additionalContext && <button disabled={state.busy || !!state.pending} onClick={() => session.addContext(additionalContext)}>Use current selection</button>}
      <div style={{ maxHeight: 180, overflow: "auto" }}>
        {state.context.items.map((item) => <div key={item.id}><strong>{item.label}</strong>
          <button disabled={state.busy || !!state.pending} onClick={() => session.removeContext(item.id)}>Remove</button>
          <pre style={{ whiteSpace: "pre-wrap" }}>{item.text}</pre></div>)}
        {state.turns.length > 0 && <p>Earlier turns retain their original context. Start a new question for a clean conversation.</p>}
      </div>
    </details>
    <div className="hz-inline-ask-scroll">
      <p className="hz-inline-ask-hint">Answers use the supplied context. Actions continue in an agent.</p>
      {state.turns.map((turn) => <div className="hz-inline-ask-turn" key={turn.id}>
        <div className="hz-inline-ask-question">{turn.prompt}</div>
        {turn.response && <div className="hz-inline-ask-answer hz-md"><MarkdownText text={turn.response} /></div>}
        <small>{turn.status}</small>
        {turn.error && <p role="alert">{turn.error}</p>}
      </div>)}
      {state.error && <p className="hz-inline-ask-error" role="alert">{state.error}</p>}
      {state.pending && !state.busy && <button onClick={() => void session.reconcile()}>Reconcile submission</button>}
      {!state.busy && latest && !isTerminalRunStatus(latest.status) && <button onClick={() => void session.observe()}>Reconnect</button>}
    </div>
    <footer className="hz-inline-ask-composer">
      <details><summary>Add context</summary>
        <textarea aria-label="Additional context" rows={2} value={extra} onChange={(e) => setExtra(e.target.value)} />
        <button disabled={state.busy || !!state.pending || !extra} onClick={() => {
          session.addContext({ id: crypto.randomUUID(), kind: "text.v1", label: "Added context", text: extra }); setExtra("");
        }}>Attach text</button>
      </details>
      <textarea ref={input} aria-label="Question" rows={2} value={state.draft} onChange={(e) => session.setDraft(e.target.value)}
        placeholder="Ask about this context…" onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void session.submit(); }
          if (e.key === "Escape") onClose();
        }} />
      {state.busy && <small role="status">Working on the original machine…</small>}
      <div className="hz-inline-ask-actions">
        <button disabled={state.busy || !!state.pending} onClick={() => session.newQuestion()}>New question</button>
        {state.busy ? <button onClick={() => void session.stop()}>Stop</button> :
          <button className="hz-inline-ask-send" disabled={!state.ready || !!state.pending || !state.draft.trim() || latest?.status === "promoted"}
            onClick={() => void session.submit()}>Ask</button>}
      </div>
      {latest?.status === "completed" && !state.busy && <button onClick={() => setHandoff(true)}>Continue in agent…</button>}
      {handoff && latest?.status === "completed" && <div>
        <p>Open an agent on the original machine with this conversation. Enter your action request there.</p>
        <button disabled={state.busy} onClick={() => { setHandoff(false); void session.promote(); }}>Open agent with context</button>
        <button onClick={() => setHandoff(false)}>Cancel</button>
      </div>}
      {latest?.status === "promoted" && <p>Conversation handed off. Open the new Agent chat in this workspace to continue.</p>}
    </footer>
  </section>;
}
