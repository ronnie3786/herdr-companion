# Dashboard companion data

The Mac Dashboard uses additive fields on the existing First Mate and PR Review
list responses. Older clients ignore these fields. New clients must keep them
optional, and display unavailable data honestly when connected to older servers.
No existing authorization or write contract changes.

## First Mate cards

`GET /api/v1/first-mate/features` includes `dashboard_summary` on each feature:

- `current_stage_title`, `current_stage_index`: nullable current stage and its
  one-based index within the current plan revision.
- `stage_count`: number of recorded stages in that revision.
- `stage_count_is_estimate`: true. The ledger has no complete future stage plan,
  so render “Stage 2”, not a promised “Stage 2 of 5”.
- `latest_message`, `latest_message_at`: latest assistant message, capped at
  1,200 characters, and its timestamp. Both are null before the first reply.
- `needs_user`, `needs_user_prompt`: attention only for `awaiting_direction` and
  `blocked`, with a bounded checkpoint or recovery prompt. When `awaiting_turn`
  is true, `needs_user_prompt` is instead the latest assistant message, capped at
  600 characters, while `needs_user` stays false.
- `awaiting_turn`: true when First Mate finished its turn and is parked until a
  human replies: status is `coordinating` or `running`, no coordinator owns a
  turn, no current-visit assignment is running (the same set as
  `running_assignment_count`), no user message is queued or processing, and the
  newest user or assistant message is from the assistant. It is presentation
  only; it does not change `needs_user` or workflow status.
- `assignment_count`, `running_assignment_count`: assignments in the current
  visit, including those carried across a revision. Running includes dispatch,
  child-wait, handoff, acknowledgement, and recovery states, but excludes queued
  and paused assignments.
- `activity_at`: the newest `created_at` among the feature's journal events and
  messages, or the feature's `created_at` when it has neither. Pi telemetry
  (`pi.*` events) never moves it. Sort and label “last activity” by this field:
  the feature's own `updated_at` also advances on every telemetry event, and the
  list response keeps its existing `updated_at` ordering.

The projection is one SQLite query. It does not load full feature snapshots.

## Agent view board

Capability `first-mate-board-v1` adds a bounded, versioned projection for one
Agent view column:

`GET /api/v1/first-mate/features/{featureId}/board?messages=60&journal=40&if_version=…`

All query fields are optional and may each occur once. Unknown or repeated fields
and out-of-range values return 400 `invalid_request`; an unknown feature returns
404.

- `messages`: integer 1–200, default 60. The newest `user`, `assistant`, and
  `human` messages, returned oldest first. System messages are omitted.
- `journal`: integer 0–200, default 40. The newest journal events, returned in
  sequence order.
- `if_version`: string of at most 200 characters. When it equals the current
  version the response is exactly `{"ok":true,"version":"b1-…","unchanged":true}`.

A full response contains:

- `version`: opaque token (`b1-` plus 20 hex characters). Compare it only for
  equality.
- `unchanged`: `false`.
- `feature`: the feature object from `GET /features`, including
  `dashboard_summary` and the coordinator `model_selection`. It omits `usage` and
  `coordinator_context`, which require job and transcript scans. Keep reading
  those from the feature list.
- `visits`: every stage visit, ordered by creation.
- `assignments`: current and historical assignments, ordered by creation, with
  only `id`, `feature_id`, `visit_id`, `visit_ids`, `title`, `role`, `status`,
  `verdict`, `native_session_id`, `attempt`, `generation`, `input_revision`,
  `created_at`, `updated_at`, and `summary` (at most 600 characters). Prompts,
  metadata, session paths, owners, and dispatch or run identities are never
  included, nor are `usage` or `model_selection`.
- `messages`, `messages_total`: the bounded messages and the total count of those
  roles.
- `journal`, `journal_total`: the bounded journal events and the total count.
- `sessions`, `sessions_truncated`: every coordinator session plus the newest
  session for each assignment, newest first, capped at 200. Session rows contain
  `native_session_id`, `feature_id`, `assignment_id`, `title`, `role`, `status`,
  `generation`, `attempt`, `input_revision`, `created_at`, `updated_at`, and
  `ownership_status`, without paths, `kind`, `usage`, or `model_selection`.
- `event_cursor`: the highest event sequence for the feature, including telemetry,
  or 0.
- `runtime_health`: the same object the feature list returns.

