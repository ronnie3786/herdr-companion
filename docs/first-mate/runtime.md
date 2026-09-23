# First Mate execution runtime

First Mate is one saved Pi conversation per feature. Managed roles also receive
compact, validated Companion/role identity and pointers to the installed on-demand
references; see [agent awareness](../agent-awareness.md). The companion service owns
its message queue, assignments, process receipts, work log and human checkpoints.
The Mac app and web inspector read that state and can close without stopping work.

Archiving is a separate persisted presentation axis. `archived_at` and the
optional validated `archive_reason` never replace workflow status or revision.
Active lists and attention counts omit archived features, while explicit archived
and all views remain available. Reconciliation deliberately reads all features,
so archiving a running feature does not stop, pause, cancel, resume, or otherwise
steer its coordinator or workers. Unarchive restores list visibility without
changing the workflow. No visits, assignments, documents, sessions, events,
Active Work linkage, or work item identity are deleted.

## Runtime boundary

`FirstMateRuntime(store, environ=..., runtime_root=...)` exposes `start()`, `stop()`,
`wake()`, `capabilities()`, `health()`, `action(feature_id, action, request_id,
expected_revision=None)` and `session(native_session_id)`. HTTP authentication
continues to belong to the companion service. Session lookup is scoped to retained
First Mate executions and validates the exact native Pi session header.

`stop()` stops reconciliation, not detached executions. A new service instance
reattaches to the same private dispatch directories. A manager lock protects a
runtime root; each dispatch and native conversation has its own OS writer lock.

The same managed inventory drives usage accounting: the unbounded retained SQL
session ledger plus started dispatch jobs, including failed starts, coordinator
rotations, retries, handoff predecessors/successors, nested workers, watchdog
advisors and recovery advisors. Pending jobs that never launched are not sessions.
Arbitrary Pi sessions outside this inventory and external services are not
attributed to a feature.

The Pi supervisor is a detached Python module using Pi's documented JSONL RPC.
It maintains a saved session even if the first model request fails.

Every dispatch uses a typed `coordinator`, `planning`, `execution`, or `architect`
routing profile. `fm_delegate` can choose any delegated profile explicitly. Use
`architect` when natural-language intent asks for an architecture/design review,
architect audit, or a second opinion on an implementation, independent of the
stage. For example, `Give me an architect review` is routed explicitly with
`model_profile: architect`. Ordinary planning, implementation, routine code
review, and testing retain their existing profiles. A model name or worker title
alone does not override host pins; the coordinator interprets intent and supplies
the typed profile rather than Python classifying prompt text. When the field is
omitted, only an exact current visit `stage_key` of `planning` selects planning;
every other stage selects execution. The resolved profile is stored with the
assignment, including nested delegation. An unavailable or mismatched requested
architect is a blocker and is never re-routed through planning or execution.

Feature coordinator settings override host coordinator fields for the next turn.
A configured planning or execution model wins over the legacy assignment model.
Without a configured planning/execution role model, routing falls back through
the assignment model, the legacy host `first_mate.model`, and finally Pi's
default. Architect is intentionally different: it requires the operator's exact
provider-qualified `first_mate.architect_model` pin and never falls back to an
assignment, worker, legacy, or Pi-default model. Its effort is optional, but when
configured it must match Pi's effective effort. Advisors continue to use execution
policy.

Before an architect prompt is sent, the supervisor inspects Pi's initial RPC
`get_state`. Pi must report the exact pinned provider/model identity and, when
configured, the exact architect effort. Missing or mismatched evidence blocks the
assignment before the task prompt and retains the requested and observed values.
The same policy is frozen in the immutable workspace plan before delegation
allocates a workspace or assignment, then checked again under the dispatch writer
lock immediately before launch. Replaying the same delegation request reuses that
frozen requested selection even if host policy changed or was removed; changed
parameters are rejected. Legacy plans without selection metadata retain their
original receipt shape. An unstarted queued claim is blocked visibly if its pin
disappears; rejection and finalization occur while holding the writer lock, and a
delayed supervisor refuses the rejected job. Started or writer-locked dispatches
keep their recorded policy. Retries, child continuations, and handoff successors
resolve the current host policy as new dispatches.

Saved Pi JSONL is streamed from the private runtime sessions root and validated
against its session header. Assistant usage, explicit tool-result usage,
compaction usage and branch-summary usage are counted; compaction `retainedTail`
is not re-counted. A compaction or branch summary without usage lowers coverage.
Entry IDs deduplicate repeated records. Recorded message/usage provider and model
fields drive historical grouping; configured model settings are never substituted.
Public `model_selection` acknowledgements report the requested role and pin, with
actual values left null until observed. Actual model and effort come only from Pi
`get_state` or identity-validated saved-session
metadata. Later validated native changes supersede startup observations. Unknown
actual values remain `null`; selection metadata never contains transcript text.
Partial final lines wait for completion. Missing, malformed, identity-mismatched,
escaped, negative, boolean, unsafe-integer and non-finite data lower coverage
without exposing transcript content or breaking feature reads. Canonical path and
native-ID ownership conflicts across features are unavailable to every claimant.

