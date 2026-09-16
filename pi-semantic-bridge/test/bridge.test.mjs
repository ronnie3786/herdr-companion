import { createJiti } from "jiti";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const temporary = mkdtempSync(join(tmpdir(), "pi-semantic-extension-test-"));
process.env.HERDR_SOCKET_PATH = join(temporary, "herdr.sock");
process.env.HERDR_PANE_ID = "w1:p1";
process.env.HERDR_PI_SEMANTIC_MAX_QUEUE_RECORDS = "8";
process.env.HERDR_PI_SEMANTIC_MAX_QUEUE_BYTES = String(64 * 1024);
process.env.HERDR_PI_SEMANTIC_CHECKPOINT_EVENT_INTERVAL = "8";

const jiti = createJiti(import.meta.url);
const bridgeModule = await jiti.import("../extensions/pi-semantic-bridge.ts");
const handlers = new Map();
const commands = new Map();
const sent = [];
let aborted = false;
let compactCalls = 0;
let compactOptions;
const setModelCalls = [];
let setModelResult = true;
const setThinkingLevelCalls = [];
let effectiveThinkingLevel = "high";
const availableModels = [
	{ provider: "test", id: "model", name: "Test Model", reasoning: true, contextWindow: 128000 },
	{ provider: "other", id: "other-model", name: "Other Model", reasoning: false, contextWindow: 32000 },
];
const pi = {
	on(type, handler) {
		const previous = handlers.get(type);
		handlers.set(type, previous ? (...args) => {
			const result = previous(...args);
			return handler(...args) ?? result;
		} : handler);
	},
	registerFlag() {},
	getFlag() {},
	registerCommand(name, command) { commands.set(name, command); },
	appendEntry(customType, data) { costEntries.push({ type: "custom", customType, data }); },
	sendUserMessage(text, options) { sent.push({ text, options }); },
	async setModel(model) {
		setModelCalls.push(model);
		return setModelResult;
	},
	setThinkingLevel(level) {
		setThinkingLevelCalls.push(level);
	},
	getThinkingLevel() {
		return effectiveThinkingLevel;
	},
};

let idle = true;
let contextUsageValue = { tokens: 12_345, contextWindow: 192_000, percent: 6.43 };
const entries = [
	{
		type: "message",
		id: "entry-1",
		parentId: null,
		timestamp: "2026-08-12T00:00:00Z",
		message: { role: "user", content: "hello" },
		future: {
			kept: true,
			thinkingSignature: "secret-thinking",
			thought_signature: "secret-thought",
		},
	},
];
let costEntriesShouldThrow = false;
const costEntries = [
	{
		type: "message",
		id: "cost-entry-assistant",
		parentId: null,
		message: {
			role: "assistant",
			content: [{ type: "text", text: "done" }],
			usage: {
				input: 100,
				output: 50,
				cacheRead: 10,
				cacheWrite: 5,
				totalTokens: 165,
				cost: { input: 0.01, output: 0.02, cacheRead: 0, cacheWrite: 0, total: 0.03 },
			},
		},
	},
	{
		type: "compaction",
		id: "cost-entry-compaction",
		parentId: "cost-entry-assistant",
		usage: {
			input: 20,
			output: 10,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 30,
			cost: { input: 0.003, output: 0.002, cacheRead: 0, cacheWrite: 0, total: 0.005 },
		},
	},
	{
		type: "message",
		id: "cost-entry-user",
		parentId: "cost-entry-compaction",
		message: { role: "user", content: "no usage here" },
	},
];
const context = {
	ui: { notify() {} },
	mode: "tui",
	model: { provider: "test", id: "model" },
	thinkingLevel: "high",
	isIdle: () => idle,
	getContextUsage: () => contextUsageValue,
	hasPendingMessages: () => false,
	abort: () => { aborted = true; },
	compact: (options) => {
		compactCalls += 1;
		compactOptions = options;
	},
	modelRegistry: {
		getAvailable: () => availableModels,
		find: (provider, id) => availableModels.find((item) => item.provider === provider && item.id === id),
	},
	scopedModels: [],
	sessionManager: {
		getSessionId: () => "session-1",
		getSessionFile: () => "/tmp/session.jsonl",
		getCwd: () => "/tmp/project",
		getLeafId: () => "entry-1",
		getSessionName: () => "Fixture",
		getHeader: () => ({ type: "session", version: 3, id: "session-1" }),
		getEntries: () => {
			if (costEntriesShouldThrow) throw new Error("boom");
			return costEntries;
		},
		buildContextEntries: () => entries,
	},
};

