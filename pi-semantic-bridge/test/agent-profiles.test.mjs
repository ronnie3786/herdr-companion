import { createJiti } from "jiti";
import assert from "node:assert/strict";
import test from "node:test";
const jiti = createJiti(import.meta.url);
const { createAgentProfilesExtension, profileEligible, PROFILE_MARKER, fetchProfile } = await jiti.import("../extensions/agent-profiles.ts");
const pane = { HERDR_PANE_ID: "w1:p1" };
const saved = { prompt: `${PROFILE_MARKER}\nSynthetic preferences`, binding: { revision: 1 } };

function harness(load) {
  const handlers = new Map(), entries = [];
  createAgentProfilesExtension(pane, load)({ on(name, fn) { handlers.set(name, fn); }, appendEntry(type, data) { entries.push({ type: "custom", customType: type, data }); } });
  return { handlers, entries, start() { handlers.get("session_start")({}, { sessionManager: { getBranch: () => entries } }); } };
}

test("only pane conversations load; managed jobs and restricted profiles never discover personal context", () => {
  assert.equal(profileEligible(pane), true);
  for (const env of [{}, { ...pane, HERDR_FIRST_MATE_MANAGED_ROLE: "worker" }, { ...pane, HERDR_AGENT_RUN_ID: "agr_000000000001" },
    { ...pane, HERDR_AGENT_RUN_PROFILE: "response-brief-v1" }]) assert.equal(profileEligible(env), false);
});

test("profile stays pinned through turns, compaction branch entries and reload; injection deduplicates", async () => {
  let calls = 0;
  const h = harness(async () => { calls++; return saved; });
  h.start();
  const before = h.handlers.get("before_agent_start");
  const first = await before({ systemPrompt: "AGENTS rules" });
  assert.equal(first.systemPrompt, "AGENTS rules\n\n" + saved.prompt);
  await before({ systemPrompt: "AGENTS rules" });
  h.start();
  await before({ systemPrompt: "After reload" });
  assert.equal(calls, 1);
  assert.equal(h.entries.length, 1);
  assert.equal(await before({ systemPrompt: first.systemPrompt }), undefined);
});

test("unavailable backend does not pin invented defaults; successful empty binding does pin", async () => {
  let calls = 0;
  const h = harness(async () => ++calls === 1 ? undefined : { prompt: "" });
  h.start();
  const before = h.handlers.get("before_agent_start");
  await before({ systemPrompt: "base" });
  assert.equal(h.entries.length, 0);
  await before({ systemPrompt: "base" });
  await before({ systemPrompt: "base" });
  assert.equal(calls, 2);
  assert.equal(h.entries.length, 1);
});

test("switching to another branch/session never retains a previous profile in memory", async () => {
  let value = saved;
  const h = harness(async () => value);
  h.start();
  await h.handlers.get("before_agent_start")({ systemPrompt: "base" });
  h.entries.splice(0);
  value = { prompt: `${PROFILE_MARKER}\nDifferent` };
  h.start();
  assert.match((await h.handlers.get("before_agent_start")({ systemPrompt: "base" })).systemPrompt, /Different/);
});

test("transport is bounded, authenticated, no-redirect, and quiet for missing credentials", async () => {
  const original = globalThis.fetch;
  try {
    let options;
    globalThis.fetch = async (_url, init) => { options = init; return new Response(JSON.stringify({ ok: true, effective: saved })); };
    const env = { HERDR_HARNESS_URL: "http://127.0.0.1:9092", HERDR_HARNESS_API_TOKEN: "synthetic-token" };
    assert.deepEqual(await fetchProfile(env), saved);
    assert.equal(options.redirect, "error");
    assert.equal(options.headers.Authorization, "Bearer synthetic-token");
    globalThis.fetch = async () => new Response("x".repeat(256 * 1024 + 1));
    assert.equal(await fetchProfile(env), undefined);
    assert.equal(await fetchProfile({}), undefined);
  } finally { globalThis.fetch = original; }
});
