import { createJiti } from "jiti";
import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const jiti = createJiti(import.meta.url);
const { FIRST_MATE_EXTENSION_PATH, createFirstMateExtension, spoolRequestId, observationalShellCommand } = await jiti.import("../extensions/first-mate.ts");
const { COMPANION_AWARENESS_MARKER } = await jiti.import("../lib/companion-awareness.ts");

function fixture(role = "worker", overrides = {}) {
  const root = mkdtempSync(join(tmpdir(), "herdr-first-mate-extension-"));
  const job = {
    id: "synthetic-job",
    kind: role,
    feature_id: "fmf_synthetic-feature",
    claim: {id:"fma_synthetic-assignment", generation:3, metadata:{parent_assignment_id:"fma_synthetic-parent"}},
    extension: FIRST_MATE_EXTENSION_PATH,
    ...overrides,
  };
  writeFileSync(join(root, "job.json"), JSON.stringify(job));
  const tools = new Map(), handlers = new Map(), messages = [];
  const pi = { registerTool(t) { tools.set(t.name, t); }, on(name, fn) { handlers.set(name,fn); }, sendUserMessage(...args) { messages.push(args); } };
  try {
    createFirstMateExtension({ HERDR_FIRST_MATE_JOB_DIR: root, HERDR_FIRST_MATE_MANAGED_ROLE: role, HERDR_FIRST_MATE_CONTEXT_TARGET: "150000" })(pi);
  } catch (error) {
    rmSync(root,{recursive:true,force:true});
    throw error;
  }
  const ctx = { sessionManager: { getSessionId: () => "native-synthetic", getSessionFile: () => join(root,"session.jsonl") }, getContextUsage: () => ({tokens:150001,contextWindow:200000}) };
  return { root, tools, handlers, messages, ctx, cleanup: () => rmSync(root,{recursive:true,force:true}) };
}

test("ordinary Pi sessions gain no First Mate tools", () => {
  createFirstMateExtension({})({registerTool() { assert.fail("unexpected tool"); }});
});

test("legacy role identity and a non-selected extension copy remain dormant", () => {
  const root = mkdtempSync(join(tmpdir(), "herdr-first-mate-extension-"));
  try {
    writeFileSync(join(root, "job.json"), JSON.stringify({id:"synthetic-job",kind:"coordinator",extension:FIRST_MATE_EXTENSION_PATH}));
    const registered = [];
    createFirstMateExtension({HERDR_FIRST_MATE_JOB_DIR:root,HERDR_FIRST_MATE_ROLE:"coordinator"})({registerTool(tool) { registered.push(tool.name); }});
    assert.deepEqual(registered, []);
    writeFileSync(join(root, "job.json"), JSON.stringify({id:"synthetic-job",kind:"coordinator",extension:join(root,"other-first-mate.ts")}));
    writeFileSync(join(root,"other-first-mate.ts"), "// synthetic stale copy\n");
    createFirstMateExtension({HERDR_FIRST_MATE_JOB_DIR:root,HERDR_FIRST_MATE_MANAGED_ROLE:"coordinator"})({registerTool(tool) { registered.push(tool.name); }});
    assert.deepEqual(registered, []);
  } finally { rmSync(root,{recursive:true,force:true}); }
});

test("canonical extension identity accepts a symlink spelling of the selected module", () => {
  const root = mkdtempSync(join(tmpdir(), "herdr-first-mate-alias-"));
  const alias = join(root, "selected-first-mate.ts");
  symlinkSync(FIRST_MATE_EXTENSION_PATH, alias);
  const f = fixture("coordinator", {extension:alias});
  try {
    assert.ok(f.tools.has("fm_status"));
    assert.ok(f.tools.has("fm_read_document"));
  } finally {
    f.cleanup();
    rmSync(root,{recursive:true,force:true});
  }
});

