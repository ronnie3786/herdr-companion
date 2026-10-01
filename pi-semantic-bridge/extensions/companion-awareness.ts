import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendWorkflowPolicy } from "../lib/workflow-policy";
import {
  appendCompanionAwareness,
  companionAwarenessInstructions,
  companionSurface,
} from "../lib/companion-awareness";

export function createCompanionAwarenessExtension(environment: NodeJS.ProcessEnv = process.env) {
  return (pi: ExtensionAPI): void => {
    pi.on("before_agent_start", (event) => {
      const instructions = companionAwarenessInstructions(environment);
      const awareness = appendCompanionAwareness(event.systemPrompt, instructions);
      const systemPrompt = companionSurface(environment) ? appendWorkflowPolicy(awareness) : awareness;
      if (systemPrompt !== event.systemPrompt) return { systemPrompt };
    });
  };
}

export default createCompanionAwarenessExtension();
