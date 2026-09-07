# Herdr Pi integration

This Pi package adds four integrations to the stock interactive TUI:

- a local, pane-specific semantic side channel for Pi processes launched by
  Herdr, without replacing or parsing the terminal;
- persisted parent session IDs, automatic child-process inheritance, and
  agent instructions for tagging delegated Pi work across workspaces;
- `/send-to-herdr`, which hands a persisted Pi session running outside Herdr to
  the local Herdr Harness and opens the resulting pane in the Mac app;
- `present_result`, an agent tool that explicitly registers a finished file or
  HTTP(S) link for the floating Herdr HUD. The Mac app shows only unviewed
  results and opens them with their native default application.

For an isolated local test, launch Pi through Herdr with this directory as a
temporary extension:

```bash
herdr agent start mobile-pi --kind pi --pane <pane-id> -- --extension \
  /absolute/path/to/herdr-companion/pi-semantic-bridge
```

Equivalently, from an existing Herdr-managed shell whose environment contains
`HERDR_SOCKET_PATH` and `HERDR_PANE_ID`:

```bash
pi -e /absolute/path/to/herdr-companion/pi-semantic-bridge
```

No global Pi settings are changed by either command. For durable installation,
`pi install /absolute/path/to/herdr-companion/pi-semantic-bridge` is
idempotent because Pi records the local package path rather than copying or
modifying another extension.

## Track parent and child sessions

Lineage is active in every Pi session that loads this package, including
sessions outside Herdr and headless Pi runs. Each session stores its own native
Pi session ID and one optional `parent_session_id` in a `herdr.session-lineage`
custom entry. Herdr derives children from those parent references, so there is
no second child list to keep synchronized. Session IDs are independent of pane
IDs, workspace paths, and Pi's conversation-tree entry `parentId` values.

The extension injects the current session ID and spawning instructions into
each agent turn. It sets `HERDR_PI_SESSION_ID` to the current ID, and sets
`HERDR_PI_PARENT_SESSION_ID` to that same ID for child processes to inherit.
Launching a new `pi` subprocess from Pi's bash tool therefore tags the child
automatically, even after changing directories. Every child then exports its
own ID for its children. Shells with a replaced environment, new terminals,
SSH, and processes launched by a server need an explicit parent:

```bash
pi --herdr-parent-session-id <parent-pi-session-id>
HERDR_PI_PARENT_SESSION_ID=<parent-pi-session-id> pi
herdr agent start child --kind pi --pane <pane-id> -- --herdr-parent-session-id <parent-pi-session-id>
```

When creating a session through `POST /api/v1/quick-sessions/pi`, include
`parentSessionId` in the JSON body. SSH does not normally forward environment
variables; pass the Pi flag in the remote command instead. The remote machine
must also have this package installed. Parent IDs can cross workspace and
machine boundaries, but a client can associate them only while it has both
sessions available; the Mac groups the sessions available on the selected
machine across its workspaces.

Existing saved ancestry wins on resume, reload, or handoff. Ambient environment
variables apply only to fresh startup sessions, so resuming an unrelated
conversation cannot accidentally attach it to the launching session. `/new`
starts an independent root. Native Pi forks use the source session ID, including
forks into another working directory; copied metadata from the original session
is never mistaken for the fork's own metadata. Lineage survives compaction and
conversation-tree navigation because it is restored from all saved entries.

Use these commands in Pi to inspect or correct an association:

```text
/herdr-parent
/herdr-parent <parent-pi-session-id>
/herdr-parent none
```

Corrections immediately refresh a connected Herdr client. The startup flag can
also tag an existing untagged session; it never overwrites saved lineage.
`--herdr-parent-session-id none` explicitly starts a root, suppressing ambient
inheritance. Invalid and self-referential IDs are rejected. Pi persists custom
entries with the rest of its session: a fresh session is not written to disk
until Pi saves its first assistant response, and `--no-session` stays ephemeral.
Already running sessions need `/reload` to start tracking newly spawned work.

## Send an existing session to Herdr

The package must be installed in Pi's user settings so the command is present
in sessions started outside Herdr. From a persisted Pi session, run:

```text
/send-to-herdr
```

Herdr resumes the exact session in workspace `Random`, tab `One-off Tasks`,
reusing either by an exact name match and creating it when missing. The command
first waits for Pi to become idle, then switches the source process to a blank
placeholder session. That releases the original session file before Herdr
starts it. The harness does not report success until the new pane's semantic
bridge is connected and reports the exact requested session ID.

After that readiness proof, the command opens `herdr://pane/<id>` and cleanly
exits the source Pi process. A known harness rejection restores the original
session locally and removes the blank placeholder. If a transport failure makes
the outcome unknowable, the original stays closed so two Pi processes cannot
write the same session file. The warning tells the user to check Herdr before
resuming manually. Successful handoffs remove any exact, empty placeholder file
after the source process exits, so it does not remain in Pi's session history.

Explicit Herdr IDs override either default destination:

```text
/send-to-herdr --workspace-id <workspace-id>
/send-to-herdr --tab-id <tab-id>
/send-to-herdr --workspace-id <workspace-id> --tab-id <tab-id>
```

Use `/send-to-herdr --help` for the same usage summary. Start an external Pi
session with the companion's shared configuration:

```bash
herdr-config exec --config ~/.config/herdr-companion/config.toml --machine desktop -- pi
```

The wrapper passes the selected local API connection and model-provider settings
without printing credentials or putting them in command arguments. Server
administration, remote-machine, APNs, fleet, and transcription settings are
excluded from the child environment. A configured server port automatically
selects its loopback API URL when no explicit server URL is supplied.

