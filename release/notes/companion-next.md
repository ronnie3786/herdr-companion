# Next companion update — unreleased

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
