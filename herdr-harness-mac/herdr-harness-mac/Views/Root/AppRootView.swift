import AppKit
import SwiftUI

/// Which view the detail column is showing. The Mac shell has no tab bar, so
/// this is what replaced `AppTab` for the two non-settings destinations plus
/// the workspace overview that only iPad ever showed as a middle column.
enum HerdrDetailScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case session
    /// Git shares the mounted pane with Chat, but is a distinct history stop.
    case git
    case workspace
    case activeWork
    case prReview
    case firstMate
    case fleet
    case attention
    case activity

    var id: String { rawValue }

    /// Destinations represented by the central segmented picker.
    ///
    /// First Mate and PR Review have dedicated rails reached from the navigator.
    static let pickerCases: [HerdrDetailScope] = [
        .session,
        .git,
        .workspace,
        .activeWork,
        .fleet,
        .attention,
        .activity,
    ]

    /// The segments actually rendered. Git only earns a segment when the pane
    /// on screen has a repository, mirroring how the old header button came and
    /// went with `gitIsAvailable`.
    static func pickerCases(includingGit: Bool) -> [HerdrDetailScope] {
        includingGit ? pickerCases : pickerCases.filter { $0 != .git }
    }

    /// Returns a scope only when the central picker has a matching segment.
    /// Dedicated toolbar destinations intentionally resolve to no selection.
    static func pickerSelection(for scope: HerdrDetailScope) -> HerdrDetailScope? {
        pickerCases.contains(scope) ? scope : nil
    }

    var label: String {
        switch self {
        case .session: "Session"
        case .git: "Git"
        case .workspace: "Workspace"
        case .firstMate: "First Mate"
        case .activeWork: "Active Work"
        case .prReview: "PR Review"
        case .fleet: "Fleet"
        case .attention: "Attention"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .session: "bubble.left"
        case .git: "arrow.triangle.branch"
        case .workspace: "rectangle.3.group"
        case .firstMate: "sailboat"
        case .activeWork: "square.grid.2x2"
        case .prReview: "arrow.triangle.pull"
        case .fleet: "desktopcomputer"
        case .attention: "bell"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

/// Window-shell state that the menu bar and the window content both drive.
/// Everything durable still lives in `HerdrAppModel`; this only holds what the
/// iOS app kept in view-local `@State` (the tab selection and a sheet flag).
@MainActor
@Observable
final class HerdrShellState {
    var detailScope: HerdrDetailScope = .session
    private(set) var firstMate = FirstMateStore()
    let firstMateFleet = FirstMateFleetIndex()
    /// One cache coordinator per app process: the main rail and every popped
    /// out review or document window share download phases and window-lifetime
    /// cache protection, so no window can evict a file another is displaying.
    let prReviewDocumentResources: PRReviewDocumentResources
    let prReview: PRReviewStore
    var firstMateMachineID: String?
    var firstMateScope: FirstMateMachineScope?
    private(set) var activeFirstMateMachineID: String?
    var prReviewMachineID: String?
    var prReviewOpenRequest: PRReviewOpenRequest?
    var prReviewAppliedRequestID: UUID?
    var firstMateOpenRequest: FirstMateOpenRequest?
    var firstMateAppliedRequestID: UUID?
    @ObservationIgnored private var firstMateStores: [String: FirstMateStore] = [:]
    @ObservationIgnored private var configuredFirstMateConnectionIdentities: [String: FirstMateConnectionIdentity] = [:]
    @ObservationIgnored private var firstMateCacheGeneration: Int?
    @ObservationIgnored private var firstMateCacheIsDemo: Bool?
    @ObservationIgnored private var configuredPRReviewConnectionIdentity: PRReviewConnectionIdentity?
    private(set) var paneModeFocusRequest = 0
    private(set) var agentControlPaneMode: PaneDetailMode?
    private var agentControlPaneID: String?
    private var agentControlSelectionPaneID: String?
    private(set) var highlightedOverviewTabID: String?
    var agentControlWindow: AgentControlWindow = .main
    var piSessionSummaryRequest: PiSessionSummaryRequest?
    var pendingFirstMateControlTarget: (machineID: String, featureID: String, inspector: FirstMateInspector)?
    var pendingFirstMateCreateMachineID: String?
    var isCreatingWorkspace = false
    var isCreatingPRReview = false
    var isAddingPRReviewSkill = false
    var hasPRReviewQuestionDraft = false
    var isAgentPresented = false
    /// Help ▸ Report a Bug or Request a Feature… (⌘⌥F), also posted by the
    /// Settings Feedback section through `.herdrPresentIssueReport`.
    var isIssueReportPresented = false
    /// Navigate ▸ Jump to Pane…. A pasted reference, not a picker: the ids
    /// come from outside the app — a URL, a log line, a message — which is
    /// exactly the case the ⌘K palette cannot serve.
    var isJumpToPanePresented = false
    var jumpToPaneInput = ""
    var agentInitialPrompt: String?
    var isCommandPalettePresented = false
    private(set) var commandPaletteFocusRequest = 0

    /// Browser-style back/forward over the places the detail column has been.
    ///
    /// Persisted to UserDefaults (`NavigationHistoryPersistenceStore`, key
    /// `herdr.navigation.history`) so Back/Forward survive an app restart. Pane
    /// and workspace ids are machine-scoped and the fleet is re-fetched on every
    /// launch, so most restored entries are dead the instant the app relaunches;
    /// `goBack`/`goForward` already skip dead destinations at traversal time via
    /// `isAlive`, and `pruneHistory(for:)` sweeps both stacks once the fleet has
    /// actually loaded. See the early return there for why it must NOT sweep
    /// during the pre-load window, or it would delete the very stack this
    /// feature exists to restore.
    private(set) var history: NavigationHistory
    @ObservationIgnored private let historyStore: NavigationHistoryPersistenceStore

    init(userDefaults: UserDefaults = .standard) {
        let historyStore = NavigationHistoryPersistenceStore(userDefaults: userDefaults)
        self.historyStore = historyStore
        self.history = NavigationHistory(snapshot: historyStore.load())
        let documentResources = PRReviewDocumentResources()
        self.prReviewDocumentResources = documentResources
        self.prReview = PRReviewStore(documentResources: documentResources)
    }

    /// First Mate belongs to the process-owned shell, so a newly created main
    /// window must not treat an unchanged connection as a new store lifetime.
    /// The identity intentionally stays private and in memory: it can contain
    /// an authenticated configuration and is never part of agent-control UI state.
    @discardableResult
    func configureFirstMateIfNeeded(
        machineID: String? = nil,
        configuration: ServerConfiguration?,
        connectionGeneration: Int,
        isDemo: Bool,
        client: (any FirstMateClient)? = nil
    ) -> Bool {
        resetFirstMateCacheIfNeeded(connectionGeneration: connectionGeneration, isDemo: isDemo)
        let key = isDemo ? "demo" : machineID ?? configuration?.baseURL.absoluteString ?? "unconfigured"
        let identity = FirstMateConnectionIdentity(
            configuration: configuration,
            generation: connectionGeneration,
            isDemo: isDemo
        )
        let appearance = firstMate.isDark
        if identity == configuredFirstMateConnectionIdentities[key], let store = firstMateStores[key] {
            store.isDark = appearance
            firstMate = store
            activeFirstMateMachineID = machineID ?? (isDemo ? "demo" : nil)
            return false
        }
        let configuredClient: (any FirstMateClient)?
        if let client {
            configuredClient = client
        } else {
            configuredClient = configuration.map { HerdrAPIClient(configuration: $0) }
        }
        if let oldStore = firstMateStores[key] {
            oldStore.configure(client: nil, demo: false)
        }
        let store = FirstMateStore()
        store.isDark = appearance
        store.configure(client: configuredClient, demo: isDemo)
        firstMateStores[key] = store
        configuredFirstMateConnectionIdentities[key] = identity
        firstMate = store
        activeFirstMateMachineID = machineID ?? (isDemo ? "demo" : nil)
        return true
    }

    func reconcileFirstMateStores(
        configurations: [String: ServerConfiguration],
        connectionGeneration: Int,
        isDemo: Bool
    ) {
        resetFirstMateCacheIfNeeded(connectionGeneration: connectionGeneration, isDemo: isDemo)
        guard !isDemo else { return }
        var evictedActiveStore = false
        for key in Array(firstMateStores.keys) {
            let expectedConfiguration = configurations[key]
            let configuredIdentity = configuredFirstMateConnectionIdentities[key]
            guard expectedConfiguration == nil || configuredIdentity?.configuration != expectedConfiguration else { continue }
            firstMateStores[key]?.configure(client: nil, demo: false)
            firstMateStores[key] = nil
            configuredFirstMateConnectionIdentities[key] = nil
            evictedActiveStore = evictedActiveStore || key == activeFirstMateMachineID
        }
        if evictedActiveStore || activeFirstMateMachineID.map({ configurations[$0] == nil }) == true {
            let previousMachineID = activeFirstMateMachineID
            self.activeFirstMateMachineID = nil
            if firstMateMachineID == previousMachineID, previousMachineID.map({ configurations[$0] == nil }) == true {
                firstMateMachineID = nil
            }
        }
        if let desiredMachineID = firstMateMachineID, configurations[desiredMachineID] == nil {
            firstMateMachineID = nil
            if firstMateScope == .machine(desiredMachineID) { firstMateScope = nil }
            firstMateOpenRequest = nil
        }
        if let target = pendingFirstMateControlTarget, configurations[target.machineID] == nil {
            pendingFirstMateControlTarget = nil
        }
        if let target = pendingFirstMateCreateMachineID, configurations[target] == nil {
            pendingFirstMateCreateMachineID = nil
        }
    }

    func isActiveFirstMateConnection(
        machineID: String?,
        configuration: ServerConfiguration?,
        connectionGeneration: Int,
        isDemo: Bool
    ) -> Bool {
        let key = isDemo ? "demo" : machineID ?? configuration?.baseURL.absoluteString ?? "unconfigured"
        let expectedIdentity = FirstMateConnectionIdentity(
            configuration: configuration,
            generation: connectionGeneration,
            isDemo: isDemo
        )
        return activeFirstMateMachineID == (machineID ?? (isDemo ? "demo" : nil))
            && firstMateStores[key] === firstMate
            && configuredFirstMateConnectionIdentities[key] == expectedIdentity
    }

    func selectFirstMateScope(_ scope: FirstMateMachineScope) {
        firstMateOpenRequest = nil
        pendingFirstMateControlTarget = nil
        pendingFirstMateCreateMachineID = nil
        firstMateScope = scope
        if case .machine(let machineID) = scope { firstMateMachineID = machineID }
    }

    func openFirstMateFeatureFromFleet(machineID: String, featureID: String) {
        firstMateOpenRequest = nil
        pendingFirstMateCreateMachineID = nil
        firstMateScope = .all
        firstMateMachineID = machineID
        pendingFirstMateControlTarget = (machineID, featureID, .overview)
    }

    func createFirstMateFeature(on machineID: String) {
        firstMateOpenRequest = nil
        pendingFirstMateControlTarget = nil
        firstMateScope = .all
        firstMateMachineID = machineID
        pendingFirstMateCreateMachineID = machineID
    }

    private func resetFirstMateCacheIfNeeded(connectionGeneration: Int, isDemo: Bool) {
        guard firstMateCacheGeneration != connectionGeneration || firstMateCacheIsDemo != isDemo else { return }
        let appearance = firstMate.isDark
        for store in firstMateStores.values { store.configure(client: nil, demo: false) }
        firstMateStores = [:]
        configuredFirstMateConnectionIdentities = [:]
        firstMate = FirstMateStore()
        firstMate.isDark = appearance
        activeFirstMateMachineID = nil
        firstMateCacheGeneration = connectionGeneration
        firstMateCacheIsDemo = isDemo
    }

    @discardableResult
    func configurePRReviewIfNeeded(configuration: ServerConfiguration?, machineID: String?, connectionGeneration: Int, isDemo: Bool, client: (any PRReviewClient)? = nil) -> Bool {
        let identity = PRReviewConnectionIdentity(configuration: configuration, generation: connectionGeneration, isDemo: isDemo, machineRevision: machineID?.hashValue ?? 0)
        guard identity != configuredPRReviewConnectionIdentity else { return false }
        prReviewMachineID = machineID ?? (isDemo ? "demo" : nil)
        prReview.configure(client: client ?? configuration.map { HerdrAPIClient(configuration: $0) }, machineID: machineID, demo: isDemo)
        configuredPRReviewConnectionIdentity = identity
        return true
    }

    func showPRReview(machineID: String?, reviewID: String?, file: String? = nil, line: Int? = nil, side: PRReviewSide = .after, tab: PRReviewTab = .files, model: HerdrAppModel) {
        let resolvedMachineID = machineID ?? (model.isDemoMode ? "demo" : model.prReviewMachine?.id)
        prReviewMachineID = resolvedMachineID
        if let reviewID {
            prReviewOpenRequest = PRReviewOpenRequest(
                reviewID: reviewID,
                serverURL: model.prReviewConfiguration(machineID: resolvedMachineID)?.baseURL.absoluteString ?? "demo",
                file: file,
                line: line,
                side: side,
                tab: tab
            )
        }
        show(.prReview, model: model)
    }

    /// Present the global pane navigator. Incrementing the request also lets a
    /// repeated ⌘K put keyboard focus back in its search field.
    func presentCommandPalette() {
        isCommandPalettePresented = true
        commandPaletteFocusRequest &+= 1
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
    }

    /// Bring the selected pane's session to the front.
    ///
    /// Routing has to be an explicit *intent*, not something inferred from
    /// `selectedPaneID` changing: clicking the pane you are already on (from
    /// the attention deck, the sidebar, or the workspace overview) assigns the
    /// same ID, so a change observer would never fire and the click would be
    /// dead.
    func showSession() {
        agentControlPaneMode = nil
        agentControlPaneID = nil
        agentControlSelectionPaneID = nil
        detailScope = .session
        highlightedOverviewTabID = nil
        paneModeFocusRequest &+= 1
    }

    func selectedPaneDidChange(model: HerdrAppModel) {
        guard let paneID = model.selectedPaneID else { return }
        // Consume the exact route's selection observation without issuing a
        // second default-Chat request after its actual mode was acknowledged.
        if agentControlSelectionPaneID == paneID {
            agentControlSelectionPaneID = nil
            return
        }
        agentControlSelectionPaneID = nil
        // An exact native mode request owns this selection until the mounted
        // PaneSessionView acknowledges the requested mode.
        if agentControlPaneID == paneID, agentControlPaneMode != nil { return }
        // Preserve an explicit history replay to Git. External pane routes
        // from every other screen still bring the primary session forward.
        guard detailScope != .git || history.current != .git(paneID) else { return }
        showSession()
    }

    func showActiveWork() {
        detailScope = .activeWork
    }

    func presentAgent(prompt: String? = nil) {
        agentInitialPrompt = prompt
        isAgentPresented = true
    }

    /// Show a workspace's tab/pane overview — what iOS navigated to when you
    /// opened a workspace rather than one of its panes.
    func showWorkspace(id: String, model: HerdrAppModel) {
        showWorkspace(id: id, highlightedTabID: nil, model: model)
    }

    func showWorkspace(id: String, highlightedTabID: String?, model: HerdrAppModel) {
        guard let workspace = model.workspace(id: id),
              highlightedTabID == nil || workspace.tabs.contains(where: { $0.id == highlightedTabID })
        else { return }
        model.selectedWorkspaceID = id
        agentControlPaneMode = nil
        agentControlPaneID = nil
        agentControlSelectionPaneID = nil
        // Deliberately clears the pane: selecting one would bounce the detail
        // back to `.session` through the pane observer below.
        model.selectedPaneID = nil
        highlightedOverviewTabID = highlightedTabID
        detailScope = .workspace
        recordVisit(for: model)
    }

    func showFirstMate(
        machineID: String,
        featureID: String,
        inspector: FirstMateInspector,
        model: HerdrAppModel
    ) {
        firstMateOpenRequest = nil
        pendingFirstMateCreateMachineID = nil
        firstMateScope = .machine(machineID)
        firstMateMachineID = machineID
        pendingFirstMateControlTarget = (machineID, featureID, inspector)
        show(.firstMate, model: model)
    }

    /// Scope-only destinations (Active Work, Fleet, Attention, and Activity).
    func show(_ scope: HerdrDetailScope, model: HerdrAppModel) {
        if scope == .git {
            agentControlPaneMode = .git
            agentControlPaneID = model.selectedPaneID
        } else {
            agentControlPaneMode = nil
            agentControlPaneID = nil
            agentControlSelectionPaneID = nil
        }
        detailScope = scope
        paneModeFocusRequest &+= 1
        recordVisit(for: model)
    }

    /// The scope actually rendered: `.session` falls back to the workspace
    /// overview when no pane is selected, and to the attention deck when
    /// nothing is selected at all.
    func resolvedScope(for model: HerdrAppModel) -> HerdrDetailScope {
        switch detailScope {
        case .session, .git:
            if model.pane(id: model.selectedPaneID) != nil { return .session }
            if model.workspace(id: model.selectedWorkspaceID) != nil { return .workspace }
            return .attention
        case .workspace:
            return model.workspace(id: model.selectedWorkspaceID) != nil ? .workspace : .attention
        case .firstMate:
            return .firstMate
        case .activeWork:
            return .activeWork
        case .prReview:
            return .prReview
        case .fleet:
            return .fleet
        case .attention:
            return .attention
        case .activity:
            return .activity
        }
    }

    /// The destination currently on screen. Reads `resolvedScope(for:)` rather
    /// than the raw `detailScope` so a `.session` with no pane is recorded as
    /// the workspace overview or the attention deck the user is actually
    /// looking at — the same reason the toolbar picker reads resolved
    /// (`WorkspaceNavigationView.scopeSelection`).
    func currentDestination(for model: HerdrAppModel) -> HerdrDestination? {
        switch resolvedScope(for: model) {
        case .session, .git:
            model.selectedPaneID.map { detailScope == .git ? .git($0) : .pane($0) }
        case .workspace: model.selectedWorkspaceID.map(HerdrDestination.workspace)
        case .firstMate: .firstMate
        case .activeWork: .activeWork
        case .prReview: .prReview
        case .fleet: .fleet
        case .attention: .attention
        case .activity: .activity
        }
    }

    /// Records where the shell just landed.
    ///
    /// Recorded after the fact rather than from the requested destination:
    /// `HerdrAppModel.openPane(id:)` can defer an unknown pane
    /// (`pendingPaneRoutes`) and `openPane(rawPaneID:machineID:)` resolves the
    /// scoped id internally, so only the post-routing state is truthful. A
    /// route that did not land records nothing.
    func recordVisit(for model: HerdrAppModel) {
        guard let destination = currentDestination(for: model) else { return }
        mutateHistory { $0.record(destination) }
    }

    func openPane(id paneID: String, model: HerdrAppModel) {
        agentControlPaneMode = nil
        showSession()
        model.openPane(id: paneID)
        recordVisit(for: model)
    }

    func openPane(id paneID: String, mode: PaneDetailMode, model: HerdrAppModel) {
        agentControlPaneMode = mode
        agentControlPaneID = paneID
        agentControlSelectionPaneID = paneID
        highlightedOverviewTabID = nil
        detailScope = mode == .git ? .git : .session
        paneModeFocusRequest &+= 1
        model.openPane(id: paneID)
        recordVisit(for: model)
    }

    func openPane(rawPaneID: String, machineID: String?, model: HerdrAppModel) {
        agentControlPaneMode = nil
        showSession()
        model.openPane(rawPaneID: rawPaneID, machineID: machineID)
        recordVisit(for: model)
    }

    /// Routes to a pasted pane reference, recording it in the history like any
    /// other visit.
    ///
    /// Goes through `openPane(rawPaneID:machineID:)` rather than
    /// `openPane(id:)` because that path already toasts when the pane is not in
    /// the connected fleet. `openPane(id:)` would instead park the id as a
    /// pending route and wait silently, which is right for a notification tap
    /// arriving before the fleet loads and wrong for someone who just pressed
    /// a button.
    func jumpToPane(reference: String, model: HerdrAppModel) {
        guard let normalized = PaneReference.normalize(reference) else {
            model.toastMessage = "That doesn't look like a pane id"
            return
        }
        agentControlPaneMode = nil
        showSession()
        if let scoped = MachineScopedID.split(normalized) {
            model.openPane(rawPaneID: scoped.rawID, machineID: scoped.machineID)
        } else {
            model.openPane(rawPaneID: normalized, machineID: nil)
        }
        recordVisit(for: model)
    }

    @discardableResult
    func goBack(model: HerdrAppModel) -> Bool {
        guard let destination = mutateHistory({ $0.goBack(isAlive: { isAlive($0, model: model) }) }) else { return false }
        apply(destination, model: model)
        return true
    }

    @discardableResult
    func goForward(model: HerdrAppModel) -> Bool {
        guard let destination = mutateHistory({ $0.goForward(isAlive: { isAlive($0, model: model) }) }) else { return false }
        apply(destination, model: model)
        return true
    }

    /// Applies a remembered destination WITHOUT recording it — otherwise every
    /// Back would push a new entry and Forward could never be reached.
    private func apply(_ destination: HerdrDestination, model: HerdrAppModel) {
        paneModeFocusRequest &+= 1
        agentControlPaneMode = nil
        agentControlPaneID = nil
        agentControlSelectionPaneID = nil
        switch destination {
        case let .pane(id):
            agentControlPaneMode = nil
            detailScope = .session
            model.openPane(id: id)          // clears alerts + repairs selectedWorkspaceID
        case let .git(id):
            agentControlPaneMode = .git
            agentControlPaneID = id
            model.openPane(id: id)
            detailScope = .git
        case let .workspace(id):
            agentControlPaneMode = nil
            model.selectedWorkspaceID = id
            model.selectedPaneID = nil      // mirrors showWorkspace(id:model:)
            detailScope = .workspace
        case .firstMate: detailScope = .firstMate
        case .activeWork: detailScope = .activeWork
        case .prReview: detailScope = .prReview
        case .fleet: detailScope = .fleet
        case .attention: detailScope = .attention
        case .activity: detailScope = .activity
        }
        mutateHistory { $0.setCurrent(destination) }     // bypasses record() deliberately, see NavigationHistory
    }

    private func isAlive(_ destination: HerdrDestination, model: HerdrAppModel) -> Bool {
        switch destination {
        case let .pane(id), let .git(id): model.pane(id: id) != nil
        case let .workspace(id): model.workspace(id: id) != nil
        case .firstMate, .activeWork, .prReview, .fleet, .attention, .activity: true
        }
    }

    func pruneHistory(for model: HerdrAppModel) {
        // A restored stack must survive the pre-load window: right after
        // relaunch the fleet hasn't been fetched yet, `model.workspaces` is
        // still empty, and every restored pane/workspace destination would look
        // dead to `isAlive`; a sweep here would wipe the stack this feature
        // exists to restore before the user ever gets a chance to use it.
        // goBack/goForward already filter dead destinations at traversal time,
        // so it is safe to simply skip the proactive sweep whenever there is no
        // fleet to check liveness against (this also means a fully-disconnected
        // fleet, not just first launch, defers its sweep).
        guard !model.workspaces.isEmpty else { return }
        mutateHistory { $0.prune(isAlive: { isAlive($0, model: model) }) }
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    var agentControlBlockingModal: String? {
        if isCreatingWorkspace { return "create-workspace" }
        if isCreatingPRReview { return "pr-review-create" }
        if isAddingPRReviewSkill { return "pr-review-add-skill" }
        if hasPRReviewQuestionDraft { return "pr-review-question" }
        if isAgentPresented { return "agent" }
        if isIssueReportPresented { return "issue-report" }
        if isJumpToPanePresented { return "jump-to-pane" }
        if isCommandPalettePresented { return "command-palette" }
        if piSessionSummaryRequest != nil { return "pi-session-summary" }
        return nil
    }

    func agentControlPaneModeDidApply(_ mode: PaneDetailMode, paneID: String) {
        guard mode == agentControlPaneMode, paneID == agentControlPaneID else { return }
        agentControlPaneMode = nil
        agentControlPaneID = nil
    }

    func agentControlSegment(model: HerdrAppModel) -> String {
        switch resolvedScope(for: model) {
        case .session, .git:
            return model.currentPaneDetailMode?.rawValue ?? "session"
        case .workspace: return "workspace"
        case .activeWork: return "active-work"
        case .prReview: return "pr-review"
        case .firstMate: return "first-mate"
        case .fleet: return "fleet"
        case .attention: return "attention"
        case .activity: return "activity"
        }
    }

    @discardableResult
    private func mutateHistory<T>(_ mutation: (inout NavigationHistory) -> T) -> T {
        let result = mutation(&history)
        historyStore.save(history.snapshot)
        return result
    }
}

struct AppRootView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Bindable var activeWorkStore: ActiveWorkStore
    let driver: HerdrConnectionDriver
    let hudController: HerdrHudController
    let quickVoiceController: QuickVoicePanelController
    let hudSession: HerdrHudSession
    let hudNotes: HerdrHudNotesState
    let agentSettings: AgentModelSettingsStore
    let promptSettings: HerdrPromptSettingsStore
    let modelFavorites: ModelFavoritesStore
    let fontScale: HerdrFontScaleStore
    let agentControl: AgentControlController
    let updates: HerdrUpdateController
    @Environment(HerdPulseCoordinator.self) private var herdPulse
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var statusHapticTracker = AgentStatusHapticTracker()
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var externalPiError = ""
    @State private var externalPiPrompt = ""
    @State private var isShowingExternalPiError = false

    var body: some View {
        rootContent
            .overlay {
                commandPaletteOverlay
            }
            .animation(.snappy, value: shell.isCommandPalettePresented)
            .alert("Pi session could not start", isPresented: $isShowingExternalPiError) {
                if !externalPiPrompt.isEmpty {
                    Button("Copy Prompt") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(externalPiPrompt, forType: .string)
                    }
                }
                Button("Dismiss", role: .cancel) { }
            } message: {
                Text(externalPiError)
            }
    }

    private var rootContent: some View {
        Group {
            if model.hasCompletedSetup {
                WorkspaceNavigationView(
                    model: model,
                    shell: shell,
                    activeWorkStore: activeWorkStore,
                    modelFavorites: modelFavorites,
                    updates: updates
                )
            } else {
                OnboardingView(model: model)
            }
        }
        // The event stream and the pulse feed belong to the process, not this
        // window — see `HerdrConnectionDriver`. The window only nudges them.
        .onChange(of: model.connectionGeneration, initial: true) { _, _ in
            driver.syncConnection(model: model)
            agentControl.synchronize()
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            if state == .key { agentControl.noteWindow(.main) }
        }
        .onChange(of: model.hasCompletedSetup) { _, _ in
            driver.syncConnection(model: model)
        }
        .onAppear {
            driver.startPulse(model: model, pulse: herdPulse)
            agentControl.configure(
                model: model,
                shell: shell,
                hudController: hudController,
                openMainWindow: { openWindow(id: HerdrWindowID.main) },
                openSettingsWindow: { openSettings() }
            )
            agentControl.noteWindow(.main)
            // The isolated First Mate recording and unit-test host need no floating HUD.
            // Creating it here also asks iconservices for an app icon during layout.
            if !ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateDemo"),
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
               NSClassFromString("XCTestCase") == nil {
                hudNotes.configureSync(model: model)
                hudController.configure(model: model, session: hudSession, notes: hudNotes, fontScale: fontScale, quickVoice: quickVoiceController)
            }
        }
        .task {
            if let paneID = HerdrMacAppDelegate.takePendingPaneID() {
                openPane(id: paneID)
            }
            for await notification in NotificationCenter.default.notifications(named: .herdrOpenPane) {
                guard let paneID = notification.object as? String else { continue }
                // Drain the static the delegate also set: handled here, it must
                // not be replayed the next time this window is re-created.
                _ = HerdrMacAppDelegate.takePendingPaneID()
                openPane(id: paneID)
            }
        }
        .task {
            // A request made while this window was closed (Settings ▸ Feedback
            // after `openWindow` recreated it) is parked on the delegate.
            if HerdrMacAppDelegate.takePendingIssueReport() {
                shell.isIssueReportPresented = true
            }
            for await _ in NotificationCenter.default.notifications(named: .herdrPresentIssueReport) {
                // Handled here: it must not replay the next time this window
                // is re-created.
                _ = HerdrMacAppDelegate.takePendingIssueReport()
                shell.isIssueReportPresented = true
            }
        }
        .task(id: model.hasCompletedSetup && model.smartAlertsEnabled && !model.isDemoMode) {
            await model.prepareSmartAlerts()
        }
        // Fleet-transition feedback. iOS hung this on the always-alive
        // Workspaces tab root; the Mac's equivalent always-alive surface is the
        // window root, so it lives here.
        .onChange(of: agentStatuses, initial: true) { _, statuses in
            if let event = statusHapticTracker.observe(statuses) {
                hapticPulse.fire(event)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            statusHapticTracker.setSceneActive(
                phase == .active,
                isDemoMode: model.isDemoMode,
                statuses: agentStatuses
            )
        }
        .onChange(of: model.refreshTick) {
            statusHapticTracker.recordRefresh(statuses: agentStatuses)
        }
        .herdrHaptic(trigger: hapticPulse)
        .environment(\.openResponsePane, openPane)
        .onOpenURL(perform: openURL)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                openURL(url)
            }
        }
        .onChange(of: model.selectedPaneID) { _, _ in
            shell.selectedPaneDidChange(model: model)
        }
        // Panes close and machines drop; a Back button that offers a dead id and
        // then no-ops is worse than one that is greyed out. `repairNavigation`
        // clears the live selection on the same revision — this clears the trail.
        .onChange(of: model.fleetRevision) { shell.pruneHistory(for: model) }
        .sheet(item: $shell.piSessionSummaryRequest) { request in
            PiSessionSummaryView(model: model, request: request)
        }
        .sheet(isPresented: $shell.isCreatingWorkspace) {
            CreateWorkspaceView { label, cwd in
                let machineID: String?
                if case let .machine(id) = model.machineScope {
                    machineID = id
                } else {
                    machineID = model.machines.first?.id
                }
                return await model.createWorkspace(label: label, cwd: cwd, machineID: machineID)
            }
            .frame(minWidth: 460, minHeight: 340)
        }
        .sheet(isPresented: $shell.isAgentPresented) {
            HeadlessAgentView(
                model: model,
                initialPrompt: shell.agentInitialPrompt,
                agentSettings: agentSettings,
                promptSettings: promptSettings
            ) { pane in
                openPane(id: pane.id)
            }
            .onDisappear { shell.agentInitialPrompt = nil }
        }
        .sheet(isPresented: $shell.isIssueReportPresented) {
            IssueReportView(model: model)
        }
        .alert("Jump to pane", isPresented: $shell.isJumpToPanePresented) {
            TextField("w1:p2", text: $shell.jumpToPaneInput)
                .accessibilityIdentifier("jump-to-pane-field")
            Button("Cancel", role: .cancel) { shell.jumpToPaneInput = "" }
            Button("Jump") {
                let reference = shell.jumpToPaneInput
                shell.jumpToPaneInput = ""
                shell.jumpToPane(reference: reference, model: model)
            }
            .disabled(PaneReference.normalize(shell.jumpToPaneInput) == nil)
        } message: {
            Text("Paste a pane id, a machine-scoped id, or a herdr:// link. Percent-encoded ids work too.")
        }
        .overlay(alignment: .top) {
            if let message = model.toastMessage {
                ToastView(message: message, dismiss: model.clearToast)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toastMessage)
        .alert(
            "Connection issue",
            isPresented: $model.isShowingError
        ) {
            Button("Dismiss", role: .cancel, action: model.clearError)
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    /// Deep links and notification taps always land on the session, including
    /// when they name the pane that is already selected.
    private func openPane(id paneID: String) {
        shell.openPane(id: paneID, model: model)
    }

    private func openURL(_ url: URL) {
        if url.scheme == "herdr", url.host == "pr-review" {
            guard let request = PRReviewOpenRequest(url: url) else { externalPiError = "Invalid PR Review navigation link."; isShowingExternalPiError = true; return }
            if model.isDemoMode { model.leaveDemo() }
            guard let machine = model.machines.first(where: { ServerConfiguration(urlString: $0.urlString, token: "route-validation")?.baseURL.absoluteString == request.serverURL }) else { externalPiError = "Add this review companion server in Settings → Machines, then open the link again."; isShowingExternalPiError = true; return }
            shell.showPRReview(machineID: machine.id, reviewID: request.reviewID, file: request.file, line: request.line, side: request.side, tab: request.tab, model: model)
            return
        }
        if url.scheme == "herdr", url.host == "first-mate" {
            guard let request = FirstMateOpenRequest(url: url) else {
                externalPiError = "Invalid First Mate navigation link."
                isShowingExternalPiError = true
                return
            }
            if model.isDemoMode { model.leaveDemo() }
            guard let machine = model.machines.first(where: {
                ServerConfiguration(urlString: $0.urlString, token: "route-validation")?.baseURL.absoluteString == request.serverURL
            }) else {
                externalPiError = "Add this feature's companion server in Settings → Machines, then open the link again."
                isShowingExternalPiError = true
                return
            }
            shell.selectFirstMateScope(.machine(machine.id))
            shell.firstMateOpenRequest = request
            shell.show(.firstMate, model: model)
            return
        }

        if ExternalPiRequest.recognizes(url) {
            launchExternalPi(url)
            return
        }
        guard let paneID = HerdrAppModel.paneID(from: url) else { return }
        openPane(id: paneID)
    }

    private func launchExternalPi(_ url: URL) {
        let request: ExternalPiRequest
        do {
            request = try ExternalPiRequest(url: url)
        } catch {
            externalPiPrompt = ""
            externalPiError = error.localizedDescription
            isShowingExternalPiError = true
            return
        }
        externalPiPrompt = request.composedPrompt
        Task { @MainActor in
            do {
                let machineID = model.externalPiLauncher.hasReceipt(for: request.requestID)
                    ? nil : try await model.prepareExternalPiLaunch(request)
                let generation = model.connectionGeneration
                try await model.externalPiLauncher.start(request) {
                    guard let machineID else { throw ExternalPiLauncher.LaunchError.unconfirmed }
                    return try await model.createExternalPiSession(request, machineID: machineID)
                } send: { paneID, prompt in
                    try await model.sendExternalPiPrompt(paneID: paneID, text: prompt, expectedGeneration: generation)
                } openPane: { paneID in
                    guard generation == model.connectionGeneration else { return }
                    openPane(id: paneID)
                    NotificationCenter.default.post(name: .herdrFocusPaneMode, object: PaneDetailMode.chat)
                }
            } catch {
                externalPiError = error.localizedDescription
                externalPiPrompt = request.composedPrompt
                isShowingExternalPiError = true
            }
        }
    }

    private func openCommandPaletteEntry(_ entry: CommandPaletteEntry) {
        shell.dismissCommandPalette()
        openPane(id: entry.paneID)
    }

    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if shell.isCommandPalettePresented, model.hasCompletedSetup {
            CommandPaletteView(
                entries: CommandPaletteIndex.entries(
                    workspaces: model.workspaces,
                    machines: model.machines
                ),
                focusRequest: shell.commandPaletteFocusRequest,
                dismiss: shell.dismissCommandPalette,
                select: openCommandPaletteEntry
            )
            .transition(commandPaletteTransition)
        }
    }

    private var commandPaletteTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
    }

    private var agentStatuses: [String: AgentStatus] {
        AgentStatusHapticTracker.snapshot(model.workspaces)
    }
}
