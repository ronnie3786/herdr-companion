# Agent control for Mac Companion

`herdr-control` separates **finding/managing data** from **controlling a Mac
window**. It does not simulate mouse clicks, run AppleScript, or replace the
upstream `herdr` terminal CLI.

This is an unreleased capability-based update. It requires the matching companion
package/CLI and Mac app. The server advertises `agent-control-v1` and `discovery-v1`.
Existing clients and endpoints remain compatible. The Mac updater does not install
the companion package or CLI; update those components separately.

## Setup and authority

1. Configure each data machine and its own API credential in the existing private
   cluster TOML. See [configuration](../README.md#one-private-configuration-for-your-computers).
   Remote origins require HTTPS; loopback can use HTTP. Credentials are never
   supplied as command-line arguments or placed in target files.
2. Pair those companions in Mac Settings as usual. In the updated Mac app, turn on
   **Allow agent control**. This is a one-time opt-in, off by default—not a
   per-command confirmation. Demo mode does not register a live receiver.
3. Use `ui clients` to find the receiving app. The app maintains an outbound
   connection to configured companions; there is no new inbound Mac listener,
   SSH requirement, or Accessibility permission requirement.
4. Invoke actions only within the human's authorization in the agent conversation.
   **CLI actions do not require another confirmation in the Mac UI.** Normal
   manually clicked confirmations remain unchanged. Authentication, exact-target
   checks, busy-state guards and existing Active Work/First Mate human checkpoints
   still apply. Discovering an action never grants permission to execute it.

Turning off Mac agent control stops UI control. It does not revoke the companion
API credential or disable existing authenticated resource-management APIs.
Credential entry, operating-system permission prompts, app installation and server
deployment are not automated by this interface.

## Choose the data host and the receiving app separately

Global options precede the command:

- `--config PATH`: existing private cluster TOML.
- `--machine desktop`: companion hosting the target workspace/chat.
- `--control-machine desktop`: companion relaying commands to an enabled Mac app.
  This is **not necessarily the Mac displaying the UI**.
- `--all-machines`: search across configured data companions.
- `--client ui_…`: leaf-command option identifying the receiving Mac app.

An explicit `--client` takes precedence over `HERDR_UI_CLIENT_ID`; an unavailable
hint fails rather than choosing another Mac. Without a hint, a sole online
receiver is selected. With several online receivers, the CLI can select the one
whose current conversation exactly matches the calling agent's valid
`PI_SESSION_ID`. Zero or multiple exact matches require `--client`; bare pane IDs,
list order and recent activity never choose the receiver. These hints select a
window, not an authorization grant.

```sh
herdr-control --help
herdr-control machines
herdr-control --control-machine desktop ui clients
herdr-control --control-machine desktop ui state
```

The receiving app can open a chat on another configured data companion. Raw IDs
such as `w1:p2` are only meaningful on their specified data machine. Stable server
identity maps CLI aliases to native saved connections; their display names and
locally assigned IDs need not match. Unknown connections are never silently paired.

## Find → inspect → open

```sh
herdr-control find chats --all-machines --ticket EXAMPLE-123 --sort updated --limit 10
herdr-control find chats --all-machines --query "upload retry"
herdr-control --machine desktop find workspaces --query "Upload feature"

# Save the chosen result's target, or the single result object, as target.json.
herdr-control --machine desktop inspect --ref-file target.json
herdr-control --machine desktop --control-machine desktop ui open \
  --ref-file target.json --view chat --wait 30

# An explicit pane ID is resolved and pinned before opening.
herdr-control --machine desktop --control-machine desktop ui open \
  --pane w1:p2 --view git --wait 30
```

Search results include names, timestamps, match excerpts, typed targets and source
coverage. A source `generatedAt` is its cached snapshot time, not the time the
search command ran; an empty string accompanies `freshness: "unknown"` when that
time is unavailable. Choose a result deliberately; never treat the first match
as the user's intent when multiple tickets/features/conversations fit. Natural-language
interpretation belongs to the calling agent. `--query` is text search, not a claim
of semantic/embedding search.

Live targets carry workspace/tab/pane and terminal/session identity. Inspection
and execution reject a closed, replaced or moved target rather than opening a
different conversation that reused the same pane ID. Opening saved HUD history
or a First Mate feature does not resume a model turn or promote it to a workspace.

**Search limits matter:** discovery covers live topology/current Pi content,
saved HUD conversations and First Mate metadata. Closed standalone Pi session
archives are not a complete indexed corpus. Read each source's `coverage`, errors
and continuation information; partial coverage is not “no chat exists anywhere.”
Do not silently discard an offline machine from an all-machines conclusion.

Use the returned `nextCursor` with `--cursor` and the same query settings to
continue a federated search. It records only the rows actually emitted from each
machine, so a globally limited page does not skip the other machines' remaining
results. `--offset` is an initial **per-source** offset, not a global page offset.
Like the underlying APIs, pagination is a live view, not a frozen snapshot;
concurrent additions/removals can change subsequent pages.

## Navigate the current window

```sh
herdr-control --control-machine desktop ui segment git --wait 30
herdr-control --control-machine desktop ui segment chat --wait 30
herdr-control --control-machine desktop ui segment workspace --wait 30
herdr-control --control-machine desktop ui segment active-work --wait 30
herdr-control --control-machine desktop ui segment fleet --wait 30
herdr-control --control-machine desktop ui back --wait 30
herdr-control --control-machine desktop ui forward --wait 30
```

Other segments are `terminal`, `skills`, `first-mate`, `attention` and `activity`.
Chat/Git/Terminal/Skills require an appropriate selected pane; unavailable modes
fail instead of silently selecting another view. Explicit tab navigation opens
its workspace overview and highlights that tab, not an arbitrary pane in it.
The main window is reused, including reopening it after it was closed.

Existing drafts and blocking dialogs are preserved. A blocked navigation returns
an error; automation does not dismiss an editor or discard unsent work to proceed.
After navigation completes, a human's subsequent click wins.

## Discover and invoke actions

```sh
# Resource operations run on the selected data companion.
herdr-control --machine desktop actions list
herdr-control --machine desktop actions describe pane.rename

# UI operations run in the selected Mac receiver.
herdr-control --control-machine desktop ui actions
# Unified aliases: actions list --ui / actions describe ACTION --client UI_ID.
herdr-control --control-machine desktop ui invoke chat.summarize \
  --current --request-id summarize-example-1 --wait 30
herdr-control --control-machine desktop ui invoke ui.settings --wait 30
```

Action descriptors contain IDs, parameter schemas, target kinds, effects and
capability availability. Exact target and busy/modal conditions are rechecked at
execution. Use `--parameters-file FILE` for a JSON parameter object. A target
reference is data, not a command, executable path or permission to act.

Summarize uses the existing separate summary flow, not a prompt sent to the
selected conversation. Its presentation receipt distinguishes opening/starting
that flow from completion of the model's summary. Smart Rename and other
long-running work may have separate operation state as described by their receipt.

### Implemented surface and boundaries

The live action catalog is authoritative; this is not yet every nested Mac UI
control from the [long-term plan](agent-control-plan.md).

| Area | Control surface |
| --- | --- |
| Main shell | Exact pane/workspace/tab opening; main segments; back/forward; refresh; reveal in sidebar |
| Chat | Chat/Terminal/Git/Skills modes, summary presentation, Smart Rename, exact model selection, local unread marking, tab color |
| Sidebar | Supported query/category/recency filters through a typed action |
| Other native surfaces | Settings window, HUD, HUD notes, saved HUD chat history, First Mate feature/inspector |
| Workspace resources | Create workspace, tab and Pi chat; rename workspace/tab/pane |
| Pane resources | Set star, split, close, end Pi while preserving the tab, compact, interrupt |
| Upstream terminal | Explicit focus and zoom operations, separate from Companion navigation |
| Existing domain tools | Notes, Active Work and First Mate retain their dedicated authenticated CLIs and workflow rules |
| Not app-wide parity yet | Individual Git diff/file controls, every Active Work/Fleet submenu, all settings setters, attachment/quote editors, and complete closed-session archive search |

Unsupported actions return an error. Do not substitute arbitrary terminal
keystrokes or a generic shell command to bypass the catalog or validation.
`pane.close` stops the pane's process and can remove its tab/workspace when it is
the last pane. Use the separately authorized `pane.retire` operation to end Pi
while retaining the tab/workspace. Neither operation asks again in the Mac UI.

## Create and then open

A workspace, a tab and a new chat are different operations. Search for the existing
feature workspace first; do not create a second workspace merely because the
human asked for another chat.

```sh
herdr-control --machine desktop --control-machine desktop workspace create \
  --name "Upload feature" --cwd /projects/example \
  --request-id workspace-example-1 --open --wait 30

herdr-control --machine desktop --control-machine desktop chat create \
  --workspace w1 --name "Investigate retries" \
  --request-id chat-example-1 --open --wait 30
```

Creation and UI opening have separate receipts. If creation succeeds but opening
fails, keep the created target and retry **navigation only**. Never create again
just to focus the result. New Pi chats can carry `--parent-session-id`; the CLI
otherwise uses the current Pi session context when available.

## Receipts, errors and retries

Every mutation returns its `requestId`. Provide a stable `--request-id` for a
logical operation and reuse it only with the same payload. The server reserves
resource operations durably before execution, binds UI commands to one receiver
instance, and never replays a claimed command after an uncertain outcome.
Receipts are retained for 30 days; new admission is bounded rather than evicting
young receipts to make space. An older missing receipt is not proof that the
operation never ran—inspect/reconcile rather than blindly resubmitting it.

- `accepted` / `running`: not completed navigation.
- `completed`: the control operation or navigation completed. This is not a
  promise that asynchronous model work finished. Summary presentation reports
  `operationState: started`; compact/interrupt use Pi's existing dispatch
  acknowledgement. Inspect the underlying session before reporting compaction,
  cancellation or summary generation finished.
- `failed`: inspect the structured error; do not bypass its guard.
- `expired`: a queued command was not executed before its short TTL.
- `outcome_unknown`: an effect may have occurred. Inspect/reconcile; do not issue a
  new create request hoping that it will be harmless.

`--wait SECONDS` waits at most 300 seconds. A timeout reports a pending receipt,
not success and not cancellation. No-wait mode reports submission, not visual
completion. `--dry-run` performs no mutation or enqueue.

```sh
herdr-control --machine desktop actions receipt workspace-example-1
herdr-control --control-machine desktop ui receipt navigation-example-1
```

Success/receipts are JSON on stdout. Argument/authentication/transport errors are
JSON on stderr. Exit codes are 0 for completion, 2 for invalid input/configuration, 3 for
transport/source unavailability, 4 for conflicts, 5 for failed/unknown operations,
and 6 for pending commands or wait timeouts. No-wait submission also exits 6
until a terminal receipt is available. Always read receipt status, not just
process exit status. Help works without credentials.

## Protocol and private state

The additive API exposes `/api/v1/control/capabilities`, `/api/v1/discovery`,
`/api/v1/control/inspect`, resource actions/receipts under `/api/v1/control`, and
receiver clients/state/actions/commands under `/api/v1/ui`. It requires the main
API bearer even when the server otherwise permits insecure loopback development.
Active Work scoped credentials do not authorize UI control.

Receiver registration, heartbeats and acknowledgements also require a per-server
receiver secret. The app keeps it in Keychain; the server stores only its hash.
UI state contains selection/navigation metadata, not drafts or credential values.
Control state belongs in private server storage, never in the repository.

A normal full-API caller is already trusted to manage that companion. This layer
adds receiver identity binding and typed operations; it is not a sandbox for an
untrusted agent holding that full bearer credential.

## Verification and delivery

Regression coverage must exercise exact IDs/session changes, alias differences,
partial and paginated discovery, credential isolation, redirects, stale receivers,
request/receipt conflicts, restart uncertainty, UI selection/history, modal/draft
preservation and no additional CLI confirmation. Use synthetic data and injected
transports/clocks, not captured personal conversations.

Implementation does not publish or install anything. A releasable candidate still
requires reviewed version/notes, exact-source Verify, privacy/signing gates and an
authorized signed-feed release. Server/CLI packages have their own delivery step.
