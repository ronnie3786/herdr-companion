# Research: First Mate server API and shared Swift client (origin/main 30627dc, 2026-09-28)

Read-only sweep made for the iPhone port. Paths are relative to the repository root unless an absolute scratchpad path is shown (that export is gone; use the same path under the checkout).

## First Mate API contract and shared Swift client: findings

All paths below are relative to this absolute root: `<repository-root>`. The root is not a git repo; `pyproject.toml` says companion `0.64.1b1`.

**Server files** (under `herdr_harness/`):
- `server.py`: routes; the First Mate handler is `_first_mate_route`, lines 1130-1444
- `first_mate_fleet.py`, `first_mate_store.py`, `first_mate_runtime.py`, `first_mate_peers.py`
- `first_mate_notifications.py`, `push_notifications.py`, `unread_notifications.py`, `alerts.py`
- `skim.py`, `skim_service.py`, `service.py`, `config.py`

**Swift files:**
- `HerdrFirstMateShared/*.swift`. This is a synced folder compiled into both app targets, not a package. Types such as `APIError`, `ServerConfiguration`, `UploadedAttachment`, `VoiceTranscriptionResponse` and `HerdrTimestamp` come from each app target.
- iOS: `herdr-harness-ios/herdr-harness-ios/Infrastructure/HerdrAPIClient.swift` and `herdr-harness-ios/herdr-harness-ios/FirstMate/*`
- Mac: `herdr-harness-mac/herdr-harness-mac/Infrastructure/HerdrAPIClient.swift`, `.../FirstMate/FirstMateFleetIndex.swift`, `.../FirstMate/FirstMateLeadMachine.swift`, `.../FirstMate/ChatWindow/*`

**Docs:** `docs/first-mate/build-contract.md` is the authoritative API contract. Its "Fleet summary API" section is at lines 419-510.

---

### 1. Routes and capabilities

**Common rules**
- Prefix is `/api/v1/first-mate`. Everything is authenticated (see section 7).
- JSON is snake_case.
- Errors:
  - Validation errors: `{ok:false, error:{code,message}, generatedAt}`.
  - Store errors (`FirstMateError`, server.py:978-980): `{ok:false, error:{code,message,next_permitted_actions}}`. Default status is 409 with code `first_mate_conflict`.
- Body limit is 1 MiB. Attachment and voice routes allow 29 MiB (server.py:931-954).
- **The server does not enforce capabilities.** Every route exists regardless; the capability strings are only what clients check.

**Capability discovery**
- `GET /api/v1/first-mate/capabilities` (server.py:1137-1153) returns `{ok, capabilities:[…]}` plus flattened runtime fields and a skim block:
  - Runtime fields (runtime.py:703-709): `available`, `pi_available`, `saved_sessions`, `durable_dispatch`, `context_handoff_target`, `max_workers`, `runtime_health`, `reason`.
  - `skim:{enabled, hud_chats, min_words, format, prompt_version}` (skim_service.py:177-180).
  - Capability list: first-mate-v1, -model-settings-v1, -usage-v1, -archive-v1, -attachments-v1, -context-v1, -safe-model-settings-v1, -git-v1, -runtime-health-v1, -reliability-v1, -board-v1, -journal-events-v1, -feedback-v1, -links-v1, -quiet-chat-v1, -skim-v1, -lead-v1, -lead-peers-v1, -fleet-v1, -verification-v1.
- `GET /api/v1` (`api_description`, server.py:437-638) returns a capabilities list, an `endpoints` map, a `mutations` list and `sseEvents`.
  - Its list omits model-settings, runtime-health, reliability, board and journal-events.
- `GET /api/v1/health` (server.py:1948 → service.py:2033-2062) carries no capabilities.
- The list is static. For example, lead-peers is advertised even when no peers are configured.
- Swift reads only `/first-mate/capabilities`, into `FirstMateCapabilities` (FirstMateClient.swift:135-148). It decodes only `ok` and `capabilities`, plus computed `supportsArchive/Attachments/Context/SafeModelSettings/JournalEventSnapshots/Feedback/Links/Fleet/Lead/LeadPeers`.
- A 404 or 501 from the capability probe means an older companion (FirstMateFleetIndex.swift:450-461).

**Route table** (server.py line; gating capability)

