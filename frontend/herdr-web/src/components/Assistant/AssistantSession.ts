import { ApiError } from "../../api/client";
import { isTerminalRunStatus, type AgentRun } from "../../api/agentRuns";
import type { AssistantContext, AssistantRequest, AssistantTransport } from "../../api/assistant";

export interface AssistantState {
  draft: string;
  turns: AgentRun[];
  context: AssistantContext;
  pending: AssistantRequest | null;
  busy: boolean;
  ready: boolean;
  error: string | null;
}

/** Feature-independent session. View unmount never stops accepted server work. */
export class AssistantSession {
  private listeners = new Set<() => void>();
  private stopped = false;
  private preparing = false;
  private observing = false;
  state: AssistantState;
  constructor(readonly key: string, readonly paneId: string, readonly rootPath: string | undefined,
              context: AssistantContext, private transport: AssistantTransport) {
    this.state = { draft: "", turns: [], context, pending: null, busy: false, ready: false, error: null };
    try {
      const stored = sessionStorage.getItem(key);
      if (stored) this.state = { ...this.state, ...JSON.parse(stored), busy: false, ready: false, error: null };
    } catch { /* A restricted browser still supports an in-memory conversation. */ }
  }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  snapshot = () => this.state;
  private set(patch: Partial<AssistantState>) {
    this.state = { ...this.state, ...patch };
    try { sessionStorage.setItem(this.key, JSON.stringify(this.state)); } catch { /* In-memory fallback. */ }
    this.listeners.forEach((listener) => listener());
  }
  setDraft = (draft: string) => this.set({ draft });
  get latest() { return this.state.turns[this.state.turns.length - 1]; }
  async prepare() {
    if (this.state.ready || this.preparing) return;
    this.preparing = true;
    try {
      const caps = await this.transport.capabilities();
      if (!caps.profiles.includes("contextual-question-v1")) throw new Error("Update this machine's companion to use contextual questions.");
      this.set({ ready: true });
      if (this.latest && !isTerminalRunStatus(this.latest.status)) void this.observe(this.latest.id);
    } catch (error) { this.set({ error: message(error) }); }
    finally { this.preparing = false; }
  }
  async submit() {
    if (!this.state.ready || this.state.busy || this.state.pending || !this.state.draft.trim() ||
        (this.latest && (!isTerminalRunStatus(this.latest.status) || this.latest.status === "promoted"))) return;
    this.set({ pending: { profile: "contextual-question-v1", mode: "ask", prompt: this.state.draft,
      paneId: this.paneId, scope: { expectedRootPath: this.rootPath }, context: this.state.context,
      clientRequestId: crypto.randomUUID(), continueFromRunId: this.latest?.id } });
    await this.reconcile();
  }
  async reconcile() {
    if (this.state.busy || !this.state.pending) return;
    const request = this.state.pending;
    this.stopped = false;
    this.set({ busy: true, error: null });
    try {
      const run = await this.transport.start(request);
      this.update(run);
      this.set({ pending: null, draft: this.state.draft === request.prompt ? "" : this.state.draft });
      if (this.stopped) this.update(await this.transport.stop(run.id));
      await this.observe(run.id);
    } catch (error) {
      if (error instanceof ApiError && [400, 403, 404, 409, 413, 422].includes(error.status)) this.set({ pending: null, error: message(error) });
      else this.set({ error: message(error) + " Reconcile submission before starting another question." });
    }
    finally { this.set({ busy: false }); }
  }
  private update(run: AgentRun) {
    const exists = this.state.turns.some((turn) => turn.id === run.id);
    this.set({ turns: exists ? this.state.turns.map((turn) => turn.id === run.id ? run : turn) : [...this.state.turns, run] });
  }
  async observe(id = this.latest?.id) {
    if (!id || this.observing) return;
    this.observing = true;
    this.set({ busy: true });
    let failures = 0;
    try {
      for (;;) {
        try {
          const run = await this.transport.fetch(id);
          this.update(run);
          this.set({ error: null });
          failures = 0;
          if (isTerminalRunStatus(run.status)) return;
        } catch (error) {
          this.set({ error: "Reconnecting: " + message(error) });
          if (++failures >= 10) return;
        }
        await new Promise((resolve) => setTimeout(resolve, failures ? 3000 : 900));
      }
    } finally { this.observing = false; this.set({ busy: false }); }
  }
  async stop() {
    this.stopped = true;
    if (this.state.pending || !this.latest) return;
    try { this.update(await this.transport.stop(this.latest.id)); }
    catch (error) { this.set({ error: message(error) }); }
  }
  async promote() {
    if (this.state.busy || this.latest?.status !== "completed") return;
    this.set({ busy: true, error: null });
    try { this.update(await this.transport.promote(this.latest.id)); }
    catch (error) { this.set({ error: message(error) }); }
    finally { this.set({ busy: false }); }
  }
  newQuestion() {
    if (this.state.busy || this.state.pending || (this.latest && !isTerminalRunStatus(this.latest.status))) return;
    this.set({ turns: [], draft: "", error: null });
  }
  addContext(item: AssistantContext["items"][number]) {
    if (this.state.busy || this.state.pending) return;
    this.set({ context: { ...this.state.context, snapshotId: crypto.randomUUID(), capturedAt: new Date().toISOString(),
      items: [...this.state.context.items.filter((old) => old.id !== item.id), item] } });
  }
  removeContext(id: string) {
    if (this.state.busy || this.state.pending) return;
    this.set({ context: { ...this.state.context, snapshotId: crypto.randomUUID(), capturedAt: new Date().toISOString(),
      items: this.state.context.items.filter((item) => item.id !== id) } });
  }
}
function message(error: unknown) { return error instanceof Error ? error.message : "Question unavailable"; }
