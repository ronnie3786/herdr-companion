# First Mate response feedback on Mac

Every completed text-bearing First Mate assistant response in the Mac
conversation offers compact thumbs-up and thumbs-down controls. The saved rating
is shown next to them, with an explicit label and selected state rather than
color alone. Feedback is local data collection for later manual review; nothing
in this feature changes prompts, preferences, models, or workflows.

## Interaction

- Controls appear under completed assistant responses only. User, human, and
  system messages have none.
- Older responses, checkpoint summaries, and responses inside closed or
  archived features remain rateable. This policy is independent of the
  three-reply quote window and of workflow status.
- **Thumbs up** saves immediately and shows **Helpful**.
- Rating controls are disabled until the retained ratings for that feature have
  loaded completely. The cached rating stays visible while loading, and no
  draft is seeded from the empty cache, so an early click can never overwrite a
  record that has not arrived yet.
- **Thumbs down** opens a small editor pinned to that exact response:
  - The three starting reasons appear with the exact requested wording:
    **Longer than it needed to be**, **Unnecessary message**, and
    **Incorrect assumption** (stable IDs `too_long`, `unnecessary_message`,
    `incorrect_assumption`). Reasons start unselected and any combination is
    allowed.
  - **Add** next to the reusable-reason field creates a persistent category for
    that companion, trims and collapses whitespace, deduplicates
    case-insensitively, accepts at most 80 single-line scalars, and selects the
    new or equivalent reason for the current response. At most 100 categories
    exist per companion. Categories are append-only: a delayed full catalog read
    merges by stable ID and never drops a category that was added while the read
    was in flight. Until a full catalog read has succeeded, the editor shows
    **Reload reasons** so the complete list can be fetched; adding one category
    is not treated as a complete load. A request that is confirmed after the
    editor is cancelled, dismissed, or invalidated by a feature switch or
    reconnect remains available in the catalog, but it never recreates or
    reselects the discarded draft; reopening the response starts from the
    retained rating.
  - **Notes** is an optional multiline field preserved exactly as typed,
    including Unicode and line breaks, up to 4000 Unicode scalars. The editor
    shows the running count and clamps further input at that boundary.
  - **Save feedback** records the negative rating even when no reason or note is
    selected. **Cancel** (or Escape) changes no rating and discards the edit,
    including a reusable reason confirmed after cancellation. A failed save
    keeps the editor and everything typed visible, reuses the same request
    identity, and offers **Retry save**; the previously saved rating is never
    changed optimistically.
- Each editable draft is pinned to the retained revision it was loaded from.
  A successful fetch that found no record pins revision zero, so a delayed read
  that discovers another client's first rating conflicts with the typed draft
  instead of silently replacing it. A refresh that arrives while the editor is
  open updates the read-only cache but never rebases the draft. Saving with a
  stale revision is rejected and shows **Reload latest**; that explicit action
  reloads the record and rebases the preserved reasons and note so the next
  **Save feedback** uses the new revision and a fresh request identity. The
  editor cannot save a conflicting draft before that reload.
- While a save is in flight the editor freezes: category rows, the reusable
  reason field, **Add**, the note, and **Cancel** are disabled and interactive
  dismissal is blocked, so input typed after submission cannot be silently
  discarded. On failure the same draft is restored exactly as submitted for
  retry; on success the editor closes normally.
- A failed **Thumbs up** or **Remove rating** save changes no rating and shows a
  compact error under that response. A plain failure offers **Try again**, which
  resubmits the exact attempted payload and reuses its request identity. A
  stale-revision rejection instead offers **Reload and retry**, which reloads
  the latest revision, rebases the preserved up/clear payload, and retries with
  a fresh request identity only after that explicit action.
- A response has one current rating. Selecting thumbs up on a negative response,
  or **Remove rating**, clears the reasons and note only after the save
  succeeds.
