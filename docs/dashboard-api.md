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
  `blocked`, with a bounded checkpoint or recovery prompt.
- `assignment_count`, `running_assignment_count`: assignments in the current
  visit, including those carried across a revision. Running includes dispatch,
  child-wait, handoff, acknowledgement, and recovery states, but excludes queued
  and paused assignments.

The projection is one SQLite query. It does not load full feature snapshots.

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
