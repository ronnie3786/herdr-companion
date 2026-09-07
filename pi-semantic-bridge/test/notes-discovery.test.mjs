import { createJiti } from "jiti";
import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

const extension = await createJiti(import.meta.url).import("../extensions/notes-discovery.ts");

test("notes discovery is scoped to Herdr sessions and explains conflict handling", () => {
	assert.equal(extension.notesInstructions({}), undefined);
	for (const environment of [{ HERDR_PANE_ID: "w1:p1" }, { HERDR_AGENT_RUN_ID: "agr_123" }]) {
		const instructions = extension.notesInstructions(environment);
		assert.match(instructions, /herdr-notes get/);
		assert.match(instructions, /--expected-revision/);
		assert.match(instructions, /never blindly overwrite/);
		assert.match(instructions, /only when requested/);
	}
});

test("registered hook preserves the session system prompt without reading notes", () => {
	let handler;
	extension.default({ on(name, callback) { assert.equal(name, "before_agent_start"); handler = callback; } });
	const prior = process.env.HERDR_PANE_ID;
	try {
		process.env.HERDR_PANE_ID = "w1:p1";
		assert.match(handler({ systemPrompt: "Original instructions" }).systemPrompt, /^Original instructions\n\nHerdr notes/);
	} finally {
		if (prior === undefined) delete process.env.HERDR_PANE_ID;
		else process.env.HERDR_PANE_ID = prior;
	}
});