function readRecords(socket, until) {
	return new Promise((resolve, reject) => {
		const records = [];
		let buffered = "";
		const cleanup = () => {
			clearTimeout(timeout);
			socket.off("data", onData);
			socket.off("error", onError);
		};
		const onError = (error) => {
			cleanup();
			reject(error);
		};
		const onData = (chunk) => {
			buffered += chunk.toString("utf8");
			let newline = buffered.indexOf("\n");
			while (newline >= 0) {
				const raw = buffered.slice(0, newline);
				buffered = buffered.slice(newline + 1);
				if (raw) records.push(JSON.parse(raw));
				if (until(records)) {
					cleanup();
					resolve(records);
					return;
				}
				newline = buffered.indexOf("\n");
			}
		};
		const timeout = setTimeout(() => {
			cleanup();
			reject(new Error("timed out waiting for bridge records"));
		}, 3000);
		socket.on("data", onData);
		socket.on("error", onError);
	});
}

async function connect(path) {
	for (let attempt = 0; attempt < 60; attempt += 1) {
		try {
			return await new Promise((resolve, reject) => {
				const socket = createConnection(path, () => resolve(socket));
				socket.once("error", reject);
			});
		} catch {
			await delay(20);
		}
	}
	throw new Error("extension socket never appeared");
}

