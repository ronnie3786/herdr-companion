import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { createJiti } from "jiti";

const lineagePath = fileURLToPath(new URL("../lib/session-lineage.ts", import.meta.url));
const lineage = await createJiti(import.meta.url).import(lineagePath);
const metadata = (id, parent) => ({
	type: "custom", customType: lineage.LINEAGE_ENTRY_TYPE,
	data: { version: 1, session_id: id, parent_session_id: parent },
});

function fixture({ id = "child-session", parentFile, entries = [], environment = {}, flag } = {}) {
	const handlers = new Map();
	const commands = new Map();
	const notices = [];
	const context = {
		ui: { notify: (...args) => notices.push(args) },
		sessionManager: {
			getSessionId: () => id,
			getHeader: () => ({ type: "session", id, parentSession: parentFile }),
			getEntries: () => entries,
		},
	};
	const callbacks = lineage.registerSessionLineage({
		on: (name, handler) => handlers.set(name, handler),
		registerCommand: (name, command) => commands.set(name, command),
		registerFlag: (name, options) => {
			assert.equal(name, "herdr-parent-session-id");
			assert.equal(options.type, "string");
		},
		getFlag: () => flag,
		appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
	}, environment);
	return {
		context, entries, environment, notices, callbacks,
		start: (reason = "startup", previousSessionFile) => handlers.get("session_start")({ reason, previousSessionFile }, context),
		parent: () => lineage.savedParentSessionId(context.sessionManager),
		command: (args) => commands.get("herdr-parent").handler(args, context),
		prompt: () => handlers.get("before_agent_start")({ systemPrompt: "Original prompt" }, context).systemPrompt,
	};
}

test("fresh children inherit their parent, while grandchildren inherit the child", () => {
	const environment = { HERDR_PI_PARENT_SESSION_ID: "parent-session" };
	const child = fixture({ environment, entries: [{ type: "model_change" }, { type: "thinking_level_change" }] });
	child.start();
	assert.equal(child.parent(), "parent-session");
	assert.equal(environment.HERDR_PI_SESSION_ID, "child-session");
	assert.equal(environment.HERDR_PI_PARENT_SESSION_ID, "child-session");
	const grandchild = fixture({ id: "grandchild-session", environment: { ...environment } });
	grandchild.start();
	assert.equal(grandchild.parent(), "child-session");
});

test("roots and resumed sessions retain explicit null or saved ancestry despite inherited environment and flags", () => {
	for (const parent of [null, "original-parent"]) {
		for (const reason of ["startup", "reload", "resume"]) {
			const session = fixture({
				entries: [metadata("child-session", parent)],
				environment: { HERDR_PI_PARENT_SESSION_ID: "unrelated-session" }, flag: "another-session",
			});
			session.start(reason);
			assert.equal(session.parent(), parent);
			assert.equal(session.entries.length, 1);
		}
	}
});

test("existing untagged history never acquires an ambient parent during startup, resume, or reload", () => {
	for (const reason of ["startup", "resume", "reload"]) {
		const session = fixture({
			entries: [{ type: "message", parentId: "transcript-entry", message: { role: "user" } }],
			environment: { HERDR_PI_PARENT_SESSION_ID: "unrelated-session" },
		});
		session.start(reason);
		assert.equal(session.parent(), null);
	}
});

test("new sessions in the same process start independent roots and rebind inherited IDs", () => {
	const environment = { HERDR_PI_SESSION_ID: "previous-session", HERDR_PI_PARENT_SESSION_ID: "previous-session" };
	const session = fixture({ environment, flag: "initial-launch-parent" });
	session.start("new");
	assert.equal(session.parent(), null);
	assert.equal(environment.HERDR_PI_PARENT_SESSION_ID, "child-session");
});

test("explicit startup flags tag untagged history and none suppresses inheritance", () => {
	const history = fixture({ flag: "explicit-parent", entries: [{ type: "message" }] });
	history.start();
	assert.equal(history.parent(), "explicit-parent");
	const root = fixture({ flag: "none", environment: { HERDR_PI_PARENT_SESSION_ID: "ambient-parent" } });
	root.start();
	assert.equal(root.parent(), null);
});

test("native forks read the source header ID and ignore copied grandparent metadata", () => {
	const directory = mkdtempSync(join(tmpdir(), "herdr-lineage-fork-"));
	try {
		const source = join(directory, "arbitrary-session-file.jsonl");
		writeFileSync(source, `${JSON.stringify({ type: "session", id: "actual-source", parentSession: "/not-the-parent-id" })}\n`);
		for (const reason of ["startup", "fork", "reload"]) {
			const session = fixture({
				parentFile: source, entries: [metadata("actual-source", "grandparent-session")],
				environment: { HERDR_PI_PARENT_SESSION_ID: "ambient-session" },
			});
			session.start(reason);
			assert.equal(session.parent(), "actual-source");
		}
	} finally { rmSync(directory, { recursive: true, force: true }); }
});

