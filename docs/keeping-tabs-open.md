# Close chats, keep their tabs

In the updated Mac or iPhone app, choose **Pane actions → End Pi & close pane**.
The tab and workspace stay open. If the chat is the tab's last pane, Companion
creates a fresh shell in the chat's folder before asking Pi to quit, then closes
only the old pane. If another pane already exists in that tab, no shell is added.
Panes in other tabs do not count as replacements.

When only the reserved shell remains, Companion shows **No open chats**, the
folder path, **New Pi chat**, and **Open shell**. This appears both in the pane
view and the workspace overview. The tab's add-Pi/add-shell actions reuse the
reserved shell too, rather than adding an unnecessary split. Starting a quick Pi
session in an explicitly selected empty tab also reuses its reserved pane when
the requested folder matches.

Upstream Herdr still has a real shell pane: its current API cannot retain a
zero-pane tab. The existing workspace and tab IDs remain unchanged, preserving
Mac tab-color assignments and container references. The new pane gets a new ID,
without the old pane's label, terminal scrollback, or Pi conversation association.
Closed pane links do not silently redirect to a different conversation.

This clears the active chat surface, not saved history. Pi session files,
Companion's semantic journal, and existing local conversation archives are not
deleted or copied into the new chat.

## Installation and compatibility

Install the updated Companion server and native app(s), following the component
update instructions in the repository README. No upstream Herdr upgrade or
plugin is needed for this workflow; the native replacement/quit/close sequence
has been checked with Herdr 0.8.2 in an isolated synthetic session.

The server advertises `pane-retirement-v1` from `GET /api/v1`. Updated native
clients check it before acting. An older server gets an upgrade message, never
a fallback to the old destructive close sequence. Older native/web clients
continue to decode the existing API; they see the backing pane as a normal shell
and do not gain the preserving action automatically.

No new operator setting is required. Reservation and request records live in
`pane-lifecycle.sqlite3` under the configured `server.state_dir`, with private
file permissions. Keep this file with the other private server state during
updates. Records are scoped to the native socket and terminal identity, so a
reused pane ID does not inherit an old reservation.

## Safety and limits

- Replacement creation and shell-readiness verification happen **before** `/quit`.
  If they fail, the old chat is not ended. Any uncertain new pane is left visible
  rather than guessed at or automatically destroyed.
- A live Pi session must match the selected session/terminal identities and its
  foreground process must be recognizable as Pi. An already-ended session can
  be retired when its terminal has returned to a recognizable shell.
- A disconnected bridge alone does not prove Pi exited. Companion verifies the
  foreground shell or the disappearance of a command-only pane. If Pi does not
  exit, its pane stays open. A created replacement stays available for inspection.
- Concurrent Companion placement/close operations are serialized. Topology,
  session, terminal, and surviving-pane checks are repeated before closing.
  Native Herdr clients remain independent: without an upstream atomic
  replace/conditional-close primitive, a simultaneous native close or move can
  still race these checks. Uncertain outcomes require inspection, not blind
  retries or destructive rollback.
- Each retirement carries a request ID. Repeating that ID replays a completed
  result or reports its failed/unknown outcome without repeating a split,
  `/quit`, or close—even after a Companion restart. A new explicit attempt uses
  a new request ID and rechecks live state.
- Ordinary idle shells are never automatically treated as placeholders. Only
  shells created by retirement get the reserved marker. Input/agent launch
  through Companion, or a detected native agent, clears it. **Open shell** can
  always reveal a reserved terminal, including a shell command started directly
  in native Herdr. **New Pi chat** refuses to overwrite foreground work.
- Failed Pi startup does not delete the reserved anchor. It becomes a normal
  terminal, where startup output can be inspected.
- Intentional tab names are retained. New automatic lone-pane rename fan-outs
  record their prior tab name; retirement restores that name only while the
  recorded chat-derived label still matches. Older labels have no provenance and
  are conservatively retained rather than guessing which names were intentional.
- **Close pane**, **Close tab/workspace**, and cleanup retain their existing
  explicit destructive meanings. Ordinary close in upstream Herdr is unchanged.
  **End Pi session** still leaves its existing pane, and **New Pi chat** in an
  existing chat still uses the history-preserving `/new` behavior.

## API additions

All routes use the existing API authentication and identifier validation.

```text
POST /api/v1/panes/{paneId}/end-pi-and-close
  { requestId, terminalId, sessionId? }
  → { ok, closedPaneId, workspaceId, tabId, nextPaneId, reservedShell, warnings }

POST /api/v1/panes/{paneId}/reserved-shell
  { terminalId, action: "shell" | "pi" }
  → { ok }
```

Workspace and snapshot pane objects optionally include `reserved_shell: true`.
Its absence means a normal pane. Existing pane IDs, endpoints, and delete
semantics have not changed. An unsuccessful or interrupted close never triggers
a native client's fallback `DELETE`.

## Verification

```sh
.venv/bin/python -m unittest tests.test_pane_lifecycle tests.test_herdr_http tests.test_herdr_service

# Optional: isolated HOME + named native server + synthetic stdin program.
# This does not open a real Pi session or use any running workspace.
HERDR_NATIVE_TEST_BIN="$(command -v herdr)" \
  .venv/bin/python -m unittest tests.test_pane_lifecycle_native
```

The native `PaneRetirementTests` suites cover capability gating, authenticated
identity-bound requests, no destructive fallback, destination validation,
reserved-shell reuse, and backward-compatible model decoding. Run them with the
existing native test schemes; see the README for build and full-suite commands.

Manual check in a disposable workspace: close its only Pi chat with the
preserving action, confirm the same tab/color/folder remains in both Herdr and
Companion, then choose **New Pi chat**. No previous chat name or transcript should
appear in that new pane. Repeat with another shell in the same tab and with the
only other pane in a different tab.
