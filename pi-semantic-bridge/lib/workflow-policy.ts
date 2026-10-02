import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const WORKFLOW_POLICY_VERSION = "herdr-workflow-policy-v1";
export const WORKFLOW_POLICY_MARKER = "<!-- herdr-workflow-policy:v1 -->";
export const WORKFLOW_POLICY = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)),
  "../agent-docs/workflow-policy.md"), "utf8").trim();

export function appendWorkflowPolicy(prompt: string): string {
  return prompt.includes(WORKFLOW_POLICY_MARKER) ? prompt : `${prompt}\n\n${WORKFLOW_POLICY}`;
}