test("validated First Mate roles inject exact scoped identity without job-body leakage", () => {
  for (const role of ["coordinator", "worker", "advisor"]) {
    const f = fixture(role, {prompt:"PRIVATE full assignment body", cwd:"/private/synthetic/worktree"});
    try {
      const result = f.handlers.get("before_agent_start")({systemPrompt:"role charter"});
      assert.ok(result.systemPrompt.startsWith("role charter\n\n"));
      assert.match(result.systemPrompt, /Herdr Companion/);
      assert.match(result.systemPrompt, new RegExp(`role=${role}`));
      assert.match(result.systemPrompt, /feature=fmf_synthetic-feature/);
      assert.match(result.systemPrompt, /job=synthetic-job/);
      assert.match(result.systemPrompt, /fm_delegate/);
      assert.match(result.systemPrompt, /never unmanaged Pi subprocesses/);
      assert.match(result.systemPrompt, /yield rather than polling/);
      assert.match(result.systemPrompt, /external authenticated operator CLI/);
      assert.match(result.systemPrompt, /agent-docs\/first-mate\.md/);
      const awareness = result.systemPrompt.slice(result.systemPrompt.indexOf(COMPANION_AWARENESS_MARKER));
      assert.ok(awareness.trim().split(/\s+/u).length >= 150 && awareness.trim().split(/\s+/u).length <= 220);
      assert.equal(result.systemPrompt.split(COMPANION_AWARENESS_MARKER).length - 1, 1);
      assert.doesNotMatch(result.systemPrompt, /PRIVATE full assignment body|private\/synthetic\/worktree/);
      if (role === "worker") {
        assert.match(result.systemPrompt, /assignment=fma_synthetic-assignment/);
        assert.match(result.systemPrompt, /generation=3/);
        assert.match(result.systemPrompt, /parent-assignment=fma_synthetic-parent/);
      } else {
        assert.doesNotMatch(result.systemPrompt, /assignment=fma_synthetic-assignment/);
      }
      assert.equal(f.handlers.get("before_agent_start")({systemPrompt:result.systemPrompt}), undefined);
    } finally { f.cleanup(); }
  }
});

test("root worker with explicit null parent keeps tools and awareness without parent identity", () => {
  const f = fixture("worker", {
    claim: {id:"fma_synthetic-root", generation:0, metadata:{parent_assignment_id:null}},
  });
  try {
    assert.ok(f.tools.has("fm_status"));
    assert.ok(f.tools.has("fm_delegate"));
    const result = f.handlers.get("before_agent_start")({systemPrompt:"worker charter"});
    assert.match(result.systemPrompt, /role=worker/);
    assert.match(result.systemPrompt, /assignment=fma_synthetic-root/);
    assert.match(result.systemPrompt, /generation=0/);
    assert.doesNotMatch(result.systemPrompt, /parent-assignment=/);
  } finally { f.cleanup(); }
});

test("invalid scoped First Mate identity is rejected after extension ownership validation", () => {
  assert.throws(() => fixture("worker", {feature_id:"bad\nfeature"}), /Invalid First Mate feature identity/);
  assert.throws(() => fixture("worker", {
    claim: {id:"fma_synthetic-root", generation:0, metadata:{parent_assignment_id:"bad\nparent"}},
  }), /Invalid First Mate parent assignment identity/);
});

