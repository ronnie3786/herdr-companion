# iOS mobile UI revision 02 — implementation plan

Status: implemented native slice; full native suite passed on September 12, 2026.
Planned against `0efbb60` (September 11, 2026).
`design/ios-mobile-ui-v2-2026-09-11/` is the visual/spec source, not runtime
behavior, production data, a model catalog, or a terminal implementation.

## Scope and decisions

Implement:

1. Align iOS semantic colors with the current charcoal/lavender Mac palette,
   while retaining iOS spacing and 44-point touch sizing.
2. Use Mac-style system prose for assistant output while retaining the existing
   semantic role sizes, Dynamic Type scaling, and monospaced code treatment.
3. Make the existing navigator conversation-first. **Recents** is a flat newest
   20; **All** is Unread, Starred, then machine → workspace → actual tab → pane.
   These are ranges in one navigator, not new app tabs.
4. Add six optional tab-owned colors — Lavender, Iris, Rose, Clay, Sage, Slate —
   as secondary local iOS organization. Tint only navigator tab/chat rows and
   the color key.
5. Add a prominent pane title/scope header and a distinct, equal-width
   **Chat / Git / Terminal** row. Keep Skills in Pane actions.
6. Improve the existing separate Model and Thinking controls without replacing
   their live catalog, session state, or capability gates.
7. Retain unsent text verbatim in memory per machine-scoped pane across pane and
   mode changes.

Do not implement session families, manual Mark Unread, Smart Rename, saved HUD
chats, quotes/chapters, Active Work parity, broad Git redesign, or other features
from the 37-item audit. Do not change server, Pi, Mac, authentication, or API
contracts.

No blocking product decision remains.

## Existing foundation

- iOS already has `SidebarTree`, date ranges, machine scoping, persisted collapse
  state, Starred reconciliation, and `HerdrAppModel.unreadPaneIDs` from server
  alerts. It lacks flat Recents and an Unread priority projection.
- Opening a pane already clears its alerts optimistically and retries the
  authenticated server acknowledgement. Reuse this; unread is not a second
  status model.
- iOS has no `parentSessionID` decoding or `PiSessionTree`. Children remain
  reachable as ordinary panes under actual tabs in this slice.
- Model and Thinking already have independent store mutations and capability
  checks. Keep them independent and production-catalog-driven.
- `HerdrProse` currently calls `Font.custom` with bundled Inter faces. Replace
  prose role fonts with system fonts at the same semantic sizes/weights and
  Dynamic Type anchors; keep monospaced inline/code-block styling. Do not delete
  unrelated font assets as part of this slice.
- Native Photos, Files, quick dictation, voice recording, uploads, response
  audio, haptics, notifications, links, and Live Activities remain intact.
- Git continues using the existing workspace Git routes.

## Stable shared APIs

### Local tab colors

```swift
enum ChatTabColor: String, CaseIterable, Codable, Hashable, Identifiable, Sendable

enum ChatTabColorFilter {
    static func workspaces(
        _ workspaces: [HerdrWorkspace],
        tabIDs: Set<String>?
    ) -> [HerdrWorkspace]
}

@MainActor @Observable
final class ChatTabColorStore {
    init(defaults: UserDefaults)
    func color(for tabID: String) -> ChatTabColor?
    func tabIDs(for color: ChatTabColor) -> Set<String>
    func label(for color: ChatTabColor) -> String
    func assign(_ color: ChatTabColor?, to tabID: String)
    @discardableResult func rename(_ color: ChatTabColor, to text: String) -> Bool
    func resetLabel(_ color: ChatTabColor)
    func activeColors(tabIDs: Set<String>) -> [ChatTabColor]
    static func validLabel(_ text: String) -> String?
}
```

`HerdrAppModel` owns:

```swift
let chatTabColors: ChatTabColorStore
```

Use `herdr.chatTabColors.v1` with:

- `assignments[machineScopedTabID] = colorRawValue`
- `labels[colorRawValue] = text`

The same key/schema as Mac is only local format compatibility; app sandboxes are
separate. iOS neither reads nor claims to show current Mac assignments. Labels
are trimmed 1–80 characters without control characters. Invalid saved values
are ignored without destructive rewriting. Keep absent-tab assignments so a
temporary disconnect does not erase organization. One iOS-local label applies
to every tab assigned that color.