| Method and path | Query / body | Response |
|---|---|---|
| GET `/capabilities` (1137) | — | above |
| GET `/models` (1154) · model-settings-v1 | — | `{ok, models:[{id "provider/model", name, provider, reasoning}], default_model, thinking_levels:[off,minimal,low,medium,high,xhigh,max], routing:{coordinator,planning,execution:{model,thinking}, architect:{model,thinking,configured}}}`. Cached 30 s; 503 `model_catalog_unavailable` (first_mate_models.py:55-97) |
| GET/POST `/feedback-categories` (1156) · feedback-v1 | POST body exactly `{label≤80, request_id}` | `{ok, categories:[{id,label,created_at}]}` / `{ok, category}` |
| POST `/lead/remote` (1165) · lead-peers-v1 | no query; body exactly `{action, params, request_id, lead:{machine, message_id}}` | `{ok, result}`. **Server-to-server only** |
| GET/POST `/lead` (1184) · lead-v1 | no query; POST body optional `{request_id}` | `{ok, lead}`. POST returns 201 when created, 200 when it already existed |
| GET `/fleet` (1200) · fleet-v1 | only `view=active\|archived\|all`, once | `{ok, generated_at, features:[entry]}` (section 2) |
| GET `/features` (1211) · v1 (+archive-v1 for non-active views) | `view=active\|archived\|all`; other fields ignored | `{ok, features:[feature], runtime_health}` |
| POST `/features` (1217) · v1 | `{title≤300, goal, cwd (existing absolute dir), request_id, work_item_id?}` | 201 `{ok, feature}` |
| GET `/features/{id}` (1307) · v1; `?events=journal` needs journal-events-v1 | `events=all\|journal` | full snapshot (section 4) + `runtime_health` |
| GET `/features/{id}/board` (1315) · board-v1 | `messages` 1-200 (default 60), `journal` 0-200 (default 40), `if_version` | full board, or exactly `{ok, version, unchanged:true}` |
| GET `/features/{id}/events` (1432) · v1 | `after=<seq>` | `{ok, events, cursor}`. Up to 1000 events, **includes `pi.*` telemetry** |
| POST `/features/{id}/messages` (1403) · v1 (context: lead-v1) | `{text≤200000, request_id, context?}` | **202** `{ok, message, feature}` (partial acknowledgement) |
| POST `/features/{id}/attachments` (1340) · attachments-v1 | exactly `{filename≤512, content_type, data_base64}` (20 MiB data) | `{ok, attachment:{id, filename, originalFilename, contentType, size, path, workspaceId:"first-mate:<fid>", createdAt}}`. **camelCase** (service.py:1759-1769) |
| POST `/features/{id}/model-settings` (1336) · model-settings-v1 / safe-model-settings-v1 | `{model ("" or provider/model), thinking, expected_settings_revision:int, request_id, expected_session_id?, confirm_session_model_change?:bool}` | `{ok, …full snapshot}`. 409 codes: `stale_model_settings`, `feature_closed`, `coordinator_busy`, `stale_coordinator_session`, `model_change_confirmation_required` (store 789-857) |
| POST `/features/{id}/actions` (1413) · v1; archive-v1 | `{action, request_id, expected_revision?, reason?}` | `{ok, feature}`. Details in section 4 |
| POST `/features/{id}/read` (1383) · fleet-v1 | exactly `{through_message_id}`, no query | `{ok, feature_id, read_through_message_id, unread}` |
| POST `/features/{id}/hud` (1392) · fleet-v1 | `{label?, emoji?}`, at least one; each string or null | `{ok, feature:<fleet entry>}` |
| GET `/features/{id}/feedback` (1328) · feedback-v1 | — | `{ok, feature_id, records}` |
| POST `/features/{id}/messages/{mid}/feedback` (1330) · feedback-v1 | exactly `{rating up\|down\|null, category_ids, comment, expected_revision, request_id}` | `{ok, feature_id, feedback}` |
| POST `/features/{id}/links` (1354) · links-v1 | `{url, request_id, title?, kind?}` | `{ok, link, …snapshot, runtime_health}` |
| POST `/features/{id}/links/{lid}/visibility` (1370) · links-v1 | exactly `{hidden:bool, request_id}` | same as links |
| GET `/features/{id}/git[/diff\|/commit-files\|/commit-diff\|/compare]`, GET `/git/workspaces`, POST `/git/stage\|unstage\|open` (1228-1306) · git-v1 | `workspace`, `file`, `section`, `hash`, `expected_root`, `mode`, `start_commit`, `end_commit`, `reveal` | git payloads |
| GET `/documents/{id}` (1438) · v1 | — | `{ok, document:{id, feature_id, visit_id, assignment_id, native_session_id, generation, input_revision, title, media_type, content, content_hash, created_at}}` |
| GET `/sessions/{native_session_id}` (1440) · v1 | `before`, `limit` 1-100 | `{ok, native_session_id, messages:[{role user\|assistant\|toolResult, text, created_at, index}], next_before, total_messages, usage, model_selection, session:{…}}` (runtime.py:3598-3661) |

