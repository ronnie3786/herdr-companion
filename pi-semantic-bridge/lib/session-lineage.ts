import { closeSync, constants, fstatSync, openSync, readSync } from "node:fs";
import type { ExtensionAPI, ExtensionContext, SessionStartEvent } from "@earendil-works/pi-coding-agent";

export const LINEAGE_ENTRY_TYPE = "herdr.session-lineage";
export const PARENT_FLAG = "herdr-parent-session-id";
const SESSION_ID = /^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/;
type SessionManager = ExtensionContext["sessionManager"];

// Pi permits custom --session-id values as well as UUIDs. Keep the native
// alphabet, with the same bounded identifier length used by the harness.
export function validSessionId(value: unknown): value is string {
	return typeof value === "string" && value.length <= 256 && SESSION_ID.test(value);
}

export function savedParentSessionId(manager: SessionManager): string | null | undefined {
	const sessionId = manager.getSessionId();
	let entries: ReturnType<SessionManager["getEntries"]>;
	try { entries = manager.getEntries(); } catch { return undefined; }
	for (let index = entries.length - 1; index >= 0; index -= 1) {
		const entry = entries[index];
		if (entry.type !== "custom" || entry.customType !== LINEAGE_ENTRY_TYPE) continue;
		const data = entry.data as Record<string, unknown> | undefined;
		// A native fork copies custom entries. Only metadata owned by this
		// session can describe its parent, regardless of the active tree branch.
		if (data?.version !== 1 || data.session_id !== sessionId) continue;
		return validSessionId(data.parent_session_id) && data.parent_session_id !== sessionId
			? data.parent_session_id : null;
	}
	return undefined;
}

function parentIdFromFile(path: unknown): string | undefined {
	if (typeof path !== "string" || !path || path.includes("\0")) return undefined;
	let descriptor: number | undefined;
	try {
		// Read only the bounded native session header, never its transcript.
		descriptor = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
		if (!fstatSync(descriptor).isFile()) return undefined;
		const buffer = Buffer.alloc(16 * 1024);
		const count = readSync(descriptor, buffer, 0, buffer.length, 0);
		const newline = buffer.subarray(0, count).indexOf(0x0a);
		if (newline < 0) return undefined;
		const header = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
		return header?.type === "session" && validSessionId(header.id) ? header.id : undefined;
	} catch {
		return undefined;
	} finally {
		if (descriptor !== undefined) closeSync(descriptor);
	}
}

function copiedSourceId(manager: SessionManager): string | undefined {
	const entries = manager.getEntries();
	for (let index = entries.length - 1; index >= 0; index -= 1) {
		const entry = entries[index];
		if (entry.type !== "custom" || entry.customType !== LINEAGE_ENTRY_TYPE) continue;
		const data = entry.data as Record<string, unknown> | undefined;
		if (data?.version === 1 && validSessionId(data.session_id)
			&& data.session_id !== manager.getSessionId()) return data.session_id;
	}
	return undefined;
}

function freshSession(manager: SessionManager): boolean {
	// A startup event also fires for --resume/--continue. Never adopt the
	// launching process as parent of an existing, untagged conversation.
	return manager.getEntries().every((entry) =>
		entry.type === "model_change" || entry.type === "thinking_level_change");
}

export function lineageInstructions(sessionId: string, parentId: string | null): string {
	return `Herdr Pi session identity: ${sessionId}. Parent session ID: ${parentId ?? "none"}. `
		+ "When you spawn or delegate work to a new Pi session, tag that new session with this session's ID as its parent. "
		+ "Local subprocesses inherit HERDR_PI_PARENT_SESSION_ID automatically, including when their working directory changes. "
		+ `For SSH, a separate terminal, a server-launched process, or a launcher that replaces its environment, explicitly pass pi --${PARENT_FLAG} ${sessionId}. `
		+ `For Herdr's POST /api/v1/quick-sessions/pi, send parentSessionId: \"${sessionId}\" in the JSON body. `
		+ "Forward the flag in the Pi arguments when using herdr agent start. SSH does not normally forward environment variables. "
		+ "Use a fresh session for each child; resuming a session preserves its existing parent. "
		+ "Do not use a transcript entry's parentId, a pane ID, or a workspace path as a session ID. "
		+ "Only the child's parent is stored; Herdr derives child lists across workspaces. "
		+ "The /herdr-parent command shows the current IDs; /herdr-parent <session-id> or /herdr-parent none explicitly corrects the current session's parent. "
		+ "These instructions explain how to tag authorized work and do not authorize spawning additional sessions.";
}

