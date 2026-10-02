import { createJiti } from "jiti";
import assert from "node:assert/strict";
import test from "node:test";

const extension = await createJiti(import.meta.url).import("../extensions/watchers-discovery.ts");
test("Watchers discovery covers pane, agent run and lead without granting activation", () => {
	assert.equal(extension.watchersInstructions({}), undefined);
	for (const environment of [{ HERDR_PANE_ID: "pane_synthetic" }, { HERDR_AGENT_RUN_ID: "agr_synthetic" }, { HERDR_FIRST_MATE_MANAGED_ROLE: "lead" }]) {
		const text = extension.watchersInstructions(environment);
		assert.match(text, /herdr-watchers schema/);
		assert.match(text, /ask for clarification/);
		assert.match(text, /Never activate or resume/);
		assert.match(text, /turn Watchers on or off/);
		assert.match(text, /dry-run executes scripts/);
	}
});
test("restricted profiles receive no scheduling tool discovery", () => {
	assert.equal(extension.watchersInstructions({ HERDR_AGENT_RUN_ID: "agr_example", HERDR_AGENT_RUN_PROFILE: "smart-rename-v1" }), undefined);
});