The board is built from SQLite alone. It performs no job scan, usage accounting,
or context projection. The version changes for any feature field other than
`updated_at`, a new journal event (including attention events), and any message,
assignment, visit, or session insert or update. Telemetry alone never changes it,
so an unchanged poll is one small query. Consequently a cached board may show an
older `feature.updated_at` and `event_cursor`, which telemetry advances, and
`runtime_health` is returned only with a full response.

### Journal events

Journal events are every event whose `type` does not start with `pi.`. Pi
telemetry (`pi.message_end`, `pi.tool_execution_start`, `pi.context_usage`, and
similar types) is excluded. Native clients read no `pi.*` event type.

Capability `first-mate-journal-events-v1` adds opt-in
`GET /api/v1/first-mate/features/{featureId}?events=journal`. It returns the normal
feature detail with `events` limited to all journal events, uncapped. `events=all`
and an omitted `events` return every event as before. Any other value, or a
repeated `events` field, returns 400 `invalid_request`; other query fields remain
ignored.

Feature detail in both modes includes additive `event_cursor`, the highest event
sequence for the feature including telemetry. A client that rejects older
snapshots by event sequence must compare `event_cursor` rather than the largest
sequence in `events`, because a journal-only snapshot omits newer telemetry.

Example board response, abbreviated and synthetic:

```json
{"ok":true,"version":"b1-3f0c2a9e41d7b58c6a10","unchanged":false,
 "feature":{"id":"fmf_synthetic","title":"Garden irrigation","status":"running",
  "dashboard_summary":{"activity_at":"2026-01-02T03:04:05.000001Z"}},
 "visits":[],"assignments":[],"messages":[],"messages_total":0,
 "journal":[{"sequence":7,"type":"visit.started","summary":"Planning started"}],
 "journal_total":1,"sessions":[],"sessions_truncated":false,"event_cursor":912,
 "runtime_health":{"status":"healthy"}}
```

## PR Review rows

`GET /api/v1/pr-reviews` includes two additive fields per review:

- `skill_runs`: latest actual run per skill, with `skill_id`, `title`, `state`,
  and `updated_at`. No runs produces an empty array. Manual “ran” marks remain
  available in the full review and are not represented as executions here.
- `viewer_review`: cached state for the authenticated GitHub user on the selected
  PR Review host, independent of the PR's own `github_state`.

`viewer_review.state` is `pending`, `re_review_requested`, `approved`,
`changes_requested`, `commented`, `not_reviewed`, or `unknown`.
`pending_comment_count` counts the viewer's own pending review comments.
`needs_user` is true only for pending or re-review states on someone else's PR.
`is_own_pr` is null until known, otherwise GitHub's `viewerDidAuthor` value.
The Dashboard excludes rows when `is_own_pr` is true.

`reviewed_at`, `reviewed_commit`, `head_commit`, and `review_requested` retain the
evidence for the projection. Re-review means the head differs from the viewer's
last reviewed commit or a current request for that user was made after their
submitted review. An initial request with no review remains `not_reviewed`.
Pending review state takes priority. Submitted reviews from other users cannot
affect the state because both review connections are filtered by the authenticated
login. The implementation uses the documented
[GitHub pull request fields](https://docs.github.com/en/graphql/reference/pulls).

`updated_at` is the last successful GitHub refresh, `checked_at` is the latest
attempt, and `error` is a safe failure explanation or null. A failed refresh
retains prior state and its successful timestamp. Before any successful fetch,
state is `unknown`, never a fabricated `not_reviewed`. A truncated request
history that prevents an accurate answer is treated as an unsuccessful refresh.

One background worker refreshes active reviews every 60 seconds and coalesces
overlapping requests. Each GitHub command has a maximum 15-second timeout.
Simple list requests read only the cache and never invoke GitHub or rebuild a
checkout. Status refreshes do not advance checkout revision or reorder reviews.

`POST /api/v1/pr-reviews/review-status/refresh` with
`{"request_id":"a-unique-request-id"}` queues a viewer-state refresh immediately.
It uses the existing main API token, returns HTTP 202 and
`{"ok":true,"refreshing":true}`, and performs no checkout mutation.
`refreshing` is false when there are no active reviews or runtime shutdown has
started. The existing per-review Refresh action also queues viewer-state work.
The PR Review capabilities response advertises `pr-review-dashboard-v1`.

All example data and test fixtures are synthetic. A companion upgrade is required
for these fields; delivering a Mac update does not install a companion package.