Parsed results retain only the current stat-keyed version for each resolved path
and expected identity, so ordinary feature-list polling does not rescan unchanged
transcripts. File changes refresh accounting without a workflow event. A previously
valid amount may be retained with `stale:true` and `partial` status while its source
is temporarily unreadable or its header is incomplete; a readable identity mismatch
never reuses that amount. A valid header-only session is complete with explicit zero
usage; a started job with no readable session is unavailable. Aggregation reads files
outside SQLite transactions and performs no provider request.

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

Feature totals deduplicate the complete managed inventory directly. Assignment
`usage` includes every attempt and advisor attached to that assignment;
`subtree_usage` recursively includes child assignments without double counting.
The public session history remains capped at 1,000 rows and can include retained
job-only advisors, while totals remain unbounded. Transcript pages return the
whole-session summary at top level regardless of pagination.

The SQLite claim is committed before `job.json` exists, and `job.json` exists
before process launch. Recovery reconstructs a missing spool from its original
claim ID and owner. Before an unstarted recovered job launches, the manager
selects the currently installed trusted First Mate extension and records the
previous path when it changed. A started or writer-locked dispatch keeps its
recorded extension and tools until its process ends. A supervisor launch receipt
that lacks a final outcome is reported as unknown rather than automatically
re-executed. A process exiting successfully does not complete an assignment.
Extension and routing refresh share the dispatch writer lock. An unstarted spool
can adopt current policy immediately before launch; a started or writer-locked
dispatch remains immutable. Retries, continuations, advisors, and handoff
successors are new dispatches and resolve current policy.
An already persisted typed outcome is not overwritten merely because the
supervisor's final receipt is missing.

## Agent tools

The First Mate extension registers tools only in a scoped managed process. Its
private file spool carries stable tool request IDs and atomic replies; workers do
not inherit the companion control token.

- Coordinator: read reference-oriented status, begin one human-authorized major
  stage, delegate, steer, retry, revise affected work, resolve explicit human
  gates, complete a stage and finish the feature. It can also read bounded
  feature Documents and saved sessions. Pi's normal configured tools, extensions,
  skills, prompt templates and project context remain available. Its charter
  interprets requests such as `Give me an architect review` and selects
  `architect` explicitly for architecture/design reviews, architect audits, and
  second opinions on implementations. Names alone do not override host pins.
- Worker: read feature evidence, delegate scoped children, yield until their
  outcomes, retry a direct child, record durable progress and bounded wait leases,
  report a verdict with documents, request a human decision, produce a checkpoint
  and acknowledge a predecessor's handoff or automatic recovery.
- Advisor: return a bounded intervention decision or assemble an independent
  recovery brief. Automatic stability/recovery assessments are restricted to
  read-only tools; ordinary advisors retain normal configured tools.

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

### Storage faults and engine health

The scheduler catches both reconciliation failures and failures writing its error
record. Diagnostic persistence is best-effort, never a prerequisite for keeping
the loop alive. Failed passes retry with an interruptible 1–30 second exponential
backoff; wake requests cannot create a tight disk-error loop. A job observation
failure does not prevent observing other jobs, but that pass will not launch new
work using incomplete writer counts. Failed atomic writes attempt to remove their
partial temporary file without changing the previous committed file.

`health()` is an in-memory, request-time observation independent of the scheduler's
mutex, SQL writes, and diagnostic files. The authenticated capabilities, feature
list and feature-detail responses include `runtime_health`. States are `starting`,
`healthy`, `degraded`, `stalled` (no pass completed for 60 seconds), or `stopped`.
It includes scheduler liveness, last successful pass, a safe error category and
consecutive failed-pass count; it does not expose raw exception text. This reports
monitoring health, not proof that a worker is making useful progress. It can detect
a dead/stuck scheduler while the API still responds. An independent guardian
restarts dead scheduler threads under the original manager lock (three per hour
maximum). It does not replace a live hung thread or supervise the whole backend
process. A timed-out scheduler stop retains its manager lock to prevent a second
scheduler from taking ownership.

The updated Mac app labels active features **Unverified** when the engine is
unhealthy or refreshing fails. It shows storage/retry guidance and the last
successful pass rather than claiming work continues. Older servers remain
compatible but cannot establish engine health. A completely unavailable server
still requires client connection-error handling; no process can guarantee a
persisted alert while its storage is unwritable.

