# Agent-driven Herdr Companion

**Status: core v1 implementation plus longer-term parity plan.** The CLI names and
API routes below describe the original proposed interface. Consult
[the command guide](agent-control.md) for implemented syntax, capability coverage
and remaining gaps. This plan is not evidence of complete app-wide parity.

## Goal

An agent can find relevant work across configured machines, resolve its exact
identity, open it in the user's current Companion UI, navigate every app surface,
and invoke supported workspace-management actions through the same handlers as
the UI. The agent can inspect the result instead of assuming that a click or a
submitted request succeeded.

Example human requests:

- “Find the latest chat for EXAMPLE-123 and open it here.”
- “Find the conversation about retrying failed uploads.”
- “Open this pane, then switch to Git.”
- “Show this workspace / Active Work ticket / Fleet machine.”
- “Summarize this chat.”
- “Find the feature's workspace, add a new chat there, and open it.”
- “Create a separate workspace for this feature and open it.”

**Completion means app-wide coverage, not just pane deep links.** Deliver the
foundation first, then finish a tracked navigation/action inventory. Do not call
the first milestone complete automation of the app.

## Existing foundations and gaps

Inspected against source revision `5f51749cf9264f0be5b57d294393a94beff572f7`, with
unrelated local edits present. Those edits must remain untouched.

| Existing foundation | Relevant source | Remaining gap |
| --- | --- | --- |
| Workspace/tab/pane snapshots and mutations | `herdr_harness/server.py`, `service.py` | One discoverable cross-machine CLI; stable search results and mutation receipts |
| Pane focus and zoom endpoints | `server.py`; `HerdrAppModel.focus` | These control the upstream terminal, **not** the Companion chat UI |
| Pane links and Jump to Pane | `Models/PaneReference.swift`, `Models/PaneResponseLinkCatalog.swift`, `Views/Root/AppRootView.swift` | General destinations, inspectable state, explicit receiver, acknowledgement |
| Single main Companion window and additional windows | `App/HerdrHarnessMacApp.swift` | Address app instance and window independently from the machine hosting a chat |
| Shell segments and navigation history | `Views/Root/AppRootView.swift`, `Models/NavigationHistory.swift` | Typed external navigation and subview state rather than scattered notifications |
| Existing Notes, Active Work, HUD history and First Mate CLIs | `scripts/herdr_*_cli.py`, `herdr_harness/commands.py` | Unified discovery without breaking or duplicating those domain APIs |
| Saved HUD chats and First Mate sessions | `herdr_harness/hud_chats.py`, `docs/first-mate/cli.md` | Search together with workspace chats while preserving different kinds of conversation |
| Summarize and pane/menu actions | `Views/Pane/PiSessionSummaryView.swift`, `PaneActionsMenu.swift`, `PaneSessionView.swift` | Callable action handlers outside view-local closures, with observable progress |
| Private machine roster and per-machine secrets | `herdr_harness/config.py` | Safe bounded fan-out; do not reuse one machine's inherited token for another |

Existing URLs and CLIs remain supported. This feature must not rename the upstream
`herdr` terminal CLI or change what its focus commands mean.

## Proposed interface: `herdr-control`

One installed JSON CLI, with separate discovery, UI and resource commands.
Natural-language interpretation stays with the agent; the CLI performs predictable
searches and typed operations. No additional LLM call is required just to search.

```sh
# Discovery: consult all configured, authorized companions.
herdr-control machines
herdr-control find chats --all-machines --ticket EXAMPLE-123 --sort updated --limit 10
herdr-control find chats --all-machines --query "failed upload retry"
herdr-control find workspaces --all-machines --query "upload feature"
herdr-control inspect --ref-file selected-chat.json

# Discover the receiving app, not just the machine hosting the data.
herdr-control ui clients
herdr-control ui state --client ui_example --window main
herdr-control ui open --client ui_example --ref-file selected-chat.json --view chat --wait
herdr-control ui segment git --client ui_example --wait
herdr-control ui segment active-work --client ui_example --wait
herdr-control ui segment fleet --client ui_example --wait

# Agents inspect schemas and disabled reasons instead of guessing menu labels.
herdr-control actions list --client ui_example --context current
herdr-control actions describe chat.summarize
herdr-control actions invoke chat.summarize --client ui_example \
  --ref-file selected-chat.json --request-id summary-example-1 --wait

# Creating a workspace and creating a chat are deliberately different operations.
herdr-control workspace create --machine desktop --name "Upload feature" \
  --cwd /projects/example --request-id workspace-example-1
herdr-control chat create --workspace-ref-file selected-workspace.json \
  --request-id chat-example-1 --open --client ui_example
```

