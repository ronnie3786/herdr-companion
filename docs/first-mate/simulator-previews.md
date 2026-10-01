# First Mate simulator checkpoints and previews

First Mate can keep **simulator checkpoints**: compiled iOS Simulator builds of
a feature, saved along the way (for example at the end of each implementation
round), that you can open in a live, interactive simulator from the Mac app
or the iPad and iPhone app. The builds and simulators live in
[SimPortal](#simportal), a separate local service on the machine that compiled
them. The companion connects the two; the Mac shows the simulator in a native
window, and iPad and iPhone show it full screen.

Capability: `first-mate-simulator-previews-v1`, advertised by `GET /api/v1` and
`GET /api/v1/first-mate/capabilities`. The feature is inert until the
companion's private configuration has a `[simportal]` section.

## Who owns what

| Part | Owns |
|---|---|
| The project's build workflow (a First Mate worker) | Compiling for an iOS Simulator destination, and choosing which successful build is a checkpoint |
| SimPortal, on the build machine | The saved build bytes, each owned simulator's create → boot → install → launch lifecycle, readiness receipts, and the viewer stream |
| The companion on that machine | The SimPortal URL and credential, build ↔ feature/stage/assignment/session associations, a durable request outbox, the idle and capacity policy, and a stream relay scoped to one exact simulator |
| The Mac app | Showing checkpoints, the explicit **Open in Simulator** choice, the pop-out simulator window, and **Open in Browser** |
| The iPad and iPhone app | The same Builds rows and stage chip, a full-screen simulator with touch and hardware-keyboard input, Home, Lock and Type, and **Open in SimPortal** (the tailnet browser link) |

The Mac never holds the SimPortal credential and never talks to SimPortal
directly. A **ready** simulator means SimPortal booted it, installed the exact
build, launched it, and saw a video frame. It is never a verification verdict:
First Mate's gate verification is unchanged and unaffected.

## Topology

```
Mac app (UI machine)
  │  companion API, existing credentials (HTTPS over the tailnet, or loopback)
  ▼
Companion on the feature's machine
  │  loopback HTTP and WebSocket, SimPortal token from a private file
  ▼
SimPortal on the same machine
```

SimPortal accepts only apps that are already on its own disk (it has no upload
or cross-machine transfer), so registering a build needs SimPortal on the
machine where the First Mate worker compiles. The companion refuses to
register builds when its configured SimPortal URL is not loopback, and says so.

## Saving a checkpoint

Managed coordinators and workers on a machine with `[simportal]` configured get
one extra tool, `fm_register_simulator_build`:

| Field | Required | Meaning |
|---|---|---|
| `app_path` | yes | Absolute path of the built iOS Simulator `.app` (for example `…/Build/Products/Debug-iphonesimulator/App.app`) |
| `label` | no | Short checkpoint label, at most 160 characters (default: the assignment or stage title) |
| `configuration` | no | Build configuration; default read from the `<Configuration>-iphonesimulator` products folder |
| `scheme` | no | Scheme or target that produced it |
| `hub_build_id` | no | The Mobile App Hub build ID of the matching device build, so the Mac can show both together |

Workers are told (only on configured machines) to build for the simulator and
register the build at the end of each meaningful round of iOS app work.

The companion derives everything else from the validated dispatch, exactly like
`fm_save_link`: the feature, the stage visit, the assignment, and the native
Pi session. A stale generation, another session, an advisor, or the lead First
Mate cannot register. It observes the workspace's `HEAD` and whether the tree
is clean and passes them as SimPortal's caller-reported source metadata.

Before anything is sent, the companion checks:

- the path is a real `.app` directory inside the assignment's workspace, Xcode
  DerivedData, or a temporary build folder, with no symbolic links or special
  files, within SimPortal's size limits;
- `Info.plist` names an **iOS Simulator** build (a device build is refused with
  instructions);
- SimPortal is reachable, is the pinned server, has its build catalog enabled,
  approves the configured intake folder, and admits new work (free-space floor).

It then records the registration (build UUID, request UUID, and the exact JSON
body) in its private ledger, copies the app to
`<intake_root>/<project_id>/<feature_id>/<build_id>/<App>.app`, and sends
`POST /api/builds`. The tool call stays pending until SimPortal has saved or
refused the build (up to two minutes, then it reports "still saving"). Once the
build is ready, the companion checks the returned server and scope, keeps the
artifact digest and app metadata, removes its own intake copy (SimPortal keeps
a private staged copy), and adds a `simulator.build_ready` (or
`simulator.build_failed`) entry to the feature journal.

Scope mapping: `projectId` is `[simportal] project_id` (default `herdr`),
`featureId` is the First Mate feature ID, `sessionId` is the producing Pi
session (or a stable hash when it is not a valid scope ID), and `checkpointId`
is the assignment ID (the stage visit ID for a coordinator). Checkpoint history
belongs to the feature, so session handoffs and coordinator rotation never
reattribute or hide a build.

## Previews

**Open in Simulator** on a ready build:

1. reuses a simulator that is already starting or running for that build,
   otherwise
2. confirms the exact build with SimPortal, picks the device (the configured
   `device_type`/`runtime`, else iPhone 17 Pro on the newest installed iOS
   runtime that runs the app's minimum OS), makes room under the cap, records
   the start request, and sends `POST /api/portals` with `buildId`.

Every new start creates a new simulator owned by SimPortal. The simulator is
streamable as soon as its boot step finishes, while the app is still being
installed and launched.

**Stop** is explicit. A start in progress is cancelled first and the simulator
is shut down once the start settles. Stopping never deletes the simulator's
data, the build, or anything else.

### Keeping resources in check

- **Cap.** At most `max_running_previews` (default 4) Herdr previews run on a
  machine. Opening a fifth shuts down the least recently watched preview that
  has no viewer, and says which one. If every preview is being watched, the
  request is refused with `simulator_capacity` and the list of running previews.
- **Idle shutdown.** A running Herdr preview that nobody has watched for
  `idle_shutdown_minutes` (default 60; `0` turns this off) is shut down.
  "Watched" means an open Herdr window or any other SimPortal viewer, as
  SimPortal counts them. Closing the window never stops anything by itself; it
  starts the idle clock. The Mac window pauses its stream after a minute
  hidden, so a forgotten window does not keep a simulator busy.
- Only previews this companion started are ever stopped. Other simulators on
  the machine, including other SimPortal previews, are never touched.
- **Disk.** Shutting down keeps a simulator's data, and every new start makes
  a new simulator, so shut-down simulators add up. The companion never deletes
  them. SimPortal's **Machines** page (`/machines` on any SimPortal Mac) lists
  every Mac's simulators, groups the ones unused for 7+ days, and deletes them
  after you confirm. A preview whose simulator was deleted there shows as
  stopped ("Simulator deleted") with its build kept; Start Again opens a fresh
  simulator.

## Durable requests

Every SimPortal mutation (register, start, cancel, stop) is written to the
companion's outbox with its request UUID and exact body **before** it is sent.
A lost response is resolved by resending the identical body, which SimPortal
answers with the original operation, so a retry never creates a second build or
simulator. The outbox survives companion restarts. A registration interrupted
before its handoff is marked failed after 30 minutes, and its partial intake
copy is removed.

The companion pins SimPortal's `serverId` on first contact. If SimPortal later
answers as a different server (for example after its ledger was reset), every
automatic mutation stops, previous builds and previews show as unavailable, and
nothing is migrated. An operator accepts the new server explicitly by setting
`[simportal] server_id`; records from the old server stay as history.

The ledger is `simulator-previews.sqlite3` in the companion's state directory
(owner-only permissions). It holds identifiers, request bodies, and paths on
this machine, never the credential.

## API

All routes are under `/api/v1/first-mate` and need the companion's main bearer
token. JSON is snake_case. Errors use
`{"ok": false, "error": {"code", "message", "details"?}}`.

| Method | Path | Result |
|---|---|---|
| GET | `/simulator[?fresh=1]` | `{simulator}`: this machine's SimPortal status |
| GET | `/features/{id}/simulator-builds` | `{feature_id, simulator, builds, selected_build_id, generated_at}` |
| POST | `/features/{id}/simulator-builds/{build_id}/preview` | Body `{request_id, device_type?, runtime?}` → `{preview, reused, stopped_to_make_room}` |
| GET | `/features/{id}/simulator-previews/{preview_id}` | `{preview, build, feature, simulator}` with a live refresh |
| POST | `/features/{id}/simulator-previews/{preview_id}/stop` | Body `{request_id, mode: "shutdown" \| "stream"}` → `{preview}` |
| GET (WebSocket) | `/features/{id}/simulator-previews/{preview_id}/stream` | The preview's exact simulator viewer stream |

`request_id` makes the two POSTs idempotent: the same ID and body return the
original result; the same ID with a different body is `idempotency_conflict`.

**Status** (`simulator`): `configured`, `state` (`unconfigured`,
`misconfigured`, `unavailable`, `unsupported`, `server_changed`,
`storage_low`, `ready`), `reason`, `server_id`, `pinned_server_id`,
`registration_available`, `registration_reason`, `preview_available`,
`storage` (free and minimum bytes), `toolchain`, `default_device`, `policy`
(`idle_shutdown_minutes`, `max_running_previews`), `running_previews`,
`checked_at`. With `storage_low`, running previews can still be watched and
stopped, but nothing new is saved or started.

**Build**: `id` (the SimPortal build UUID), `checkpoint_id`,
`checkpoint_label`, `stage_title`, `visit_id`, `assignment_id`,
`native_session_id`, `hub_build_id`, `origin` (`agent`, or `external` for a
build registered for this feature outside Herdr), `status` (`registering`,
`ready`, `failed`, `cancelled`, `interrupted`, `outcome_unknown`, `conflict`,
`deleted`, `unavailable`, or another SimPortal status), `app` (name, bundle ID,
version, build, minimum OS), `digest`, `bytes`, `source` (reported revision,
working tree, configuration, target), `error`, `launchable`, timestamps, and up
to five brief `previews`. Only `launchable` builds can be opened. Unknown
statuses are never treated as ready.

**Preview**: `id` (`fmsp_…`), `portal_id`, `build_id`, `phase` (`starting`,
`running`, `stopping`, `stopped`, `failed`, `cancelled`, `uncertain`,
`unavailable`, `unknown`), the raw SimPortal `status` (`simulator_deleted`,
with `delete_queued` and `deleting_simulator` before it, when the simulator was
deleted in SimPortal; the phase is then `stopped`), `device` (type and
runtime IDs and names), `udid`, `stream_available`, `operation` (kind, status,
current step and the ordered `steps` with their states, error), `observation`
(device state, viewer count, last frame time), `browser_links` (`local`,
`tailnet`), `idle` (`shutdown_after_minutes`, `shutdown_at`, `watchers`),
`stop_reason` (`user`, `idle`, `capacity`), `error`, timestamps.

### Stream

`GET …/stream` must be a WebSocket upgrade (`426 upgrade_required` otherwise).
The companion validates the preview, dials SimPortal's viewer socket for the
preview's exact UDID with its credential in a header, and only then upgrades the
client, so every refusal is an ordinary HTTP error (`409
simulator_preview_not_running`, `503 simulator_unavailable`, `503
simulator_stream_limit` past 8 concurrent streams). After the upgrade it relays
SimPortal's [viewer protocol](#simportal) unchanged in the server-to-client
direction. From the client it accepts only `hello`, `quality`, `keyframe`,
`ping`, `touch`, `key`, `button`, `text`, and `paste`, with bounded fields, and
it rewrites every `hello` to `observe: true, focus: false`. `focus` and `boot`
messages are dropped. Attaching Herdr's window therefore never changes
SimPortal's shared focus.

### Open in Browser

`browser_links` are SimPortal's own exact-simulator viewer pages (`/d/<udid>`),
validated to carry no credentials or query. The Mac uses the loopback link when
its companion is on the same machine and the tailnet link otherwise. The
browser signs in to SimPortal on its own (tailnet identity or SimPortal's login
page). **Opening SimPortal's normal viewer makes that simulator SimPortal's
focused simulator**, the one agents use when they do not name one. The Mac
says so before opening, and so do iPad and iPhone (Open in SimPortal), which
pick the link the same way.

## Configuration

In the companion's private configuration (per machine with
`[machines.<id>.simportal]`):

```toml
[simportal]
url = "http://127.0.0.1:4280"            # SimPortal on this machine
token_file = "~/.config/herdr-companion/secrets/simportal-token"  # owner-only file
intake_root = "~/.simportal/builds"      # must be one of SimPortal's lifecycle.artifactRoots
# project_id = "herdr"
# device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
# runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
# idle_shutdown_minutes = 60             # 0 turns idle shutdown off
# max_running_previews = 4               # opening a fifth shuts down the least recently watched idle one
# server_id = "…"                        # only to accept a replaced SimPortal explicitly
```

Setup on each build machine:

1. Install and start SimPortal, and add the intake folder to its
   `lifecycle.artifactRoots` (see SimPortal's `docs/portals.md`). For Open in
   Browser from another machine, enable its tailnet link
   (`simportal tailscale enable`).
2. Write SimPortal's service token to the token file (`chmod 600`).
3. Add the `[simportal]` section and restart the companion.
4. Check `GET /api/v1/first-mate/simulator?fresh=1`, or the **Builds** section
   in First Mate, for `ready`.

SimPortal refuses new builds and simulators while its disk has less free space
than its floor (20 GB by default). Herdr reports that as `storage_low` and never
lowers the floor. SimPortal's **Machines** page shows each Mac's free space and
the simulators you could delete to get above it.

## SimPortal

SimPortal is a separate project; this integration follows its application
contract (`docs/integration.md`, `docs/api.md`, `docs/builds.md`,
`docs/portals.md`, `docs/viewer-protocol.md` in that repository). Capabilities
it does not have yet, and what Herdr does meanwhile:

| Missing in SimPortal | Effect today |
|---|---|
| Scoped viewer grants (short-lived, one simulator, no focus change) | The companion relays the stream with its service token and filters input |
| A browser viewer link that does not claim shared focus | Open in Browser warns that it changes focus |
| Resuming a stopped preview | Reopening after an idle shutdown creates a new simulator |
| Transferring a build to another machine | SimPortal must run on each build machine |
| Server-side idle shutdown | Enforced by the companion, only while it runs |
| Installing a newer build into a running preview | Each build gets its own simulator |

## Testing

`tests/test_simulator_previews.py` runs the adapter, the runtime tool, the HTTP
routes, and the stream relay against an in-process fake of SimPortal's HTTP and
viewer WebSocket surfaces with synthetic app bundles. It covers exact replay
after a lost acknowledgement, restart recovery, server pinning and explicit
re-pinning, storage admission, device selection, reuse, the cap and idle
policy, stop during start, catalog sync, input filtering, and link validation.
The Pi extension test covers the tool's registration and spooling. Mac tests
cover the wire protocol, an H.264 encode/decode round trip, input mapping, the
stream controller, and renders of the window and sections.

An opt-in end-to-end check runs the Mac's real URLSession WebSocket client
through the companion relay against the same fake SimPortal:

```sh
python3.11 scripts/simulator-preview-fixture.py --port 9197 --report /tmp/viewer.json
# In another shell, pass the JSON line it printed:
TEST_RUNNER_HERDR_SIMULATOR_RELAY_FIXTURE='{"base_url":…}' xcodebuild test \
  -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac \
  -destination 'platform=macOS' -only-testing:herdr-harness-macTests/SimulatorStreamRelayE2ETests
```

Stopping the fixture writes the viewer messages the fake received to
`--report`: a `hello` with `focus: false` and the input, never `focus` or `boot`.
