# First Mate execution runtime

First Mate is one saved Pi conversation per feature. The companion service owns
its message queue, assignments, process receipts, work log and human checkpoints.
The Mac app and web inspector read that state and can close without stopping work.

## Runtime boundary

`FirstMateRuntime(store, environ=..., runtime_root=...)` exposes `start()`, `stop()`,
`wake()`, `capabilities()`, `action(feature_id, action, request_id,
expected_revision=None)` and `session(native_session_id)`. HTTP authentication
continues to belong to the companion service. Session lookup is scoped to retained
First Mate executions and validates the exact native Pi session header.

`stop()` stops reconciliation, not detached executions. A new service instance
reattaches to the same private dispatch directories. A manager lock protects a
runtime root; each dispatch and native conversation has its own OS writer lock.
The Pi supervisor is a detached Python module using Pi's documented JSONL RPC.
It maintains a saved session even if the first model request fails.

Status responses contain canonical projections and short event summaries.
The coordinator receives a current-stage, reference-oriented projection with
authoritative feature, visit, assignment, revision, blocker and Document IDs. It
does not receive worker prompts, worktree metadata, transcript pages or Document
bodies. Workers and advisors retain the detailed evidence readers. Status results
never contain previous status-tool payloads. The SQL ledger stores operation
identities, hashes and references to the exact private JSONL evidence rather than
recursively embedding tool results. This prevents repeated status reads from
expanding the agent's context. Model document/session reads are paginated, with
explicit continuation offsets; the authenticated human session API returns full
message bodies in pages of up to 100 entries.

The SQLite claim is committed before `job.json` exists, and `job.json` exists
before process launch. Recovery reconstructs a missing spool from its original
claim ID and owner. Before an unstarted recovered job launches, the manager
selects the currently installed trusted First Mate extension and records the
previous path when it changed. A started or writer-locked dispatch keeps its
recorded extension and tools until its process ends. A supervisor launch receipt
that lacks a final outcome is reported as unknown rather than automatically
re-executed. A process exiting successfully does not complete an assignment.

## Agent tools

The First Mate extension registers tools only in a scoped managed process. Its
private file spool carries stable tool request IDs and atomic replies; workers do
not inherit the companion control token.

- Coordinator: read reference-oriented status, begin one human-authorized major
  stage, delegate, steer, retry, revise affected work, resolve explicit human
  gates, complete a stage and finish the feature. It can also read bounded
  feature Documents and saved sessions. Pi's normal configured tools, extensions,
  skills, prompt templates and project context remain available.
- Worker: read feature evidence, delegate scoped children, yield until their
  outcomes, retry a direct child, report a verdict with documents, request a
  human decision, produce a checkpoint and acknowledge a predecessor's handoff.
- Advisor: read evidence, use normal configured tools when needed,
  return a bounded intervention decision or assemble an independent recovery
  brief when the stopped predecessor cannot summarize.

The coordinator is a small conversational router. Simple direction,
clarification and status replies stay in the feature conversation and default to
one to three sentences (normally at most 80 words). Substantive planning,
research, investigation, implementation, review, testing, evidence reading and
synthesis are tracked worker assignments; their detailed deliverables live in
Documents. The coordinator can use concise structured worker summaries to close
a stage. If the evidence needs substantial reconciliation, it delegates that
reconciliation to a lead or reviewer before completing the stage. It does not
turn a request for detail into a long untracked response.

Coordinators can use normal tools for brief routing diagnostics and CLI lookups,
but their charter keeps substantive work in tracked assignments. The Pi process
uses a replacement `--system-prompt` charter without restricting normal tool or
resource discovery. Current launch policy and charter are applied on every new
dispatch, including turns in an existing saved coordinator session. `read_only`
expresses the requirement to leave the shared workspace unchanged, not a security
sandbox or tool capability boundary. Writable
assignments use private Git worktrees and `codex/first-mate-…` branches. An explicit
source assignment selects the actual implementation/integration worktree for
review. Review verdicts are tied to its clean commit revision. A changed review
source cannot complete a stage using stale evidence. Branches and worktrees are
retained until an explicit cleanup decision.

Managed dispatches set `HERDR_FIRST_MATE_MANAGED_ROLE`, never the legacy role
variable. The selected extension also verifies that its real module path matches
the extension recorded in the private job. This leaves an older configured First
Mate copy dormant while every other configured extension remains loaded. The
companion runtime and bundled Pi extension must therefore be upgraded together;
already running legacy dispatches keep their original process policy until they
end.

A clean Git checkout is required for successful implementation and revision-bound
review; exploratory planning can inspect an existing dirty checkout. A plan is
not silently treated as a code review.

## Human direction and background execution

Every completed major stage records evidence, a recommendation and
`awaiting_direction`. A system outcome cannot authorize another stage. Explicit
internal gates have separate pending state and require a later human message;
background repair and generic Resume cannot bypass them.

Within a stage, independent assignments and bounded review/fix rounds run
asynchronously. A lead worker can delegate its own specialists through
`fm_delegate`, with immutable parent assignment membership and a four-level
nesting limit. Read-only parents cannot grant isolated worktree ownership to children.
`fm_wait_for_children` records the lead's checkpoint and ends its model turn. The
service resumes that exact saved native conversation and generation after the
children settle. A parent cannot report success while any child is unfinished or
unsuccessful. Child outcomes remain in the journal with their documents; the
owning lead collects them and sends its synthesis to First Mate. Explicit human
gates and exhausted recovery still escalate immediately. Arbitrary scripts that
launch their own Pi subprocesses bypass this
protocol; managed skills must use the typed delegation tool instead. Human messages have priority in the queue. A waiting human also
interrupts a background coordination turn at Pi's abort boundary, retaining the
background message for later processing. Only one process writes the coordinator
conversation. Coordinator and advisor turns have a configurable bounded deadline.

