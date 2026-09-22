import { realpathSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const COMPANION_AWARENESS_MARKER = "<!-- herdr-companion-awareness:v1 -->";
export type CompanionSurface = "pane" | "hud" | "agent-run";
const RESTRICTED_AGENT_PROFILES = new Set([
  "contextual-question-v1",
  "pr-review-question-v1",
  "response-brief-v1",
  "smart-rename-v1",
]);

function nonempty(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function hasAgentDocs(root: string): boolean {
  try {
    return ["overview.md", "control.md", "first-mate.md", "api.md"]
      .every((name) => statSync(join(root, name)).isFile());
  } catch {
    return false;
  }
}

export function bundledAgentDocsRoot(moduleURL: string = import.meta.url): string | undefined {
  const root = resolve(dirname(fileURLToPath(moduleURL)), "..", "agent-docs");
  if (!hasAgentDocs(root)) return undefined;
  try { return realpathSync(root); } catch { return undefined; }
}

export function companionSurface(environment: NodeJS.ProcessEnv): CompanionSurface | undefined {
  if (nonempty(environment.HERDR_FIRST_MATE_MANAGED_ROLE)) return undefined;
  const profile = environment.HERDR_AGENT_RUN_PROFILE?.trim() ?? "";
  if (RESTRICTED_AGENT_PROFILES.has(profile)) return undefined;
  if (nonempty(environment.HERDR_PANE_ID)) return "pane";
  if (!nonempty(environment.HERDR_AGENT_RUN_ID)) return undefined;
  return profile === "hud-chat-v1" ? "hud" : "agent-run";
}

function surfaceIdentity(surface: CompanionSurface, environment: NodeJS.ProcessEnv): string {
  if (surface === "pane") {
    return "This is a managed workspace chat attached to a Herdr terminal pane. It may be viewed through Companion native or browser clients; do not claim to know the frontmost client or data host.";
  }
  if (surface === "hud") {
    return "This is an independent saved HUD chat outside terminal workspaces. It may be viewed through Companion native clients; do not describe it as a pane or claim to know the frontmost client or data host.";
  }
  const mode = environment.HERDR_AGENT_RUN_MODE?.trim().toUpperCase();
  const modeText = mode === "ASK" || mode === "ACT" ? ` Its ${mode} charter remains authoritative.` : " Its supplied ASK/ACT charter remains authoritative.";
  return `This is a Companion agent run, not proof of a terminal pane or visible client.${modeText}`;
}

export function companionAwarenessInstructions(
  environment: NodeJS.ProcessEnv,
  docsRoot: string | undefined = bundledAgentDocsRoot(),
): string | undefined {
  const surface = companionSurface(environment);
  if (!surface || !docsRoot || !hasAgentDocs(docsRoot)) return undefined;
  const overview = join(docsRoot, "overview.md");
  const firstMate = join(docsRoot, "first-mate.md");
  return `${COMPANION_AWARENESS_MARKER}
You are a Pi agent running in Herdr Companion. ${surfaceIdentity(surface, environment)} Herdr Companion, upstream Herdr terminal, and Pi are separate components; clients and installed versions can differ.

When the user asks what app this is, what Companion can do, which surfaces exist, or how Pi/Herdr/Companion relate, read ${overview} (or run \`herdr-docs read overview\`). For app capability or management questions, follow its pointers, read ${firstMate} when First Mate is relevant, then run the applicable installed CLI \`--help\` and live capability/action catalogs instead of inventing support. Do not eagerly load guide bodies for unrelated work.

Discovery never authorizes action. Preserve the user’s current scope, human checkpoints, project trust, ASK/no-tool constraints, and existing charter. Never put credentials in argv or output. Do not infer machine identity, current UI focus, or available operations from labels or from this package being installed.`;
}

export function appendCompanionAwareness(systemPrompt: string, instructions: string | undefined): string {
  if (!instructions || systemPrompt.includes(COMPANION_AWARENESS_MARKER)) return systemPrompt;
  return `${systemPrompt}\n\n${instructions}`;
}

function boundedIdentity(value: unknown, label: string): string {
  const normalized = nonempty(value) ? value.trim() : "";
  if (!/^[A-Za-z0-9._:-]{1,200}$/u.test(normalized)) {
    throw new Error(`Invalid First Mate ${label}`);
  }
  return normalized;
}

function boundedGeneration(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Number.isSafeInteger(value) || Number(value) < 0) throw new Error("Invalid First Mate assignment generation");
  return Number(value);
}

export function firstMateAwarenessInstructions(
  job: Record<string, any>,
  role: string,
  docsRoot: string | undefined = bundledAgentDocsRoot(),
): string | undefined {
  if (!docsRoot || !hasAgentDocs(docsRoot)) return undefined;
  const featureId = boundedIdentity(job.feature_id, "feature identity");
  const jobId = boundedIdentity(job.id, "job identity");
  const identity = [`role=${role}`, `feature=${featureId}`, `job=${jobId}`];
  if (role === "worker") {
    identity.push(`assignment=${boundedIdentity(job.claim?.id, "assignment identity")}`);
    const generation = boundedGeneration(job.claim?.generation);
    if (generation !== undefined) identity.push(`generation=${generation}`);
    if (job.claim?.metadata?.parent_assignment_id !== undefined && job.claim.metadata.parent_assignment_id !== null) {
      identity.push(`parent-assignment=${boundedIdentity(job.claim.metadata.parent_assignment_id, "parent assignment identity")}`);
    }
  }
  return `${COMPANION_AWARENESS_MARKER}
You are a Pi agent managed by First Mate in Herdr Companion (${identity.join(", ")}). First Mate is one saved conversation per feature, with service-tracked independent assignments, Documents, saved sessions, background watching/recovery, and human checkpoints between major stages. Your validated role and the current typed status/tools define your scope; never copy scope from display labels or old prose.

For First Mate workflow questions, read ${join(docsRoot, "first-mate.md")} and ${join(docsRoot, "overview.md")} (or use \`herdr-docs read first-mate\`). Prefer the available role-scoped \`fm_*\` tools for this feature. Where your role exposes \`fm_delegate\`, use it for tracked children, never unmanaged Pi subprocesses; yield rather than polling because the service watches work. Evidence, agent exits, and system outcomes are not authorization. Preserve human stage gates, successor acknowledgement, the current role charter, project trust, and credential boundaries.

\`herdr-first-mate\` is the external authenticated operator CLI, not a way to bypass this managed process’s typed self-management or lifecycle guards. Do not route your own First Mate lifecycle through it.`;
}