- Selecting thumbs down again reopens the editor prefilled with the saved
  reasons and note; each response's writes are serialized so overlapping saves
  cannot interleave.
- The editor is pinned to the captured response, feature, and connection
  lifecycle. Switching features, reconnecting, or rotating the lifecycle
  dismisses and invalidates it instead of retargeting another response. The
  saved rating remains readable; unavailable or read-only states disable writes
  without hiding what is already saved.
- When the workspace is read-only, the footer still shows the saved rating but
  the rating controls are disabled.

## Storage locality and privacy

- Ratings, reasons, notes, custom categories, and provenance are stored only in
  the owning companion's private `first-mate.sqlite3` beside the work ledger,
  under the operator's configured private state directory. Existing databases
  migrate additively.
- This is local-to-companion storage, not Mac-only storage. The Mac app keeps
  only an in-memory cache for the current connection and feature, clears it when
  the connection is reconfigured, and reloads from the companion. Feedback is
  shared by clients authorized to that companion and is not synchronized through
  any separate Mac database or cloud service.
- The built-in synthetic demo stores feedback in memory only.
- Provenance is captured once, when the assistant response is created, from the
  runtime's exact verified session: verbatim response text and time, source kind
  (`reply` or `checkpoint`), `in_reply_to`, producing visit, plan revision, and
  coordinator session ID. Rating never substitutes the feature's current
  coordinator session, so a later session rotation cannot reattribute an older
  response.
- Responses created before this surface existed remain rateable with explicit
  unknown provenance: `session_provenance: "unavailable"`, a null coordinator
  session, and `source_kind: "legacy"`.
- The companion keeps one current feedback record per response and stores an
  idempotency receipt for each accepted request together with its result, so an
  identical retry replays safely and reusing a request ID with different
  content is rejected. **Remove rating** writes a new current revision with
  `rating: null` instead of deleting the record; it is not described as complete
  historical erasure, because the record and earlier accepted receipts remain
  in the private database.
- Recording feedback does not enqueue a conversation message, wake an agent,
  change feature status or revision, append workflow events, call a model, or
  publish data. Feedback text is private and is not written to public logs or
  reports. No automatic prompt injection, preference change, analytics export,
  model training, or conversation refinement is implemented.

## Compatibility and separate server installation

- The companion advertises `first-mate-feedback-v1` through
  `GET /api/v1/first-mate/capabilities` and `GET /api/v1`.
- A companion without the capability receives no feedback requests. The Mac app
  shows one upgrade notice in the First Mate conversation, does not add
  per-response controls for unsupported hosts, and never substitutes another
  host.
- Installing or restarting the companion is a separate step from a Mac app
  update. The signed Mac feed updates only the app and does not install
  companion server packages. This release does not deploy, publish, or install
  the companion; publishing a server package and cutting it over on any host is
  a separately authorized operation. Publish companion packages separately and
  restart the companion on each host that owns First Mate features; reconnect or
  refresh the Mac app afterwards.
- The iPhone/iPad and web clients do not offer the rating controls in this
  release. Ratings and reasons saved from an updated companion are the same
  records the Mac reads when it loads that feature.

## Authenticated readback and private inspection

Feedback is read back through the existing authenticated First Mate routes.
They use the same authenticated First Mate prefix, bearer token, and scoped
credential rules as the other First Mate routes: a credential that is rejected
there is rejected here too, and feedback never broadens what a token can
access.

```
GET /api/v1/first-mate/feedback-categories
GET /api/v1/first-mate/features/{feature_id}/feedback
POST /api/v1/first-mate/feedback-categories
POST /api/v1/first-mate/features/{feature_id}/messages/{message_id}/feedback
```

The feature read returns every retained record for that feature, ordered by
feedback creation, including cleared revisions. A record includes `rating`
(`up`, `down`, or `null`), `category_ids`, the verbatim `comment`, `revision`,
timestamps, and the frozen `provenance` object. The exact validation, bounds,
conflict codes, and provenance fields are part of the First Mate build contract
(`docs/first-mate/build-contract.md`). The `herdr-first-mate` CLI does not add
feedback commands in this release.