`selected-chat.json` and `selected-workspace.json` contain a returned target object,
not prose or a credential. Convenience flags for exact machine/workspace/tab/pane
IDs resolve to the same typed target. A tab request never silently chooses one of
several chats: it opens/selects the tab overview or returns candidates.

Global conventions:

- JSON success on stdout and JSON errors on stderr; documented stable exit codes.
- Return schema/capability versions, request ID, operation state and exact target.
- Read commands never launch an app, change selection, resume agents or create work.
- Explicit bounded waits and cancellation; no endless implicit polling.
- `--dry-run` validates and describes effects without executing an action.
- A missing or unsupported capability is an actionable error, not a fallback to
  terminal keystrokes or a different mutation.
- Existing domain CLIs stay available. Share their clients/services rather than
  invoking shell-built command strings or reimplementing their business rules.

## 1. Cross-machine discovery

### Searchable entities

Workspace, tab, live pane, Pi conversation, saved HUD conversation, First Mate
feature/conversation and Active Work ticket. Include saved, closed conversations;
clearly distinguish them from live panes. A pane is a container and may host more
than one Pi session over its lifetime.

Search titles, labels, project paths, session metadata, linked ticket IDs, and
indexed conversation text. Prefer explicit Active Work/First Mate relationships
for a ticket lookup; distinguish an actual ticket link from a textual mention.
Expose why a result matched, with a small relevant excerpt, rather than reporting
an opaque AI confidence score.

Each result needs:

- Entity kind and immutable conversation ID where available.
- Data-server identity and configured machine alias.
- Workspace, tab and pane IDs when present; terminal identity and Pi session ID.
- Title, project path, status, last-activity timestamp and match evidence.
- Live/saved/closed status, supported open modes and a typed open target.
- Snapshot/index freshness and the sources searched.

“Latest” means newest matching conversation activity, not newest workspace label,
filesystem modification time or unspecified search relevance. Use an explicit
sort with deterministic tie-breaking. Never select the first result silently when
identities or the intended feature are ambiguous.

### Federated query contract

Each companion owns a local search index and enforces its existing authentication.
The CLI fans out to explicitly configured machines with bounded concurrency and
per-machine deadlines, then merges paginated results. It reports unavailable,
unauthorized, unsupported and truncated sources separately. An offline machine
must not turn into “no matching chats anywhere.”

Do not fetch every transcript into the CLI for each search. Start with live
metadata and existing saved-chat sources; add incremental local full-text indexing
for the app-wide milestone. Approved session roots only, bounded ingestion,
symlink/path safeguards, retention/deletion handling, and rebuildable private
index state. Never index arbitrary caller-supplied paths or publish the index.

Proposed additive capabilities: `discovery-v1` and `conversation-search-v1`.
Older servers can provide an explicitly marked metadata-only result. A partial
search must never claim full historical coverage.

## 2. Identity and the “Mac I am currently using”

There are two independent destinations:

1. **Data target:** the companion hosting the workspace or conversation.
2. **UI target:** the Mac app instance and window that should display it.

Opening a remote machine's chat must not foreground a Companion installation on
that remote machine. Nor should a bare `w1:p2` resolve across machines by accident.

Use a persistent server identity plus existing machine aliases and normalized
known origins. CLI aliases and native saved-connection IDs are not assumed to be
identical. Pair/migrate identities explicitly; never auto-create trusted native
connections from a navigation request or send credentials in a deep link.

A live target includes expected terminal/session identity so a reused pane ID
cannot open or mutate an unrelated conversation. Revalidate identity, membership,
connection generation and capability immediately before execution.

Receiver selection:

- A request originating in the app carries its originating UI client/window ID
  into the agent context. This identifies the window the human meant by “here.”
- A local CLI may resolve the one enabled local app instance.
- A remote agent uses the supplied originating client or explicit `--client`.
- If the receiver is missing or ambiguous, return candidates. Do not guess the
  most recently active Mac globally or broadcast a navigation to every Mac.
- Child agents do not inherit unrestricted permission to take over the UI merely
  because they inherit a session parent. Target context and authority are separate.

Today the primary UI is a single `Window`, not a `WindowGroup`. Start with its
stable `main` destination while addressing Settings, Active Work pop-out, HUD and
sheets explicitly. Restore a closed main window instead of spawning duplicates.

## 3. Acknowledged Mac control

Deep links remain useful for user-clickable navigation but are not the automation
protocol: operating-system URL delivery does not prove the app reached a target.

Use an authenticated companion-mediated control channel. An explicitly enabled
Mac app registers its client identity and capabilities with a selected control
companion, publishes a minimal state snapshot, and maintains an outbound event
connection. Agents submit typed commands addressed to that client. This supports
remote agents without SSH, Accessibility permission or an inbound Mac listener.