test("coordinator exposes evidence and orchestration while normal tools remain unrestricted", () => {
  const f = fixture("coordinator");
  try {
    assert.ok(f.tools.has("fm_status"));
    assert.ok(f.tools.has("fm_delegate")); assert.ok(f.tools.has("fm_complete_stage")); assert.ok(f.tools.has("fm_resolve_gate"));
    assert.ok(!f.tools.has("fm_outcome"));
    assert.ok(f.tools.has("fm_read_document")); assert.ok(f.tools.has("fm_read_session"));
    for (const toolName of ["read","bash","edit","write","grep","find","ls","synthetic_third_party"]) assert.equal(f.handlers.get("tool_call")({toolName}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_invented_tool"}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_outcome"}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_delegate"}), undefined);
    const profile = f.tools.get("fm_delegate").parameters.properties.model_profile;
    assert.deepEqual(profile.anyOf.map((item) => item.const), ["planning", "execution", "architect"]);
    assert.match(profile.description, /second opinion on an implementation/);
    assert.match(profile.description, /Give me an architect review/);
    assert.match(profile.description, /model name or worker title alone does not override host pins/);
    assert.match(profile.description, /NEVER be re-routed through planning or execution/);
    assert.match(profile.description, /actual model only from model_selection actual evidence/);
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

test("verification recording is worker-scoped and carries the exact gate contract", () => {
  const worker = fixture("worker", {workspace_mode:"isolated"});
  try {
    assert.ok(worker.tools.has("fm_record_verification"));
    assert.equal(worker.handlers.get("tool_call")({toolName:"fm_record_verification"}), undefined);
    const record = worker.tools.get("fm_record_verification");
    assert.match(record.description, /failures, errors, skipped suites, and interrupted runs/);
    assert.match(record.description, /never claim unqualified green from a total test count/);
    const inventory = record.parameters.properties.inventory;
    assert.deepEqual(inventory.properties.state.anyOf.map((item) => item.const), ["complete", "incomplete"]);
    const gates = record.parameters.properties.gates;
    assert.deepEqual(gates.items.properties.outcome.anyOf.map((item) => item.const),
                     ["passed", "failed", "error", "skipped"]);
    assert.ok(worker.tools.get("fm_outcome").parameters.properties.verification_run_ids);
  } finally { worker.cleanup(); }
  for (const role of ["coordinator", "advisor"]) {
    const other = fixture(role);
    try {
      assert.ok(!other.tools.has("fm_record_verification"));
      assert.equal(other.handlers.get("tool_call")({toolName:"fm_record_verification"}).block, true);
      if (role === "coordinator") {
        assert.ok(other.tools.get("fm_complete_stage").parameters.properties.verification_run_ids);
        assert.ok(other.tools.get("fm_finish_feature").parameters.properties.verification_run_ids);
      }
    } finally { other.cleanup(); }
  }
});

test("read-only workers retain normal tools while workspace policy remains instructional", () => {
  const f = fixture("worker", {workspace_mode:"read_only"});
  try {
    for (const toolName of ["read","bash","edit","write","grep","find","ls","synthetic_third_party"]) assert.equal(f.handlers.get("tool_call")({toolName}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_read_document"}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_begin_stage"}).block, true);
  } finally { f.cleanup(); }
});

test("advisor retains normal tools but cannot use another role's workflow actions", () => {
  const f = fixture("advisor");
  try {
    for (const toolName of ["read","bash","edit","write","grep","find","ls","synthetic_third_party"]) assert.equal(f.handlers.get("tool_call")({toolName}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_delegate"}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_advice"}), undefined);
  } finally { f.cleanup(); }
});

test("automatic recovery advisors cannot use mutating tools while ordinary advisors retain them", () => {
  for (const flag of ["recovery_mode", "reliability_assessment"]) {
    const f = fixture("advisor", {[flag]:true});
    try {
      for (const toolName of ["bash", "write", "edit", "synthetic_third_party"]) assert.equal(f.handlers.get("tool_call")({toolName}).block, true);
      assert.equal(f.handlers.get("tool_call")({toolName:"read"}), undefined);
    } finally { f.cleanup(); }
  }
});

test("coordinator and read-only worker effects are recorded despite instructional workspace policy", () => {
  for (const role of ["coordinator", "worker"]) {
    const f = fixture(role, {safety_ledger_version:1,workspace_mode:"read_only"});
    try {
      f.handlers.get("session_start")({}, f.ctx);
      assert.equal(f.handlers.get("tool_call")({toolName:"bash",toolCallId:"shell",input:{command:"synthetic lookup"}}), undefined);
      const rows = readFileSync(join(f.root,"effects.jsonl"),"utf8").trim().split("\n").map(JSON.parse);
      assert.equal(rows[1].scope, "external");
    } finally { f.cleanup(); }
  }
});

test("successor is fenced until verified acknowledgement", async () => {
  const f = fixture("worker", {handoff_id:"handoff-synthetic",workspace_mode:"isolated"});
  try {
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"bash"}).block, true);
    const id = spoolRequestId("synthetic-job", "ack-call");
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:true,result:{acknowledged:true}}));
    await f.tools.get("fm_acknowledge_handoff").execute("ack-call",{summary:"Workspace verified"},undefined,undefined,f.ctx);
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"bash"}), undefined);
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

test("automatic recovery successor can inspect evidence but is fenced until acknowledgement", async () => {
  const f = fixture("worker", {requires_recovery_ack:true,workspace_mode:"isolated"});
  try {
    for (const toolName of ["write", "bash", "fm_delegate", "fm_progress"]) assert.equal(f.handlers.get("tool_call")({toolName}).block, true);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_read_document"}), undefined);
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_request_human"}), undefined, "a fenced successor can report a real human decision");
    const id = spoolRequestId("synthetic-job", "recovery-ack");
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:true,result:{acknowledged:true}}));
    await f.tools.get("fm_acknowledge_recovery").execute("recovery-ack",{summary:"Verified safe next step"},undefined,undefined,f.ctx);
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}), undefined);
  } finally { f.cleanup(); }
});

test("effect ledger persists before mutations and distinguishes local from external effects", () => {
  const f = fixture("worker", {safety_ledger_version:1,workspace_mode:"isolated",cwd:tmpdir()});
  try {
    f.handlers.get("session_start")({}, f.ctx);
    f.handlers.get("tool_call")({toolName:"write",toolCallId:"local",input:{path:join(f.root,"source.txt")}});
    f.handlers.get("tool_result")({toolName:"write",toolCallId:"local",isError:false});
    f.handlers.get("tool_call")({toolName:"bash",toolCallId:"external",input:{command:"synthetic build"}});
    f.handlers.get("tool_result")({toolName:"bash",toolCallId:"external",isError:true});
    const rows = readFileSync(join(f.root,"effects.jsonl"),"utf8").trim().split("\n").map(JSON.parse);
    assert.deepEqual(rows[0], {type:"ledger_ready",version:1,job_id:"synthetic-job"});
    assert.equal(rows[1].scope, "workspace");
    assert.equal(rows[3].scope, "external");
    assert.equal(rows[4].is_error, true);
  } finally { f.cleanup(); }
});