Scope changes are revisioned. Explicit affected assignment IDs stop only those
executors; unaffected work is associated with the new visit through recorded
membership. Old evidence retains its original revision and session provenance.

## Monitoring, recovery and handoff

Reconciliation is ordinary code. Every ten seconds the watchdog checks activity,
repeated tool patterns, repetitive generated text and progress deadlines. It does
not invoke a model for unchanged healthy work. Suspicious work receives an
independent read-only advisor assessment. Advice can continue, steer, request a
handoff or pause. Subsequent observations can trigger another assessment, with a
cooldown and a new observation cursor.

The default context target is 150,000 current context tokens, reduced for smaller
model windows to preserve headroom. The extension reports actual context usage,
requests one checkpoint and cancels compaction. If the worker cannot produce a
checkpoint within the bounded deadline, the supervisor stops it and an independent
advisor assembles a recovery brief from recorded evidence.

A checkpoint is retained before the predecessor stops. A fresh native Pi session
continues the same assignment in its existing workspace. The successor must
inspect and acknowledge the handoff before mutation tools are available. The
predecessor's transcript and native ID remain retained; lineage changes to
`handed_off` only after acknowledgement. The predecessor process stops at the safe
checkpoint before successor execution, so there are no overlapping writers.

First Mate's own conversation can also rotate after a completed turn. Its
checkpoint retains the reference-oriented current workflow state, all human
directives with source IDs, and the latest 30 user/assistant messages. The recent
window preserves the meaning of terse answers such as “yes” beside the
coordinator question they answer. The old native session remains retained in
full. Very long feature histories may ultimately need an incremental
decision-summary service to avoid reinjecting an ever-growing list of human
directives; this implementation favors retaining instructions over silently
dropping older constraints.

Unsuccessful process recovery is bounded to two retries. Internal repair has a
separate bounded count. A third unsuccessful result blocks the feature and brings
the evidence back to First Mate. Interrupted executions are never labeled success.

## Verification

Run the focused suite from the repository with Python 3.11 or newer:

```sh
python3 -m unittest tests.test_first_mate_store tests.test_first_mate_runtime tests.test_first_mate_acceptance
node --test pi-semantic-bridge/test/first-mate.test.mjs
```

The process integration tests replace model decisions with a synthetic RPC
executable while exercising real detached processes, session files, writer locks,
spool callbacks and SQLite transactions. They cover stage checkpoints, seven
independent reviewers, restart, exact document authorship, bounded missing-outcome
recovery, fresh successor acknowledgement, worktree isolation, role scoping and
idempotent delegation. They also cover the coordinator's replacement prompt,
resumed-session charter and extension refresh, normal configured tool access,
role-specific First Mate workflow actions, reference-oriented input, worker
evidence capabilities and question/answer continuity across rotation.
Acceptance tests inject claim-creation crash gaps and
exercise paused handoffs, cancellation, direction changes and context rotation.

A separate live verification used the installed Pi provider to delegate a
read-only planner, retain its markdown document, inspect its evidence and park at
a human checkpoint. A restarted manager then resumed the exact same native
coordinator conversation and answered a status question without starting a stage.
A second live verification exercised nested delegation: a planning lead delegated
two independent reviewers, yielded without polling, resumed the same native
session at the same generation, collected their documents and reported its own
successful outcome. The overall stage then parked awaiting human direction with
three successful assignments and three correctly attributed documents. This test
also exposed and verified the fix for recursive status payload growth.
A third live test used the authenticated HTTP API to request a tiny implementation,
run three standard-library tests, and commit the result on an isolated private
branch. The original checkout stayed unchanged. After the implementation paused,
an explicit human API message authorized a read-only review of that exact source
assignment and commit. The reviewer passed, both stages retained documents, and
First Mate paused again. An independent local test run also passed. This validates
the implementation and review plumbing on a bounded synthetic change, not the
quality of an arbitrary large application change.
Only synthetic project data was used; verification records remain private in the
ignored build directory.

## Configuration and installation

Use the operator's private companion configuration. Relevant environment values
are `HERDR_HARNESS_FIRST_MATE_RUNS_ROOT`, `HERDR_STATE_DIR`,
`HERDR_FIRST_MATE_MODEL`, `HERDR_FIRST_MATE_MAX_WORKERS`,
`HERDR_FIRST_MATE_CONTEXT_TARGET`, `HERDR_FIRST_MATE_STALL_SECONDS`, and
`HERDR_FIRST_MATE_COORDINATOR_TIMEOUT_SECONDS`. The default runtime directory is
`$HERDR_STATE_DIR/first-mate-runs`, falling back to
`~/.local/share/herdr-companion/first-mate-runs`. Model authentication remains in
Pi's existing provider configuration. Missing Pi or a missing bundled extension
is reported as an unavailable capability.

The repository's existing wheel build bundles the `pi-semantic-bridge` package,
including `extensions/first-mate.ts`. Runtime resource discovery first supports
the configured trusted package override, then the installed wheel's bundled
package, and finally the source checkout. Do not install a second competing Pi
manager to use First Mate. Follow the main README's installation and verification
commands for the server and Mac client.

The extension spool and session directories are private to the local user. This
is process and assignment ownership on one trusted host, not an operating-system
sandbox against hostile code running as that same user. Model-provider credentials
are inherited as needed; companion administration and cluster credentials are
stripped. Process stop targets the supervisor-owned Pi process group. Arbitrary
programs deliberately detached by a worker into another process group are outside
the initial lifecycle contract and should not be used for managed assignments.