**Capabilities that add fields rather than routes:**
- usage-v1: `usage`
- context-v1: `coordinator_context`
- quiet-chat-v1: message `visibility`
- skim-v1: message `skim` and fleet `skim_say`
- verification-v1: `verification`, `verification_runs`, `suite_inventories`
- runtime-health-v1 and reliability-v1: `runtime_health`
- **Skims have no route.** They are embedded in messages.
- Separately, the static web client is served at `/first-mate/` (server.py:1065-1093).

---

### 2. `GET /api/v1/first-mate/fleet` in detail

**How it is built**
- Rows come from `store.fleet_rows(view)`, a single SQL query (first_mate_store.py:1077-1150). The public entry is built by `first_mate_fleet.entry()` (first_mate_fleet.py:268-308).
- The lead is always excluded.
- The `active` view means not archived, and includes completed and cancelled features.
- Sort order: `activity_at` descending, then `feature_id`.
- **There is no version or `if_version`**, only `generated_at` (millisecond ISO). Conditional polling exists only on `/board`.

**Entry fields**
- `feature_id` (str), `title` (str), raw `status`.
- `label`: the user's label, or the title clipped to 24 characters at a word boundary with "…".
- `emoji`: the user's emoji, or FNV-1a default `PALETTE[((h>>16)^(h&0xffff))%16]` over `🧭📦🧪🔍🧾📋🧩🚀🔔🎨📚🌱💡🔧🧰🪁`.
- `emoji_source`: `user` or `default`.
- `hud_status`: `blocked|turn|ready|working|idle|done` (first_mate_fleet.py:80-100):
  - blocked → blocked
  - recovering → working when automatic recovery is on, else blocked
  - awaiting_direction → ready when (a visible non-unverified PR link exists) or (latest attention event is `visit.awaiting_direction` and the visit is completed and the step is 2, 4 or 5); otherwise turn. The rule is in `awaiting_direction_is_ready` (66-77).
  - running/coordinating → turn when `awaiting_turn`, else working
  - ready/paused → idle
  - completed → done
  - cancelled and anything else → idle
  - Needs-you means blocked, turn or ready.
- `step_index` (0-5: Plan, Build, Review, QA, PR, Merge), `step_fraction` (1.0 if the visit is completed, else 0.0), `percent` (`round((idx+frac)/6*100)`).
  - All three are null when the step is unknown.
  - The step comes only from keyword matching on the current visit's `stage_key` (105-124). Active Work stages are not used.
- `now`: at most 120 characters, or null (225-239).
  - Needs-you: `needs_user_prompt`, else the skim say-line, else the First Mate text.
  - Working: the running assignment's `metadata.progress.summary`, else say, else text.
  - Otherwise: say, else text.
- `latest_message`: `{id, role, text (≤200 chars, one line), created_at, skim_say?}` or null.
  - It is the newest conversation row of role user, human or assistant.
  - `skim_say` appears only when that row is the newest First Mate message and its skim is ready.
- `latest_first_mate_message_id`, `read_through_message_id` (nullable).
- `unread` (bool), `working_on_reply` (bool: a queued/processing human message exists, or `coordinator_owner` is set).
- `activity_at`, `updated_at`, `archived_at` (nullable).
- **Not emitted:** `awaiting_turn` and `needs_user_prompt`. They only feed `hud_status` and `now`. `awaiting_turn` does appear in `GET /features` under `dashboard_summary`.

**How `unread` is computed** (`is_after`, first_mate_fleet.py:244-251)
- Unread is true when the newest assistant message with conversation visibility is after the read marker, comparing `(created_at, id)`.
- No First Mate message → false. No marker → true.
- The human's own messages never make a feature unread.
- The marker lives in `fm_feature_presentation`, schema 15 (store 214-218).
- Only moves forward: via `POST /read` (store 1163-1192), and when the lead relays (`relay_human_message` 957-987) or calls `fm_mark_read` (989-998).
- `POST /read` accepts any message belonging to the feature, including the human's. Errors: 404 `not_found`, 409 `message_feature_mismatch`.