### Uncertain worker recovery

An orphaned dispatch is not blindly replayed. First Mate records a recovery notice,
queues a coordinator system update (evidence, never authorization), then assesses
whether a fresh checkpointed continuation is safe within the existing stage.
Configured Message Hub delivery covers unknown dispatches, exhausted recovery,
reliability blockers, and stage checkpoints. Delivery still uses durable receipts and
never blindly resends an ambiguous notification. Nothing enables a notification
provider by default.

For stopped workers, a private `jobs/<job>/recovery-checkpoint.json` freezes the
workspace path, observed branch/HEAD, bounded dirty/untracked file listing, exact
saved session and latest handoff-document reference. These facts are also recorded
in the feature journal for unknown dispatches. On Mac, expand **Workflow → Recovery
checkpoint** to inspect them or open the predecessor session/latest handoff. Git
inspection is read-only; checkpoints are evidence, **not backups**, and do not
prove external side effects completed. Missing Git access is recorded explicitly.
No automatic cleanup, commit, push, or deployment is performed.

Automatic recovery first verifies writer stop, preserves source changes, checks
side-effect receipts, and obtains an independent safe-next-action assessment.
The successor is fenced until it acknowledges the retained checkpoint. If safety
cannot be established, inspect the evidence and direct First Mate to recover the
assignment in the existing stage. `fm_recover` accepts an uncertain assignment
without requiring a separate Pause first. It checks the prior writer stopped and uses the store's atomic
recovery transition rather than a second Resume. It does not bypass pending human
gates, another uncertain assignment, or the existing two-retry budget. Generic
Resume cannot convert unresolved dispatches into running work. Successors receive
the retained recovery facts and are instructed to preserve edits, verify uncertain
effects, and read the referenced handoff rather than every predecessor transcript.
A crash between recording the unknown state and finalizing the job can retry the
final receipt without duplicate notices or a replayed dispatch.

The persistent hourly controller also checks unchanged progress, nudges stale
live workers, verifies stop before continuation, wakes stranded coordinators,
and stops repeated low-progress handoff churn. New launches require a free-space
reserve. Bounded private source archives protect stopped recovery boundaries,
not every live edit or the whole volume. See the [complete recovery ladder,
configuration, safety rules, and limits](reliability.md).

### Worker activity and context handoff

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
python3 -m unittest tests.test_first_mate_store tests.test_first_mate_runtime tests.test_first_mate_acceptance tests.test_first_mate_usage tests.test_first_mate_recovery tests.test_first_mate_reliability
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
evidence capabilities, explicit architect routing and startup pin validation,
and question/answer continuity across rotation. Focused
usage tests cover mixed models and entry shapes, zero/missing/corrupt numeric
values, append refresh and stale cache behavior, header/path validation, retries,
nested/advisor attribution, unbounded inventory and transcript-page independence.
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
`HERDR_FIRST_MATE_MODEL`, `HERDR_FIRST_MATE_COORDINATOR_THINKING`,
`HERDR_FIRST_MATE_PLANNER_MODEL`, `HERDR_FIRST_MATE_PLANNER_THINKING`,
`HERDR_FIRST_MATE_WORKER_MODEL`, `HERDR_FIRST_MATE_WORKER_THINKING`,
`HERDR_FIRST_MATE_ARCHITECT_MODEL`, `HERDR_FIRST_MATE_ARCHITECT_THINKING`,
`HERDR_FIRST_MATE_MAX_WORKERS`,
`HERDR_FIRST_MATE_CONTEXT_TARGET`, `HERDR_FIRST_MATE_STALL_SECONDS`, and
`HERDR_FIRST_MATE_COORDINATOR_TIMEOUT_SECONDS`, `HERDR_FIRST_MATE_AUTO_RECOVERY`,
`HERDR_FIRST_MATE_SWEEP_SECONDS`, `HERDR_FIRST_MATE_NUDGE_GRACE_SECONDS`, and
`HERDR_FIRST_MATE_MINIMUM_FREE_MB`. See [reliability configuration](reliability.md#configuration-and-compatibility).
The default runtime directory is
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

For a concise agent-facing workflow reference, run `herdr-docs read first-mate`.
It is bundled with the wheel, works offline, and does not replace the current
role-scoped `fm_*` tool schemas or authoritative status.

The extension spool and session directories are private to the local user. This
is process and assignment ownership on one trusted host, not an operating-system
sandbox against hostile code running as that same user. Model-provider credentials
are inherited as needed; companion administration and cluster credentials are
stripped. Process stop targets the supervisor-owned Pi process group. Arbitrary
programs deliberately detached by a worker into another process group are outside
the initial lifecycle contract and should not be used for managed assignments.
