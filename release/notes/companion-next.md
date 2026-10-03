# Next companion update, unreleased

## Share Agent Roles

- Adds `agent-roles-share-v1`. `GET /api/v1/agent-roles/export?preview=1` lists
  exportable roles; `GET /api/v1/agent-roles/export?roleIds=…` returns a
  `herdr-agent-roles` v1 document with each role's stored skill copies. Untouched
  built-ins, Recovery Advisor, machine IDs, revisions, team IDs and paths are never
  exported, and a private key in a prompt or skill file blocks the export.
- `POST /api/v1/agent-roles/import` plans a file with `dryRun: true` and applies a
  reviewed plan atomically with `planDigest`, `expectedRevision`, `roleIds` and
  `replaceRoleIds`. Existing roles change only when listed in `replaceRoleIds`.
  Skills are matched by content; a skill ID this computer already uses for other
  files is installed under a derived ID, so existing copies never change. Teams
  are matched by name. A commit bumps the revision and publishes
  `agent_roles.changed` once; dry runs and no-op imports do neither.
- The import route accepts the same 16 MB body as role saves. Deeply nested
  JSON bodies now return 400 instead of a server error.
- Requires the saved-teams companion changes (`pr-review-teams-v1`). Older Mac
  apps are unaffected. Install and restart this package separately from the Mac
  app.

## Turn Watchers on from the app

- A person can turn Watchers on or off per machine without editing
  configuration or restarting the companion. `POST /api/v1/watchers/settings`
  takes `{request_id, enabled, confirmed_by: "user", changed_via?}`, works while
  Watchers is off, returns the capabilities payload, and starts or stops the
  scheduler at once. Turning it off never signals detached runners. Each change
  publishes `watchers.updated` with `settings`; `GET /api/v1` lists
  `watchersSettings`.
- Capabilities add `settings: {enabled, source: config|app|default, changeable}`.
  `HERDR_WATCHERS_ENABLED` set to `"1"` or `"0"` still wins and makes the
  setting read-only (409 `watchers_setting_locked`); other values are now
  ignored. Otherwise the choice lives in a private `watchers-settings.json`
  under the state root (`HERDR_HARNESS_WATCHERS_SETTINGS_PATH` overrides it).
- `herdr-watchers enable|disable --i-confirm` are person-only verbs, like
  `activate`. `doctor`, `machines` and the disabled error point to the app or
  `enable`; `machines` rows include `settings`. Agents hold the main token, so
  `confirmed_by: "user"` is an audit convention, not a security boundary.
- Machines that set `HERDR_WATCHERS_ENABLED=1` behave as before, and older Mac
  apps are unaffected. Install and restart this package separately from the Mac
  app.

## Watchers

- Adds the optional `watchers-v1` API, disabled until `HERDR_WATCHERS_ENABLED=1`.
  Schedules support intervals, daily times, cron and one-time tasks in IANA
  timezones, with daylight-saving handling and bounded next-fire calculations.
- Private definitions, script revisions, run history and Watcher inbox results
  survive restarts. Detached script workers, checks, overlap control, catch-up,
  cancellation, liveness checks and retention work while the Mac app is closed.
- `herdr-watchers` provides schema and asset discovery, draft/script editing,
  non-executing schedule and Cronboard import previews, history, inbox, bundles,
  and doctor. Confirmed Cronboard imports arrive resting and never change the
  original jobs. Cutover and rollback remain explicit operator actions.
- A focused skills-enabled Watchers agent builder supplies the feature context,
  asks about unclear requirements and saves drafts for the person to activate.
  Main-token activation records are an audit convention, not scoped security.
- Install and restart this companion package separately from the signed Mac app
  update. See `docs/watchers.md` for compatibility, private configuration and
  migration instructions.

## First Mate simulator checkpoints (SimPortal)

- Adds `first-mate-simulator-previews-v1`, advertised by `GET /api/v1` and
  `GET /api/v1/first-mate/capabilities`. It connects First Mate to SimPortal,
  a separate local service that saves compiled iOS Simulator builds and
  streams simulators. The feature is inert until the private configuration has
  a `[simportal]` section (`url`, `token_file`, `intake_root`; optional
  `project_id`, `device_type`, `runtime`, `idle_shutdown_minutes` (default 60),
  `max_running_previews` (default 4), and `server_id`).