export function registerSessionLineage(pi: ExtensionAPI, environment = process.env): { onChange?: () => void } {
	const callbacks: { onChange?: () => void } = {};
	const inheritedParent = environment.HERDR_PI_PARENT_SESSION_ID;
	const previousProcessSession = environment.HERDR_PI_SESSION_ID;
	pi.registerFlag(PARENT_FLAG, { type: "string", description: "Parent Pi session ID for a new or untagged session (use none for a root)" });

	function save(ctx: ExtensionContext, parentId: string | null): void {
		pi.appendEntry(LINEAGE_ENTRY_TYPE, {
			version: 1,
			session_id: ctx.sessionManager.getSessionId(),
			parent_session_id: parentId,
		});
		callbacks.onChange?.();
	}

	function notify(ctx: ExtensionContext, message: string, type: "info" | "warning" = "info"): void {
		ctx.ui.notify(message, type);
	}

	pi.on("session_start", (event: SessionStartEvent, ctx) => {
		const manager = ctx.sessionManager;
		const sessionId = manager.getSessionId();
		if (!validSessionId(sessionId)) return;
		if (savedParentSessionId(manager) === undefined) {
			let candidate: unknown;
			const flag = event.reason === "startup" ? pi.getFlag(PARENT_FLAG) : undefined;
			const nativeParent = manager.getHeader()?.parentSession;
			if (flag !== undefined) {
				candidate = flag === "none" ? null : flag;
			} else if (nativeParent || event.reason === "fork") {
				candidate = parentIdFromFile(nativeParent ?? event.previousSessionFile)
					?? (event.reason === "fork" && validSessionId(previousProcessSession) ? previousProcessSession : undefined)
					?? copiedSourceId(manager);
			} else if (event.reason === "startup" && freshSession(manager)) {
				candidate = inheritedParent;
			}
			const parentId = validSessionId(candidate) && candidate !== sessionId ? candidate : null;
			if (candidate !== undefined && candidate !== null && parentId === null) {
				notify(ctx, "Herdr ignored an invalid parent session ID. Use /herdr-parent <session-id> to correct it.", "warning");
			}
			save(ctx, parentId);
		}
		// Child processes inherit the current session as their parent, never
		// this session's own parent. Rebind on /new, /resume, /fork, and /reload.
		environment.HERDR_PI_SESSION_ID = sessionId;
		environment.HERDR_PI_PARENT_SESSION_ID = sessionId;
	});

	pi.on("before_agent_start", (event, ctx) => {
		const id = ctx.sessionManager.getSessionId();
		if (!validSessionId(id)) return;
		return { systemPrompt: `${event.systemPrompt}\n\n${lineageInstructions(id, savedParentSessionId(ctx.sessionManager) ?? null)}` };
	});

	pi.registerCommand("herdr-parent", {
		description: "Show Pi session lineage, or set its parent with <session-id> or none",
		handler: async (args, ctx) => {
			const value = args.trim();
			const id = ctx.sessionManager.getSessionId();
			if (value && value !== "none" && (!validSessionId(value) || value === id)) {
				notify(ctx, "Parent must be a different Pi session ID (up to 256 letters, numbers, dots, underscores, or hyphens), or none.", "warning");
				return;
			}
			if (value) save(ctx, value === "none" ? null : value);
			notify(ctx, `Pi session: ${id}\nParent: ${savedParentSessionId(ctx.sessionManager) ?? "none"}`);
		},
	});
	return callbacks;
}