Proposed endpoints:

```text
GET  /api/v1/ui/clients
GET  /api/v1/ui/clients/{clientId}/state
GET  /api/v1/ui/clients/{clientId}/actions
POST /api/v1/ui/clients/{clientId}/commands
GET  /api/v1/ui/commands/{requestId}
```

Registration, event delivery and acknowledgements need separate authenticated
client operations. Pairing must bind the receiver identity to its credential; a
caller must not be able to impersonate another app or acknowledge its commands.
Specify these wire schemas and threat-model them before implementation.

State includes actual window/surface, segment, selected machine/workspace/tab/
pane/session, selected item, modal state, available actions and a UI revision.
Do not expose unsent drafts, tokens, screenshot contents or Keychain values.

Command states: `accepted`, `running`, `awaiting_confirmation`, `completed`,
`failed`, `expired`, and `outcome_unknown` where appropriate. A navigation is
completed only after the app has resolved the target and reported the applied
selection. A long summary returns an operation ID; opening its sheet is not the
same as completing the summary.

Commands have short explicit expiry, bounded queues and request-ID deduplication.
No stale navigation or destructive command should fire after a Mac reconnects.
A retry of the same request ID with a different body conflicts. Session/terminal
and optional expected-UI-revision checks prevent acting on a changed selection.

Use explicit targets for management actions. “Current” resolves to a concrete
identity/revision before dispatch. Preserve drafts and report blocking sheets or
unsaved-change confirmations; do not dismiss them to force navigation. Once a
navigation is acknowledged, a subsequent human click wins—no automatic refocusing.

## 4. Shared action registry, not UI scripting

Create a versioned registry with contributions from each feature module. Each
action describes its stable ID, parameters, target kinds, effects, permission and
confirmation requirements, capability prerequisites, enabled state and disabled
reason. Long-running operations expose progress/results/cancellation.

Menus, buttons, keyboard shortcuts and automation use the same handlers. Move
business actions out of view-local closures into the appropriate stores/services;
keep view rendering in SwiftUI. UI-only commands route through shell state.
Resource mutations reuse authenticated domain services and remain usable without
a visible window. Embedded Git and Active Work web views need typed navigation
bridges and acknowledgements, not JavaScript string injection or pixel clicks.

Prefer explicit setters (`starred: true`, `mode: chat`) over toggles that flip on
retries. Keep native validation, busy-state guards, revision checks, exact-session
checks and human checkpoints. No generic arbitrary-selector/shell-command escape
hatch should masquerade as full action coverage.

### Coverage inventory

This is the initial inventory. Complete a control-by-control audit before claiming
parity, including toolbar, context-menu, submenu, keyboard-only and sheet actions.

| Surface | Navigation and action families |
| --- | --- |
| Shell | Chat/Session, Terminal, Git, Workspace, Active Work, First Mate, Fleet, Attention, Activity; back/forward; next/previous pane; palette; reveal in sidebar; refresh |
| Sidebar | Search and machine/recency/category/color filters; expand/collapse; workspace/tab/chat selection; starred/unread; tab colors and labels |
| Workspaces/tabs | Inspect, create, rename, open, terminal focus; new shell/chat, split; cleanup preview; separately confirmed close/apply |
| Chat | Exact live or saved conversation; summarize; smart/manual rename; new Pi session; model/thinking; compact/reload; draft vs send; attachments, quotes, results and prompt history; separate stop/close operations |
| Git | Repository/file/section/commit selection, diff state, refresh; explicitly authorized staging/unstaging and other existing mutations |
| Active Work | Board/item/path/stage/agent/evidence selection; existing revision-checked updates and lifecycle actions; preserve recorded human gates |
| First Mate | Host/feature, conversation, workflow graph/timeline, agents, documents; existing create/send/model/lifecycle operations without implicit stage approval |
| Fleet | Machine/catalog/item selection, status and refresh; explicit plan/sync/install/remove with existing safeguards |
| Attention/activity | Filters, item selection, linked session navigation and acknowledgement/read state |
| HUD/Notes/Agent window | Show/hide, saved chat selection, history, folders, note selection/editing, summary/question views, results, explicit promotion to workspace |
| Settings and other windows | Open specific sections, inspect nonsecret settings, typed supported setters, update checks; credential entry and OS security prompts stay human-controlled |

Maintain a checked-in action manifest and coverage matrix with a handler, schema,
test and any intentional human-only boundary per row. New UI controls must be
registered or explicitly classified in review. This makes “every component” a
verifiable scope rather than an open-ended promise.

### Authorized confirmation policy

Discovery and ordinary navigation are non-destructive. Workspace creation,
summarization and other agent-starting actions require explicit task authority
and report their side effects/cost-bearing work.

