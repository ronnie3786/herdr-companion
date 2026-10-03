# Archive cleanup and completion history

On Mac, choose **Archive…** from a completed session's context menu. A blocking
review shows every host-owned cleanup candidate, then a spinner and live
newest-first operation log follow the confirmed archive through its saved
completion record. The user chooses the exact resource IDs, whether readable
live document bodies remain, and whether the readable live conversation
remains. The confirmed selection is saved with that archive generation and
retries cannot broaden it. Mac, iOS and the browser show **Overview → Archive
cleanup**, with progress, approximate reclaimed bytes, a completion record,
the removal/retention log and a retry button. Enable **Show archived** to find
the session again. Mac's session sidebar has **Search completed work**; on iOS
use **First Mate options → Search completed work → host**. The browser has the
same search in its sidebar. Search includes requests, outcomes, documents,
commits and saved links. **Export Markdown** saves the complete report.

In the Mac project editor, **Archive project** can optionally **Review completed
sessions for cleanup**. Each exact session opens the same review in sequence
before the project entry is archived. Project-only archive never cleans a
session, reports zero cleanup bytes, and always retains the source folder.

The companion advertises `first-mate-archive-cleanup-v1` and
`first-mate-archive-review-v1`. The legacy archive request remains compatible
for independently updated clients and remains visibility-only, with no cleanup
generation and no filesystem or Git deletion. A
review-capable client sends the preview token, expected feature revision, and
explicit cleanup options together. Mac disables completed-session archive when
a companion advertises cleanup-v1 without archive-review-v1, so it cannot bypass
the review. Original companions with no cleanup capability can still perform the
older hide-only archive. Selective review is available on Mac and in the browser.
Install the server/Pi package separately from any native client update. This
feature does not deploy a server or run a retroactive cleanup during upgrade.

## Requirements and implementation choices

The [product brief](archive-resource-cleanup-brief.md) requests smart cleanup
when completed sessions are archived. This implementation requires an exact
reviewed selection before cleanup, plus useful durable documentation, ownership
checks, protection of unfinished work and unsaved source, understandable results,
safe retries, and preserved historical verification/usage. Its individual
retention examples are proposals, not blanket deletion authorization.

These are the conservative defaults chosen for this implementation:

| Resource | Default and rationale |
| --- | --- |
| Runtime-created temporary builds and caches | Delete only directories explicitly allocated for this session by `fm_allocate_resource` or `allocate-resource`. Check the managed path, original filesystem identity and absence of overlapping ownership before deletion. Links, mounts and nested repositories cause retention. |
| Runtime-created isolated worktrees | Record ownership at creation. Remove only if the recorded repository, path, branch and final revision still match, no tracked/untracked/ignored changes exist, no other session references the workspace, and every commit is reachable from the recorded independent project branch. Git removal never uses force. |
| Task branches | Remove only after the worktree is gone, if no other worktree checks out the branch and the exact saved tip is integrated. A Git ref transaction compares the branch tip and verifies the surviving integration tip together. No remote branch changes. |
| Unmerged, dirty, untracked or ignored source | Retain. Unmerged branches also retain their worktrees. Squash/cherry-pick equivalence is not inferred. Because retries cannot broaden the reviewed selection, integrating the exact commits permits deletion only after unarchiving and starting a new reviewed archive generation. |
| Older or unregistered resources | Retain. Assignment paths are documented as legacy/shared without adoption. There is no directory scan that infers ownership from names. |
| Shared project folders/build caches | Retain, including folders belonging to archived projects or other sessions. Archiving a project entry never queues session cleanup. |
| Documents | Always retain original bodies and hashes in the verified completion catalog. The archive choice either keeps the readable live bodies too, or replaces each live body with a catalog pointer while preserving its document ID and references. This is SQLite compaction, not a promise of immediate free-disk growth. |
| Conversations | Always retain the original human request and full conversation in the verified completion catalog. The archive choice either keeps the readable live transcript too, or replaces live message and feedback-source bodies with catalog pointers while preserving IDs and references. Derived skim caches are removed only after they have been captured in the catalog, because their offsets no longer describe the pointer text. |
| Artifacts and published builds | Retain. Saved links and recorded build/version references remain searchable. Existing artifact copies and published releases are outside cleanup; external availability and independent artifact retention are not guaranteed by this feature. |
| Execution logs and recovery backups | Retain. Backup deletion requires stronger independent preservation evidence than the current ledger supplies. |

