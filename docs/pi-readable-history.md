# Pi conversation history versus model context

A conversation's readable history is not the same as the history sent to the
model. Pi compaction reduces model context but normally retains the original
session entries in its JSONL file. Herdr must not use that reduced context as the
only copy readers can see.

## What caused the missing history

Herdr's semantic bridge calls Pi's `buildContextEntries()`, which excludes older
messages after compaction. It also limits each live checkpoint to approximately
384 KiB, dropping older entries and any single oversized entry. Those limits keep
the local socket and live event journal bounded. The native and web clients used
to show only that checkpoint and later events. Their **Older context was omitted
by Pi** warning attributed Herdr's transport clipping to Pi and offered no route
to recover it. Compaction could also hide messages without that warning.

## Reader recovery

Companion 0.65.1b1 advertises `pi-readable-history-v1`. On the existing authenticated
`GET /api/v1/panes/{paneId}/pi/snapshot` route, it restores reader-visible entries
from the saved session named by the checkpoint:

- The file header must match the exact session ID. No cwd, latest-file, or label
  fallback is used. The file must be an owner-owned regular JSONL file, not a
  symlink or special device.
- The branch is walked through `parentId` links from the checkpoint's exact
  `leafId`. Abandoned branches and newer entries are excluded. Later turns still
  arrive through event replay, without advancing or rewriting its cursor.
- Prompts, assistant responses, tool activity, visible extension messages, and
  compaction/branch summaries remain chronological. Context edits and compaction
  do not erase the original reader-visible text.
- System prompts, private extension state, hidden extension messages, provider
  signatures, and large binary payloads are not exposed as reader history.
- Successful recovery sets `truncated: false` and adds
  `history: { source: "session_file", complete: true }`. This is compatible with
  existing clients. The bounded bridge checkpoint in SQLite is unchanged, as are
  model-facing session-context limits and Pi's context usage/compaction settings.

Mac initially mounts recent rows for responsive scrolling. **Show earlier rows**
reveals the older loaded rows. This display window is not deletion or model
compaction. Switching sessions or navigating the Pi tree loads the correct
branch; it does not concatenate unrelated conversations.

## Installation and verification

Install the matching companion server wheel on every machine that owns sessions,
using the [server update procedure](../herdr_harness/README.md#update-the-server).
Update its installed CLI/Pi package paths together as usual. The recovery works
with already-running older bridges that include session file and leaf metadata;
no Pi restart or `/reload` is needed for those sessions. No native app update,
upstream terminal replacement, database migration, or public transcript upload is
required. An app-only update cannot repair a remote server's truncated projection.

After updating a server, reopen an affected chat (or reconnect the client). Scroll
up and use **Show earlier rows** on Mac. Earlier prompts should be readable even
if large tool results or compaction followed them. Verify both a long existing
session and a compacted one; compare the exact selected branch, not the last
record in the session file.

## Limits and honest fallback

This restores retained local session data; it cannot recreate a deleted file,
messages never persisted by an ephemeral `--no-session` run, or tool text that Pi
itself never saved. Missing leaf/file metadata, a mismatched header, malformed or
incomplete ancestry, an unreadable file, or an individual JSONL record larger
than 64 MiB leaves the existing bridge transcript intact. An attempted but failed
recovery reports `history: { source: "bridge", complete: false }` and preserves
its original truncation flag, never falsely claiming a complete conversation.
Legacy clients may still show their old warning in this fallback case.

There is no aggregate 384 KiB reader-history cap. A small bounded memory cache
avoids repeated file scans; it does not impose a limit on the returned
conversation. Extremely large saved conversations can take longer to load.
Saved HUD chats and First Mate's separate paginated session viewers are unchanged.

## Focused regression checks

```sh
.venv/bin/python -m unittest discover -s tests -p 'test_pi_history.py'
.venv/bin/python -m unittest discover -s tests -p 'test_pi_semantic.py'
```

Coverage includes large and oversized entries, pre-compaction text, context edits,
multiple roots/branches, exact live replay boundaries, hidden setup and binary
redactions, invalid/mismatched files, safe cache invalidation, and recovery through
the existing manager without changing the journal or cursors.
