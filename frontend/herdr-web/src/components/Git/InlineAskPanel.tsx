import { useState } from "react";
import { AssistantConversation } from "../Assistant/AssistantConversation";
import { AssistantSession } from "../Assistant/AssistantSession";
import { assistantTransport, type AssistantContext } from "../../api/assistant";
import { getServerUrl } from "../../api/client";
import type { SelectionAskContext } from "./selectionAsk";
import "../Pi/pi.css";

export interface InlineAskAnchor { left: number; top: number }
const sessions = new Map<string, AssistantSession>();
export function gitQuestionKey(paneId: string, file: string, section = "unstaged", rootPath = "") {
  return "herdr.assistant." + JSON.stringify([getServerUrl(), paneId, rootPath, file, section]);
}
export function hasGitQuestion(key: string) {
  if (sessions.has(key)) return true;
  try { return sessionStorage.getItem(key) !== null; } catch { return false; }
}
export function InlineAskPanel({ paneId, file, context, anchor, onClose, section, rootPath, revision }: {
  paneId: string; file: string; context: SelectionAskContext; anchor: InlineAskAnchor;
  onClose: () => void; section?: string; rootPath?: string; revision?: string;
}) {
  const key = gitQuestionKey(paneId, file, section, rootPath);
  const [session] = useState(() => {
    const existing = sessions.get(key);
    if (existing) return existing;
    const snapshot: AssistantContext = {
      version: 1, snapshotId: crypto.randomUUID(), capturedAt: new Date().toISOString(),
      source: { feature: "git.diff", instanceId: file },
      items: [{ id: "selection", kind: "text-selection.v1", label: file + " · " + (section ?? "diff"),
        text: context.exactCode ?? context.code,
        locator: { path: file, section, revision, spans: context.spans } }],
    };
    const created = new AssistantSession(key, paneId, rootPath, snapshot, assistantTransport());
    sessions.set(key, created);
    return created;
  });
  return <AssistantConversation session={session} title={file} style={anchor} onClose={onClose} additionalContext={context.code ? {
    id: "selection", kind: "text-selection.v1", label: file + " · " + (section ?? "diff"),
    text: context.exactCode ?? context.code, locator: { path: file, section, revision, spans: context.spans },
  } : undefined} />;
}