**User decision:** authorization in the agent conversation is sufficient. CLI
commands do not require a second confirmation in the Mac UI. Invoke the shared
operation directly after validating its exact target and parameters. Keep normal
manual UI confirmations unchanged, and preserve authentication, revision checks,
busy-state guards and recorded Active Work/First Mate human checkpoints. Discovery
alone never authorizes a mutation. This implementation request does not authorize
publication, installation or server deployment.

## 5. Search → resolve → create/open workflows

The agent searches first, inspects candidate context, and chooses the intended
existing workspace, tab and conversation. Search never grants mutation authority.
A new workspace, new tab, new chat and resuming saved history are distinct verbs.

Create returns the exact created resource IDs. If `--open` is requested, UI
navigation is a second recorded step. If opening fails, return “created, not
opened” with the IDs; do not create another resource to retry navigation.

Add durable operation receipts for retry safety. Existing workspace/tab creation
RPCs must be audited for idempotency. A crash after a non-idempotent upstream
mutation but before recording its result cannot be claimed as exactly-once:
return `outcome_unknown` and reconcile rather than automatically resend. New Pi
sessions preserve the caller's authorized parent-session linkage.

Saved-chat `open` displays history. `resume`, `promote`, and `new-session` are
separate explicit mutations. Never start a model turn merely to show a result.

## Delivery plan and acceptance gates

### A. Search and exact, acknowledged navigation

- Finalize identity, receiver authentication, command/receipt schemas and threat model.
- Add `herdr-control`, live metadata discovery and existing saved-chat discovery.
- Add registered Mac receiver, state inspection and the shared route dispatcher.
- Open the exact pane/conversation/workspace/tab and all main segments; support
  current-context Git/Chat/Terminal switching, closed-window recovery and history.
- Explicitly report metadata-only or unsupported historical search on older hosts.

Acceptance: two machines contain the same raw pane ID; an agent on one machine
opens the intended other-machine chat in the requesting Mac's current UI. Repeating
the request does not duplicate windows. A missing/replaced target fails instead
of selecting another pane. An offline receiver is not reported as success.

### B. Search → manage → show

- Complete full-text history/ticket discovery, pagination and freshness reporting.
- Add workspace/tab/chat create and rename operations with receipts/reconciliation.
- Route Summarize, smart rename, star/unread, tab color and session view actions
  through their shared handlers, preserving drafts and session identity.
- Make result resources/operations navigable and propagate origin UI context into
  authorized app-launched agent requests.

Acceptance: “latest chat for ticket” reports its matching evidence, opens the
correct conversation and can summarize it without sending a prompt into that
conversation. “Add a chat to the existing feature workspace” creates exactly the
requested kind of resource; a navigation retry does not repeat creation.

### C. App-wide parity

- Finish every coverage-inventory row, including nested views, embedded web
  surfaces, HUD, Notes, settings, dialogs and asynchronous operations.
- Publish the registry/schema through CLI help and machine-readable discovery.
- Add concise agent usage guidance so callers use search → inspect → act → verify.
- Declare human-only boundaries, not fake successful automation of OS prompts.

Acceptance: audit every actionable UI control against the coverage manifest;
there are no unexplained gaps. Unsupported/disabled actions return their reasons.

### D. Final validation and delivery

Astra writes bounded interfaces and worktree handoffs, Sol implements and authors
synthetic tests, Astra reviews, and Luna owns one final validation matrix. No
incremental suites or routine repeated builds. Preserve the user's current dirty
checkout; use separate worktrees and integrate only reviewed feature changes.

Required regression coverage includes cross-machine credential isolation, partial
search, ambiguity, exact-session routing, stale/reused IDs, unauthorized clients,
forged receipts, request-ID conflicts, expiry/reconnect/restart behavior, blocked
modals, draft preservation, creation outcome uncertainty, saved-vs-live histories,
Git/Chat history, action guards and backward compatibility. UI tests must inspect
actual selection, not just receipt acceptance. Use synthetic data only.

Freeze reviewed source, notes and version metadata before final execution. Use
exact-SHA Verify as the authoritative full suite when a push is authorized; don't
duplicate it locally by habit. No push, publication, app installation or server
cutover is authorized by this plan. Publish a Mac update through the signed feed
only when requested. Package the companion/CLI separately, documenting capability
requirements and upgrade order; an app update does not deploy server packages.

## Implementation decision

Proceed with the user's no-additional-UI-confirmation policy above. Deliver the
CLI, authenticated receiver, discoverable actions and navigation in isolated
worktrees, preserving unrelated in-progress source. Report actual implemented
coverage and final validation rather than treating this plan as proof of parity.
