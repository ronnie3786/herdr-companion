/** Git endpoints for pane and First Mate feature-scoped workspaces. */

import { apiRequest } from "./client";

const GIT_TIMEOUT_MS = 30_000;
const FIRST_MATE_KEY_PREFIX = "first-mate-git:";

export type GitTarget =
  | { kind: "pane"; paneId: string }
  | { kind: "firstMate"; featureId: string; workspaceId: string };

/** Opaque store identity. Feature-scoped keys can never be sent to pane APIs. */
export function gitTargetKey(target: GitTarget): string {
  return target.kind === "pane"
    ? target.paneId
    : `${FIRST_MATE_KEY_PREFIX}${encodeURIComponent(target.featureId)}:${encodeURIComponent(target.workspaceId)}`;
}

export function gitTargetFromKey(key: string): GitTarget {
  if (!key.startsWith(FIRST_MATE_KEY_PREFIX)) return { kind: "pane", paneId: key };
  const encoded = key.slice(FIRST_MATE_KEY_PREFIX.length);
  const separator = encoded.indexOf(":");
  if (separator < 1 || encoded.indexOf(":", separator + 1) !== -1) {
    throw new Error("Invalid First Mate Git target");
  }
  try {
    const featureId = decodeURIComponent(encoded.slice(0, separator));
    const workspaceId = decodeURIComponent(encoded.slice(separator + 1));
    if (!featureId || !workspaceId) throw new Error("Invalid First Mate Git target");
    return { kind: "firstMate", featureId, workspaceId };
  } catch {
    throw new Error("Invalid First Mate Git target");
  }
}

function targetBase(targetKey: string): { path: string; workspaceId?: string } {
  const target = gitTargetFromKey(targetKey);
  if (target.kind === "pane") {
    return { path: `/panes/${encodeURIComponent(target.paneId)}/git` };
  }
  return {
    path: `/first-mate/features/${encodeURIComponent(target.featureId)}/git`,
    workspaceId: target.workspaceId,
  };
}

function targetQuery(targetKey: string, fields: Record<string, string>): URLSearchParams {
  const target = targetBase(targetKey);
  return new URLSearchParams({ ...(target.workspaceId ? { workspace: target.workspaceId } : {}), ...fields });
}

function targetBody(targetKey: string, fields: Record<string, unknown>): string {
  const target = targetBase(targetKey);
  return JSON.stringify({ ...fields, ...(target.workspaceId ? { workspace: target.workspaceId } : {}) });
}

export interface GitFile { status: string; file: string; }
export interface GitCommit { hash: string; message: string; }
export interface PaneGitResponse {
  ok: boolean;
  pane_id?: string;
  feature_id?: string;
  workspace?: string;
  cwd?: string | null;
  root_path?: string | null;
  branch?: string | null;
  detached?: boolean | null;
  staged: GitFile[];
  unstaged: GitFile[];
  untracked: string[];
  commits: GitCommit[];
}

export interface FirstMateGitWorkspace { id: string; title: string; path: string; }
export interface FirstMateGitWorkspacesResponse { ok: boolean; workspaces: FirstMateGitWorkspace[]; }

export function firstMateGitWorkspaces(featureId: string, signal?: AbortSignal): Promise<FirstMateGitWorkspacesResponse> {
  return apiRequest<FirstMateGitWorkspacesResponse>(`/first-mate/features/${encodeURIComponent(featureId)}/git/workspaces`, { signal }, GIT_TIMEOUT_MS);
}

export function gitStatus(targetKey: string, signal?: AbortSignal): Promise<PaneGitResponse> {
  const target = targetBase(targetKey);
  const suffix = target.workspaceId ? `?${new URLSearchParams({ workspace: target.workspaceId })}` : "";
  return apiRequest<PaneGitResponse>(`${target.path}${suffix}`, { signal }, GIT_TIMEOUT_MS);
}

export function paneGit(paneId: string, signal?: AbortSignal): Promise<PaneGitResponse> {
  return gitStatus(paneId, signal);
}