**`POST /hud`**
- User labels accept up to 100 Unicode code points after trimming, on one line; default labels still clip the title to 24 code points at a word boundary. Emoji limit is 16 code points with no whitespace or control characters. Null or empty resets to the default (see [the build contract](../../build-contract.md#fleet-summary-api)).
- The lead is refused with 409 `lead_unsupported`.
- Read and hud writes never emit events, never change `updated_at`, activity or the board version, and never wake the coordinator.

**Swift models** (FirstMateFleet.swift)
- `FirstMateHudStatus` (6-37): adds an `unknown` case and a `fallback(featureStatus:)` mapping.
- `FirstMateFleetLatestMessage` (40-71).
- `FirstMateFleetEntry` (78-174): lenient decoding; only `feature_id` is required.
- `FirstMateFleetResponse` (176-204): a malformed entry is dropped, not fatal.
- `FirstMateReadResponse` (207-229), `FirstMateHudUpdateResponse` (232-235), `FirstMateDefaultEmoji` (241-264), `FirstMateChatSteps` (267-271).

---

### 3. The lead (`first-mate-lead-v1`; docs/first-mate/lead.md:78-103)

**Storage and scope**
- There is one lead per companion ledger, stored as an `fm_features` row with `kind:"lead"` (store 71-77, 881-905).
- It never appears in `/features`, `/fleet`, notifications or control discovery.
- It refuses archive, pause/resume/cancel, and label/emoji changes.

**`GET /lead`** returns `{ok, lead:null|summary}` (runtime.py:2245-2252; store 938-955). The summary contains:
- `feature`: the full row plus `model_selection {profile, requested_model, requested_thinking, actual_model, actual_thinking, source}`, `coordinator_model`, `coordinator_thinking`, `model_settings_revision`, `native_session_id`, `kind`, …
- `unread`, `working_on_reply`
- `latest_message {id, role, text ≤200, created_at}` or null
- `machine {id, name}` or null
- `peers [{id, name, url}]`
- **Not included:** context usage and cost. `coordinator_context` and `usage` come only from `GET /features/{lead_id}` (or `/board`).
- `POST /lead` ensures the lead exists and returns the same summary.

**Messaging the lead**
- Everything else uses the ordinary feature routes with `lead.feature.id`: detail and board, `messages`, `attachments`, `model-settings`, `read` (the lead's own marker), and `feedback`.
- A message to the lead may add `context: {machines:[{name, offline?, features:[{label, title, status, step, now, unread:bool, latest}]}]}`.
  - At most 8 machines and 40 features each. Strings are clipped; unknown fields are dropped (store 80-107).
  - It is stored in `fm_message_context` and never shown in the conversation.
  - A non-lead feature returns 400 `invalid_request` when given `context`.
- Swift: `FirstMateLeadContext` (FirstMateClient.swift:54-75), `FirstMateLeadSummary` (80-117). **Swift does not decode `machine`.**

**Remote peers**
- Peers are other machines in the private `[machines]` roster whose credential this host holds.
- The lead's tools call `POST /lead/remote` on those machines: 6 s timeout, 30 s offline window, roster cached 300 s (first_mate_peers.py:25-134).
- Lead tools: `fm_fleet`, `fm_feature_status`, `fm_read_document`, `fm_relay`, `fm_mark_read`, `fm_create_feature` (runtime.py:128-129, 2369-2535).
- A relayed message is a `user` row with `metadata.relayed_by:"lead"`, `lead_message_id` and `lead_machine?`. It also marks that feature read.

**Failover is entirely client-side** (Mac `FirstMateLeadMachine.swift:18-171`)
- A machine is capable when it advertises `first-mate-lead-v1`. It counts as offline after 2 failed polls in a row (capped at 3).
- Preference order: pinned in UserDefaults (`herdr.mac.firstMate.lead.pinned`); then this Mac's own machine, only if it supports lead-peers; then machines that already have a lead conversation; then the busiest (most non-done, non-archived entries).
- If the preferred machine is offline, the first reachable capable machine stands in. If none is reachable, the Mac stays on the preferred machine and shows it offline. It moves back when the preferred machine answers again.
- Each machine's lead is a separate conversation with its own ID and history. There is no server-side migration.
- The client should:
  - call `POST /lead` before first use
  - poll `GET /lead` per capable host
  - build `context` from hosts not reached by the current lead (exclude its own machine and any whose origin matches `peers[].url`; mark offline hosts)
  - reuse the same `context` and `request_id` on retry (`FirstMateStore.pendingLeadContexts`)
- An iPhone has no local machine, so the order reduces to pinned → has a conversation → busiest.

---

### 4. Feature conversation

**Fetching**
- **Snapshot:** `GET /features/{id}[?events=journal]` (store 1564-1598; runtime 986-1061). Returns:
  - `feature`, plus `usage`, `model_selection`, `verification`, `coordinator_context` (`native_session_id, status measured|unavailable, tokens, context_window, handoff_target_tokens, observed_at`)
  - `visits`, `assignments` (plus `usage`, `subtree_usage`, `model_selection`, `progress_lease`), `documents` (no content)
  - `messages`: **all rows including system and background**
  - `events`, `handoffs`, `links`, `memberships`, `verification_runs`, `suite_inventories`
  - `sessions` (≤1000), `sessions_truncated`, `event_cursor`, `runtime_health`
- **Board:** `GET /board` (store 1611-1653; runtime 962-984; docs/dashboard-api.md:41-123).
  - Messages are conversation rows only, oldest first, with `messages_total`. Also `journal` (non-`pi.*`) with `journal_total`.
  - `feature` includes `dashboard_summary` and `model_selection`, but no `usage` or `coordinator_context`.
  - Also returns `visits`, `assignments` (limited columns, `summary`≤600), `sessions`, `event_cursor`, `runtime_health`.
  - `version` is `b1-…`, or `bv1-…` when verification evidence exists. Telemetry never changes it; a landed skim does.
- **Message fields:** `id, feature_id, role, text, status, owner, metadata, created_at, updated_at, visibility (conversation|background), skim?`.
  - Roles: `user` (human; also the initial goal with `metadata.initial`, and relays), `assistant` (First Mate), `system` (coordinator input, always background).
  - Clients also accept `human`; I found no server writer for it.
  - Status goes `queued` → `processing` → `done`. Assistant rows are written as `done`. Demos use `delivered`.

**Metadata on assistant rows**
- Reply: `in_reply_to`, plus `origin:"background"` and `state_fingerprint` for background reports.
- Checkpoint (stage result): `checkpoint:true`, `visit_id`, `turn_id?`. The text ends with "Suggested next step: …\n\nAwaiting your direction." (store 2363-2379).
- Notice: `notice:true`, `turn_id`, `origin:"background"`, `state_fingerprint` (1863-1866).
- `verification`, a compact projection (2252-2270), on checkpoints and replies.
- System rows carry `attention human|background`, `assignment_id`, `human_gate`, `recovery_count`, `repair_count`.
- **Swift `FirstMateMessageMetadata` (6-33) decodes only** `in_reply_to`, `turn_id`, `visit_id`, `checkpoint`, `assignment_id`.

**Skims** (`skim.served`, skim.py:973-985)
- Shape: `{status pending|ready|failed|rejected, format, prompt_version, segmenter_version, skim_version}`. When ready it adds `document`, `segments` and `reply_sha256`.
- A skim pending longer than 300 s is served as failed.
- Swift: `FirstMateSkim` and `FirstMateSkimReader`, which checks the SHA and offsets. Its `sentence`, `caveats`, `nextSteps` and `replies` come from block kinds `say/list/ask/heads_up/what/why/next/reply`.

**Suggested replies**
- There is no dedicated field. They come from the newest First Mate message's skim `reply` blocks, shown only when the feature needs you and nothing is typing (Mac FirstMateChatTranscript.swift:138-143).

**Other chat features**
- Mentions go over the wire as Markdown: `[Name](herdr://first-mate?feature_id=…[&assignment_id=…])` (FirstMateMention.swift).
- Attachments: upload first, then put `Attachment: \`<path>\`` lines in the message text.
- The voice marker is the text suffix "(transcribed audio, please account for incorrect names or typos)".
- Quotes use a "Quoted response segments:" block.

**Posting a message**
- `POST /messages` is idempotent per `(feature, request_id)`; reusing a `request_id` with different content returns 409 `idempotency_conflict`. A closed feature returns 409 `feature_closed`.
- It returns 202 with a partial response. Swift decodes that as a `FirstMateSnapshot` with `hasDetails=false` and merges it.
- It publishes the SSE event `first_mate.updated`.

**Voice**
- `POST /api/v1/voice/transcriptions` `{filename, mime_type (default audio/wav), data_base64}` → `{ok, text, backend, language}` (server.py:2343-2357; service.py:1995-2032).
- There is no First Mate-specific voice route.

**Actions** (`POST /actions`)
- `pause`, `resume` (only from paused, blocked or recovering), `cancel` (immediate pause, committed once writers stop).
- `archive` (optional `reason` ∈ completed, test/synthetic, duplicate, no longer relevant, superseded, other) and `unarchive`.
- Anything else returns 400 `first_mate_action_invalid` ("Use a message to direct the next stage").
- **There is no HTTP "recover" or "complete".** Recovery is the coordinator's `fm_recover`, triggered by a human message.
- A stale `expected_revision` returns 409 `stale_revision`. The lead is refused.

**Banners**
- `runtime_health` fields: `status, scheduler_alive, last_success_at, error_kind, consecutive_failures, guardian_alive, scheduler_restarts, automatic_recovery, sweep_interval_seconds, coordinator_gap_interval_seconds, last_sweep_at, next_sweep_at`. Swift `FirstMateRuntimeHealth.warning` turns this into text.
- `feature.verification` is shown as a verdict; its shape is in build-contract.md:222-265.
- `FirstMateStore.executionDisplayStatus` returns "unverified" when health warns.

**SSE**
- `GET /api/v1/events` emits `first_mate.updated {feature_id, generatedAt}` only when a client creates a feature, sends a message or runs an action (service.py:654-657), and when a skim settles (skim_service.py:295-300).
- Coordinator replies and status changes publish nothing. The event is not in `sseEvents`, and no Swift client listens. **Polling is required.**

---

### 5. Swift client

**`FirstMateClient`** (internal protocol, FirstMateClient.swift:3-49; default implementations 238-296)

| Method | Route | iOS `HerdrAPIClient` | Mac |
|---|---|---|---|
| `fetchFirstMateModels()` | GET /models | line 21 | 206 |
| `fetchFirstMateCapabilities()` | GET /capabilities | 25 | 210 |
| `setFirstMateModel(featureID:settings:)` | POST /model-settings | 29 | 214 |
| `fetchFirstMateFeatures()` / `(scope:)` | GET /features[?view] | 33/37 | 218/222 |
| `fetchFirstMateFeature(_:)` | GET /features/{id} | 41 | 226 |
| `fetchFirstMateFeature(_:journalEventsOnly:)` | ?events=journal | **missing: default fetches the full snapshot** | 232 |
| `createFirstMateFeature(title:goal:cwd:requestID:)` | POST /features | 45 | 258 |
| `sendFirstMateMessage(featureID:text:requestID:)` | POST /messages | 51 | 264 |
| `sendFirstMateMessage(featureID:text:requestID:context:)` | POST /messages with context | **missing: default drops context** | 270 |
| `uploadFirstMateAttachment(featureID:fileURL:contentType:)` | POST /attachments | **missing (throws)** | 276 |
| `transcribeFirstMateVoice(fileURL:)` | POST /voice/transcriptions | **missing (throws)** | 297 |
| `performFirstMateAction(featureID:action:requestID:)` | POST /actions | 57 | 301 |
| `setFirstMateArchived(featureID:archived:reason:requestID:)` | POST /actions | 63 | 307 |
| `fetchFirstMateDocument(_:)` | GET /documents/{id} | 70 | 330 |
| `fetchFirstMateSession(_:before:)` | GET /sessions/{id}?limit=100 | 98 | 366 |
| feedback: categories GET, create, fetch, save | as in section 1 | 104-132 | 372-400 |
| `saveFirstMateLink(...)` / `setFirstMateLinkVisibility(...)` | POST links | **missing** | 314/321 |
| `fetchFirstMateFleet()` | GET /fleet | 74 (unused) | 334 |
| `markFirstMateRead(featureID:throughMessageID:)` | POST /read | 78 (unused) | 346 |
| `updateFirstMateHud(featureID:label:emoji:)` | POST /hud | 84 (unused) | 352 |
| `fetchFirstMateLead()` / `ensureFirstMateLead(requestID:)` | GET/POST /lead | **missing** | 338/342 |

- The Mac also has `fetchFirstMateBoard` (239-252), which is **not** on the protocol.
- No client method exists for `/events` or `/lead/remote`.

**`FirstMateStore`** (`@MainActor @Observable`, FirstMateStore.swift)

State it holds:
- `features` (never the lead), `snapshots[id]` (including the lead), `leadFeatureID`
- Selection and UI: `selectedFeatureID`, `inspector`, `documentsMode`, `graphMode`, `selectedVisitID`, `draft` plus per-feature `drafts`, `search`, `showArchived`, `isCreating`, `isDark`
- Status: `isDemo`, `isRefreshing`, `isSending` (one flag for the whole store), `hasLoaded`, `error`, `unsupported`
- Capability flags (397-409), `controlAvailable`
- Feedback caches, link state, `runtimeHealth`, `lastUpdated`, resource and session-viewer state
- Fences: `generation`, `lifecycleIdentity`
- `pendingMessages` (retries reuse the `request_id`), `pendingLeadContexts`, `leadContextProvider`

Behaviour:
- `receive` (307-395) rejects older `revision`, `model_settings_revision` or `event_cursor`, and merges partial acknowledgements.
- `refresh()` (475-547) fetches capabilities, then `GET /features`, then the selected feature's snapshot, **on every call**.
- **The store has no timer.** Callers drive it:
  - iOS `FirstMateMobileFleetStore.pollingInterval` is 10 s (line 117; observe 566-584), refreshing every host's store. The demo does not poll.
  - Mac `FirstMateFleetIndex` polls every 10 s (line 119). `FirstMateFleetDriver` uses 10 s active and 30 s background.
  - Mac chat window refreshes the selected store every 2 s, and every 60 s when idle (FirstMateChatWindowSession.swift:26, 460).
  - Mac HUD lead card refreshes every 2 s (FirstMateHudController.swift:78).
  - The web client polls every 2.5 s.
- **Selection and data are mixed:** docs/first-mate/chat-window/BUILD-SPEC.md:42-44 says the store "keeps UI state and data together … `send`, `perform` and `saveModelSettings` act on `selectedFeatureID`", and warns not to share an instance between windows.
  - `sendPreparedMessage` (592-634) requires `expectedContext == operationContext`, so the feature must be the selected one.
  - `isSending` blocks all sends and actions on that host's store.

**`FirstMateFleetIndex`** (Mac only)
- `FirstMateFleetSource{machine, configuration, client}`.
- `FirstMateFleetHost{machineID, machineName, features, isLoading, error, unsupported, lastUpdated, supportsFleet, fleetEntries:[featureID:FirstMateFleetEntry]?, supportsLead, supportsLeadPeers, lead:FirstMateLeadSummary?, failedPolls}` (lines 10-40).
- Index state: `hosts`, `contentRevision`, `readState` (client overrides, FirstMateReadState.swift), `badgeCount`, `attentionCount`. Capabilities are re-probed every 5 min; failed read markers retry after 8 s, doubling up to 180 s.
- Each refresh: `GET /features`, then `GET /lead` if capable, then `GET /fleet` if capable (284-416).
- iOS has no equivalent. `FirstMateMobileFleetStore` mirrors `FirstMateFeature` lists only: no fleet entries, no unread, no lead.

---

### 6. Push, APNs and device registration

**Routes**
- `POST /api/v1/push/devices` (alias `/push/register`): `{deviceToken|token, bundleId?, environment sandbox|production, machineId?}` → `{ok, registered, device{tokenSuffix, bundleId, environment}, deviceCount}` (server.py:2947-2966; push_notifications.py:190-216).
- `POST /push/unregister` (2967-2971).
- `GET /push/status` → `{ok, apns:{configured, environment, topicConfigured, deviceCount, liveActivityCount, reason}}` (2423; push_notifications.py:336-365).
- `POST /live-activities` `{activityId, pushToken, bundleId, environment, revealSessionTitles?}` and `/live-activities/unregister` (2973-3004).
- Push mutation routes need `HERDR_HARNESS_API_TOKEN` set, otherwise 503 `api_token_required` (899-912).
- APNs is configured with the env vars `HERDR_APNS_KEY_ID`, `_TEAM_ID`, `_KEY_PATH`, `_TOPIC`, `_ENV`.
- iOS registers in HerdrAPIClient.swift:557-576.

**What triggers APNs today:** only pane agent alerts (`agent_blocked`/`agent_done`, alerts.py:200-209), delivered after 60 s if still unread (unread_notifications.py), plus Herd Pulse live activities. Alert payload: `aps{alert{title,body}, badge, sound, thread-id}`, `event, alertId, workspaceId, tabId, paneId, agentName, status, machine_id`.

**First Mate events do not trigger APNs.** The only notifier is an optional Message Hub webhook (first_mate_notifications.py:30-162):
- Configured with `HERDR_FIRST_MATE_MESSAGE_HUB_URL`/`_TOKEN[_FILE]` and `HERDR_FIRST_MATE_APP_URL`.
- Fires on events `visit.awaiting_direction`, `assignment.dispatch_unknown`, `assignment.recovery_exhausted`, `reliability.blocked`, `coordinator.interrupted`.
- Payload: `{title, sender, text, notify, urgency, metadata{feature_id, event_id}, link?}`. Results are journalled as `notification.*` events.
- Covers active features only; the lead is excluded.

---

### 7. Machine roster, auth, aggregation

**Auth**
- Header `Authorization: Bearer <HERDR_HARNESS_API_TOKEN>` (server.py:669-682, 728-785). Failure returns 401 `unauthorized` with `WWW-Authenticate`.
- With no token configured, the server runs in open loopback development mode.
- Active Work scoped tokens do not grant First Mate access.

**Roster and base URLs**
- Each machine is its own companion with its own base URL and token. Feature IDs are unique only per machine, so key everything by `(machineID, featureID)` (`FirstMateFeatureTarget`).
- iOS: `HerdrMachine{id, name, urlString, role?}` stored in UserDefaults `herdr.machines`, seeded from the bundled `HerdrBootstrap.plist`. The token is in Keychain as `api-token.<machineID>` (HerdrAppModel.swift:2301-2341).
  - `ServerConfiguration` requires https except for loopback http.
- Mac: `GET /api/v1/config/machines` → `{ok, machines:[{id, name, url, role, sidebarLabel?, sidebarOrder?}], localMachineId?}` (server.py:1950-1961).

**Aggregation**
- **No HTTP route aggregates features across machines.** `/fleet` covers the local machine only.
- The only server-side cross-machine view is the lead's `fm_fleet` tool (`other_machines`), and its output goes to the model, not to clients.
- Clients aggregate: Mac `FirstMateFleetIndex`, iOS `FirstMateMobileFleetStore` "All Machines".
- `/api/v1/fleet` is an unrelated managed-machine inventory.

---

### 8. Demo and fixture data

- `FirstMateDemo.features(step:)`: two features and six scenario steps, fixed timestamp `2026-01-15T14:30:00Z`, `demoLinks`, `newFeature`, `sessionMessages`, `content`, `modelCatalog`.
- `FirstMateChatDemo`:
  - `chatWindowFeatures(now:)`: seven features covering every hud status — demo-receipts blocked, demo-release turn, demo-search ready with PR #214, demo-quiet working, demo-offline working, demo-widgets idle, demo-launch done. Three are unread, and three carry suggested replies.
  - `chatWindowLead` ("demo-lead": skim plus measured context), `chatWindowFleet` (entries, badge count 3), `fleetEntry(for:snapshot:)`, and a `skim(...)` builder.
  - Wiring example: `store.configure(client:nil, demo:true, demoFeatures: chatWindowFeatures(now:) + [chatWindowLead(now:)])`, as in Mac `State/FirstMateChatDemoSource.swift`.
- iOS `FirstMateMobileDemo.supplementalSnapshots(forMachineID:"demo2")` adds `demo2-release-checklist`.
- iOS launch flags `-HerdrFirstMateDemo`/`-HerdrDemoMode` give demo stores using the default `features(step:0)` demo, not the chat demo.
- Test fixtures: `HerdrFirstMateSharedTests/FirstMateSkimFixtures.swift`, `tests/fixtures/first_mate_skim`.
- Live fixture: `scripts/first-mate-ios-fixture.py` (port 9196, token `synthetic-first-mate-ios-token`).

---

### Gotchas for the iPhone build

1. **The iOS client is incomplete for First Mate.**
   - There is no journal-only fetch, so every 10 s poll downloads all `pi.*` telemetry.
   - Attachments, First Mate voice, links, the lead, and lead context are not implemented.
   - The generic 15 s timeout applies to First Mate POSTs; the Mac uses 24 h.
2. **Attachment decoding will fail on iOS as-is.** iOS `UploadedAttachment` (Models/WorkspaceToolModels.swift:239-259) decodes snake_case only, but `/features/{id}/attachments` returns camelCase. The Mac model accepts both.
3. **Error codes are lost.** `APIError.server` keeps only status and message; `code` and `next_permitted_actions` are dropped.
4. **The HUD build spec's fleet section (docs/first-mate/hud/BUILD-SPEC.md:60-131) differs from the implementation.** It specifies a 2-minute window for completed features, Active Work step mapping and 5 s polling. Trust build-contract.md and `first_mate_fleet.py`.
5. **Swift drops some server fields.** Unsupported metadata keys (notice, verification, relay info), lead `machine`, and session message `created_at`/`index` are not decoded.
6. **Label fallback differs.** Swift uses `prefix(24)`; the server clips at a word boundary and adds "…".
7. **The live fixture is probably broken.** `FixtureRuntime` defines no `health()`, `lead()` or `ensure_lead()`, while the server calls `runtime.health()` unconditionally (server.py:1216, 1314, 1327). `GET /features`, feature detail and board likely return 500 `internal_error`, and `POST /lead` too. I did not run it; verify before relying on it.
8. **No First Mate deep links on iOS.** `FirstMateOpenRequest` (`herdr://first-mate?feature_id=&server_url=`) exists on the Mac only.