test("fork identity survives a missing source file and supports an in-memory native fork", () => {
	const copied = fixture({ parentFile: "/missing-source.jsonl", entries: [metadata("actual-source", "grandparent")] });
	copied.start();
	assert.equal(copied.parent(), "actual-source");
	const inMemory = fixture({ environment: { HERDR_PI_SESSION_ID: "in-memory-source" } });
	inMemory.start("fork");
	assert.equal(inMemory.parent(), "in-memory-source");
});

test("malformed IDs, transcript IDs with punctuation, and self-parenting fail closed", async () => {
	for (const value of ["child-session", "../parent", "-option", "with space", "x\ny", "x;cmd", "x".repeat(257), "trailing-"]) {
		const session = fixture({ environment: { HERDR_PI_PARENT_SESSION_ID: value } });
		session.start();
		assert.equal(session.parent(), null);
		assert.equal(session.notices[0][1], "warning");
		const count = session.entries.length;
		await session.command(value);
		assert.equal(session.entries.length, count);
	}
	for (const value of ["a", "a-b.c_d", "01983f81-b27e-7245-9011-bba0872a2510"]) assert.ok(lineage.validSessionId(value));
});

test("parent corrections checkpoint immediately, survive branch navigation and reload, and support detaching", async () => {
	const session = fixture();
	session.start();
	let checkpoints = 0;
	session.callbacks.onChange = () => { checkpoints += 1; };
	await session.command("correct-parent");
	assert.equal(session.parent(), "correct-parent");
	assert.equal(checkpoints, 1);
	// getEntries, not getBranch, remains authoritative after tree navigation.
	session.context.sessionManager.getBranch = () => [metadata("child-session", null)];
	assert.equal(session.parent(), "correct-parent");
	const resumed = fixture({ entries: session.entries, environment: { HERDR_PI_PARENT_SESSION_ID: "stale-parent" } });
	resumed.start("reload");
	assert.equal(resumed.parent(), "correct-parent");
	await resumed.command("none");
	assert.equal(resumed.parent(), null);
	await resumed.command("");
	assert.match(resumed.notices.at(-1)[0], /Pi session: child-session\nParent: none/);
});

test("every agent turn knows its current ID and explicit remote/API spawn contract", () => {
	const session = fixture({ flag: "parent-session" });
	session.start();
	const prompt = session.prompt();
	assert.match(prompt, /^Original prompt\n\nHerdr Pi session identity: child-session/);
	assert.match(prompt, /--herdr-parent-session-id child-session/);
	assert.match(prompt, /parentSessionId: "child-session"/);
	assert.match(prompt, /SSH does not normally forward environment variables/);
	assert.match(prompt, /resuming a session preserves its existing parent/);
});

test("a real subprocess in another workspace inherits its parent's session ID", () => {
	const directory = mkdtempSync(join(tmpdir(), "herdr-lineage-spawn-"));
	try {
		const otherWorkspace = join(directory, "other-workspace");
		mkdirSync(otherWorkspace);
		const parent = fixture({ id: "parent-session" });
		parent.start();
		const child = spawnSync(process.execPath, ["--input-type=module", "-e", `
			const { createJiti } = await import(process.argv[1]);
			const { registerSessionLineage, savedParentSessionId } = await createJiti(import.meta.url).import(process.argv[2]);
			const entries = [], handlers = new Map();
			const manager = { getSessionId: () => "spawned-child", getEntries: () => entries, getHeader: () => ({}) };
			registerSessionLineage({
				on: (type, handler) => handlers.set(type, handler), registerFlag() {}, registerCommand() {}, getFlag() {},
				appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
			});
			handlers.get("session_start")({ reason: "startup" }, { sessionManager: manager, ui: { notify() {} } });
			process.stdout.write(JSON.stringify({ parent: savedParentSessionId(manager), nextParent: process.env.HERDR_PI_PARENT_SESSION_ID, cwd: process.cwd() }));
		`, import.meta.resolve("jiti"), lineagePath], {
			cwd: otherWorkspace, env: { ...process.env, ...parent.environment }, encoding: "utf8",
		});
		assert.equal(child.status, 0, child.stderr);
		assert.deepEqual(JSON.parse(child.stdout), { parent: "parent-session", nextParent: "spawned-child", cwd: realpathSync(otherWorkspace) });
	} finally { rmSync(directory, { recursive: true, force: true }); }
});
