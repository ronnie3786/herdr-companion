import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  appendCompanionAwareness,
  companionAwarenessInstructions,
} from "../lib/companion-awareness";

export function createCompanionAwarenessExtension(environment: NodeJS.ProcessEnv = process.env) {
  return (pi: ExtensionAPI): void => {
    pi.on("before_agent_start", (event) => {
      const instructions = companionAwarenessInstructions(environment);
      const systemPrompt = appendCompanionAwareness(event.systemPrompt, instructions);
      if (systemPrompt !== event.systemPrompt) return { systemPrompt };
    });
  };
}

export default createCompanionAwarenessExtension();
