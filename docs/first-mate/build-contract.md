# First Mate implementation contract

Approved product decisions, 2026-09-13. This is implementation work in an isolated worktree. All examples and demos use synthetic work.

## Product

One human-facing First Mate conversation per feature. The human authorizes each major stage through plain English. Every completed stage pauses for human direction, including stages that previously continued automatically. Internal chunk/review loops are autonomous within the authorized scope; explicit internal human gates still hold. No reply is never approval. Quality is prioritized over token efficiency.

Stage completion creates a concise coordinator message, evidence links, a suggested next step, and awaiting_direction state. Human changes version the plan and pause affected work safely. Two unsuccessful recovery attempts is the initial default unless a recipe is stricter. Preserve all history. Quiesce the predecessor at its saved checkpoint before starting a successor, and finalize its retained lineage only after successor verification. Session history remains available; deleting branches/worktrees is a separate explicit decision.

Start with one authoritative host, existing Herdr Companion server and Pi extension, integrated Mac feature, and reusable web inspector. Parent/session identity is durable and independent of terminal panes. Agent status is distinct from work verdict. Routine events and ten-second reconciliation are ordinary code. Model judgment is permitted for interpretation, advising, and synthesis. First Mate must never wait on workers in a long-running tool. User messages have priority over background coordinator turns.

## Shared initial API

Root prefix `/api/v1/first-mate`, authenticated with normal companion read/control policy. Capabilities `first-mate-v1` and `first-mate-usage-v1`. JSON uses snake_case. Errors use existing structured HTTP conventions. Initial endpoints:

- GET `/features`: `{ok:true,features:[feature]}`
- POST `/features`: `{title,goal,cwd,request_id,work_item_id?}` -> `{ok:true,feature}`
- GET `/features/{id}`: `{ok:true,feature,visits,assignments,documents,messages,events,handoffs,memberships,sessions,sessions_truncated}`
- POST `/features/{id}/messages`: `{text,request_id}` -> `{ok:true,message,feature}` immediately after durable queueing. This acknowledgment is partial; clients fetch feature detail separately.
- POST `/features/{id}/actions`: `{action,request_id,expected_revision?}` for pause/resume/cancel. No HTTP action bypasses a human gate; demo scenario advancement is local to the synthetic native fixture.
- GET `/features/{id}/events?after=0`: `{ok:true,events,cursor}`
- GET `/sessions/{native_session_id}?before=<cursor>&limit=100`: `{ok:true,native_session_id,messages:[{role,text,created_at?}],next_before,total_messages,usage,session?:metadata}`, host-owned exact-session lookup. `usage` always describes the entire saved session, independent of the transcript page.
- GET `/documents/{id}`: `{ok:true,document:{metadata...,content}}`, retaining producer associations.

Feature minimum fields: `id,title,goal,cwd,status,current_visit_id,revision,created_at,updated_at,work_item_id?`. Status vocabulary: `ready,coordinating,running,awaiting_direction,paused,blocked,completed,cancelled,recovering`. Detail arrays use persistent IDs and timestamps. Stage visit: `id,feature_id,stage_key,title,status,revision`. Assignment: `id,feature_id,visit_id,title,role,status,verdict,native_session_id,attempt,generation,input_revision,updated_at`. Document: `id,feature_id,visit_id,assignment_id,native_session_id,title,media_type,content_hash,created_at`. Message: `id,feature_id,role,text,status,created_at`. Event: monotonic `sequence,id,feature_id,type,summary,created_at,payload`.

Usage accounting is additive. Feature objects, assignment objects and session objects may contain `usage`; assignments may also contain `subtree_usage` for that assignment, all recursive child assignments and attached advisors, deduplicated by native Pi session. Session objects may contain `kind` (`coordinator`, `worker`, or `advisor`) and `parent_session_id`. Older clients must ignore these fields and newer clients must accept their absence. The detail response still exposes at most the most recent 1,000 sessions and preserves `sessions_truncated`; feature and assignment totals always use the complete managed inventory, never that page.