export type GitSection = "staged" | "unstaged" | "untracked";
export interface PaneGitDiffResponse {
  ok: boolean; pane_id?: string; feature_id?: string; file: string; section: GitSection; diff: string; truncated?: boolean | null;
}

export function gitDiff(targetKey: string, file: string, section: GitSection, expectedRoot: string, signal?: AbortSignal): Promise<PaneGitDiffResponse> {
  const target = targetBase(targetKey);
  const params = targetQuery(targetKey, { file, section, expected_root: expectedRoot });
  return apiRequest<PaneGitDiffResponse>(`${target.path}/diff?${params}`, { signal }, GIT_TIMEOUT_MS);
}
export function paneGitDiff(paneId: string, file: string, section: GitSection, expectedRoot: string, signal?: AbortSignal) {
  return gitDiff(paneId, file, section, expectedRoot, signal);
}

export interface GitMutateResponse { ok: boolean; pane_id?: string; feature_id?: string; file?: string; }
export interface GitOpenFileResponse extends GitMutateResponse { absolute_path?: string | null; revealed?: boolean | null; }

export function gitOpenFile(targetKey: string, file: string, expectedRoot: string, reveal: boolean, signal?: AbortSignal): Promise<GitOpenFileResponse> {
  const target = targetBase(targetKey);
  return apiRequest<GitOpenFileResponse>(`${target.path}/open`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: targetBody(targetKey, { file, expected_root: expectedRoot, reveal }), signal,
  }, GIT_TIMEOUT_MS);
}

export function gitStage(targetKey: string, file: string, expectedRoot: string, signal?: AbortSignal): Promise<GitMutateResponse> {
  const target = targetBase(targetKey);
  return apiRequest<GitMutateResponse>(`${target.path}/stage`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: targetBody(targetKey, { file, expected_root: expectedRoot }), signal,
  }, GIT_TIMEOUT_MS);
}

export function gitUnstage(targetKey: string, file: string, expectedRoot: string, signal?: AbortSignal): Promise<GitMutateResponse> {
  const target = targetBase(targetKey);
  return apiRequest<GitMutateResponse>(`${target.path}/unstage`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: targetBody(targetKey, { file, expected_root: expectedRoot }), signal,
  }, GIT_TIMEOUT_MS);
}

export interface PaneGitCommitFilesResponse { ok: boolean; pane_id?: string; feature_id?: string; hash?: string; files: GitFile[]; }
export function gitCommitFiles(targetKey: string, hash: string, expectedRoot: string, signal?: AbortSignal): Promise<PaneGitCommitFilesResponse> {
  const target = targetBase(targetKey);
  const params = targetQuery(targetKey, { hash, expected_root: expectedRoot });
  return apiRequest<PaneGitCommitFilesResponse>(`${target.path}/commit-files?${params}`, { signal }, GIT_TIMEOUT_MS);
}
export function paneGitCommitFiles(paneId: string, hash: string, expectedRoot: string, signal?: AbortSignal) {
  return gitCommitFiles(paneId, hash, expectedRoot, signal);
}

export interface PaneGitCommitDiffResponse { ok: boolean; pane_id?: string; feature_id?: string; hash?: string; file?: string; diff: string; truncated?: boolean | null; }
export function gitCommitDiff(targetKey: string, hash: string, file: string, expectedRoot: string, signal?: AbortSignal): Promise<PaneGitCommitDiffResponse> {
  const target = targetBase(targetKey);
  const params = targetQuery(targetKey, { hash, file, expected_root: expectedRoot });
  return apiRequest<PaneGitCommitDiffResponse>(`${target.path}/commit-diff?${params}`, { signal }, GIT_TIMEOUT_MS);
}
export function paneGitCommitDiff(paneId: string, hash: string, file: string, expectedRoot: string, signal?: AbortSignal) {
  return gitCommitDiff(paneId, hash, file, expectedRoot, signal);
}