Cross-client sync/import is separate future work requiring an authority,
revision conflicts, stable tab incarnation rules, explicit import, and rollback.
No endpoint or capability is added now.

### Navigator projection

Extend `SidebarRecency` with `.recents` and `recentsLimit = 20`. Recents ranks by
`lastActivityAt ?? firstSeenAt`, descending, with scoped pane ID as tie-break.
It is not a date predicate.

Add `SidebarTree.UnreadGroup`, `recentChats(...)`, and explicit pane exclusions.
Add this pure projection:

```swift
struct SidebarProjection: Equatable {
    let isRecents: Bool
    let recentChats: [HerdrPane]
    let unreadGroups: [SidebarTree.UnreadGroup]
    let starredGroups: [SidebarTree.StarredGroup]
    let tree: [SidebarTree.ProjectEntry]
    let machineGroups: [SidebarTree.MachineGroup]
    let visiblePaneCount: Int

    init(
        workspaces: [HerdrWorkspace],
        machines: [HerdrMachine],
        machineStates: [String: ConnectionState],
        machineScope: MachineScope,
        query: String,
        recency: SidebarRecency,
        colorFilterTabIDs: Set<String>?,
        collapsedMachineIDs: Set<String>,
        collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String>,
        starredPaneIDs: Set<String>,
        unreadPaneIDs: Set<String>,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    )
}
```

Projection order is fixed:

1. machine scope;
2. tab-color filter;
3. query/range;
4. Recents: one flat top-20 list, with unread/star as row attributes;
5. grouped modes: Unread, then Starred excluding Unread, then ordinary tree
   excluding both.

No pane ID may render twice. Search matches pane, actual tab, workspace/path,
and the active machine scope. Search force-expands only its projection; it does
not rewrite persisted collapse state. Heading counts remain real container
counts, not post-promotion counts.

Use `.recents` as the iOS default. Today, Last 3 Days, This Week, and All remain
in the same range menu. `HerdrAppModel` owns the transient in-process navigator
selection alongside recency:

```swift
var sidebarQuery = ""
var sidebarColorFilter: ChatTabColor?
```

The sidebar binds directly to those properties so query and color survive drawer
close/unmount/reopen during the app session. Do not persist either property.
Sheet/dialog presentation and editing state remain local to `HerdrSidebarView`,
so closing the drawer still tears those views down automatically. Color
assignments/labels and existing collapse/machine state retain their current
persistence behavior.

### In-memory drafts

```swift
@MainActor @Observable
final class PaneDraftStore {
    func text(for paneID: String) -> String
    func setText(_ text: String, for paneID: String)
    @discardableResult
    func clearText(for paneID: String, ifUnchanged expectedText: String) -> Bool
    func reconcile(machineID: String, validPaneIDs: Set<String>)
    func removeAll(forMachineID machineID: String)
}
```

`HerdrAppModel` owns:

```swift
let paneDrafts = PaneDraftStore()
```

`PaneSessionView` binds to `model.paneDrafts` using `pane.id`. Store every
nonempty String exactly, including whitespace-only text, leading newlines, and
indentation; remove an entry only when the String is exactly empty. Trimming is
allowed only to decide whether there is sendable text, not to normalize stored
or submitted nonblank text. Text survives mode/sidebar/pane switches during the
process, but is not persisted, synced, uploaded, or sent before Send.

Before an async send, capture the origin pane ID, exact draft, and submitted
attachment identities. On success, `clearText(for:ifUnchanged:)` clears only the
origin pane and only if that pane still contains the submitted draft; text typed
later or in another pane must survive. Remove/clean only attachments included in
that successful origin-pane submission. Failed sends retain their exact text and
attachments.

Attachments remain mounted-session state because temporary/security-scoped URLs
cannot be honestly restored. Preserve their current cleanup. Never erase drafts
from a transient empty refresh; reconcile only after a successful machine
snapshot with at least one valid pane. Explicit machine removal may clear that
machine's drafts.

### Scoped integration exception — prompt text forwarding