- Managed coordinators and workers on a configured machine get
  `fm_register_simulator_build`. The companion derives the feature, stage,
  assignment, and session itself (like `fm_save_link`), validates that the path
  is an iOS Simulator `.app` in the workspace, DerivedData, or a temporary build
  folder, copies it into SimPortal's approved intake folder, and registers it.
  Workers are asked to save one at the end of each round of iOS app work.
  Registration adds `simulator.build_ready`/`simulator.build_failed` journal
  events. A saved build is never verification evidence.
- New routes: `GET /first-mate/simulator`, `GET
  /first-mate/features/{id}/simulator-builds`, `POST
  …/simulator-builds/{build_id}/preview` (reuse a running simulator or start
  one), `GET` and `POST …/stop` on `…/simulator-previews/{preview_id}`, and a
  WebSocket relay at `…/simulator-previews/{preview_id}/stream` scoped to that
  preview's exact simulator. The relay attaches with `focus: false` and drops
  `focus` and `boot` messages, so it never changes SimPortal's shared focus.
- Every SimPortal mutation is persisted with its request ID and exact body
  before it is sent and replayed unchanged after a lost response, so a retry
  never creates a second build or simulator. SimPortal's server identity is
  pinned; a replaced server stops automatic changes until an operator sets
  `[simportal] server_id`.
- Resource policy: at most `max_running_previews` (default 4) Herdr simulators
  run per machine (opening one more shuts down the least recently watched idle
  one), and a simulator nobody has watched for `idle_shutdown_minutes`
  (default 60) is shut down. Only this companion's own previews are ever
  stopped; other simulators are never touched, and none are ever deleted.
- A preview whose simulator was deleted in SimPortal (its Machines page)
  reports phase `stopped` with status `simulator_deleted`; a stop refused for
  that reason settles quietly instead of recording an error.
- State lives in a new private `simulator-previews.sqlite3`; `first-mate.sqlite3`
  gets no schema change. SimPortal must run on the machine that compiles the
  builds, with enough free disk for its admission floor (20 GB by default).
  See docs/first-mate/simulator-previews.md.
- Install and restart the companion package separately from the Mac app. The
  Mac updater does not install or restart companion server packages.

## First Mate fleet summary and read markers

- Adds `first-mate-fleet-v1` as an additive authenticated API capability,
  advertised by `GET /api/v1` and `GET /api/v1/first-mate/capabilities`. It
  backs the Mac First Mate chat window and its Dock badge.
- `GET /api/v1/first-mate/fleet?view=active|archived|all` returns one small
  entry per feature: label, emoji, a HUD status that separates **Your turn**
  from **Ready for review**, the Plan/Build/Review/QA/PR/Merge step from the
  current stage, a one-line "now", the latest message (with its skim sentence
  when one is ready), the read marker, unread, and whether First Mate is
  working on a reply. It is one SQLite query and never scans job files or
  session usage, so polling it is cheap.
- `POST /api/v1/first-mate/features/{featureId}/read` stores a per-feature read
  marker so every client agrees on what is unread. It only moves forward, so
  replays and racing windows are harmless.
- `POST /api/v1/first-mate/features/{featureId}/hud` sets or resets a feature's
  user label (up to 100 Unicode code points after trimming, on one line) and emoji.
  Default labels still clip the feature title to 24 code points at a word boundary.
  Without a user emoji, the server picks a stable default from the feature ID
  with the same rule the Mac app uses.
- These are presentation writes: they never wake First Mate, enqueue work,
  append events, change status or revision, reorder the list, or change the
  Agent view board version.
- Existing databases migrate additively (a new `fm_feature_presentation` table,
  schema version 15); no existing row changes. Older clients ignore the new
  routes. A Mac app that needs the capability falls back to the existing
  feature list against an older companion, where the unread dot equals the
  attention badge and labels and emoji are the client defaults.
- Install and restart the companion package separately from the Mac app. The
  Mac updater does not install or restart companion server packages.

## Quick-session launch options

- Adds `quick-session-launch-options-v1` as an additive authenticated API
  capability, advertised by the `GET /api/v1` capability list.
- `POST /api/v1/quick-sessions/pi` additionally accepts optional `model`
  (`{provider, id}`), `thinkingLevel`, and `focus` fields, and accepts the
  endpoint-scoped `cwd: "~"` home alias. Values are validated before any
  workspace, tab, or pane mutation and forwarded to the existing quick-session
  implementation. Omitting or nulling model/thinking and omitting focus keeps
  the legacy payload byte-for-byte.
