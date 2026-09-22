import { createJiti } from "jiti";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const jiti = createJiti(import.meta.url);
const {
  COMPANION_AWARENESS_MARKER,
  appendCompanionAwareness,
  bundledAgentDocsRoot,
  companionAwarenessInstructions,
  companionSurface,
} = await jiti.import("../lib/companion-awareness.ts");
const { createCompanionAwarenessExtension } = await jiti.import("../extensions/companion-awareness.ts");

const docsRoot = bundledAgentDocsRoot();

function words(value) {
  return value.trim().split(/\s+/u).length;
}

test("only known nonempty Companion runtime hints select a surface", () => {
  assert.equal(companionSurface({}), undefined);
  assert.equal(companionSurface({HERDR_PANE_ID:"  ", HERDR_AGENT_RUN_ID:""}), undefined);
  assert.equal(companionSurface({HERDR_PANE_ID:"w1:p1"}), "pane");
  assert.equal(companionSurface({HERDR_AGENT_RUN_ID:"agr_000000000001", HERDR_AGENT_RUN_PROFILE:"hud-chat-v1"}), "hud");
  assert.equal(companionSurface({HERDR_AGENT_RUN_ID:"agr_000000000002", HERDR_AGENT_RUN_MODE:"ask"}), "agent-run");
  for (const profile of ["contextual-question-v1", "pr-review-question-v1", "response-brief-v1", "smart-rename-v1"]) {
    assert.equal(companionSurface({HERDR_AGENT_RUN_ID:"agr_000000000003", HERDR_AGENT_RUN_PROFILE:profile}), undefined);
  }
  assert.equal(companionSurface({
    HERDR_PANE_ID:"stale-pane",
    HERDR_AGENT_RUN_ID:"agr_000000000004",
    HERDR_AGENT_RUN_PROFILE:"contextual-question-v1",
  }), undefined);
  assert.equal(companionSurface({HERDR_PANE_ID:"w1:p1", HERDR_FIRST_MATE_MANAGED_ROLE:"worker"}), undefined);
});

test("pane, HUD, and headless bootstraps are bounded and accurately distinct", () => {
  const cases = [
    [{HERDR_PANE_ID:"w1:p1"}, /managed workspace chat/],
    [{HERDR_AGENT_RUN_ID:"agr_000000000001",HERDR_AGENT_RUN_PROFILE:"hud-chat-v1"}, /independent saved HUD chat/],
    [{HERDR_AGENT_RUN_ID:"agr_000000000002",HERDR_AGENT_RUN_MODE:"act"}, /ACT charter remains authoritative/],
  ];
  for (const [environment, expected] of cases) {
    const value = companionAwarenessInstructions(environment, docsRoot);
    assert.match(value, expected);
    assert.match(value, /You are a Pi agent running in Herdr Companion/);
    assert.ok(words(value) >= 150 && words(value) <= 220, words(value));
    assert.ok(value.includes(`${docsRoot}/overview.md`));
    assert.ok(value.includes(`${docsRoot}/first-mate.md`));
    assert.doesNotMatch(value, /DESKTOP_HERDR_TOKEN|captured conversation|# Herdr Companion agent overview/);
  }
});

test("external Pi remains silent and missing, partial, or non-file guides are never advertised", () => {
  assert.equal(companionAwarenessInstructions({}, docsRoot), undefined);
  const root = mkdtempSync(join(tmpdir(), "herdr-awareness-docs-"));
  try {
    assert.equal(companionAwarenessInstructions({HERDR_PANE_ID:"w1:p1"}, join(root, "missing")), undefined);
    writeFileSync(join(root, "overview.md"), "# Synthetic overview\n");
    assert.equal(companionAwarenessInstructions({HERDR_PANE_ID:"w1:p1"}, root), undefined);
    for (const name of ["control.md", "first-mate.md"]) writeFileSync(join(root, name), `# ${name}\n`);
    mkdirSync(join(root, "api.md"));
    assert.doesNotThrow(() => companionAwarenessInstructions({HERDR_PANE_ID:"w1:p1"}, root));
    assert.equal(companionAwarenessInstructions({HERDR_PANE_ID:"w1:p1"}, root), undefined);
  } finally {
    rmSync(root, {recursive:true, force:true});
  }
});

test("append preserves the chained prompt and marker makes it idempotent", () => {
  const instructions = companionAwarenessInstructions({HERDR_PANE_ID:"w1:p1"}, docsRoot);
  const once = appendCompanionAwareness("original system prompt", instructions);
  assert.ok(once.startsWith("original system prompt\n\n"));
  assert.equal(once.split(COMPANION_AWARENESS_MARKER).length - 1, 1);
  assert.equal(appendCompanionAwareness(once, instructions), once);
});

test("extension evaluates and injects on every agent turn", () => {
  const handlers = new Map();
  createCompanionAwarenessExtension({HERDR_PANE_ID:"w1:p1"})({on(name, handler) { handlers.set(name, handler); }});
  const handler = handlers.get("before_agent_start");
  const first = handler({systemPrompt:"turn one"});
  const resumed = handler({systemPrompt:"turn after resume"});
  assert.match(first.systemPrompt, /turn one/);
  assert.match(resumed.systemPrompt, /turn after resume/);
  assert.equal(first.systemPrompt.split(COMPANION_AWARENESS_MARKER).length - 1, 1);
  assert.equal(handler({systemPrompt:first.systemPrompt}), undefined);
});
