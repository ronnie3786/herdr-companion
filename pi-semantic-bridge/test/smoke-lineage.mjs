// No provider requests: exercise the installed Pi runtime using RPC extension
// commands and entirely synthetic saved sessions. This is opt-in because Pi
// itself is an optional peer dependency.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const extensionPath = process.argv[2] ? resolve(process.argv[2])
	: fileURLToPath(new URL("../extensions/pi-semantic-bridge.ts", import.meta.url));
const piBinary = process.argv[3] ?? "pi";
const directory = mkdtempSync(join(tmpdir(), "herdr-pi-lineage-smoke-"));
const agentDir = join(directory, "config");
const sourceWorkspace = join(directory, "source-workspace");
const targetWorkspace = join(directory, "other-workspace");
const sessionsDir = join(directory, "sessions");
for (const path of [agentDir, sourceWorkspace, targetWorkspace, sessionsDir]) mkdirSync(path);
const sourceId = `smoke-${randomUUID()}`;
const parentId = `parent-${randomUUID()}`;
const sourceFile = join(sessionsDir, "synthetic-source.jsonl");
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
writeFileSync(sourceFile, [
	{ type: "session", version: 3, id: sourceId, timestamp: new Date().toISOString(), cwd: sourceWorkspace },
	{ type: "message", id: "aabbccdd", parentId: null, timestamp: new Date().toISOString(),
		message: { role: "assistant", content: [{ type: "text", text: "Synthetic lineage verification fixture." }],
			api: "openai-completions", provider: "openai", model: "gpt-4o-mini", usage, stopReason: "stop", timestamp: Date.now() } },
].map((entry) => JSON.stringify(entry)).join("\n") + "\n");

async function withPi(args, parent, verify) {
	const records = [];
	const waiting = new Set();
	const child = spawn(piBinary, ["--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-tools",
		"--extension", extensionPath, "--session-dir", sessionsDir, ...args], {
		cwd: targetWorkspace,
		env: { PATH: process.env.PATH, PI_CODING_AGENT_DIR: agentDir, HERDR_PI_PARENT_SESSION_ID: parent },
		stdio: ["pipe", "pipe", "pipe"],
	});
	let stderr = "";
	child.stderr.on("data", (chunk) => { stderr += chunk; });
	const exited = new Promise((done) => child.once("exit", done));
	const lines = createInterface({ input: child.stdout });
	lines.on("line", (line) => {
		try {
			const record = JSON.parse(line);
			records.push(record);
			for (const check of waiting) check();
		} catch { /* Pi startup text is not an RPC record. */ }
	});
	function waitFor(predicate, after = 0) {
		return new Promise((done, reject) => {
			const timer = setTimeout(() => { waiting.delete(check); reject(new Error(`Pi RPC verification timed out: ${stderr}`)); }, 15_000);
			const check = () => {
				const match = records.slice(after).find(predicate);
				if (match) { clearTimeout(timer); waiting.delete(check); done(match); }
			};
			waiting.add(check);
			check();
		});
	}
	async function request(type, fields = {}) {
		const id = randomUUID();
		const response = waitFor((record) => record.type === "response" && record.id === id);
		child.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n");
		const result = await response;
		assert.equal(result.success, true, result.error);
		return result.data;
	}
	async function lineage(args = "") {
		const notification = waitFor((record) => record.type === "extension_ui_request" && record.method === "notify"
			&& record.message?.startsWith("Pi session:"), records.length);
		await request("prompt", { message: `/herdr-parent${args ? ` ${args}` : ""}` });
		return (await notification).message;
	}
	try {
		const commands = await request("get_commands");
		assert.ok(commands.commands.some((command) => command.name === "herdr-parent"));
		await verify({ request, lineage });
		assert.deepEqual(records.filter((record) => record.type === "extension_error"), []);
		assert.equal(records.some((record) => record.type === "agent_start"), false, "Smoke test must never invoke the model");
	} finally {
		child.kill("SIGTERM");
		await exited;
		lines.close();
	}
}

try {
	await withPi(["--session", sourceFile, "--herdr-parent-session-id", parentId], "unrelated-parent", async ({ lineage, request }) => {
		assert.equal(await lineage(), `Pi session: ${sourceId}\nParent: ${parentId}`);
		assert.equal((await request("get_state")).sessionId, sourceId);
	});
	const persisted = readFileSync(sourceFile, "utf8").trim().split("\n").map((line) => JSON.parse(line))
		.find((entry) => entry.customType === "herdr.session-lineage");
	assert.deepEqual(persisted.data, { version: 1, session_id: sourceId, parent_session_id: parentId });
	await withPi(["--session", sourceFile], "stale-parent", async ({ lineage, request }) => {
		assert.equal(await lineage(), `Pi session: ${sourceId}\nParent: ${parentId}`);
		await request("new_session");
		const next = await request("get_state");
		assert.notEqual(next.sessionId, sourceId);
		assert.equal(await lineage(), `Pi session: ${next.sessionId}\nParent: none`);
	});
	const forkId = `fork-${randomUUID()}`;
	await withPi(["--fork", sourceFile, "--session-id", forkId], "unrelated-parent", async ({ lineage }) => {
		assert.equal(await lineage(), `Pi session: ${forkId}\nParent: ${sourceId}`);
	});
	const freshId = `fresh-${randomUUID()}`;
	await withPi(["--session-id", freshId], parentId, async ({ lineage }) => {
		assert.equal(await lineage(), `Pi session: ${freshId}\nParent: ${parentId}`);
		assert.equal(await lineage("none"), `Pi session: ${freshId}\nParent: none`);
	});
	console.log("Pi lineage RPC smoke passed: registration, native persistence, resume, new-session isolation, cross-workspace fork, inherited parent, and detachment. No model requests.");
} finally {
	rmSync(directory, { recursive: true, force: true });
}