Foundation additionally owns only the text-forwarding seam in
`State/PiConversationStore.swift`, `HerdrAppModel.sendPiConversationPrompt`, and
`HerdrAppModel.sendPrompt`. Each layer trims solely to reject whitespace-only
input and must forward the original nonblank String to `HerdrAPIClient`. Existing
slash-command, disposition, capability, authentication, pane-existence,
compaction, connection, and busy gates remain unchanged.

The existing server request validator preserves `text` and `command` after
validation, so this native repair requires no server or HTTP API change. The
current Pi semantic bridge separately applies `payload.text.trim()` before Pi's
`sendUserMessage`; that behavior remains outside this approved iOS exception.
The native guarantee therefore ends at the outgoing request body. Verbatim final
Pi delivery would require a separately reviewed Pi bridge behavior change.

## Native UI contract

### Navigator

Keep `HerdrSidebarView(model:)`. Split its body into focused view files.

- Header: Herdr identity, labeled 44-point range menu, 44-point close.
- Keep the existing machine picker and machine capability checks.
- Search is followed by one 44-point **Tab colors** row, then existing New
  workspace, New Pi session, and Run agent actions.
- Color sheet: All colors, active labels/counts, manual label editing, and clear
  text that values are saved only on this iPhone/iPad.
- Recents row: prominent regular title, quiet machine/workspace context, explicit
  icon+status, unread/star cues, optional subdued tint.
- All: Unread and Starred priority sections, then real hierarchy.
- Color assignment is available from tab/chat rows and Pane actions. Future
  panes inherit through the tab ID.
- Selected rows use background/stroke, not a leading stripe.

Reusable UI API:

```swift
struct ChatTabColorMenu: View {
    let store: ChatTabColorStore
    let tabID: String
}
```

Rows use minimum, not fixed, 44-point heights. Long titles may wrap. At large
Dynamic Type, secondary content may stack. Under Differentiate Without Color,
show the stable numbered color symbol. Status, unread, star, selection, and mode
also have symbols/text and VoiceOver labels.

The compact navigator remains a drawer. Regular-width iPad retains the existing
`NavigationSplitView`/workspace overview so no destination is removed. Global
Workspaces, Attention, Notes, and Settings navigation is unchanged.

### Pane and modes

Add:

```swift
PaneSessionHeader(model:pane:store:)
PaneModeBar(selection:supportsChat:gitAvailability:)
```

- Header shows prominent pane title, agent/status, and machine → workspace →
  actual tab. Native rename and Star remain available. It stays neutral even
  when the tab is colored.
- Mode row always has three equal columns in the order Chat, Git, Terminal;
  controls are at least 44 points. Skills remains reachable from Pane actions.
- Semantic Pi panes auto-open Chat as today. Plain/reserved shells open Terminal,
  disable Chat, hide Pi context/model/thinking, and retain ReservedShell actions.
- Probe Git using existing `fetchGitStatus(for workspace:)`. Port the pure
  `PaneGitAvailability`/`PaneGitProbePolicy` states: checking, available,
  unavailable; transient failures preserve the last known state. Demo Git is
  available. Disable Git until confirmed and fall back to Terminal if a selected
  Git mode becomes unavailable.
- `PaneActionsMenu` receives `gitIsAvailable`, adds Star and
  `ChatTabColorMenu`, and retains every current view/focus/control/Pi/pane/close
  action and guard.
- Ordinary Close pane and End Pi & close pane keep distinct confirmations and
  existing final-pane safety.

### Prose typography

Update `HerdrProse.font(_:)` to return system fonts using each role's existing
base size, weight, and Dynamic Type-relative text style. Preserve role spacing,
heading hierarchy, block quotes, and monospaced inline/code-block styling. Keep
bundled Inter assets because their removal is unrelated cleanup, not part of the
approved slice.

### Model and Thinking controls

Keep current initializer signatures for `PiComposerOptionsBar`,
`PiModelPickerChip`, and `PiThinkingLevelChip`.

- Render separate labeled Model and Thinking controls, minimum 44 points.
- Model gets flexible width; long real names wrap. Stack at accessibility sizes
  when horizontal layout no longer fits. Response-audio controls remain visible.
- Use `availableModels`; add no illustrative HTML names to production data.
- Selecting one control never mutates the other. Preserve live state, catalog
  loading/retry, reasoning support, bridge/compaction/busy gates, notices,
  haptics, and cancellation.