Inside Herdr-managed panes, the running companion publishes a generated,
owner-only connection record indexed by `HERDR_SOCKET_PATH` under
`~/.local/share/herdr-companion/connections`. Pi and the notes CLI read only the
record matching their terminal socket. These files are runtime state projected
from the single TOML configuration; do not edit or commit them. The record
contains only the matching companion API URL and token. It is refreshed on
server start and removed on orderly shutdown without deleting a newer instance's
record. No terminal restart or second configuration file is needed.

Explicit `HERDR_HARNESS_API_TOKEN` or `HERDR_HARNESS_API_TOKEN_FILE` overrides
runtime discovery. Explicit file paths must name owner-only regular files.
`HERDR_SEND_TO_HERDR_URL` can select another loopback endpoint. Redirects are
always rejected; another local bind interface can be selected only through the
socket-specific, owner-private server record.

The command is deliberately a no-op inside an already Herdr-managed Pi pane.
Existing Pi processes started before installation can load the command with
`/reload`; newly started processes discover it automatically.

## Present finished results in the HUD

Herdr-managed interactive panes and headless Agent runs expose the
`present_result` tool to the model. Agents call it for intentional deliverables
such as documents, HTML pages, images, audio, video, and useful web links. They
do not infer attachments by scraping prose from a final answer, and they do not
register ordinary source edits, logs, or intermediate build products.

File locations may be absolute or relative to the Agent's working directory.
The harness validates the allowlisted file type, rejects symlinks and executable
content, then copies the bytes into private durable storage before publishing an
authenticated `result_artifact.created` event. Registration retries carry a
stable idempotency key, so a lost HTTP response cannot create duplicate HUD
nodes. The Mac independently rejects missing or oversized file metadata, caps
each transfer at 512 MiB, and refuses symlinked cache destinations before
opening a result. ASK-mode headless runs can present HTTP(S) links only; ACT runs and
interactive panes can also present finished local files.

Each registration carries the Pi session ID and producing `toolCallId`. The
native Chat UI uses this identity to place a result beneath the response that
created it. The tool also saves the complete public artifact metadata in its
session result details, so older saved transcripts keep their document cards
after the harness expires a download. Opening an expired file shows an
unavailable alert. Results whose original response was omitted by compaction
stay in a separately labeled session attachment group while the harness still
retains them. Install the extension and harness changes together; already
running Pi sessions use `/reload` to load the updated tool.

The extension socket is derived from the complete Herdr socket path and a full
SHA-256 of `HERDR_PANE_ID`, so multiple Pi panes coexist safely. The socket is
created inside a dedicated user-only directory, and the harness independently
verifies its type, owner, and mode. Stale sockets are removed only when their
device and inode still match the failed connection probe.

The bridge sends forward-compatible protocol version 1 NDJSON. It projects the
active, compaction-aware session branch, strips provider signatures and private
agent setup data, and checkpoints the current transcript after every settled
agent run and before shutdown. The harness journals those checkpoints and a
bounded, contiguous suffix of ordered events in SQLite. Production starts use
`~/.local/share/herdr-companion/pi-semantic.sqlite3`; tests that inject an explicit
empty environment stay in memory. Records are namespaced by the normalized
Herdr socket path so identically named panes in different Herdr sessions cannot
share history.

`snapshot.session.parent_session_id` and the `hello` envelope's
`parent_session_id` carry the parent native Pi session ID or `null` for a root.
Older bridges may omit them. A parent correction sends a `stream.reset` event
with reason `session_lineage_changed` and an authoritative snapshot.

The snapshot's `state` object also carries `context: { tokens, contextWindow, percent }` (the
active model's context usage, or nulls right after compaction before the next LLM
response), and `turn_end` events carry the same `context` object so clients can update
a live context meter during a run.

Authenticated harness routes for a detected Pi pane are:

- `GET /api/v1/panes/{paneId}/pi/snapshot`
- `GET /api/v1/panes/{paneId}/pi/events`
- `POST /api/v1/panes/{paneId}/pi/prompt`
- `POST /api/v1/panes/{paneId}/pi/steer`
- `POST /api/v1/panes/{paneId}/pi/follow-up`
- `POST /api/v1/panes/{paneId}/pi/abort`
- `POST /api/v1/panes/{paneId}/pi/compact`

Prompt, steer, follow-up, abort, and compact are delivered to the same Pi
process. Compact is accepted only while Pi is idle. Stock TUI extension dialogs
remain terminal-owned, so interaction responses are advertised as unsupported.
The terminal PTY path remains unchanged.

The bundled `notes-discovery` extension adds the installed `herdr-notes` CLI
to agent instructions for Herdr pane/run sessions. Agents can list/search,
read, create, edit, and delete the selected machine's synchronized HUD notes.
It injects usage guidance only, without loading private note content. Changes
use observed revisions so concurrent Mac/agent edits produce a conflict.
Run `herdr-notes --help`; its API connection comes from the selected TOML
configuration or the matching native terminal discovery record. Global Pi instruction files are unchanged.

## Development

Use Node.js 22.19 or newer. Run `npm ci` and `npm test` in this directory. The extension is tested with Pi 0.84.2; the declared peer range records the supported release series. Test tooling is installed locally.

With Pi installed, run `node test/smoke-lineage.mjs` for a provider-free RPC
verification of extension registration, native persistence, resume, `/new`,
cross-workspace fork, inherited parents, and detachment. It uses temporary Pi
configuration and synthetic session files, then removes them. To verify a
deployed copy, pass its extension path and optionally the Pi executable:

```bash
node test/smoke-lineage.mjs /installed/package/extensions/pi-semantic-bridge.ts /path/to/pi
```