There is no time-based retention expiry for completion records. Eligible
disposable resources are processed as soon as the completion record has been
saved and all recorded execution writers have stopped. Archive of active,
paused or cancelled work only changes visibility. Completing an already archived
active session does not retroactively authorize cleanup; a new archive
transition is required. No existing archive is swept on installation.

Unarchiving restores list visibility and cancels queued work before its next
destructive operation. It does not undo finished deletion, recreate worktrees,
restore branches, expand catalog pointers, restart agents or reopen the completed
workflow. History remains available after unarchiving. A later archive gets a
new completion record and reconstructs cataloged originals from the exact
verified archive named by each pointer. Prior records remain searchable.

## Ownership and deletion boundary

The SQLite ledger adds `fm_owned_resources`, `fm_archives`, `fm_cleanup_log`,
and `fm_catalog_pointers`. Ownership is created by the host runtime when it actually
creates the directory. Existing paths are never adopted, including uncertain
paths left between filesystem creation and a failed ownership commit. Newly
created worktrees record the common Git directory, filesystem identity,
branch and independent project integration ref. Detached project HEADs are
retained because no integration branch can be established.

Build output can be directed into explicitly disposable space:

```sh
herdr-first-mate allocate-resource FEATURE_ID --kind temporary_build --request-id build-space-1
```

Use the returned **host-local** path as a build's output directory. Managed Pi
coordinators/workers have `fm_allocate_resource({"kind":"temporary_build"})`
and `fm_allocate_resource({"kind":"cache"})`. These allocate new space, accept
no deletion path, and never grant authority to relocate shared data. Keep final
deliverables, source and backups elsewhere. Read-only advisors cannot allocate.
Older extensions remain compatible but cannot allocate this space.

The preview accepts no caller-supplied path. It inventories only
`fm_owned_resources`, runs the same managed-path, filesystem identity, overlap,
symlink/mount/repository, dirty-worktree and integrated-branch checks used by
live cleanup, and reports exact retention reasons. Its token privately binds the
feature revision, resource identities, directory observations, current branch
and integration tips, and document/message versions. `GIT_OPTIONAL_LOCKS=0`
keeps preview Git reads from refreshing the index. Logical byte estimates may be
unknown; branch-ref removal explicitly estimates zero because it does not run
Git object collection.

The archive transition and cleanup queue commit together. An enhanced request
is rejected as `archive_preview_stale` if the preview no longer matches or if a
selected ID is no longer eligible. The runtime waits
for coordinator ownership, assignments and job writer locks to settle. It
captures the original human request, final goal, dates, full stage/assignment
and attempt records, outcomes, documents, links, session identities, execution
receipts, actual verification inventories/runs/assessments, and available usage.
Unknown or unrecorded facts stay unknown. This is an evidence-based report,
not a model-generated claim of success.

The compressed record has a SHA-256 digest and document hashes are checked.
Its SQLite transaction commits before any removal begins. Every deletion
rechecks the saved record, exact archive generation, current workflow,
stopped writers, ownership and filesystem/Git safety. Historical aggregate
usage and verification are frozen separately for lightweight client polling;
verification is explicitly labeled historical rather than recomputed against
a deleted workspace. Identifiers and references remain intact. When the user
chooses catalog compaction, verified bodies live in the immutable record while
operational rows carry catalog pointers and derived skim rows are removed.

Cleanup processes one operation per scheduler pass. A committed log entry
precedes catalog compaction or removal, then a terminal
cataloged/removed/retained/failed entry records the
outcome. Reclaimed space is a logical file-size estimate, not a measurement of
free disk space (clones, hardlinks and compression differ). An interrupted
removal may already have removed files; a retry never credits absent files as
newly reclaimed space. Already removed resources cannot authorize deleting a
new directory at the old path. Failed records block deletion and produce an
explanation. A retry preserves the original completion snapshot and appends a
new attempt, including the earlier failures.