Do not edit `PiChatView`. Outside the scoped prompt-forwarding integration
exception above, do not edit `PiConversationStore`. `PromptComposerView` has one
narrowly authorized change: preserve exact nonblank draft whitespace and perform
compare-and-clear cleanup against the captured origin pane/submission. Its
Photos/Files/voice/audio/focus/sheet behavior otherwise remains unchanged.

## Exact ownership assignment

Shared checkout rule: no agent edits outside its scope, runs simulator/shared
DerivedData integration builds, commits, pushes, installs, or deploys.

### Foundation — this planning session, only after explicit authorization

Owns:

- `Design/HerdrTheme.swift`
- `Design/HerdrProse.swift`
- new `Design/ChatTabColor.swift`
- new `Models/ChatTabColorFilter.swift`
- new `Models/SidebarProjection.swift`
- `Models/SidebarRecency.swift`
- `Models/SidebarTree.swift`
- new `State/ChatTabColorStore.swift`
- new `State/PaneDraftStore.swift`
- `State/HerdrAppModel.swift`
- the text-forwarding seam only in `State/PiConversationStore.swift`
- color/projection/draft/prompt-forwarding unit tests, `SidebarTreeTests.swift`,
  and focused `HerdrProseFontResolutionTests.swift` typography expectations

This is the sole owner of `HerdrAppModel.swift` and lands first. No foundation
coding starts without authorization.

### `ios-v2-sidebar`

Owns:

- `Views/Sidebar/HerdrSidebarView.swift`
- `Views/Sidebar/SidebarRowViews.swift`
- `Views/Sidebar/SidebarMetrics.swift`
- `Views/Sidebar/SidebarDrawer.swift`
- new Sidebar view files, including `ChatTabColorMenu.swift` and color sheets
- `herdr-harness-iosUITests/HerdrSidebarUITests.swift`

Consumes the stable `SidebarProjection`, `ChatTabColorStore`, and
`ChatTabColorMenu(store:tabID:)` APIs. It does not edit app state, models, Pane
views, workspace navigation, or API code.

### `ios-v2-chat`

Owns:

- `Views/Pane/PaneSessionView.swift`
- `Views/Pane/PromptComposerView.swift` only for exact-whitespace send capture
  and origin-pane compare-and-clear cleanup
- `Views/Pane/PaneActionsMenu.swift`
- `Views/Pane/PiComposerOptionsBar.swift`
- `Views/Pane/PiModelPickerChip.swift`
- `Views/Pane/PiThinkingLevelChip.swift`
- new `PaneSessionHeader.swift`, `PaneModeBar.swift`, `PaneGitProbePolicy.swift`
- focused Git-probe/configuration tests
- `herdr-harness-iosUITests/HerdrDemoNavigationUITests.swift`

Consumes `model.paneDrafts` and Sidebar's exact
`ChatTabColorMenu(store:tabID:)`. It does not edit `PiConversationStore`, app/API
models, Sidebar files, or `HerdrAppModel`; all other composer behavior is out of
scope.

Sidebar and Chat may prepare against these signatures, but compile integration
follows Foundation. If Chat reaches the color-menu call before Sidebar adds it,
leave the single call site for integration; do not duplicate the type.

### Final integration owner

One owner only:

- resolves initializer/call-site drift without widening scope;
- updates the root `README.md` feature table, explicitly saying colors are local
  to iOS and do not import Mac assignments;
- makes only minimum synthetic-preview fixture adjustments needed for rendering;
- runs native build/tests/simulator checks and public-source guard;
- leaves the existing untracked `design/` tree out of implementation commits.

## Completed verification — September 12, 2026

- Xcode 26.2 unsigned simulator `build-for-testing` succeeded. The complete
  native unit and demo UI run passed **350/350 tests**, with no skipped tests,
  on an iPhone 17 Pro simulator running iOS 26.2.
- Verification used a neutral public-source export, excluding ignored private
  signing settings and bootstrap metadata. All 313 original unit tests also
  passed against the baseline export.
- Native UIKit-hosted component renders cover 320, 390, and 430-point widths at
  default and Accessibility 3 text sizes, using synthetic long titles/model
  names. Exact bitmap widths and 44-point minimum controls are asserted. These
  are component captures, not a connected conversation or full-device layout
  certification.
