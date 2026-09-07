import { apiRequest, getServerUrl } from "./client";
import type { AgentRun, AgentRunEnvelope } from "./agentRuns";

export interface AssistantContextItem {
  id: string;
  kind: "text-selection.v1" | "text.v1" | "note.v1" | "view.v1";
  label: string;
  text: string;
  priority?: "required" | "optional";
  locator?: { path?: string; section?: string; revision?: string; oldPath?: string; spans?: { side: "old" | "new" | "unknown"; startLine: number; endLine: number }[] };
}
export interface AssistantContext {
  version: 1;
  snapshotId: string;
  capturedAt: string;
  source: { feature: string; instanceId: string };
  items: AssistantContextItem[];
}
export interface AssistantRequest {
  profile: "contextual-question-v1";
  prompt: string;
  mode: "ask";
  clientRequestId: string;
  paneId?: string;
  scope: { expectedRootPath?: string };
  context: AssistantContext;
  continueFromRunId?: string;
  model?: string;
}
export interface AssistantTransport {
  capabilities(): Promise<{ profiles: string[] }>;
  start(request: AssistantRequest): Promise<AgentRun>;
  fetch(id: string): Promise<AgentRun>;
  stop(id: string): Promise<AgentRun>;
  promote(id: string): Promise<AgentRun>;
}
export function assistantTransport(server = getServerUrl()): AssistantTransport {
  const call = <T>(path: string, body?: unknown): Promise<T> => {
    // apiRequest resolves the connection at invocation, before its first await.
    if (getServerUrl() !== server) return Promise.reject(new Error("Reconnect to this question's original machine."));
    return apiRequest<T>(path, body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  };
  return {
    capabilities: () => call("/agent-runs/capabilities"),
    start: async (body) => (await call<AgentRunEnvelope>("/agent-runs", body)).run,
    fetch: async (id) => (await call<AgentRunEnvelope>(`/agent-runs/${encodeURIComponent(id)}`)).run,
    stop: async (id) => (await call<AgentRunEnvelope>(`/agent-runs/${encodeURIComponent(id)}/cancel`, {})).run,
    promote: async (id) => (await call<AgentRunEnvelope>(`/agent-runs/${encodeURIComponent(id)}/promote`, {})).run,
  };
}
