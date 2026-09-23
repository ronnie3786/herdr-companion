import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { herdrBaseURL, readPrivateToken } from "./send-to-herdr";

export const PROFILE_MARKER = "<!-- herdr-agent-profile:v1 -->";
const ENTRY = "herdr.agent-profile-snapshot";
const MAX_BYTES = 256 * 1024;
const RESTRICTED = new Set(["contextual-question-v1", "pr-review-question-v1", "response-brief-v1", "smart-rename-v1"]);

type Snapshot = { prompt: string; [key: string]: unknown };
function snapshot(value: unknown): Snapshot | undefined {
	if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
	const result = value as Snapshot;
	if (typeof result.prompt !== "string" || Buffer.byteLength(JSON.stringify(result)) > MAX_BYTES) return undefined;
	if (result.prompt && !result.prompt.startsWith(PROFILE_MARKER)) return undefined;
	return result;
}

export function profileEligible(environment: NodeJS.ProcessEnv): boolean {
	// Server-launched chats/runs and managed First Mate jobs carry their own
	// durable snapshot. Never let global discovery replace it on a later turn.
	return Boolean(environment.HERDR_PANE_ID) && !environment.HERDR_FIRST_MATE_MANAGED_ROLE
		&& !environment.HERDR_AGENT_RUN_ID && !RESTRICTED.has(environment.HERDR_AGENT_RUN_PROFILE ?? "");
}

export async function fetchProfile(environment: NodeJS.ProcessEnv): Promise<Snapshot | undefined> {
	try {
		const response = await fetch(`${herdrBaseURL(environment)}/api/v1/agent-profiles/effective`, {
			headers: { Authorization: `Bearer ${readPrivateToken(environment)}` },
			redirect: "error", signal: AbortSignal.timeout(2500),
		});
		if (!response.ok || !response.body) return undefined;
		const reader = response.body.getReader();
		const chunks: Uint8Array[] = [];
		let count = 0;
		try {
			while (true) {
				const { value, done } = await reader.read();
				if (done) break;
				count += value.byteLength;
				if (count > MAX_BYTES) { await reader.cancel(); return undefined; }
				chunks.push(value);
			}
		} finally { reader.releaseLock(); }
		const result = JSON.parse(Buffer.concat(chunks).toString("utf8"));
		return result.ok === true ? snapshot(result.effective) : undefined;
	} catch { return undefined; } // No secrets or profile contents in logs.
}

export function createAgentProfilesExtension(environment: NodeJS.ProcessEnv = process.env, load = fetchProfile) {
	return (pi: ExtensionAPI): void => {
		if (!profileEligible(environment)) return;
		let pinned: Snapshot | undefined;
		let loaded = false;
		pi.on("session_start", (_event, ctx) => {
			pinned = undefined;
			loaded = false;
			for (const entry of ctx.sessionManager.getBranch()) {
				if (entry.type === "custom" && entry.customType === ENTRY) {
					pinned = snapshot(entry.data);
					loaded = pinned !== undefined;
				}
			}
		});
		pi.on("before_agent_start", async (event) => {
			if (event.systemPrompt.includes(PROFILE_MARKER)) return;
			if (!loaded) {
				pinned = await load(environment);
				// A transient unavailable service doesn't pin a fabricated empty profile.
				if (pinned) { pi.appendEntry(ENTRY, pinned); loaded = true; }
			}
			if (pinned?.prompt) return { systemPrompt: `${event.systemPrompt}\n\n${pinned.prompt}` };
		});
	};
}

export default createAgentProfilesExtension();