- The home alias resolves to the server account's home directory on the
  execution machine, not the request process and not the target workspace's
  folder. Other endpoints keep rejecting `~` and short relative paths, and an
  unavailable home fails before any mutation.
- Existing request-ID idempotency is unchanged: replaying a request ID with
  different model, thinking, focus, or target content fails with a conflict and
  starts no duplicate session, while an unchanged replay returns the original
  result.
- The Mac app uses this capability for its new-chat **Create in main workspace**
  option and local/default-model routing: it pins the execution companion's
  declared default model, passes the selected thinking level, creates without
  focus, and reuses the existing saved workspace ID and working folder. An
  older companion keeps serving saved-HUD chats with the existing quick-session
  fields; a newer Mac app checks the capability first and sends no new fields
  when it is absent.
- Additive and backward compatible for existing clients, the web client, and the
  Pi package. Install and restart the companion package separately from the Mac
  app; a Mac update does not install or restart server packages.

## First Mate response feedback

- Adds `first-mate-feedback-v1` as an additive authenticated API capability.
- Completed First Mate assistant responses can be rated thumbs up or thumbs down. Thumbs down opens a feedback editor with the starting reasons Longer than it needed to be, Unnecessary message, and Incorrect assumption, reusable custom categories, and optional verbatim multiline notes. Ratings can be edited or removed later.
- Feedback and custom categories are stored only in the owning companion's private `first-mate.sqlite3` database, survive companion restarts and Mac reconnects, and are never uploaded, used to train a model, or applied to conversation preferences. Recording feedback does not enqueue messages, wake agents, change feature state, or call a model.
- Each record answers the feature, exact durable response, saved rating, reasons, comment, and provenance such as the producing coordinator session, visit, and plan revision. Legacy responses remain rateable with explicitly unavailable session provenance, and coordinator rotation cannot reattribute an earlier response.
- Existing databases migrate additively. Older servers expose no feedback capability and receive no feedback writes; the Mac app shows upgrade guidance instead of substituting another host.
## First Mate feature links

- Adds `first-mate-links-v1` as an additive authenticated API capability. First
  Mate detail snapshots gain a `links` array containing visible and hidden
  feature links.
- `POST /api/v1/first-mate/features/{featureId}/links` saves a bounded absolute
  HTTP(S) URL with an optional title and kind. Recognized exact GitHub pull
  request URLs canonicalize to their pull request root with owner/repository
  casing folded, and deduplicate across casing variants; bracketed IPv6
  literals with a port, path, query, and fragment round-trip unchanged.
  Draft/ready/merged/closed state is never inferred, fetched, or published.
- `POST /api/v1/first-mate/features/{featureId}/links/{linkId}/visibility`
  reversibly hides or restores one feature-owned link. Both routes are
  receipt-idempotent, reject client-supplied provenance, never enqueue
  coordinator work, and return the same full snapshot as the detail endpoint.
- Existing databases migrate additively. Older clients safely ignore the new
  snapshot field, and links stay private on the owning companion. Discovery
  reads only paged, lightweight feature-owned inventory and bounded content
  slices; it never reads a public snapshot or drains an over-long record.
- Install and restart the companion separately from the Mac app. A native app
  update does not install or restart companion server packages.

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
- The run's system prompt is exclusively server-owned: Pi's own prompt is
  replaced and the discovered `SYSTEM.md`/`APPEND_SYSTEM.md` are suppressed, so
  no private companion instruction can enter a drafting request. A short-lived,
  server-owned workspace beneath the system temporary directory disables
  automatic agent/provider retries and automatic compaction recovery for this
  run only, keeping one draft at one provider inference without modifying
  operator Pi settings. Pi appends the process working directory to every
  system prompt, even when `--system-prompt` replaces the base prompt, so that
  workspace never lives inside the operator's home or the private run store and
  is removed when the run reaches a terminal state, including on cancellation,
  deletion, shutdown, or restart recovery of an interrupted run.
- The server resolves the configured `defaultProvider`/`defaultModel` from the
  companion's Pi configuration directory (honoring `PI_CODING_AGENT_DIR`),
  validates that exact model against `pi --list-models`, and pins it on the
  run. An unset, unavailable, or unsupported default returns an actionable
  error instead of letting Pi substitute another authenticated provider or
  model.
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