test("only a conservative complete shell probe is observational", () => {
  for (const command of [
    'cd /synthetic/worktree && echo "=== probe ===" && grep -n "expanded" Source.swift && grep -n "foo\\|bar\\b" Other.swift',
    "test -f README.md || ls -al", "grep -n '$(literal-pattern)' README.md | head -n 5",
    "rg --no-config --files", "git --no-pager --no-optional-locks -c core.fsmonitor=false status --porcelain",
  ]) assert.equal(observationalShellCommand(command), true, command);
  for (const command of [
    "grep missing README.md; synthetic-publish artifact", "grep missing README.md > output.txt",
    "echo $(synthetic-publish)", 'echo "`synthetic-publish`"', "ls <(synthetic-publish)",
    "cat <<< input", "ls & synthetic-publish", "echo hello\nsynthetic-publish", "echo x &&", "echo x;",
    "find . -exec synthetic-publish {} ;", "sed -i replacement README.md", "rg --pre=synthetic-publish pattern",
    "rg --no-config --pre synthetic-publish pattern", "rg --no-config --hostname-bin=synthetic-publish pattern",
    "rg --no-config -z pattern", "rg pattern", "git -c core.fsmonitor=synthetic-publish status", "git status",
    "git diff --ext-diff", "bash -c 'ls'", "GIT_CONFIG=synthetic git status", 'echo "unfinished',
  ]) assert.equal(observationalShellCommand(command), false, command);
});

test("failed observational shell probes retain their command and scope", () => {
  const f = fixture("worker", {safety_ledger_version:1,workspace_mode:"read_only"});
  try {
    const command = "grep missing README.md";
    assert.equal(f.handlers.get("tool_call")({toolName:"bash",toolCallId:"probe",input:{command}}), undefined);
    f.handlers.get("tool_result")({toolName:"bash",toolCallId:"probe",isError:true});
    const rows = readFileSync(join(f.root,"effects.jsonl"),"utf8").trim().split("\n").map(JSON.parse);
    assert.equal(rows[1].scope, "observational");
    assert.equal(rows[1].command, command);
    assert.equal(rows[2].is_error, true);
  } finally { f.cleanup(); }
});

test("shared checkout cleanup is refused while ordinary Git inspection remains available", () => {
  const f = fixture("worker", {workspace_mode:"read_only"});
  const isolated = fixture("worker", {workspace_mode:"isolated"});
  try {
    for (const command of ["git stash push", "git reset --hard", "git -C /synthetic checkout HEAD .", "/usr/bin/git restore .", "git clean -fd", "cd /synthetic && git stash"])
      assert.equal(f.handlers.get("tool_call")({toolName:"bash",input:{command}}).block, true, command);
    for (const command of ["git status --porcelain", "git diff -- stash", "git log --oneline"])
      assert.equal(f.handlers.get("tool_call")({toolName:"bash",input:{command}}), undefined, command);
    assert.equal(isolated.handlers.get("tool_call")({toolName:"bash",input:{command:"git checkout topic"}}), undefined);
  } finally { f.cleanup(); isolated.cleanup(); }
});

test("recovery exposes explicit human stop and budget-reset controls", () => {
  const f = fixture("coordinator");
  try {
    const properties = f.tools.get("fm_recover").parameters.properties;
    assert.equal(properties.reset_budget.type, "boolean");
    assert.equal(properties.stop_running.type, "boolean");
    assert.match(properties.reset_budget.description, /explicit human direction/);
    assert.match(properties.stop_running.description, /verify its stop/);
  } finally { f.cleanup(); }
});

test("unwritable effect ledger fails before a mutating tool is allowed", () => {
  const f = fixture("worker", {safety_ledger_version:1,workspace_mode:"isolated"});
  try {
    mkdirSync(join(f.root,"effects.jsonl"));
    assert.equal(f.handlers.get("tool_call")({toolName:"bash",toolCallId:"blocked",input:{command:"synthetic command"}}).block, true);
  } finally { f.cleanup(); }
});

