# First Mate projects, research and prototype

October 2, 2026. Research and interactive design only. The application and server have not been changed by this work. The source review includes the existing uncommitted work in this checkout.

Open `index.html` for the interactive prototype and `research.html` for a readable implementation brief. All machines, projects, paths, tickets, and conversations in the prototype are synthetic. It never connects to a companion or starts an agent. Demo projects persist in this browser's local storage; Reset demo restores the examples.

## Recommended first version

- A project has a name, one owning machine, and one folder. iOS and web are names the user can choose, not new project types requiring separate configuration.
- New First Mate sessions default to a saved project plus a starting prompt. The project chooses the destination. Keep Manual setup for the current title, goal, and path workflow.
- Creating a project from the session form returns to the same draft with the new project selected. Saving a project never starts an agent.
- The Mac combines projects from its configured companion connections. Browse the filesystem through the selected companion's authenticated API over the existing Tailscale connection.
- Keep offline projects visible with their cached location; require the owning machine to be available to browse, save, or start. Never substitute another machine automatically.
- A project edit affects future sessions. An existing feature keeps its creation-time name/path snapshot and working directory. A machine change is a new project, not a move operation in v1.
- Use the starting prompt verbatim as the existing `goal`. Creation already queues it as the first user message and wakes the coordinator. Do not add a second send-message call.
- Generate the initial session title from the first nonempty prompt line and allow later renaming. No extra title-generation model call or required title field in the project route.

First Mate is the cross-feature product area. The per-feature coordinator is Second Mate, with the explanatory label Feature lead; the runtime kind remains `coordinator`.

## Code findings

Paths below are relative to the repository; line numbers describe the inspected working tree and may shift.

| Area | Existing behavior | Integration point |
| --- | --- | --- |
| Creation entry | The fleet plus menu chooses a machine, then opens its creation sheet | `herdr-harness-mac/herdr-harness-mac/FirstMate/FirstMateFleetSidebarView.swift:107`, `Views/Root/AppRootView.swift:301` |
| Form | Feature, Goal, and typed host repository folder; UUID rotates on edits | `herdr-harness-mac/herdr-harness-mac/FirstMate/FirstMateCreateSheet.swift:15` |
| Shared state | Creation selects and refreshes the returned feature; operation contexts fence host changes | `HerdrFirstMateShared/FirstMateStore.swift:459` |
| Request | Sends `title`, `goal`, `cwd`, and `request_id` | `herdr-harness-mac/herdr-harness-mac/Infrastructure/HerdrAPIClient.swift:258` |
| API | Rejects unknown fields and validates an existing absolute directory | `herdr_harness/server.py:1147` |
| Transaction | Saves feature, exact initial goal message, event, and receipt atomically | `herdr_harness/first_mate_store.py:673` |
| Runtime | Claims queued direction and starts the coordinator in the feature's cwd | `herdr_harness/first_mate_runtime.py:1770`, `:1843`, `:1282` |
| Machine roster | Private config supplies explicit IDs and display metadata; roster route reports local machine ID | `herdr_harness/config.py:232`, `herdr_harness/server.py:1837` |
| Native host identity | Saved connection IDs are preserved while roster labels/order are reconciled | `herdr-harness-mac/herdr-harness-mac/State/HerdrAppModel.swift:5230` |
| Fleet caching | Per-host results retain last known state, reject stale refreshes, and clear when a connection changes | `herdr-harness-mac/herdr-harness-mac/FirstMate/FirstMateFleetIndex.swift:78` |
| Server identity | Private persistent server UUID is already available through control capabilities | `herdr_harness/control_store.py:95`, `herdr_harness/server.py:1503` |
| Private state | SQLite state, transactions, and migrations already exist | `herdr_harness/first_mate_store.py:299` |
| Role names | First Mate, Second Mate / Feature lead, worker, and advisor have distinct meanings | `docs/first-mate/roles-and-sessions.md:3` |

There is no general directory browser or reusable SSH transport in the companion today. An SSH host/user example exists in configuration, but these are not exported through the public machine roster. Reuse the direct companion connection instead of introducing credential distribution and an SSH execution service.

## Proposed storage and API, not implemented

Each destination companion owns an `fm_projects` table in its private First Mate SQLite database:

```text
id, name, cwd, revision, archived_at, created_at, updated_at
```

The machine is implicit in the authenticated server that owns the record. The Mac routes through its stable saved machine ID and connection lifecycle; durable references can pair the server UUID with the project ID. The Mac ID and private TOML roster ID are separate namespaces today. Display names, role, ordering, and hostname fragments must never be used as identity. Aliases to the same server should not duplicate projects.

Proposed additions:

```text
Capability: first-mate-projects-v1
Capability: directory-browser-v1

GET   /api/v1/first-mate/projects
POST  /api/v1/first-mate/projects
PATCH /api/v1/first-mate/projects/{id}
POST  /api/v1/first-mate/projects/{id}/archive

GET   /api/v1/directories?path=...&show_hidden=false&cursor=...
```

Project writes use request IDs; edits and archive require an expected revision. Archive is a follow-on management control, not demonstrated by this prototype. Do not cascade changes or deletion into existing features. There is no project type, extra folder, remote file content, recursive search, or folder-creation API in v1.

The directory response includes canonical current path, parent, immediate directory children, and a next cursor for a bounded page. Default to the companion process account's home directory; that may differ from an interactive SSH user's home. Show hidden folders only on explicit request. Path entry is useful alongside browsing.

Enumerate directories directly, with no shell interpolation. Require the main authenticated companion credentials, reject scoped Active Work credentials, and explicitly disallow accidental unauthenticated access inherited from loopback development mode. Resolve `~` and symlinks on the destination, disclose a symlink's resolved destination, and handle inaccessible, missing, stale, and invalid paths distinctly. If private browse roots are configured, check containment after canonical resolution, including child traversal. Revalidate at save and start. macOS process permissions can differ from terminal permissions even when the host is online.