For private review, the database can be read directly with SQLite's read-only
mode. Use the operator's configured private state directory; do not copy a
database while it is being written.

```sh
sqlite3 -readonly "<private-state-dir>/first-mate.sqlite3" \
  "SELECT feature_id, message_id, rating, category_ids_json AS category_ids, comment, revision, updated_at FROM fm_feedback ORDER BY updated_at;"
```

Readback is inspect-only. There is no export, upload, or training route, and
refining future First Mate behavior from these labels remains a manual,
separately designed step.

## Manual verification checklist

Use synthetic features, responses, categories, and a disposable companion
state. Do not capture operator configuration or real conversations.

- [ ] In the synthetic demo, rate a response thumbs up and confirm the immediate
      saved **Helpful** state. Then open thumbs down and confirm all three
      starting reasons use the exact requested labels and start unselected.
- [ ] Select multiple reasons independently, add a reusable custom reason with
      **Add**, type a multiline note, save, and confirm the status line reports
      the saved reasons and note.
- [ ] Reopen the editor, confirm the saved reasons and note are prefilled, then
      Cancel and confirm the saved rating is unchanged.
- [ ] Rate a response, open the editor, and edit it while another authorized
      client advances the same response's feedback. Confirm the open draft is
      not rebased, **Save feedback** reports the conflict, **Reload latest**
      restores saving with the preserved note, and the retry succeeds. Repeat
      with **Thumbs up** and **Remove rating** and confirm **Reload and retry**
      recovers each attempted payload.
- [ ] With a slow or interrupted save, confirm category rows, the note field,
      **Add**, and **Cancel** are disabled while the save is in flight and that
      the exact submitted draft comes back if the save fails.
- [ ] Edit the selection and confirm the saved status updates only after Save.
- [ ] Use **Remove rating** and confirm the active label clears and the up/down
      controls return to an unselected state. Confirm user messages never offer
      feedback controls.
- [ ] Add a custom reason on one response, rate a different response in the same
      feature, then switch to another feature and confirm the reason remains
      available on that companion while the first feature's rating does not
      appear anywhere else. If the full reason list failed to load, confirm the
      editor shows **Reload reasons** until a full fetch succeeds and never
      drops a reason added while a read was in flight.
- [ ] Save feedback, restart the disposable companion, relaunch the Mac app,
      and reconnect: confirm the exact ratings, reasons, notes, and custom
      categories are restored from the companion database.
- [ ] Force a save failure (for example by disconnecting the host mid-request)
      and confirm the editor stays open with the typed content, the previously
      saved rating is unchanged, and **Retry save** reuses the same request and
      succeeds after reconnecting. Also confirm a failed thumbs-up or
      **Remove rating** keeps the previous label and shows the compact
      **Try again** retry under that response.
- [ ] Against a companion without `first-mate-feedback-v1`, confirm exactly one
      upgrade notice appears and no feedback request is sent. After separately
      installing and restarting the updated companion, confirm the controls
      appear on refresh or reconnect.
- [ ] Rate a response inside a closed or archived feature and confirm it remains
      rateable and does not change feature status, revision, events, or queued
      work.
- [ ] On two differently configured disposable hosts with duplicate feature and
      message labels, confirm each host's feedback stays with its own connection
      and switching hosts never retargets an open editor or save.
- [ ] Check light and dark appearance at every app text size, with long reasons,
      a long note, and VoiceOver: every control has a name, the selected state is
      announced without relying on color, and Save/Cancel/Retry are reachable by
      keyboard.

These items are a release-gate checklist, not claims of execution. Record
exact-source automated results and synthetic rendered-UI evidence separately in
[First Mate delivery verification](verification.md); UI evidence is never
recorded as connected-app persistence.
