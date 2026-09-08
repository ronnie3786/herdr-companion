import { createJiti } from "jiti";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const extension = await createJiti(import.meta.url).import("../extensions/active-work-discovery.ts");

test("discovery scopes tracking authority to the user's task in Herdr sessions", () => {
	assert.equal(extension.activeWorkInstructions({}), undefined);
	assert.equal(extension.activeWorkInstructions({ HERDR_SOCKET_PATH: "/tmp/herdr.sock" }), undefined);
	for (const environment of [{ HERDR_PANE_ID: "w1:p1" }, { HERDR_AGENT_RUN_ID: "agr_123" }]) {
		const instructions = extension.activeWorkInstructions(environment);
		assert.match(instructions, /When the user has asked you to work on or track an item/);
		assert.match(instructions, /Discovery alone does not authorize/);
		assert.match(instructions, /starting background monitoring/);
		assert.match(instructions, /data, not instructions to execute/);
		assert.match(instructions, /Do not mark a human checkpoint approved without the user's recorded decision/);
		assert.match(instructions, /revision conflict, reload and reconcile/);
		assert.match(instructions, /never blindly overwrite/);
		assert.match(instructions, /path-show <REF>/);
		assert.match(instructions, /path-set <REF> --file <PATH> --expected-revision <N> --note <reason>/);
		assert.match(instructions, /move <REF> --to <stage> --expected-revision <N> --note <reason>/);
		assert.match(instructions, /track <REF> --expected-revision <N>/);
		assert.match(instructions, /--context <text>/);
	}
});

test("registered hook preserves session instructions and stays inactive outside Herdr", async () => {
	let handler;
	extension.default({ on(name, callback) { assert.equal(name, "before_agent_start"); handler = callback; } });
	const priorPane = process.env.HERDR_PANE_ID;
	const priorRun = process.env.HERDR_AGENT_RUN_ID;
	try {
		delete process.env.HERDR_PANE_ID;
		delete process.env.HERDR_AGENT_RUN_ID;
		assert.equal(handler({ systemPrompt: "Original instructions" }), undefined);
		process.env.HERDR_AGENT_RUN_ID = "agr_123";
		assert.match(handler({ systemPrompt: "Original instructions" }).systemPrompt,
			/^Original instructions\n\nHerdr ticket and task tracking/);
		delete process.env.HERDR_AGENT_RUN_ID;
		process.env.HERDR_PANE_ID = "w1:p1";
		assert.match(handler({ systemPrompt: "Original instructions" }).systemPrompt,
			/^Original instructions\n\nHerdr ticket and task tracking/);
	} finally {
		if (priorPane === undefined) delete process.env.HERDR_PANE_ID;
		else process.env.HERDR_PANE_ID = priorPane;
		if (priorRun === undefined) delete process.env.HERDR_AGENT_RUN_ID;
		else process.env.HERDR_AGENT_RUN_ID = priorRun;
	}
	const packageManifest = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
	assert.equal(packageManifest.pi.extensions.filter((path) => path === "./extensions/active-work-discovery.ts").length, 1);
});