try {
	bridgeModule.default(pi);
	assert.ok(handlers.has("session_start"));
	assert.ok(handlers.has("message_update"));
	assert.ok(handlers.has("session_shutdown"));
	await handlers.get("session_start")({ type: "session_start", reason: "startup" }, context);

	const socketPath = bridgeModule.semanticSocketPath(process.env.HERDR_SOCKET_PATH, process.env.HERDR_PANE_ID);
	const subscription = await connect(socketPath);
	const snapshotPromise = readRecords(subscription, (records) => records.some((item) => item.kind === "snapshot"));
	subscription.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "subscribe-1",
		type: "subscribe",
		pane_id: "w1:p1",
		after: 0,
	})}\n`);
	const initial = await snapshotPromise;
	const snapshot = initial.find((item) => item.kind === "snapshot").snapshot;
	assert.equal(snapshot.entries[0].id, "entry-1");
	assert.equal(snapshot.entries[0].parentId, null);
	assert.equal(snapshot.session.parent_session_id, null);
	assert.equal(initial.find((item) => item.kind === "hello").parent_session_id, null);
	assert.equal(snapshot.entries[0].future.kept, true);
	assert.equal(snapshot.entries[0].future.thinkingSignature.reason, "provider_signature");
	assert.equal(snapshot.entries[0].future.thought_signature.reason, "provider_signature");
	assert.equal(snapshot.state.idle, true);
	assert.equal(snapshot.state.working, false);
	assert.equal(snapshot.state.isStreaming, false);
	assert.equal(snapshot.state.isCompacting, false);
	assert.equal(snapshot.state.compaction, null);
	assert.deepEqual(snapshot.state.context, { tokens: 12_345, contextWindow: 192_000, percent: 6.43 });
	const hello = initial.find((item) => item.kind === "hello");
	assert.equal(hello.capabilities.listModels, true);
	assert.equal(hello.capabilities.setModel, true);
	assert.equal(hello.capabilities.setThinkingLevel, true);
	assert.equal(hello.capabilities.compact, true);

	assert.ok(Math.abs(snapshot.state.cost.totalUSD - 0.035) < 1e-9);
	assert.equal(snapshot.state.cost.totalTokens, 195);
	assert.ok(Math.abs(snapshot.usage.costUSD - 0.035) < 1e-9);
	assert.equal(snapshot.usage.totalTokens, 195);

	costEntriesShouldThrow = true;
	const costFailure = await connect(socketPath);
	const costFailureSnapshotPromise = readRecords(costFailure, (records) => records.some((item) => item.kind === "snapshot"));
	costFailure.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "cost-failure-subscribe",
		type: "subscribe",
		pane_id: "w1:p1",
		after: 0,
	})}\n`);
	const costFailureRecords = await costFailureSnapshotPromise;
	const costFailureSnapshot = costFailureRecords.find((item) => item.kind === "snapshot").snapshot;
	assert.deepEqual(costFailureSnapshot.state.cost, { totalUSD: null });
	assert.equal(costFailureSnapshot.usage, undefined);
	costFailure.destroy();
	costEntriesShouldThrow = false;

	for (const parent of ["parent-session", null]) {
		const lineageChanged = readRecords(subscription, (records) => records.some(
			(item) => item.kind === "reset" && item.event?.reason === "session_lineage_changed",
		));
		await commands.get("herdr-parent").handler(parent ?? "none", context);
		const records = await lineageChanged;
		const reset = records.find((item) => item.event?.reason === "session_lineage_changed");
		assert.equal(reset.snapshot.session.parent_session_id, parent);
	}

	const deltas = [];
	const privateSentinel = "PRIVATE-SYSTEM-PROMPT-MUST-NOT-CROSS-WIRE";
	handlers.get("before_agent_start")({
		type: "before_agent_start",
		systemPrompt: privateSentinel,
		messages: [{ role: "user", content: privateSentinel }],
	}, context);
	const compactionAbortController = new AbortController();
	const compactingRecordsPromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "session_before_compact",
	) && records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.isCompacting === true,
	));
	handlers.get("session_before_compact")({
		type: "session_before_compact",
		reason: "threshold",
		willRetry: true,
		signal: compactionAbortController.signal,
		preparation: { secret: privateSentinel },
		branchEntries: [{ id: "inactive", content: privateSentinel.repeat(20_000) }],
		customInstructions: privateSentinel,
	}, context);
	const compactingRecords = await compactingRecordsPromise;
	const compactingEvent = compactingRecords.find((item) => item.event?.type === "session_before_compact").event;
	assert.deepEqual(compactingEvent, {
		reason: "threshold",
		willRetry: true,
		type: "session_before_compact",
	});
	const compactingSnapshot = compactingRecords.find(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.isCompacting === true,
	).snapshot;
	assert.deepEqual(compactingSnapshot.state.compaction, {
		active: true,
		reason: "threshold",
		willRetry: true,
	});
	assert.equal(JSON.stringify(compactingRecords).includes(privateSentinel), false);

	const abortedCompactionPromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "session_compact_end" && item.event.outcome === "aborted",
	) && records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.isCompacting === false,
	));
	compactionAbortController.abort();
	const abortedCompactionRecords = await abortedCompactionPromise;
	assert.equal(JSON.stringify(abortedCompactionRecords).includes(privateSentinel), false);
	handlers.get("session_before_tree")({
		type: "session_before_tree",
		entriesToSummarize: [{ id: "inactive-tree", content: privateSentinel.repeat(20_000) }],
	}, context);
	idle = false;
	for (let index = 0; index < 8; index += 1) {
		const delta = String(index);
		deltas.push(delta);
		handlers.get("message_update")({
			type: "message_update",
			assistantMessageEvent: {
				type: "text_delta",
				contentIndex: 0,
				delta,
				partial: { role: "assistant", content: "x".repeat(200_000) },
			},
			message: { role: "assistant", content: "x".repeat(200_000) },
		}, context);
		// Let the bridge's delivery microtask run so this fixture does not test
		// queue overflow while exercising the checkpoint schedule.
		await Promise.resolve();
	}
	const deltaRecords = await readRecords(subscription, (records) => records.filter(
		(item) => item.event?.type === "message_update",
	).length === deltas.length);
	assert.deepEqual(
		deltaRecords.filter((item) => item.event?.type === "message_update")
			.map((item) => item.event.assistantMessageEvent.delta),
		deltas,
	);
	assert.equal(JSON.stringify(deltaRecords).includes(privateSentinel), false);
	assert.equal(JSON.stringify(deltaRecords).includes('"partial"'), false);
	assert.equal(JSON.stringify(deltaRecords).includes('"message":{"role":"assistant"'), false);

	const toolCalls = [
		{
			id: "tool-call-1",
			name: "lookup",
			arguments: { query: "alpha" },
			result: { content: [{ type: "text", text: "alpha result" }], details: { matchCount: 1 } },
		},
		{
			id: "tool-call-2",
			name: "calculate",
			arguments: { expression: "2 + 2" },
			result: { content: [{ type: "text", text: "4" }], details: { exact: true } },
		},
	];
	const completedAnswer = {
		role: "assistant",
		content: [
			{ type: "text", text: "I will use both tools." },
			...toolCalls.map((call) => ({
				type: "toolCall",
				id: call.id,
				name: call.name,
				arguments: call.arguments,
			})),
		],
	};
	const assistantEntry = {
		type: "message",
		id: "entry-2",
		parentId: "entry-1",
		timestamp: "2026-08-12T00:01:00Z",
		message: completedAnswer,
	};
	const toolResultEntries = toolCalls.map((call, index) => ({
		type: "message",
		id: `entry-2-tool-${index + 1}`,
		parentId: index === 0 ? assistantEntry.id : `entry-2-tool-${index}`,
		timestamp: `2026-08-12T00:01:0${index + 1}Z`,
		message: {
			role: "toolResult",
			toolCallId: call.id,
			toolName: call.name,
			content: call.result.content,
			details: call.result.details,
			isError: false,
			timestamp: 1_786_493_460_000 + index,
		},
	}));
	const beforeTurnEndPromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "message_end"
			&& item.event.message?.role === "toolResult"
			&& item.event.message.toolCallId === "tool-call-2",
	));
	// Pi invokes each extension message_end handler before appending that message
	// to SessionManager. Mirror that persistence order for the assistant tool calls
	// and both tool results; no checkpoint is safe until the enclosing turn ends.
	handlers.get("message_end")({ type: "message_end", message: completedAnswer }, context);
	entries.push(assistantEntry);
	for (let index = 0; index < toolCalls.length; index += 1) {
		const call = toolCalls[index];
		handlers.get("tool_execution_start")({
			type: "tool_execution_start",
			toolCallId: call.id,
			toolName: call.name,
			args: call.arguments,
		}, context);
		handlers.get("tool_execution_end")({
			type: "tool_execution_end",
			toolCallId: call.id,
			toolName: call.name,
			result: call.result,
			isError: false,
		}, context);
		handlers.get("message_end")({
			type: "message_end",
			message: toolResultEntries[index].message,
		}, context);
		entries.push(toolResultEntries[index]);
	}
	const beforeTurnEnd = await beforeTurnEndPromise;
	assert.equal(beforeTurnEnd.some((item) => item.kind === "snapshot"), false);
	assert.equal(beforeTurnEnd.some((item) => item.event?.type === "turn_end"), false);
	assert.deepEqual(beforeTurnEnd.filter(
		(item) => item.event?.type === "tool_execution_start" || item.event?.type === "tool_execution_end",
	).map((item) => ({
		type: item.event.type,
		toolCallId: item.event.toolCallId,
		toolName: item.event.toolName,
	})), [
		{ type: "tool_execution_start", toolCallId: "tool-call-1", toolName: "lookup" },
		{ type: "tool_execution_end", toolCallId: "tool-call-1", toolName: "lookup" },
		{ type: "tool_execution_start", toolCallId: "tool-call-2", toolName: "calculate" },
		{ type: "tool_execution_end", toolCallId: "tool-call-2", toolName: "calculate" },
	]);

	const firstDurableTurnPromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "turn_end",
	) && records.some((item) => item.kind === "snapshot"));
	handlers.get("turn_end")({ type: "turn_end", turnIndex: 1 }, context);
	const firstDurableTurn = await firstDurableTurnPromise;
	const firstTurnEndIndex = firstDurableTurn.findIndex((item) => item.event?.type === "turn_end");
	const firstCheckpointIndex = firstDurableTurn.findIndex((item) => item.kind === "snapshot");
	const firstTurnEnd = firstDurableTurn[firstTurnEndIndex];
	const firstCheckpoint = firstDurableTurn[firstCheckpointIndex];
	assert.ok(firstTurnEndIndex >= 0 && firstCheckpointIndex > firstTurnEndIndex);
	assert.equal(firstCheckpoint.sequence, firstTurnEnd.sequence);
	assert.deepEqual(firstCheckpoint.snapshot.entries.map((entry) => entry.id),
		["entry-1", "entry-2", "entry-2-tool-1", "entry-2-tool-2"]);
	assert.deepEqual(firstCheckpoint.snapshot.entries.slice(1), [assistantEntry, ...toolResultEntries]);
	assert.equal(firstCheckpoint.snapshot.state.working, true);
	assert.ok(Math.abs(firstCheckpoint.snapshot.state.cost.totalUSD - 0.035) < 1e-9);
	assert.deepEqual(firstTurnEnd.event.context, { tokens: 12_345, contextWindow: 192_000, percent: 6.43 });
	assert.ok(Math.abs(firstTurnEnd.event.cost.totalUSD - 0.035) < 1e-9);

	const belowIntervalPromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "model_select" && item.event?.source === "set",
	));
	handlers.get("turn_start")({ type: "turn_start", turnIndex: 2 }, context);
	const shortAnswer = { role: "assistant", content: [{ type: "text", text: "short answer" }] };
	handlers.get("message_start")({ type: "message_start", message: shortAnswer }, context);
	handlers.get("message_end")({ type: "message_end", message: shortAnswer }, context);
	entries.push({
		type: "message",
		id: "entry-3",
		parentId: "entry-2-tool-2",
		timestamp: "2026-08-12T00:02:00Z",
		message: shortAnswer,
	});
	handlers.get("turn_end")({ type: "turn_end", turnIndex: 2 }, context);
	handlers.get("model_select")({
		type: "model_select",
		model: availableModels[0],
		previousModel: availableModels[1],
		source: "set",
	}, context);
	const belowInterval = await belowIntervalPromise;
	assert.equal(belowInterval.some((item) => item.kind === "snapshot"), false);

	const secondDurableTurnPromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "turn_end" && item.event.turnIndex === 3,
	) && records.some((item) => item.kind === "snapshot"));
	handlers.get("turn_start")({ type: "turn_start", turnIndex: 3 }, context);
	handlers.get("message_update")({
		type: "message_update",
		assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "durable" },
	}, context);
	const finalActiveAnswer = { role: "assistant", content: [{ type: "text", text: "durable answer" }] };
	handlers.get("message_end")({ type: "message_end", message: finalActiveAnswer }, context);
	entries.push({
		type: "message",
		id: "entry-4",
		parentId: "entry-3",
		timestamp: "2026-08-12T00:03:00Z",
		message: finalActiveAnswer,
	});
	costEntries.push({
		type: "message",
		id: "cost-entry-assistant-2",
		parentId: "cost-entry-user",
		message: {
			role: "assistant",
			content: [{ type: "text", text: "durable answer" }],
			usage: {
				input: 7,
				output: 3,
				cacheRead: 2,
				cacheWrite: 1,
				totalTokens: 13,
				cost: { input: 0.003, output: 0.004, cacheRead: 0, cacheWrite: 0, total: 0.007 },
			},
		},
	});
	handlers.get("turn_end")({ type: "turn_end", turnIndex: 3 }, context);
	const secondDurableTurn = await secondDurableTurnPromise;
	const secondTurnEndIndex = secondDurableTurn.findIndex(
		(item) => item.event?.type === "turn_end" && item.event.turnIndex === 3,
	);
	const secondCheckpointIndex = secondDurableTurn.findIndex((item) => item.kind === "snapshot");
	const secondCheckpoint = secondDurableTurn[secondCheckpointIndex];
	assert.ok(secondCheckpointIndex > secondTurnEndIndex);
	assert.equal(secondCheckpoint.sequence, secondDurableTurn[secondTurnEndIndex].sequence);
	assert.deepEqual(secondCheckpoint.snapshot.entries.map((entry) => entry.id),
		["entry-1", "entry-2", "entry-2-tool-1", "entry-2-tool-2", "entry-3", "entry-4"]);
	const secondCheckpointCost = secondCheckpoint.snapshot.state.cost;
	assert.ok(Math.abs(secondCheckpointCost.totalUSD - 0.042) < 1e-9);
	assert.deepEqual({ ...secondCheckpointCost, totalUSD: 0.042 }, {
		totalUSD: 0.042,
		inputTokens: 127,
		outputTokens: 63,
		cacheReadTokens: 12,
		cacheWriteTokens: 6,
		totalTokens: 208,
		assistantTurns: 2,
	});

	idle = true;
	contextUsageValue = undefined;
	const settledCheckpoint = readRecords(subscription, (records) => records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.entries?.at(-1)?.id === "entry-4",
	));
	await handlers.get("agent_settled")({ type: "agent_settled" }, context);
	const settled = await settledCheckpoint;
	assert.ok(settled.some((item) => item.kind === "snapshot" && item.snapshot.entries.at(-1).id === "entry-4"));
	assert.deepEqual(settled.find((item) => item.kind === "snapshot").snapshot.state.context,
		{ tokens: null, contextWindow: null, percent: null },
	);

	const nativeCompactionStarted = readRecords(subscription, (records) => records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.compaction?.reason === "overflow",
	));
	handlers.get("session_before_compact")({
		type: "session_before_compact",
		reason: "overflow",
		willRetry: true,
		signal: new AbortController().signal,
		preparation: {},
		branchEntries: [],
	}, context);
	await nativeCompactionStarted;
	const nativeCompactionFinished = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "session_compact",
	) && records.some(
		(item) => (item.kind === "reset" || item.kind === "snapshot")
			&& item.snapshot?.state?.isCompacting === false,
	));
	handlers.get("session_compact")({
		type: "session_compact",
		reason: "overflow",
		willRetry: true,
		fromExtension: false,
		compactionEntry: { type: "compaction", id: "compaction-1" },
	}, context);
	await nativeCompactionFinished;

	const prompt = await connect(socketPath);
	const promptResponse = readRecords(prompt, (records) => records.some((item) => item.request_id === "prompt-1"));
	prompt.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "prompt-1",
		type: "command",
		pane_id: "w1:p1",
		command: "prompt",
		payload: { text: "Fix it" },
	})}\n`);
	assert.equal((await promptResponse)[0].success, true);
	assert.deepEqual(sent.at(-1), { text: "Fix it", options: undefined });
	prompt.destroy();

	const compact = await connect(socketPath);
	const compactResponse = readRecords(compact, (records) => records.some((item) => item.request_id === "compact-1"));
	compact.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "compact-1",
		type: "command",
		pane_id: "w1:p1",
		command: "compact",
		payload: {},
	})}\n`);
	assert.equal((await compactResponse)[0].success, true);
	assert.equal(compactCalls, 1);
	assert.equal(typeof compactOptions?.onComplete, "function");
	assert.equal(typeof compactOptions?.onError, "function");
	compact.destroy();

	const callbackCompactionStarted = readRecords(subscription, (records) => records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.compaction?.reason === "manual",
	));
	handlers.get("session_before_compact")({
		type: "session_before_compact",
		reason: "manual",
		willRetry: false,
		signal: new AbortController().signal,
		preparation: {},
		branchEntries: [],
	}, context);
	await callbackCompactionStarted;
	const blockedDuringCompaction = await connect(socketPath);
	const blockedDuringCompactionResponse = readRecords(
		blockedDuringCompaction,
		(records) => records.some((item) => item.request_id === "prompt-during-compaction"),
	);
	const sentBeforeBlockedPrompt = sent.length;
	blockedDuringCompaction.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "prompt-during-compaction",
		type: "command",
		pane_id: "w1:p1",
		command: "prompt",
		payload: { text: "Do not send yet" },
	})}\n`);
	const blockedDuringCompactionRecord = (await blockedDuringCompactionResponse)[0];
	assert.equal(blockedDuringCompactionRecord.success, false);
	assert.equal(
		blockedDuringCompactionRecord.error.message,
		"Pi is compacting context; wait for compaction to finish",
	);
	assert.equal(sent.length, sentBeforeBlockedPrompt);
	blockedDuringCompaction.destroy();
	const callbackFailurePromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "session_compact_end" && item.event.outcome === "failed",
	) && records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.isCompacting === false,
	));
	compactOptions.onError(new Error(privateSentinel));
	const callbackFailureRecords = await callbackFailurePromise;
	assert.equal(JSON.stringify(callbackFailureRecords).includes(privateSentinel), false);

	idle = false;
	const busyCompact = await connect(socketPath);
	const busyCompactResponse = readRecords(busyCompact, (records) => records.some((item) => item.request_id === "compact-busy"));
	busyCompact.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "compact-busy",
		type: "command",
		pane_id: "w1:p1",
		command: "compact",
		payload: {},
	})}\n`);
	const busyCompactRecord = (await busyCompactResponse)[0];
	assert.equal(busyCompactRecord.success, false);
	assert.equal(busyCompactRecord.error.code, "command_rejected");
	assert.equal(busyCompactRecord.error.message, "Pi is busy; wait for the current turn to finish");
	assert.equal(compactCalls, 1);
	busyCompact.destroy();

	const abort = await connect(socketPath);
	const abortResponse = readRecords(abort, (records) => records.some((item) => item.request_id === "abort-1"));
	abort.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "abort-1",
		type: "command",
		pane_id: "w1:p1",
		command: "abort",
		payload: {},
	})}\n`);
	assert.equal((await abortResponse)[0].success, true);
	assert.equal(aborted, true);
	abort.destroy();

	const listModels = await connect(socketPath);
	const listModelsResponse = readRecords(listModels, (records) => records.some((item) => item.request_id === "list-models-1"));
	listModels.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "list-models-1",
		type: "command",
		pane_id: "w1:p1",
		command: "list_models",
		payload: {},
	})}\n`);
	const listedModels = (await listModelsResponse)[0];
	assert.equal(listedModels.success, true);
	assert.equal(listedModels.result.scoped, false);
	assert.equal(listedModels.result.models.length, 2);
	for (const model of listedModels.result.models) {
		assert.equal(typeof model.provider, "string");
		assert.equal(typeof model.id, "string");
		assert.equal(typeof model.name, "string");
		assert.equal(typeof model.reasoning, "boolean");
		assert.equal(typeof model.contextWindow, "number");
	}
	assert.equal(listedModels.result.current.provider, "test");
	assert.equal(listedModels.result.current.id, "model");
	listModels.destroy();

	context.scopedModels = [{ model: availableModels[0] }];
	const scopedModels = await connect(socketPath);
	const scopedModelsResponse = readRecords(scopedModels, (records) => records.some((item) => item.request_id === "list-models-2"));
	scopedModels.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "list-models-2",
		type: "command",
		pane_id: "w1:p1",
		command: "list_models",
		payload: {},
	})}\n`);
	const listedScopedModels = (await scopedModelsResponse)[0];
	assert.equal(listedScopedModels.success, true);
	assert.equal(listedScopedModels.result.scoped, true);
	assert.equal(listedScopedModels.result.models.length, 1);
	assert.equal(listedScopedModels.result.models[0].id, "model");
	scopedModels.destroy();

	const outOfScopeModel = await connect(socketPath);
	const outOfScopeModelResponse = readRecords(outOfScopeModel, (records) => records.some((item) => item.request_id === "set-model-out-of-scope"));
	const scopedSetModelCallCount = setModelCalls.length;
	outOfScopeModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-out-of-scope",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "other", id: "other-model" },
	})}\n`);
	const outOfScopeModelRecord = (await outOfScopeModelResponse)[0];
	assert.equal(outOfScopeModelRecord.success, false);
	assert.equal(outOfScopeModelRecord.error.message, "Model is not in this session's scope");
	assert.equal(setModelCalls.length, scopedSetModelCallCount);
	outOfScopeModel.destroy();

	const inScopeModel = await connect(socketPath);
	const inScopeModelResponse = readRecords(inScopeModel, (records) => records.some((item) => item.request_id === "set-model-in-scope"));
	inScopeModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-in-scope",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "test", id: "model" },
	})}\n`);
	const inScopeModelRecord = (await inScopeModelResponse)[0];
	assert.equal(inScopeModelRecord.success, true);
	assert.equal(inScopeModelRecord.result.accepted, true);
	assert.equal(inScopeModelRecord.result.model.provider, "test");
	assert.equal(inScopeModelRecord.result.model.id, "model");
	assert.equal(setModelCalls.at(-1), availableModels[0]);
	inScopeModel.destroy();

	context.scopedModels = [];

	const setModel = await connect(socketPath);
	const setModelResponse = readRecords(setModel, (records) => records.some((item) => item.request_id === "set-model-1"));
	setModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-1",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "test", id: "model" },
	})}\n`);
	const setModelResultRecord = (await setModelResponse)[0];
	assert.equal(setModelResultRecord.success, true);
	assert.equal(setModelResultRecord.result.accepted, true);
	assert.equal(setModelResultRecord.result.command, "set_model");
	assert.equal(setModelResultRecord.result.model.provider, "test");
	assert.equal(setModelResultRecord.result.model.id, "model");
	assert.equal(setModelCalls.at(-1), availableModels[0]);
	setModel.destroy();

	const unknownModel = await connect(socketPath);
	const unknownModelResponse = readRecords(unknownModel, (records) => records.some((item) => item.request_id === "set-model-unknown"));
	const setModelCallCount = setModelCalls.length;
	unknownModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-unknown",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "nope", id: "nope" },
	})}\n`);
	const unknownModelRecord = (await unknownModelResponse)[0];
	assert.equal(unknownModelRecord.success, false);
	assert.equal(unknownModelRecord.error.message, "Unknown model");
	assert.equal(setModelCalls.length, setModelCallCount);
	unknownModel.destroy();

	setModelResult = false;
	const unavailableModel = await connect(socketPath);
	const unavailableModelResponse = readRecords(unavailableModel, (records) => records.some((item) => item.request_id === "set-model-no-credentials"));
	unavailableModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-no-credentials",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "test", id: "model" },
	})}\n`);
	const unavailableModelRecord = (await unavailableModelResponse)[0];
	assert.equal(unavailableModelRecord.success, false);
	assert.equal(unavailableModelRecord.error.message, "Model has no configured credentials");
	unavailableModel.destroy();
	setModelResult = true;

	const thinkingLevel = await connect(socketPath);
	const thinkingLevelResponse = readRecords(thinkingLevel, (records) => records.some((item) => item.request_id === "thinking-level-1"));
	thinkingLevel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "thinking-level-1",
		type: "command",
		pane_id: "w1:p1",
		command: "set_thinking_level",
		payload: { level: "high" },
	})}\n`);
	const thinkingLevelRecord = (await thinkingLevelResponse)[0];
	assert.equal(thinkingLevelRecord.success, true);
	assert.equal(thinkingLevelRecord.result.accepted, true);
	assert.equal(thinkingLevelRecord.result.command, "set_thinking_level");
	assert.equal(thinkingLevelRecord.result.level, "high");
	assert.equal(setThinkingLevelCalls.at(-1), "high");
	thinkingLevel.destroy();

	effectiveThinkingLevel = "medium";
	const clampedThinkingLevel = await connect(socketPath);
	const clampedThinkingLevelResponse = readRecords(clampedThinkingLevel, (records) => records.some((item) => item.request_id === "thinking-level-clamped"));
	clampedThinkingLevel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "thinking-level-clamped",
		type: "command",
		pane_id: "w1:p1",
		command: "set_thinking_level",
		payload: { level: "max" },
	})}\n`);
	const clampedThinkingLevelRecord = (await clampedThinkingLevelResponse)[0];
	assert.equal(clampedThinkingLevelRecord.success, true);
	assert.equal(clampedThinkingLevelRecord.result.level, "medium");
	assert.equal(setThinkingLevelCalls.at(-1), "max");
	clampedThinkingLevel.destroy();
	effectiveThinkingLevel = "high";

	const unknownThinkingLevel = await connect(socketPath);
	const unknownThinkingLevelResponse = readRecords(unknownThinkingLevel, (records) => records.some((item) => item.request_id === "thinking-level-unknown"));
	const setThinkingLevelCallCount = setThinkingLevelCalls.length;
	unknownThinkingLevel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "thinking-level-unknown",
		type: "command",
		pane_id: "w1:p1",
		command: "set_thinking_level",
		payload: { level: "ultra" },
	})}\n`);
	const unknownThinkingLevelRecord = (await unknownThinkingLevelResponse)[0];
	assert.equal(unknownThinkingLevelRecord.success, false);
	assert.equal(unknownThinkingLevelRecord.error.message, "Unknown thinking level");
	assert.equal(setThinkingLevelCalls.length, setThinkingLevelCallCount);
	unknownThinkingLevel.destroy();

	idle = true;
	const settledCompactionStarted = readRecords(subscription, (records) => records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.compaction?.reason === "threshold",
	));
	handlers.get("session_before_compact")({
		type: "session_before_compact",
		reason: "threshold",
		willRetry: false,
		signal: new AbortController().signal,
		preparation: {},
		branchEntries: [],
	}, context);
	await settledCompactionStarted;
	const settledCompactionFinished = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "session_compact_end" && item.event.outcome === "settled",
	));
	handlers.get("agent_settled")({ type: "agent_settled" }, context);
	await settledCompactionFinished;

	const recoveryCompactionStarted = readRecords(subscription, (records) => records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.compaction?.reason === "manual",
	));
	handlers.get("session_before_compact")({
		type: "session_before_compact",
		reason: "manual",
		willRetry: false,
		signal: new AbortController().signal,
		preparation: {},
		branchEntries: [],
	}, context);
	await recoveryCompactionStarted;

	// Do not guess that a slow compaction ended based on wall-clock time. Pi
	// 0.84.1 can legitimately spend minutes retrying a summarization request.
	await delay(300);
	const slowCompactionProbe = await connect(socketPath);
	const slowCompactionSnapshotPromise = readRecords(
		slowCompactionProbe,
		(records) => records.some((item) => item.kind === "snapshot"),
	);
	slowCompactionProbe.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "slow-compaction-probe",
		type: "subscribe",
		pane_id: "w1:p1",
		after: 0,
	})}\n`);
	const slowCompactionSnapshot = (await slowCompactionSnapshotPromise)
		.find((item) => item.kind === "snapshot").snapshot;
	assert.equal(slowCompactionSnapshot.state.isCompacting, true);
	slowCompactionProbe.destroy();

	// After a failed manual /compact, Pi only emits its private compaction_end.
	// The next accepted input is the first public proof that compaction ended.
	const recoveredCompactionPromise = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "session_compact_end" && item.event.outcome === "settled",
	) && records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.state?.isCompacting === false,
	));
	const inputResult = await handlers.get("input")({
		type: "input",
		text: privateSentinel,
		source: "interactive",
	}, context);
	assert.deepEqual(inputResult, { action: "continue" });
	const recoveredCompactionRecords = await recoveredCompactionPromise;
	assert.equal(JSON.stringify(recoveredCompactionRecords).includes(privateSentinel), false);

	// Regression: a client that vanishes mid-command must never take down Pi.
	// Hold the async set_model open until the client's fd is fully closed, so
	// respond() deterministically writes into a dead unix socket (EPIPE).
	// Without the socket "error" handler this crashes the whole process.
	let releaseSetModel;
	const originalSetModel = pi.setModel;
	pi.setModel = async (model) => {
		setModelCalls.push(model);
		await new Promise((resolve) => { releaseSetModel = resolve; });
		return true;
	};
	const vanishing = await connect(socketPath);
	vanishing.on("error", () => {});
	vanishing.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "vanishing-set-model",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "test", id: "model" },
	})}\n`);
	for (let attempt = 0; attempt < 200 && !releaseSetModel; attempt += 1) await delay(10);
	assert.ok(releaseSetModel, "bridge never reached setModel for the vanishing client");
	vanishing.destroy();
	releaseSetModel();
	await delay(80);
	pi.setModel = originalSetModel;
	// The bridge must still be alive and serving fresh subscribers.
	const survivor = await connect(socketPath);
	const survivorSnapshotPromise = readRecords(survivor, (records) => records.some((item) => item.kind === "snapshot"));
	survivor.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "survivor-subscribe",
		type: "subscribe",
		pane_id: "w1:p1",
		after: 0,
	})}\n`);
	assert.ok((await survivorSnapshotPromise).some((item) => item.kind === "snapshot"));
	survivor.destroy();

	const shutdownRecord = readRecords(subscription, (records) => {
		const shutdown = records.find((item) => item.event?.type === "session_shutdown");
		return Boolean(shutdown && records.some(
			(item) => item.kind === "snapshot" && item.sequence === shutdown.sequence,
		));
	});
	await handlers.get("session_shutdown")({ type: "session_shutdown", reason: "quit" }, context);
	const shutdownRecords = await shutdownRecord;
	const shutdownEventIndex = shutdownRecords.findIndex((item) => item.event?.type === "session_shutdown");
	const shutdownCheckpointIndex = shutdownRecords.findIndex(
		(item) => item.kind === "snapshot" && item.sequence === shutdownRecords[shutdownEventIndex].sequence,
	);
	assert.ok(shutdownCheckpointIndex > shutdownEventIndex);
	assert.equal(shutdownRecords[shutdownEventIndex].event.reason, "quit");
	assert.equal(shutdownRecords[shutdownCheckpointIndex].snapshot.entries.at(-1).id, "entry-4");
	assert.equal(existsSync(socketPath), false);
	subscription.destroy();
} finally {
	rmSync(temporary, { recursive: true, force: true });
}

console.log("Pi semantic extension protocol tests passed");
