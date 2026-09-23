# Next companion update, unreleased

## First Mate archive

- Adds `first-mate-archive-v1` as an additive authenticated API capability.
- First Mate feature lists default to active records and accept deterministic `archived` and `all` views.
- Archive and unarchive are idempotent actions on the existing feature actions route. Optional reasons are validated as test/synthetic, duplicate, no longer relevant, superseded, or other.
- Archive is independent of workflow status. It retains visits, assignments, documents, sessions, events, Active Work linkage, and work item identity. Running work continues, while default lists and attention counts exclude archived features.
- Existing databases migrate additively. Older clients safely ignore the new nullable fields.

## Tab color discovery

Tab colors and labels can now be discovered without changing any client's local
store. Companion capabilities, endpoints, and `GET /api/v1` advertise
`chat-tab-colors-v1`. A Mac app that enables its separate **Share tab colors
with companions** setting publishes a read-only copy of each known tab's color
and effective label to the dedicated authenticated
`POST /api/v1/control/chat-tab-colors/{clientId}` route. `GET /api/v1/snapshot`
then adds `chatTabColorSources` and a per-tab `chatTabColors` array whose entries
name the publishing `clientId` and report `assigned`, `unassigned`, or
`unavailable` state, with last-known values marked `stale` after 60 seconds
without a publication or heartbeat. Discovery accepts the additive `color`,
`colorLabel`, `colorClientId`, and `chatScope` parameters; all color predicates
must match the same publisher entry and are applied before pagination.

The updated CLIs expose the data read-only:

- `herdr-control find chats|tabs` adds `--color`, `--color-label`,
  `--color-client`, and page-scoped `--group-by color|label`.
- `herdr-hud-chats list|search --scope terminal` reads live terminal chats with
  the same filters and grouping. The default saved HUD history, its envelope,
  and `show` are unchanged; color options there are rejected with a
  `--scope terminal` suggestion.

The `chat.tab-color` agent action is disabled. Relay catalogs return it with a
read-only reason, the CLI refuses it before enqueueing, and command admission
and claim reject it, including commands queued before the upgrade. Manual color
assignment, removal, and label editing in the app are unchanged. There is no
color or label write endpoint, and no client's local colors are imported or
synchronized.

This is an additive companion change. Existing clients ignore the new fields,
and a companion without it keeps its current snapshot shape while the newer
CLIs report an explicit unsupported capability instead of an empty match. The
feature needs the updated companion **and** the matching installed CLIs, plus a
Mac app that supports publication; update the wheel and the CLIs on each machine
whose colors should be discoverable. A Mac app update alone does not install or
update companion server packages or CLIs. See `docs/chat-tab-colors.md` and
`docs/chat-tab-color-api.md` for setup, commands, freshness, and error
semantics. This note does not perform any deployment.

## Issue report drafting

Adds an additive `issue-report-draft-v1` one-shot Agent-run profile for the Mac
report sheet's optional smart input.

- `/api/v1/agent-runs/capabilities` advertises the profile in `profiles` and
  describes it under the additive `issueReportDrafts` object (`tools: none`,
  `oneShot: true`, kinds `bug`/`feature`, request fields `kind` and `text`,
  output fields `title` and `body`, JSON response format, the source/title/body
  scalar limits, and `maxSeconds: 60`).
- The authenticated `POST /api/v1/agent-runs` route accepts only
  `{profile, kind, text}` for this profile and rejects every other field instead
  of ignoring it, so an attachment, working directory, model override, system
  prompt, pane scope, continuation, or supplied context cannot ride along.
- The server executes exactly one run in `ask` mode with thinking Off, no
  tools, no explicit extension, an empty topology, and no profile snapshot or
  awareness bootstrap. If a configured execution timeout is shorter, the
  shorter value applies; the profile is capped at 60 seconds. The stored run
  cannot be continued or promoted, and no generic-agent fallback exists.
- The source text travels on Pi's stdin as the exact JSON object
  `{"kind": …, "text": …}`. The server owns the drafting charter: a concise
  single-line title and structured Markdown body for the chosen kind that
  preserve the supplied details and never invent facts.
- The Mac app sends the request only after it sees the advertised profile, so
  an older companion keeps manual reporting, recording, and transcription and
  shows upgrade guidance for the optional AI action alone.

This is an additive companion change. Older clients are unaffected, and a
companion without the profile is never sent a drafting request. Install the
updated companion package separately from the Mac app; a Mac update does not
install server packages. See `docs/issue-report-smart-input.md` for interaction,
privacy, limits, and verification responsibilities.

Update the companion separately from the Mac app. No server cutover is performed by installing a native app update.
