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

## Implementation layers

- `first_mate_store.py`: SQLite transactions, deduplication, event ledger, assignments, attempts, message queue, handoffs and human gates.
- `first_mate_runtime.py` and the scoped Pi extension: saved Pi executions, asynchronous coordinator turns, typed tools, health watching, recovery and startup reconciliation.
- `service.py` and `server.py`: service lifecycle and the existing companion authentication boundary.
- Native `FirstMate` views and `/first-mate/`: clients of the same records, with separate light/dark presentation and exact resource drill-down.

Assignments preserve their producing visit and input revision. Explicit `visit_ids` and membership records associate retained work with a revised plan without rewriting its provenance. Sessions include failed attempts and handoff predecessors; the initial detail payload exposes the most recent 1,000 sessions and a truncation flag. Full saved records remain in the host ledger.

Native UX should follow the approved prototype: features on left, First Mate chat center, feature inspector with Overview/Agents/Documents/Workflow, graph/timeline and agent/document drill-down. Light and dark modes. Progressive disclosure for seven or more reviewers. All actual membership comes from exact visit/assignment records. Status must remain visible while a model is idle.

## Delivery proof

One feature must traverse planning, implementation, independent review, a human checkpoint and direction change. Test duplicate commands/results, restart during dispatch, stale generations, missing outcomes, revision-bound review gates, no concurrent session writers, bounded recovery, and a successor handoff. Verify actual Mac rendering/navigation and APIs. Demo reels may use deterministic synthetic fixtures, clearly labelled, but show the implemented UI rather than fabricate an unimplemented feature. Reels require voiceover, captions and actual playable media. Preserve production installations while validating the isolated build.