Add a mutually exclusive project-backed variant to the existing feature creation route:

```json
{
  "title": "Investigate APP-204",
  "goal": "Investigate APP-204. Read the ticket and propose a plan.",
  "project_id": "project_example",
  "expected_project_revision": 1,
  "request_id": "request_example"
}
```

The server resolves the project to cwd. Reject a request containing both project selection and an unrelated cwd. Snapshot optional project ID, name, path, and revision into the feature. Preserve the existing `title/goal/cwd/request_id` manual request and legacy responses.

Check the creation receipt against the original submitted body before resolving mutable project state. A retry after an accepted create must return that feature even if the project was subsequently renamed, archived, or moved. Resolve revision, revalidate the folder, create the feature, enqueue one initial message, and store the receipt within a coherent transaction. Keep the existing wake mechanism and scheduler recovery. A lost response must not create duplicate agents or deliver the prompt twice.

## Native integration

Introduce a project model/client and an observable Mac project index using the current fleet cache pattern. Build the project editor and folder browser as separate views; keep asynchronous loading and navigation state in their models. Reuse existing server configuration, Keychain credentials, appearance tokens, and shared form controls.

Changing the selected machine while creating a project clears its folder and cancels pending browsing. A late response must match the original machine ID, authenticated connection lifecycle, and request generation before it can update the UI. Freeze the destination, project revision, prompt, and request ID during submission; retain the exact request for retry. New edits get a new request ID.

Extend shared decoding with optional metadata and `decodeIfPresent`. Preserve the current create client method with an overload or default implementation so iOS, web, fixtures, and existing test clients remain compatible. Capability-gate new fields: current older servers explicitly reject them. When the selected server lacks projects or browsing, show update guidance and retain manual creation.

The signed Mac update does not update companion packages. Delivery will require matching companion versions on machines where projects and browsing are used, distributed separately with setup instructions. This research does not authorize or perform a server cutover.

## Implementation order and acceptance checks

1. Backend project storage and directory API, with capability flags, typed errors, bounded enumeration, authentication, and temp-directory tests.
2. Project-backed creation through the existing atomic feature/message path. Test exact prompt, cwd, request receipt replay, stale revisions, folder disappearance, and archive/edit races.
3. Shared client/model additions and Mac project index. Test independent host failure, duplicate names, alias handling, credential reconfiguration, and delayed responses after a host switch.
4. Mac project editor, folder browser, and new-session form. Test save-return-to-draft, offline state, manual fallback, keyboard flow, VoiceOver, light/dark appearance, and long names/paths.
5. Run focused Python/store/HTTP and Swift contract tests. Before delivery, run the applicable full checks from `README.md:436`, the source privacy scan, and the existing signed release gates against the reviewed revision.

Required edge cases: Unicode/spaces/quotes in paths, NUL/invalid paths, hidden folders, large directories with pagination, symlink loops and root escapes, readable but unsearchable directories, permission denial, same path on two machines, project edits during creation, repeated submit, lost response, server restart, old-client decoding, and old-server manual creation.

## Design decisions

Use Herdr's existing native palette: charcoal `#151519`, rail `#131317`, foreground `#E9E9EC`, secondary `#ACACB3`, lavender `#AAA6F4`, and green `#9CCDB9`. Light appearance follows the existing First Mate tokens. Use the system sans-serif for native controls, titles, prose, and paths; no decorative display font.

The layout uses a quiet sidebar and a focused prompt form. A project selection exposes its machine and full folder directly below it. The folder picker borrows Finder's places/list/path layout while always naming the selected machine. The visual emphasis belongs to the starting prompt and Start session action. A generic dashboard with project metric cards would add no value here.

```text
Herdr sidebar | New First Mate session
              | What are we working on?
              | [Use a project | Manual setup]
              | Project                         + New project
              | [iOS App / Studio Mac                     v]
              | /Users/developer/Projects/ios-app
              | [Starting prompt                           ]
              | [                             Start session]
```

The prototype covers new session, project picker, project list, project create/edit, destination changes, directory navigation/path entry/hidden folders, restricted and missing folders, offline destination, manual creation, sample initial prompt handoff, light/dark, and narrow layouts. It does not simulate network latency, real authentication, coordinator output, server persistence, or receipt replay. Those are implementation acceptance checks, not claims about this static demo.

## External reference

The recommendation to reuse a companion HTTP service over the tailnet is consistent with [Tailscale Serve's private local-service model](https://tailscale.com/docs/reference/tailscale-cli/serve). Apple's [directory chooser option](https://developer.apple.com/documentation/appkit/nsopenpanel/canchoosedirectories) supports a native local picker; remote companions still need their own listing API. The installed offline Apple documentation CLI could not open its index under the read-only sandbox, so the official Apple page was used as a fallback. The architecture findings above come from the local source, not assumptions about another app.

## Prototype verification

Passed 29 browser interaction checks using an isolated Chrome instance with external requests blocked. Results are recorded in `verification.json`; screenshots are in `previews/`. Covered prompt fidelity, project persistence, machine selection, folder navigation/errors, offline state, manual-path normalization, existing-session snapshots, keyboard focus, and narrow viewport overflow. Desktop light/dark, project form, folder browser, and narrow renders were visually inspected. No native app build or live companion test was needed or performed for this static design pass.

The source privacy checker passes for this design directory. The full checkout check reports only two pre-existing personal-path findings at `design/watchers-2026-10-01/PROMPT-take2.md:7` and `:8`. That unrelated file was not changed. Nothing was committed or released.