test("progress is scoped to workers and does not retire their executor", async () => {
  const f = fixture("worker", {workspace_mode:"read_only"});
  try {
    assert.equal(f.handlers.get("tool_call")({toolName:"fm_progress"}), undefined);
    const id = spoolRequestId("synthetic-job", "progress");
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:true,result:{retained:true}}));
    await f.tools.get("fm_progress").execute("progress",{summary:"Finished parsing",next_action:"Run tests",evidence:"Parser updated"},undefined,undefined,f.ctx);
    assert.equal(f.handlers.get("tool_call")({toolName:"read"}), undefined);
  } finally { f.cleanup(); }
});

test("completed outcome prevents further worker mutations", async () => {
  const f = fixture();
  try {
    const id=spoolRequestId("synthetic-job","outcome");
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:true,result:{verdict:"success"}}));
    await f.tools.get("fm_outcome").execute("outcome",{verdict:"success",summary:"Verified",documents:[]},undefined,undefined,f.ctx);
    assert.equal(f.handlers.get("tool_call")({toolName:"write"}).terminate,true);
    assert.equal(f.handlers.get("tool_call")({toolName:"bash"}).terminate,true);
  } finally { f.cleanup(); }
});

test("coordinator and worker retain links while advisors cannot mutate links", () => {
  for (const role of ["coordinator", "worker"]) {
    const f = fixture(role);
    try {
      assert.ok(f.tools.has("fm_save_link"));
      const description = f.tools.get("fm_save_link").description;
      assert.match(description, /never open, fetch, preview, or create/);
      assert.match(description, /never create a pull request or advance a stage/);
      assert.equal(f.handlers.get("tool_call")({toolName:"fm_save_link"}), undefined);
    } finally { f.cleanup(); }
  }
  const advisor = fixture("advisor");
  try {
    assert.ok(!advisor.tools.has("fm_save_link"));
    assert.equal(advisor.handlers.get("tool_call")({toolName:"fm_save_link"}).block, true);
  } finally { advisor.cleanup(); }
});

test("link saving spools exact scoped identity and parameters", async () => {
  const f = fixture("worker", {workspace_mode:"read_only"});
  try {
    const id = spoolRequestId("synthetic-job", "save-link");
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:true,result:{id:"fml_one",url:"https://github.com/synthetic-owner/synthetic-repo/pull/1"}}));
    const result = await f.tools.get("fm_save_link").execute("save-link", {
      url:"https://github.com/synthetic-owner/synthetic-repo/pull/1",
      title:"Synthetic review", kind:"pull_request",
    }, undefined, undefined, f.ctx);
    assert.equal(result.details.id, "fml_one");
    const request = JSON.parse(readFileSync(join(f.root,"requests",id+".json"),"utf8"));
    assert.equal(request.action, "fm_save_link");
    assert.equal(request.native_session_id, "native-synthetic");
    assert.deepEqual(request.params, {
      url:"https://github.com/synthetic-owner/synthetic-repo/pull/1",
      title:"Synthetic review", kind:"pull_request",
    });
  } finally { f.cleanup(); }
});

test("successor and recovery fences also gate link saving", () => {
  const handoff = fixture("worker", {handoff_id:"handoff-synthetic", workspace_mode:"isolated"});
  try {
    assert.equal(handoff.handlers.get("tool_call")({toolName:"fm_save_link"}).block, true);
  } finally { handoff.cleanup(); }
  const recovery = fixture("worker", {requires_recovery_ack:true, workspace_mode:"isolated"});
  try {
    assert.equal(recovery.handlers.get("tool_call")({toolName:"fm_save_link"}).block, true);
  } finally { recovery.cleanup(); }
});


test("structured recovery refusal reaches the coordinator tool error", async () => {
  const f = fixture("coordinator");
  try {
    const id = spoolRequestId("synthetic-job", "exhausted");
    const actions = [{tool:"fm_recover",reset_budget:true,requires_human_direction:true}];
    writeFileSync(join(f.root,"responses",id+".json"),JSON.stringify({ok:false,error:"Recovery budget exhausted",code:"recovery_exhausted",next_permitted_actions:actions}));
    await assert.rejects(f.tools.get("fm_recover").execute("exhausted",{assignment_id:"synthetic-assignment",reason:"Inspect"},undefined,undefined,f.ctx), error => {
      const value = JSON.parse(error.message);
      assert.equal(value.code,"recovery_exhausted");
      assert.deepEqual(value.next_permitted_actions,actions);
      return true;
    });
  } finally { f.cleanup(); }
});

test("Bash test array evaluation is never classified as observational", () => {
  for (const command of ["test -v 'items[0]'", "[ -v 'items[$(publish)]' ]", "test 'items[$(publish)]' -eq 1"])
    assert.equal(observationalShellCommand(command),false,command);
});