A usage summary has `currency` (`USD`), nullable `cost_usd`, `status` (`complete`, `partial`, or `unavailable`), nonnegative integer `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, and `total_tokens`, `usage_records`, `missing_cost_records`, `session_count`, `known_cost_sessions`, `models`, and `updated_at`. Public integer counters are bounded to the cross-client JSON-safe range `0...(2^53-1)`; an invalid or overflowing value is skipped and lowers coverage instead of emitting a rounded or un-decodable number. Each model row repeats the cost/status/token/record fields and adds nullable `provider` and `model`. Optional `stale:true` means a previously parsed amount was preserved after its source became temporarily unreadable; its status is never complete. Explicit Pi-reported zero is valid. Unknown cost is `null`, never an invented zero. These are Pi-reported estimates rather than provider invoices, and subscription-backed providers may report zero.

## Chat parity API additions

`GET /api/v1/first-mate/capabilities` additionally advertises
`first-mate-attachments-v1`, `first-mate-context-v1`, and
`first-mate-safe-model-settings-v1`.

`POST /features/{id}/attachments` is an authenticated control request containing
exactly `filename`, `content_type`, and `data_base64`. The feature must exist and
must not be completed or cancelled. The route alone accepts the existing 20 MiB
attachment JSON limit. Data is stored through Herdr-owned attachment storage in
the opaque `first-mate:<feature-id>` namespace; callers cannot supply a workspace
or filesystem path. Its response intentionally matches the native attachment
envelope's camel-case fields:

```json
{"ok":true,"attachment":{"id":"…","filename":"…","originalFilename":"notes.txt","contentType":"text/plain","size":12,"path":"…","workspaceId":"first-mate:fmf_…","createdAt":"…"}}
```

Feature list, single-feature, and detail projections may include
`coordinator_context`: `native_session_id` (string or null), `status` (`measured`
or `unavailable`), `tokens` (JSON-safe nonnegative integer or null),
`context_window` (JSON-safe positive integer or null), positive
`handoff_target_tokens`, and `observed_at` (timestamp or null). This is the latest
valid bounded telemetry sample for the exact current native coordinator session,
not cumulative billing usage. Foreign, predecessor, worker, malformed, negative,
boolean, non-finite, and unsafe integer values never become an invented zero. A
new or rotated session cannot inherit its predecessor's sample. The handoff target
uses the same configured-target/window-reserve calculation as managed coordinator
rotation.

`POST /features/{id}/model-settings` retains required `model`, `thinking`,
`expected_settings_revision`, and `request_id`, and accepts optional string
`expected_session_id` plus boolean `confirm_session_model_change`. A genuine
change on an established coordinator session requires confirmation and the exact
current session ID. Conflicts are `model_change_confirmation_required`,
`stale_coordinator_session`, or `coordinator_busy` when a coordinator dispatch
owns the feature or its established session has queued work. Validation,
idempotency, ownership checks, and mutation share one store transaction. Exact
receipt replay remains valid after rotation. A no-op does not increment the
settings revision, emit a change event, enqueue work, reset a session, or dispatch
an agent. Before the first session is claimed, older clients may still select the
initial model without the optional fields.

## Model routing and runtime evidence

Feature, assignment, delegation, and session projections may contain additive
`model_selection` with `profile`, `requested_model`, `requested_thinking`, nullable
`actual_model`, nullable `actual_thinking`, and `source`. The requested fields
acknowledge routing policy; they are never presented as observed execution. Actual
fields come only from Pi `get_state` or identity-validated retained session history.
Acknowledgements report the requested role and pin, never an inferred actual. The
coordinator interprets natural-language intent such as `Give me an architect
review` and uses typed `model_profile: architect` for architecture/design reviews,
architect audits, and a second opinion on an implementation. A model name or title
alone does not override host pins. An unavailable or mismatched requested architect
is blocked and is never re-routed through planning or execution. The delegated
profile vocabulary is `planning`, `execution`, and `architect`;
coordinator is a separate runtime profile. The model catalog's additive routing
object exposes coordinator, planning, execution, and architect defaults. Its
architect row includes `configured`; an unset architect model remains a readable
`configured:false` catalog state rather than breaking feature or catalog reads.
Older clients ignore these additions, and newer clients accept older servers that
omit architect routing.

## Runtime-health extension

Capability `first-mate-runtime-health-v1` adds optional `runtime_health` to GET
`/features`, GET `/features/{id}`, and `/capabilities` (the latter alongside
existing capability metadata). Fields: `status`, `scheduler_alive`,
`last_success_at` (nullable UTC string), `error_kind` (nullable safe category), and
`consecutive_failures`. This is request-time engine health, independent of workflow
status. Clients must not rewrite workflow facts or treat scheduler liveness as a
worker verdict. Older clients ignore it; newer clients accept its absence.

A `recovery.checkpoint` event may include machine-observed facts in `payload`:
`job_id`, `assignment_id`, `generation`, `observed_at`, `native_session_id`,
`session_file`, `workspace_path`, `head`, `branch`, `working_tree_status`,
`status_truncated`, `handoff_document_id`, and `side_effects_verified:false`.
Git fields may be absent with `workspace_observation` explaining unavailable
inspection. Advisor-authored events of the same type can omit workspace fields.
These private observations are not themselves a backup or an authorization receipt.

Capability `first-mate-reliability-v1` extends `runtime_health` with optional
`guardian_alive`, `scheduler_restarts` (current-hour count), `automatic_recovery`,
`sweep_interval_seconds`, `last_sweep_at`, and `next_sweep_at`. Recovery checkpoint
payloads may additionally provide `backup_path`, `backup_sha256`, and
`current_position`. Archive paths identify private files on the companion host,
not local client paths to open or restore automatically.

Assignments may expose `metadata.progress` with `summary`, `next_action`,
`evidence`, `recorded_at`, `recorded_epoch`, `position_epoch`, `wait_until_epoch`,
`generation`, and `native_session_id`. These are worker-reported checkpoints, not
success verdicts. `reliability.*` events retain interventions and their reasons.
The existing status vocabulary, authentication, writer fencing, and human stage
authorization rules are unchanged. See [stability behavior](reliability.md).

## Implementation layers

- `first_mate_store.py`: SQLite transactions, deduplication, event ledger, assignments, attempts, message queue, handoffs and human gates.
- `first_mate_runtime.py` and the scoped Pi extension: saved Pi executions, asynchronous coordinator turns, typed tools, health watching, recovery and startup reconciliation.
- `service.py` and `server.py`: service lifecycle and the existing companion authentication boundary.
- Native `FirstMate` views and `/first-mate/`: clients of the same records, with separate light/dark presentation and exact resource drill-down.

Assignments preserve their producing visit and input revision. Explicit `visit_ids` and membership records associate retained work with a revised plan without rewriting its provenance. Sessions include failed attempts and handoff predecessors; the initial detail payload exposes the most recent 1,000 sessions and a truncation flag. Full saved records remain in the host ledger.

Native UX should follow the approved prototype: features on left, First Mate chat center, feature inspector with Overview/Agents/Documents/Workflow, graph/timeline and agent/document drill-down. Light and dark modes. Progressive disclosure for seven or more reviewers. All actual membership comes from exact visit/assignment records. Status must remain visible while a model is idle.

## Delivery proof

One feature must traverse planning, implementation, independent review, a human checkpoint and direction change. Test duplicate commands/results, restart during dispatch, stale generations, missing outcomes, revision-bound review gates, no concurrent session writers, bounded recovery, and a successor handoff. Verify actual Mac rendering/navigation and APIs. Demo reels may use deterministic synthetic fixtures, clearly labelled, but show the implemented UI rather than fabricate an unimplemented feature. Reels require voiceover, captions and actual playable media. Preserve production installations while validating the isolated build.
