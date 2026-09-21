import { createJiti } from "jiti";
import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const jiti = createJiti(import.meta.url);
const { createFirstMateExtension, spoolRequestId } = await jiti.import("../extensions/first-mate.ts");

function fixture(role = "worker", overrides = {}) {
  const root = mkdtempSync(join(tmpdir(), "herdr-first-mate-extension-"));
  const job = { id: "synthetic-job", kind: role, ...overrides };
  writeFileSync(join(root, "job.json"), JSON.stringify(job));
  const tools = new Map(), handlers = new Map(), messages = [];
  const pi = { registerTool(t) { tools.set(t.name, t); }, on(name, fn) { handlers.set(name,fn); }, sendUserMessage(...args) { messages.push(args); } };
  createFirstMateExtension({ HERDR_FIRST_MATE_JOB_DIR: root, HERDR_FIRST_MATE_ROLE: role, HERDR_FIRST_MATE_CONTEXT_TARGET: "150000" })(pi);
  const ctx = { sessionManager: { getSessionId: () => "native-synthetic", getSessionFile: () => join(root,"session.jsonl") }, getContextUsage: () => ({tokens:150001,contextWindow:200000}) };
  return { root, tools, handlers, messages, ctx, cleanup: () => rmSync(root,{recursive:true,force:true}) };
}

test("ordinary Pi sessions gain no First Mate tools", () => {
  createFirstMateExtension({})({registerTool() { assert.fail("unexpected tool"); }});
});

test("coordinator exposes only asynchronous orchestration and cannot execute commands", () => {
  const f = fixture("coordinator");
  try {
    assert.ok(f.tools.has("fm_status"));
    assert.ok(f.tools.has("fm_delegate")); assert.ok(f.tools.has("fm_complete_stage")); assert.ok(f.tools.has("fm_resolve_gate"));
    assert.ok(!f.tools.has("fm_outcome"));
    assert.ok(!f.tools.has("fm_read_document")); assert.ok(!f.tools.has("fm_read_session"));
    assert.equal(f.handlers.get("tool_call")({toolName:"bash"}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_invented_tool"}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_delegate"}), undefined);
  } finally { f.cleanup(); }
});

test("writable workers retain execution and detailed evidence capabilities", () => {
  const f = fixture("worker", {workspace_mode:"isolated"});
  try {
    assert.ok(f.tools.has("fm_status")); assert.ok(f.tools.has("fm_read_document")); assert.ok(f.tools.has("fm_read_session"));
    assert.ok(f.tools.has("fm_delegate")); assert.ok(f.tools.has("fm_outcome"));
    assert.equal(f.handlers.get("tool_call")({toolName:"bash"}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}), undefined);
  } finally { f.cleanup(); }
});

test("read-only workers cannot mutate through builtins or unrelated extension tools", () => {
  const f = fixture("worker", {workspace_mode:"read_only"});
  try {
    for (const toolName of ["write","edit","bash","some_unrelated_tool"]) assert.equal(f.handlers.get("tool_call")({toolName}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"read"}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_read_document"}), undefined);
  } finally { f.cleanup(); }
});

test("successor is fenced until verified acknowledgement", async () => {
  const f = fixture("worker", {handoff_id:"handoff-synthetic",workspace_mode:"isolated"});
  try {
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}).block, true);
    const id = spoolRequestId("synthetic-job", "ack-call");
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:true,result:{acknowledged:true}}));
    await f.tools.get("fm_acknowledge_handoff").execute("ack-call",{summary:"Workspace verified"},undefined,undefined,f.ctx);
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}), undefined);
    const request = JSON.parse(readFileSync(join(f.root,"requests",id+".json"),"utf8"));
    assert.equal(request.native_session_id,"native-synthetic");
  } finally { f.cleanup(); }
});

test("context watcher measures current occupancy, requests one handoff and blocks compaction", async () => {
  const f = fixture();
  try {
    await f.handlers.get("turn_end")({}, f.ctx);
    await f.handlers.get("turn_end")({}, f.ctx);
    assert.equal(f.messages.length,1);
    assert.match(f.messages[0][0],/fm_handoff/);
    assert.deepEqual(f.handlers.get("session_before_compact")({},f.ctx),{cancel:true});
  } finally { f.cleanup(); }
});

test("model headroom lowers the 150k target for a smaller context window", async () => {
  const f = fixture();
  try {
    f.ctx.getContextUsage = () => ({tokens:115201,contextWindow:128000});
    await f.handlers.get("turn_end")({},f.ctx);
    assert.equal(f.messages.length,1);
  } finally { f.cleanup(); }
});

test("completed outcome prevents further worker mutations", async () => {
  const f = fixture();
  try {
    const id=spoolRequestId("synthetic-job","outcome");
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:true,result:{verdict:"success"}}));
    await f.tools.get("fm_outcome").execute("outcome",{verdict:"success",summary:"Verified",documents:[]},undefined,undefined,f.ctx);
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}).terminate,true);
  } finally { f.cleanup(); }
});
