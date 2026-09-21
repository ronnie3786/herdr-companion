/** Typed, assignment-scoped tools for companion-owned First Mate sessions.
 * Transport uses a private durable spool. No companion administration token is
 * exposed to a worker. Ordinary Pi sessions do not register these tools.
 */
import { Type } from "@earendil-works/pi-ai/compat";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createHash, randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const documentSchema = Type.Object({
  title: Type.String(), content: Type.String(),
  media_type: Type.Optional(Type.String()),
});
const text = (description: string) => Type.String({ description });

export function spoolRequestId(jobId: string, toolCallId: string): string {
  return createHash("sha256").update(`${jobId}\0${toolCallId}`).digest("hex");
}

export function atomicJSON(path: string, value: unknown): void {
  const temporary = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
  renameSync(temporary, path);
}

export function createFirstMateExtension(environment: NodeJS.ProcessEnv = process.env) {
  return (pi: ExtensionAPI): void => {
    const directory = environment.HERDR_FIRST_MATE_JOB_DIR;
    const role = environment.HERDR_FIRST_MATE_ROLE;
    if (!directory || !["coordinator", "worker", "advisor"].includes(role ?? "")) return;
    const root = resolve(directory);
    const job = JSON.parse(readFileSync(join(root, "job.json"), "utf8"));
    if (job.kind !== role || typeof job.id !== "string") throw new Error("Invalid First Mate execution scope");
    mkdirSync(join(root, "requests"), { recursive: true, mode: 0o700 });
    mkdirSync(join(root, "responses"), { recursive: true, mode: 0o700 });
    let retired = false;
    let checkpointRequested = false;
    let successorAcknowledged = !job.handoff_id;
    const coordinatorTools = new Set([
      "fm_status", "fm_delegate", "fm_begin_stage", "fm_recover",
      "fm_resolve_gate", "fm_steer", "fm_retry", "fm_complete_stage",
      "fm_revise", "fm_finish_feature",
    ]);

    const identity = (ctx: ExtensionContext) => ({
      native_session_id: ctx.sessionManager.getSessionId(),
      session_file: ctx.sessionManager.getSessionFile(),
    });
    const observe = (type: string, payload: unknown, ctx: ExtensionContext) => {
      appendFileSync(join(root, "telemetry.jsonl"), `${JSON.stringify({
        id: randomUUID(), type, ...identity(ctx), payload, time: new Date().toISOString(),
      })}\n`, { mode: 0o600 });
    };
    const request = async (toolCallId: string, action: string, params: unknown, signal: AbortSignal | undefined, ctx: ExtensionContext) => {
      const requestId = spoolRequestId(job.id, toolCallId);
      const input = join(root, "requests", `${requestId}.json`);
      const output = join(root, "responses", `${requestId}.json`);
      if (!existsSync(input)) atomicJSON(input, { request_id: requestId, action, params, ...identity(ctx) });
      // Service restarts do not lose the request. Abort ends this local wait,
      // while the same request ID still identifies any committed operation.
      while (!existsSync(output)) {
        if (signal?.aborted) throw new Error("First Mate request interrupted; its durable request is retained");
        await new Promise((done) => setTimeout(done, 100));
      }
      const response = JSON.parse(readFileSync(output, "utf8"));
      if (!response.ok) throw new Error(response.error || "First Mate rejected the operation");
      return { content: [{ type: "text" as const, text: JSON.stringify(response.result) }], details: response.result };
    };
    const register = (name: string, description: string, parameters: any) => pi.registerTool({
      name, label: name.replace(/^fm_/, "").replaceAll("_", " "), description, parameters,
      async execute(toolCallId, params, signal, _update, ctx) {
        const result = await request(toolCallId, name, params, signal, ctx);
        if (["fm_outcome", "fm_handoff", "fm_advice", "fm_request_human", "fm_recovery_brief", "fm_wait_for_children"].includes(name)) retired = true;
        if (name === "fm_acknowledge_handoff") successorAcknowledged = true;
        return result;
      },
    });
    register("fm_status", role === "coordinator"
      ? "Read the authoritative reference-oriented router status. Detailed evidence stays with tracked workers; no polling is necessary."
      : "Read authoritative feature status, assignments, outcomes and retained document references. No model polling is necessary.", Type.Object({}));
    if (role !== "coordinator") {
      register("fm_read_document", "Read a retained source document belonging to this feature before evaluating or synthesizing its evidence.", Type.Object({ document_id: text("Exact document ID"), offset: Type.Optional(Type.Integer({ minimum: 0 })), length: Type.Optional(Type.Integer({ minimum: 1000, maximum: 80000 })) }));
      register("fm_read_session", "Inspect a retained native Pi conversation belonging to this feature when the actual execution evidence is needed.", Type.Object({ native_session_id: text("Exact native session ID"), before: Type.Optional(Type.Integer({ minimum: 0 })), limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })), message_index: Type.Optional(Type.Integer({ minimum: 0 })), text_offset: Type.Optional(Type.Integer({ minimum: 0 })), text_length: Type.Optional(Type.Integer({ minimum: 1000, maximum: 80000 })) }));
    }
    if (role === "coordinator" || role === "worker") {
      register("fm_delegate", "Queue an independent saved Pi worker in the current authorized stage. This returns immediately. Delegate long work; never wait or poll.", Type.Object({
        title: text("Assignment title"), role: text("Specialist role"),
        prompt: text("Complete assignment including scope, required deliverables, acceptance criteria and explicit human gates"),
        model: Type.Optional(Type.String()),
        workspace_mode: Type.Union([Type.Literal("read_only"), Type.Literal("isolated")], { description: "Read-only planner/reviewer or private Git worktree for implementation/testing" }),
        source_assignment_id: Type.Optional(text("Assignment whose actual worktree and commit should be the baseline, especially for integration and review")),
      }));
    }
    if (role === "coordinator") {
      register("fm_begin_stage", "Begin exactly one major stage authorized by the current HUMAN message. Never continue a stage in response to a system outcome. Return to the human immediately after delegating.", Type.Object({
        stage_key: text("Stable stage key, for example planning or implementation"),
        title: text("Human-readable stage name"),
      }));
      register("fm_recover", "Recover an uncertain or interrupted assignment only after the human requests it and the service verifies no prior Pi writer remains. This uses the bounded recovery budget and retains prior evidence.", Type.Object({ assignment_id: text("Uncertain or interrupted assignment ID"), reason: text("Human-authorized recovery decision and evidence to verify before continuing") }));
      register("fm_resolve_gate", "Release an explicit internal human checkpoint only using the current human's direction. Background outcomes can never release a gate.", Type.Object({ assignment_id: text("Assignment with a pending human gate"), instruction: text("The human's decision and resulting instructions") }));
      register("fm_steer", "Send a bounded clarification or correction to an active worker in the current authorized stage. Returns immediately; delivery is logged.", Type.Object({ assignment_id: text("Target assignment ID"), text: text("Clarification within the authorized scope") }));
      register("fm_retry", "Repeat a blocked or failed assignment within this authorized stage after repairs or new instructions. Prior attempts and findings remain retained.", Type.Object({
        assignment_id: text("Exact assignment to repeat"), prompt: text("Complete revised assignment and evidence required"),
      }));
      register("fm_complete_stage", "Present completed stage evidence and a recommendation, then park the feature awaiting human direction. All assignments must have valid successful outcomes. Never start the next stage yourself.", Type.Object({
        summary: text("Concise evidence-backed synthesis"), recommendation: text("Suggested next action for the human to choose"),
      }));
      register("fm_revise", "Record a human-requested direction change and pause affected assignments. This versions the plan and fences stale outcomes. Only available on human turns.", Type.Object({
        goal: text("Revised goal preserving accepted constraints"), reason: text("What the human changed and why"),
        affected_assignment_ids: Type.Optional(Type.Array(Type.String(), { description: "Exact assignments affected by this change. Unaffected work remains active under explicit carried-forward membership. Omit only when the entire stage is affected." })),
      }));
      register("fm_finish_feature", "Mark the agreed feature destination achieved only after the human explicitly confirms completion. Retain all history.", Type.Object({ summary: text("Delivered destination and evidence") }));
    } else if (role === "worker") {
      register("fm_retry", "Retry only a directly delegated child within this authorized stage after its stopped execution reported failure or requested changes. Prior evidence remains retained.", Type.Object({ assignment_id: text("Direct child assignment ID"), prompt: text("Complete corrected assignment and evidence required") }));
      register("fm_wait_for_children", "Yield this worker conversation while its delegated children run. Save a checkpoint and end your turn. The service resumes this exact native conversation when they settle, without model polling.", Type.Object({ summary: text("Current assignment state, delegated work, acceptance criteria and what to do when children report") }));
      register("fm_outcome", "Report the assignment's structured verdict and durable deliverables. An ordinary final answer or clean exit does not count as completion. End your turn after this tool succeeds.", Type.Object({
        verdict: Type.Union(["success", "passed", "needs_changes", "blocked", "failed"].map(value => Type.Literal(value))),
        summary: text("Evidence, checks run, limitations and findings"), documents: Type.Array(documentSchema),
      }));
      register("fm_request_human", "Stop at an explicit internal human checkpoint. Save the reason for the human, then end. Only a later human message can release this gate; background repair cannot bypass it.", Type.Object({ reason: text("Decision needed, relevant evidence and recommended options") }));
      register("fm_handoff", "Retain a checkpoint for a fresh successor session. Include completed work, decisions, files, checks, blockers, remaining work and the exact next action. Stop making changes and end the turn after acknowledgement.", Type.Object({
        summary: text("Complete handoff document for the successor"),
      }));
      register("fm_acknowledge_handoff", "Before doing work in a successor, inspect the handoff and workspace and confirm the exact remaining assignment. Execution is fenced until this acknowledgement.", Type.Object({
        summary: text("Verified workspace, understood constraints and next concrete action"),
      }));
    } else {
      register("fm_recovery_brief", "Save an independent evidence-based checkpoint when the stopped predecessor could not summarize. Use only for a recovery assignment, then end.", Type.Object({ summary: text("Observed work, uncertain side effects, files/commits, checks, blockers and next safe action") }));
      register("fm_advice", "Return an evidence-based watchdog assessment. You cannot modify the assignment or its workspace. End after this report.", Type.Object({
        decision: Type.Union(["continue", "steer", "handoff", "pause"].map(value => Type.Literal(value))),
        reason: text("Observed evidence and why this action is appropriate"),
        instruction: Type.Optional(text("A bounded steering instruction or handoff guidance")),
      }));
    }
    pi.on("session_start", (_event, ctx) => observe("session_started", {}, ctx));
    pi.on("turn_end", (_event, ctx) => {
      const usage = ctx.getContextUsage();
      observe("context_usage", usage ?? {}, ctx);
      if (role !== "worker" || retired || checkpointRequested || !usage?.tokens) return;
      const window = Number(usage.contextWindow ?? 0);
      const configured = Number(environment.HERDR_FIRST_MATE_CONTEXT_TARGET ?? "150000");
      const reserve = Math.max(8192, Math.floor(window * 0.1));
      const target = window > 0 ? Math.min(configured, Math.max(4096, window - reserve)) : configured;
      if (usage.tokens >= target) {
        checkpointRequested = true;
        observe("checkpoint_requested", { tokens: usage.tokens, target }, ctx);
        pi.sendUserMessage("The context watcher requires a fresh-session handoff. Finish the current safe boundary, call fm_handoff with a complete checkpoint, then end. Do not compact or begin more implementation.", { deliverAs: "steer" });
      }
    });
    pi.on("session_before_compact", (_event, ctx) => {
      observe("compaction_prevented", {}, ctx);
      return { cancel: true };
    });
    pi.on("tool_call", (event) => {
      if (retired) return { block: true, reason: "This execution has reported its outcome or checkpoint. End the turn now.", terminate: true };
      if (!successorAcknowledged && !["fm_acknowledge_handoff", "fm_status", "read", "ls", "find", "grep"].includes(event.toolName)) {
        return { block: true, reason: "Inspect the handoff and workspace, then acknowledge with fm_acknowledge_handoff before executing work." };
      }
      if (role === "worker" && job.workspace_mode === "read_only" && !["read", "grep", "find", "ls", "fm_status", "fm_read_document", "fm_read_session", "fm_outcome", "fm_handoff", "fm_acknowledge_handoff", "fm_request_human", "fm_delegate", "fm_retry", "fm_wait_for_children"].includes(event.toolName)) {
        return { block: true, reason: "This assignment is read-only. Ask First Mate for an isolated testing/implementation assignment when commands or mutations are needed." };
      }
      if (role === "coordinator" && !coordinatorTools.has(event.toolName)) {
        return { block: true, reason: "First Mate delegates execution through fm_delegate. Keep this conversation available for the human." };
      }
      if (role === "advisor" && !["read", "ls", "find", "grep", "fm_status", "fm_read_document", "fm_read_session", "fm_advice", "fm_recovery_brief"].includes(event.toolName)) {
        return { block: true, reason: "The advisor is read-only and returns judgment through fm_advice." };
      }
    });
  };
}
export default createFirstMateExtension();
