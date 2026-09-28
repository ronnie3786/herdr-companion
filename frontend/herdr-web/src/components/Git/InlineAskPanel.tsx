import { useState } from "react";
import { AssistantConversation } from "../Assistant/AssistantConversation";
import { AssistantSession } from "../Assistant/AssistantSession";
import { assistantTransport, type AssistantContext } from "../../api/assistant";
import { getServerUrl } from "../../api/client";
import { gitTargetFromKey } from "../../api/git";
import { questionScopeKey, type GitComparisonSelection } from "./comparison";
import type { SelectionAskContext } from "./selectionAsk";
import "../Pi/pi.css";

export interface InlineAskAnchor { left: number; top: number }
const sessions = new Map<string, AssistantSession>();
export function gitQuestionKey(paneId: string, file: string, section = "unstaged", rootPath = "", revision = "") {
  return questionScopeKey(getServerUrl(), paneId, rootPath, file, section, revision);
}
export function hasGitQuestion(key: string) {
  if (sessions.has(key)) return true;
  try { return sessionStorage.getItem(key) !== null; } catch { return false; }
}
export function InlineAskPanel({ paneId, file, context, anchor, onClose, section, rootPath, revision, comparison, viewerContext, availableFiles, onShowFile }: {
  paneId: string; file: string; context: SelectionAskContext; anchor: InlineAskAnchor;
  onClose: () => void; section?: string; rootPath?: string; revision?: string;
  comparison?: GitComparisonSelection; viewerContext?: object;
  availableFiles?: string[]; onShowFile?: (path: string) => void;
}) {
  const key = gitQuestionKey(paneId, file, section, rootPath, revision);
  const [session] = useState(() => {
    const existing = sessions.get(key);
    if (existing) return existing;
    const snapshot: AssistantContext = {
      version: 1, snapshotId: crypto.randomUUID(), capturedAt: new Date().toISOString(),
      source: { feature: "git.diff", instanceId: file },
      items: [...(viewerContext ? [{ id: "viewer", kind: "view.v1" as const, label: "Current Git comparison",
        text: JSON.stringify(viewerContext), locator: { path: file, revision, section } }] : []),
        { id: "selection", kind: "text-selection.v1", label: file + " · " + (section ?? "diff"),
        text: context.exactCode ?? context.code,
        locator: { path: file, section, revision, spans: context.spans } }],
    };
    const target = gitTargetFromKey(paneId);
    const transport = assistantTransport();
    const created = new AssistantSession(key, paneId, rootPath, snapshot, {
      ...transport,
      start: (request) => transport.start({ ...request,
        paneId: target.kind === "pane" ? target.paneId : undefined,
        scope: { expectedRootPath: rootPath, comparison, ...(comparison ? { comparisonId: revision } : {}),
          ...(target.kind === "firstMate" ? { firstMateFeatureId: target.featureId, workspaceId: target.workspaceId } : {}) },
      }),
    }, comparison ? "git-question-v1" : "contextual-question-v1");
    sessions.set(key, created);
    return created;
  });
  return <AssistantConversation session={session} title={file} style={anchor} onClose={onClose}
    availableFiles={availableFiles} onShowFile={onShowFile} additionalContext={context.code ? {
    id: "selection", kind: "text-selection.v1", label: file + " · " + (section ?? "diff"),
    text: context.exactCode ?? context.code, locator: { path: file, section, revision, spans: context.spans },
  } : undefined} />;
}