## API and CLI

All new routes require the companion's full authentication, like other First
Mate data. They run exclusively on the requested host and accept no alternate
filesystem root or force option.

| Route | Contract |
| --- | --- |
| `GET /api/v1/first-mate/features/:id/archive-preview` | Read-only review with `feature_id`, `feature_revision`, opaque `token`, eligibility/reason, resource candidates, logical byte estimates, document/message counts, defaults and exact live-copy retention semantics. No query fields or paths are accepted. |
| `POST /api/v1/first-mate/features/:id/actions` | Legacy archive remains `{action,request_id,reason?}`. Reviewed archive sends `{action:"archive",request_id,expected_revision,preview_token,cleanup_options:{resource_ids,keep_documents,keep_chat}}`; all review fields are required together. Response pins `archive_id` and its `cleanup` even when an idempotent replay occurs after another archive generation. |
| `GET /api/v1/first-mate/features/:id/archive-progress?archive_id=...&after=0&limit=100` | Bounded structured log, at most 200 rows, plus cleanup summary and `next_after`. Omit `archive_id` only for the initial latest lookup, then pin the returned ID. A separate WAL reader keeps committed intent visible while a filesystem or Git removal holds the writer transaction. |
| `GET /api/v1/first-mate/history?q=...&offset=0&limit=50` | Literal search, up to 50 records with `next_offset`; query up to 500 characters. Includes previous archive generations. |
| `GET /api/v1/first-mate/features/:id/archive-record` | JSON with Markdown `report`, `cleanup`, `sha256` and `next_offset`. Optional `id` selects a retained archive record. `offset`/`length` page at most 80,000 characters. Send the returned `sha256` on subsequent pages; a changing report returns 409, preventing an inconsistent export. |
| `POST /api/v1/first-mate/features/:id/archive-cleanup/retry` | `{ "request_id": "unique-command-id" }`. Idempotent; requires the same completed, archived session. Completed runs may retry resources previously retained after their conditions change. |
| `POST /api/v1/first-mate/features/:id/resources` | `{ "kind": "temporary_build", "request_id": "unique-command-id" }` (or `cache`). Returns a new private directory and explicit disposable retention. Open, unarchived sessions only. |

Feature list/detail/board payloads add optional `archive_cleanup` with
`id`, `status`, `attempt`, `message`, `history_available`, `bytes_reclaimed`,
`removed`, `retained`, `failed` and `updated_at`. States are `pending`,
`waiting`, `running`, `completed`, `failed`, and `cancelled`. Retry counters
describe the latest attempt; reclaimed bytes total successful removals across
attempts. `archive.cleanup` journal events invalidate board polling as progress
changes. Verification adds `historical_only` after preservation.

```sh
herdr-first-mate history --query watering
herdr-first-mate archive-report FEATURE_ID --output ./completion.md
herdr-first-mate archive-report FEATURE_ID --record-id ARCHIVE_ID
herdr-first-mate retry-cleanup FEATURE_ID --request-id cleanup-retry-1
```

Exports never overwrite an existing file. The original report and all cleanup
attempts stay in the private companion ledger. Back up that database using the
repository's SQLite backup guidance.

## Validation

`tests/test_first_mate_cleanup.py` exercises deletion against synthetic Git
repositories and temporary files, including dirty/unmerged/shared resources,
ownership changes, same-size Git-tip changes, stale previews, explicit selection,
catalog pointer provenance, marker-like human text, re-archive reconstruction,
save/integrity failures, retry and unarchive behavior. It also proves progress
can read committed intent while a destructive operation is blocked under the
writer lock.
`tests/test_first_mate_archive_http.py` covers host-local allocation, full
authentication, preview/confirmation replay across archive generations, pinned
bounded progress, bounded report paging and fingerprint checks. Shared native
tests cover additive decoding, historical verification and complete exports;
the Mac render test uses synthetic records in both appearances. Browser and
CLI tests exercise their user-facing contracts. No test targets live sessions.