- UI regressions cover Recents/All hierarchy, priority deduplication, workspace
  collapse, tab-color sheet copy and labels, search/color continuity across
  drawer navigation and reset on relaunch, nonsemantic/shell mode gates,
  expandable controls, landscape accessibility-text voice actions, and notes.
- The public-source guard and whitespace checks passed. Existing baseline
  actor-isolation/App Intents warnings are not new failures.
- No server, Pi bridge, Mac app, or shared API changes are included. Physical
  device installation, connected Pi interaction, manual VoiceOver, and the full
  iPad/media/notification lifecycle matrix still need hands-on validation.

The checklist below retains the original broader acceptance plan; it is not a
claim that every manual/device scenario has been certified. Private signing
inputs, archives, profiles, deployment destinations, and build hashes are kept
outside the repository. Device build numbers may be supplied at archive time
with `CURRENT_PROJECT_VERSION` without changing the contributor defaults.

## Verification and acceptance plan

Parent/integration owner runs builds and simulators to avoid DerivedData
collisions. Baseline `build-for-testing` on `0efbb60` has zero errors; known
actor-isolation/App Intents warnings are baseline, not this slice.

Focused checks:

- Unit: six stable colors, label validation/persistence, scoped-tab inheritance,
  filter ordering, Recents top-20/ties, query matches, Unread-over-Starred and no
  duplicates, shell/loose panes, verbatim whitespace drafts, conditional
  origin-pane clearing, draft retention/pruning, system-prose role/Dynamic Type
  resolution, Git probe transitions, and existing model/thinking capability
  tests.
- UI/render: 320, 390, 430-point phones, landscape, and iPad regular; default and
  accessibility Dynamic Type; long synthetic names; equal mode frames; 44-point
  controls; VoiceOver; Differentiate Without Color; Reduce Motion.
- Lifecycle: two pane drafts; switch pane/mode/sidebar; open/dismiss color rename,
  Files, Photos, file search, voice, Model, and Thinking surfaces; verify no
  auto-send, wrong-pane focus/write, lost failed draft, or temporary-file leak.
- Regression: pane retirement/close safety, alert read acknowledgement, stars,
  attachments, voice/audio/haptics, links/notifications, terminal and Pi streams,
  notes conflicts, and Herd Pulse.
- Run README's unsigned iOS `build-for-testing`, relevant native suites, then
  `.venv/bin/python scripts/check-public-source.py`.

Acceptance checklist:

- [ ] Recents/All are one navigator; no invented tab/color destination.
- [ ] Recents is flat newest-20 with title, location, status, unread, and star.
- [ ] All is nonduplicate Unread → Starred → machine/workspace/tab/pane.
- [ ] Search, machine, range, and color filters intersect and reset cleanly;
      query/color survive drawer close/reopen but reset on app relaunch.
- [ ] Six local tab colors/labels persist and inherit by scoped tab ID; only
      navigator rows/key tint; non-color cues exist.
- [ ] UI never claims Mac color assignments are imported or synchronized.
- [ ] Pane title/status and full machine/workspace/tab scope are accessible.
- [ ] Chat/Git/Terminal are equal-width and distinct from global navigation;
      Skills and all existing destinations/actions remain reachable.
- [ ] Shell/reserved-shell and Git availability are truthful and safe.
- [ ] Model and Thinking remain independent, live-catalog/capability-driven,
      long-label/Dynamic-Type-safe; response audio remains reachable.
- [ ] System prose preserves role sizing, Dynamic Type, hierarchy, and
      monospaced code without unrelated font-asset deletion.
- [ ] Per-pane text drafts preserve whitespace verbatim and survive in-process
      navigation; async completion clears only an unchanged origin-pane
      submission; failed sends retain state; focus/sheets cannot target a stale
      pane.
- [ ] Native prompt layers reject whitespace-only input but preserve each
      original nonblank String through the outgoing HTTP request body; the
      documented Pi bridge normalization boundary is not misrepresented.
- [ ] Photos, Files, voice, uploads, audio, haptics, Live Activities, auth,
      validation, and stream lifecycle remain intact.
- [ ] Close-pane safeguards and confirmations are unchanged.
- [ ] No server, Pi, Mac, auth, or shared API contract changes.
- [ ] Native verification and public-source guard pass with no new warnings.
