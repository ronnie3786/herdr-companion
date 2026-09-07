import { beforeEach, describe, expect, it, vi } from "vitest";
import { AssistantSession } from "./AssistantSession";
import type { AssistantContext, AssistantRequest, AssistantTransport } from "../../api/assistant";
import type { AgentRun } from "../../api/agentRuns";

const context: AssistantContext = { version: 1, snapshotId: "snapshot", capturedAt: "2026-09-07T00:00:00Z",
  source: { feature: "notes", instanceId: "note" }, items: [{ id: "one", kind: "note.v1", label: "Note", text: "Exact context" }] };
const run = { id: "agr_0123456789ab", status: "completed", prompt: "Question", response: "Answer" } as AgentRun;
function setup(start: AssistantTransport["start"] = async () => run) {
  const transport: AssistantTransport = { capabilities: async () => ({ profiles: ["contextual-question-v1"] }),
    start, fetch: async () => run, stop: vi.fn(async () => ({ ...run, status: "cancelled" as const })), promote: async () => ({ ...run, status: "promoted" as const }) };
  return { session: new AssistantSession("test", "pane", "/example", context, transport), transport };
}
beforeEach(() => {
  const data = new Map();
  vi.stubGlobal("sessionStorage", { getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => data.set(key, value) });
});
describe("contextual conversation ownership", () => {
  it("reconciles an uncertain POST with the exact request ID and frozen context", async () => {
    const requests: AssistantRequest[] = [];
    const { session } = setup(async (request) => {
      requests.push(request);
      if (requests.length === 1) throw new Error("Connection lost after acceptance");
      return run;
    });
    await session.prepare(); session.setDraft("Question"); await session.submit();
    expect(session.state.pending).not.toBeNull();
    session.setDraft("A later draft");
    await session.reconcile();
    expect(requests[1]).toEqual(requests[0]);
    expect(session.state.draft).toBe("A later draft");
    expect(session.state.turns).toHaveLength(1);
  });
  it("view unsubscribe does not cancel execution", async () => {
    const { session, transport } = setup();
    const unsubscribe = session.subscribe(() => {});
    await session.prepare(); session.setDraft("Question");
    unsubscribe(); await session.submit();
    expect(transport.stop).not.toHaveBeenCalled();
    expect(session.state.turns[0].response).toBe("Answer");
  });
  it("Stop while POST is pending cancels after acceptance", async () => {
    let accept!: (run: AgentRun) => void;
    const { session, transport } = setup(() => new Promise((resolve) => { accept = resolve; }));
    await session.prepare(); session.setDraft("Question");
    const task = session.submit(); await session.stop(); accept(run); await task;
    expect(transport.stop).toHaveBeenCalledWith(run.id);
  });
  it("new source context is added explicitly and never changes an in-flight snapshot", async () => {
    const { session } = setup();
    await session.prepare(); session.setDraft("Question"); await session.submit();
    session.addContext({ id: "one", kind: "note.v1", label: "Updated", text: "New context" });
    expect(context.items[0].text).toBe("Exact context");
    expect(session.state.context.items[0].text).toBe("New context");
  });
});
