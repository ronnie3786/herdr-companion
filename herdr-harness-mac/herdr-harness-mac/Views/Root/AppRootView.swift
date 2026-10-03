import AppKit
import SwiftUI

/// Which retained destination the four-tab Home shell is showing.
enum HerdrDetailScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home
    case session
    /// Git shares the mounted pane with Chat, but is a distinct history stop.
    case git
    case prReview
    case watchers
    case firstMate
    case fleet

    var id: String { rawValue }

    /// The destinations in the title bar's ⋯ menu (`HerdrShellMenuSections`).
    /// Home, First Mate, PR Review and Watchers have their own entry points.
    static let menuDestinations: [HerdrDetailScope] = [
        .session,
        .fleet,
    ]

    /// Home is the overview and starts without a sidebar.
    var isHome: Bool { self == .home }

    enum SidebarContext: Hashable { case home, rail, chats }

    /// Which remembered sidebar choice applies. First Mate and PR Review use
    /// the sidebar as their navigation rail, so it is always shown there.
    var sidebarContext: SidebarContext {
        if isHome { return .home }
        return self == .firstMate || self == .prReview ? .rail : .chats
    }

    var label: String {
        switch self {
        case .home: "Home"
        case .session: "Chat"
        case .git: "Git"
        case .firstMate: "First Mate"
        case .prReview: "PR Review"
        case .watchers: "Watchers"
        case .fleet: "Fleet"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .session: "bubble.left"
        case .git: "arrow.triangle.branch"
        case .firstMate: "sailboat"
        case .prReview: "arrow.triangle.pull"
        case .watchers: "eye"
        case .fleet: "desktopcomputer"
        }
    }
}

/// Window-shell state that the menu bar and the window content both drive.
/// Everything durable still lives in `HerdrAppModel`; this only holds what the
/// iOS app kept in view-local `@State` (the tab selection and a sheet flag).
@MainActor
@Observable
final class HerdrShellState {
    var detailScope: HerdrDetailScope = .home
    let home: HomeStore
    var homeChat: HomeChatController?
    var homeQuickReply: HomeQuickReplyController?
    @ObservationIgnored let homeProjection = HomeProjectionCoordinator()
    var homeSearchPresented = false
    var homeSearchFocusRequest = 0
    var surfaceSearchFocusRequest = 0
    var homeAskRequest = 0
    var isInboxPresented = false
    var homeWatcherRevealRequest: HomeRevealRequest?
    var homeReviewRevealRequest: HomeRevealRequest?
    var homeMachineRevealRequest: HomeRevealRequest?
    var homeReviewPreparation: HomeReviewPreparation?
    var homeReviewPreparationSelection: HomeReviewPreparationSelection?
    var firstMateChatExactOpenRequest: FirstMateChatExactOpenRequest?
    var mainWindowAllowsPresentation = false
    private(set) var firstMate = FirstMateStore()
    let firstMateFleet = FirstMateFleetIndex()
    let firstMateProjects = FirstMateProjectIndex()
    let firstMateStart = FirstMateStartSessionModel()
    var firstMateSurface = FirstMateSurface.workspace
    /// One cache coordinator per app process: the main rail and every popped
    /// out review or document window share download phases and window-lifetime
    /// cache protection, so no window can evict a file another is displaying.
    let prReviewDocumentResources: PRReviewDocumentResources
    let watchers = WatchersStore()
    let workInbox = WorkInboxStore()
    @ObservationIgnored let refreshCoordinator = ShellRefreshCoordinator()
    let prReview: PRReviewStore
    /// The main window's comment sheet presentation state. The saved records
    /// themselves live in the process-owned store in `HerdrAppModel`, shared
    /// with every popped-out review window.
    let prReviewComments = PRReviewCommentsSession()
    @ObservationIgnored private var prReviewCommentStore: PRReviewCommentStore?
    var firstMateMachineID: String?
    // Start in the fleet view; explicit host choices stay in effect until changed.
    var firstMateScope: FirstMateMachineScope? = .all
    private(set) var activeFirstMateMachineID: String?
    /// The rail filter is separate from the detail store's active machine.
    var prReviewScope: PRReviewHostScope = .all
    let prReviewFleet = PRReviewFleetIndex()
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
    /// View ▸ Show/Hide Sidebar. The shell owns the rail's visibility; menu
    /// commands only ask for a toggle.
    private(set) var sidebarToggleRequest = 0
    private(set) var sidebarShowRequest = 0
    func requestSidebarShow() { sidebarShowRequest &+= 1 }

    func requestSidebarToggle() { sidebarToggleRequest += 1 }
    private(set) var agentControlPaneMode: PaneDetailMode?
    private var agentControlPaneID: String?
    private var agentControlSelectionPaneID: String?
    var agentControlWindow: AgentControlWindow = .main
    var piSessionSummaryRequest: PiSessionSummaryRequest?
    var pendingFirstMateControlTarget: (machineID: String, featureID: String, inspector: FirstMateInspector)?
    var pendingFirstMateCreateMachineID: String?
    /// A request to show a feature in the First Mate chat window (Dock menu,
    /// "Open in window"). The window applies it and sets it back to nil.
    var firstMateChatOpenRequest: FirstMateFleetFeatureID?
    /// Bumped to show My First Mate (the lead) in the chat window.
    var firstMateChatOpenLeadRequest = 0
    /// Process-owned First Mate observation and the Dock badge. Either window
    /// starts them; they keep running with every window closed.
    @ObservationIgnored private(set) var firstMateFleetDriver: FirstMateFleetDriver?
    @ObservationIgnored private(set) var firstMateDockBadge: FirstMateDockBadgeController?
    /// The First Mate HUD, separate from the agent HUD. Process-owned like
    /// the fleet driver; it shows only while its setting is on.
    @ObservationIgnored let firstMateHud = FirstMateHudController()
    @ObservationIgnored private var firstMateChatDemoStorage: FirstMateChatDemoSource?
    /// The chat window's demo, shared with the Dock badge and menu. Created on
    /// first use.
    var firstMateChatDemo: FirstMateChatDemoSource {
        if let firstMateChatDemoStorage { return firstMateChatDemoStorage }
        let demo = FirstMateChatDemoSource()
        firstMateChatDemoStorage = demo
        return demo
    }
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
    /// ids are machine-scoped and the fleet is re-fetched on every launch, so
    /// most restored entries are dead the instant the app relaunches;
    /// `goBack`/`goForward` already skip dead destinations at traversal time via
    /// `isAlive`, and `pruneHistory(for:)` sweeps both stacks once the fleet has
    /// actually loaded. See the early return there for why it must NOT sweep
    /// during the pre-load window, or it would delete the very stack this
    /// feature exists to restore.
    private(set) var history: NavigationHistory
    @ObservationIgnored private let historyStore: NavigationHistoryPersistenceStore
    @ObservationIgnored private let preferences: UserDefaults

    init(userDefaults: UserDefaults = .standard, prReviewGuide: PRReviewGuideSession = PRReviewGuideSession()) {
        self.preferences = userDefaults
        if HomeFixtures.requestedMoment != nil {
            let name = "herdr.home.synthetic.presentation"
            let syntheticDefaults = UserDefaults(suiteName: name)!
            syntheticDefaults.removePersistentDomain(forName: name)
            self.home = HomeStore(defaults: syntheticDefaults)
        } else {
            self.home = HomeStore(defaults: userDefaults)
        }
        let historyStore = NavigationHistoryPersistenceStore(userDefaults: userDefaults)
        self.historyStore = historyStore
        self.history = NavigationHistory(snapshot: historyStore.load())
        let documentResources = PRReviewDocumentResources()
        self.prReviewDocumentResources = documentResources
        self.prReview = PRReviewStore(documentResources: documentResources, guide: prReviewGuide)
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

    /// Refreshes the main window's cached store for one machine (`"demo"` in
    /// demo mode), so a change made in the First Mate chat window shows here
    /// without waiting for this screen's poll. Does nothing when that machine
    /// has no store yet.
    func refreshFirstMateStore(machineID: String) async {
        guard let store = firstMateStores[machineID] else { return }
        await store.refresh()
    }

    /// Starts the fleet driver and the Dock badge once per process. Idempotent,
    /// so the main window and the chat window both call it on appearance.
    func startFirstMateServices(model: HerdrAppModel) {
        let driver = firstMateFleetDriver ?? FirstMateFleetDriver(
            fleet: firstMateFleet,
            reconcile: { [weak self] roster in
                self?.reconcileFirstMateStores(
                    configurations: roster.configurations,
                    connectionGeneration: roster.connectionGeneration,
                    isDemo: roster.isDemo
                )
            }
        )
        firstMateFleetDriver = driver
        driver.start(model: model)
        let badge = firstMateDockBadge ?? FirstMateDockBadgeController()
        firstMateDockBadge = badge
        badge.start(model: model, shell: self)
        firstMateHud.start(model: model, shell: self)
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
        firstMateSurface = .workspace
        firstMateOpenRequest = nil
        pendingFirstMateControlTarget = nil
        pendingFirstMateCreateMachineID = nil
        firstMateScope = scope
        if case .machine(let machineID) = scope { firstMateMachineID = machineID }
    }

    func openFirstMateFeatureFromFleet(machineID: String, featureID: String) {
        firstMateSurface = .workspace
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
        firstMateStart.prepare(preferredMachineID: machineID)
        firstMateSurface = .newSession
    }

    func showFirstMateStart(project: FirstMateProjectSelection? = nil, preferredMachineID: String? = nil, mode: FirstMateStartMode? = nil) {
        firstMateOpenRequest = nil
        pendingFirstMateControlTarget = nil
        pendingFirstMateCreateMachineID = nil
        firstMateStart.prepare(preferredMachineID: preferredMachineID)
        if let mode, !firstMateStart.isSending { firstMateStart.mode = mode }
        if let project { firstMateStart.chooseProject(project) }
        firstMateSurface = .newSession
    }

    func showFirstMateProjects() {
        firstMateOpenRequest = nil
        pendingFirstMateControlTarget = nil
        pendingFirstMateCreateMachineID = nil
        firstMateSurface = .projects
    }

    @discardableResult
    func openStartedFirstMateSession(_ session: FirstMateStartedSession, connectionGeneration: Int, isDemo: Bool) -> Bool {
        guard firstMateProjects.isCurrent(session.connection), firstMateProjects.isDemo == isDemo else { return false }
        let connection = session.connection
        firstMateMachineID = connection.machineID
        firstMateScope = .all
        firstMateOpenRequest = nil
        pendingFirstMateControlTarget = nil
        pendingFirstMateCreateMachineID = nil
        configureFirstMateIfNeeded(machineID: connection.machineID,
                                   configuration: isDemo ? nil : connection.configuration,
                                   connectionGeneration: connectionGeneration, isDemo: isDemo,
                                   client: connection.client)
        firstMate.receive(session.snapshot)
        firstMate.select(session.snapshot.feature.id)
        firstMateSurface = .workspace
        return true
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

    /// Connects the process-owned comment store once the app model exists.
    /// The shell is constructed before the model, so the store is attached
    /// here rather than in `init`. Re-attaching the same store is a no-op.
    func attachPRReviewCommentStore(_ store: PRReviewCommentStore) {
        guard prReviewCommentStore !== store else { return }
        prReviewCommentStore = store
        prReviewComments.attach(store: store)
    }

    func selectPRReviewScope(_ scope: PRReviewHostScope) {
        prReviewOpenRequest = nil
        prReviewScope = scope
        if case .machine(let machineID) = scope { prReviewMachineID = machineID }
    }

    func openPRReviewFromFleet(_ target: PRReviewWindowTarget, model: HerdrAppModel) {
        prReviewScope = .all
        if target.machineID == prReview.currentMachineID {
            prReviewMachineID = target.machineID
            prReviewOpenRequest = nil
            prReview.select(target.reviewID)
            Task {
                guard prReview.currentMachineID == target.machineID,
                      prReview.selectedReviewID == target.reviewID else { return }
                await prReview.refreshSelected()
            }
        } else {
            showPRReview(machineID: target.machineID, reviewID: target.reviewID, model: model)
        }
    }

    /// The fleet reconciles server lists only. A successful archive also ends
    /// this Mac's walkthrough and forgets saved progress for that exact owner.
    func archivePRReviewFromFleet(_ target: PRReviewWindowTarget, archived: Bool) async throws {
        try await prReviewFleet.archive(target, archived: archived)
        if archived {
            prReview.guide.forgetSavedProgress(machineID: target.machineID, reviewID: target.reviewID)
        }
    }

    /// An event-driven detail update must not wait for an unreachable fleet host.
    func refreshPRReviews(refreshFleet: Bool) async {
        async let fleet: Void = refreshFleet ? prReviewFleet.refresh() : ()
        if prReview.hasLoaded {
            await prReview.refresh()
            await prReview.refreshSelected()
        }
        await fleet
    }

    /// Root-owned so links remain actionable when the workspace navigator is
    /// unmounted. Revalidate the exact request and connection after hydration.
    func applyPRReviewNavigationRequest(model: HerdrAppModel) async {
        let machineID = prReviewMachineID ?? (model.isDemoMode ? "demo" : model.prReviewMachine?.id)
        let configuration = model.prReviewConfiguration(machineID: machineID)
        let generation = model.connectionGeneration
        guard !Task.isCancelled, let request = prReviewOpenRequest,
              request.id != prReviewAppliedRequestID,
              model.isDemoMode || request.serverURL == configuration?.baseURL.absoluteString else { return }
        configurePRReviewIfNeeded(configuration: configuration, machineID: machineID,
                                  connectionGeneration: generation, isDemo: model.isDemoMode)
        prReview.tab = request.tab
        prReview.select(request.reviewID)
        await prReview.refreshSelected()
        guard !Task.isCancelled, generation == model.connectionGeneration,
              prReviewOpenRequest?.id == request.id, prReview.currentMachineID == machineID,
              prReview.selectedReviewID == request.reviewID,
              configuration == model.prReviewConfiguration(machineID: machineID) else { return }
        if let file = request.file {
            prReview.selectedPath = file
            if let line = request.line { prReview.scroll(to: file, line: line, side: request.side) }
        }
        prReviewAppliedRequestID = request.id
    }

    func preparePRReviewCreation(model: HerdrAppModel) {
        guard PRReviewHostScope.resolved(prReviewScope, availableMachineIDs: model.machines.map(\.id)) == .all,
              !model.isDemoMode,
              let machine = model.prReviewMachine,
              machine.id != prReviewMachineID else { return }
        prReviewMachineID = machine.id
        prReviewOpenRequest = nil
    }

    func prReviewHostSettingsDidChange() {
        prReviewScope = .all
        prReviewMachineID = nil
        prReviewOpenRequest = nil
    }

    func showPRReview(machineID: String?, reviewID: String?, file: String? = nil, line: Int? = nil, side: PRReviewSide = .after, tab: PRReviewTab = .files, model: HerdrAppModel) {
        prReviewScope = .all
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
    /// the sidebar or the activity feed) assigns the same ID, so a change
    /// observer would never fire and the click would be dead.
    func showSession() {
        agentControlPaneMode = nil
        agentControlPaneID = nil
        agentControlSelectionPaneID = nil
        detailScope = .session
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

    func presentAgent(prompt: String? = nil) {
        agentInitialPrompt = prompt
        isAgentPresented = true
    }

    func showFirstMate(
        machineID: String,
        featureID: String,
        inspector: FirstMateInspector,
        model: HerdrAppModel
    ) {
        firstMateSurface = .workspace
        firstMateOpenRequest = nil
        pendingFirstMateCreateMachineID = nil
        firstMateScope = .machine(machineID)
        firstMateMachineID = machineID
        pendingFirstMateControlTarget = (machineID, featureID, inspector)
        show(.firstMate, model: model)
    }

    /// Home is a place, not another stop: returning to it from a screen opened
    /// there steps back, so Back/Forward never fills with Home ⇄ feature
    /// pairs.
    func goHome(model: HerdrAppModel) {
        guard detailScope != .home else { return }
        if history.backward.last == .home, goBack(model: model) { return }
        show(.home, model: model)
    }

    /// Home screens open without the sidebar and other screens with it, until
    /// the person chooses otherwise; each context remembers its own choice.
    func sidebarVisibility(home: Bool) -> NavigationSplitViewVisibility {
        let key = home ? "herdr.shell.sidebar.home" : "herdr.shell.sidebar.screens"
        guard preferences.object(forKey: key) != nil else { return home ? .detailOnly : .all }
        return preferences.bool(forKey: key) ? .all : .detailOnly
    }

    func rememberSidebarVisibility(_ visibility: NavigationSplitViewVisibility, home: Bool) {
        preferences.set(visibility != .detailOnly, forKey: home ? "herdr.shell.sidebar.home" : "herdr.shell.sidebar.screens")
    }

    /// Opens a retained destination independently of the selected pane.
    func show(_ scope: HerdrDetailScope, model: HerdrAppModel) {
        if scope == .prReview, detailScope != .prReview { prReviewScope = .all }
        if scope == .git {
            agentControlPaneMode = .git
            agentControlPaneID = model.selectedPaneID
        } else {
            agentControlPaneMode = nil
            agentControlPaneID = nil
            agentControlSelectionPaneID = nil
        }
        surfaceSearchFocusRequest = 0
        detailScope = scope
        paneModeFocusRequest &+= 1
        recordVisit(for: model)
    }

    /// The scope actually rendered: Git is a sub-mode of the mounted session.
    func resolvedScope(for model: HerdrAppModel) -> HerdrDetailScope {
        switch detailScope {
        case .home: return .home
        case .session, .git: return .session
        case .firstMate:
            return .firstMate
        case .prReview:
            return .prReview
        case .watchers:
            return .watchers
        case .fleet:
            return .fleet
        }
    }

    /// The destination currently on screen. A session with no pane selected
    /// records nothing.
    func currentDestination(for model: HerdrAppModel) -> HerdrDestination? {
        switch resolvedScope(for: model) {
        case .session, .git:
            model.pane(id: model.selectedPaneID).map { detailScope == .git ? .git($0.id) : .pane($0.id) }
        case .home: .home
        case .firstMate: .firstMate
        case .prReview: .prReview
        case .watchers: .watchers
        case .fleet: .fleet
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
        case .home: detailScope = .home
        case .firstMate: detailScope = .firstMate
        case .prReview:
            if detailScope != .prReview { prReviewScope = .all }
            detailScope = .prReview
        case .watchers: detailScope = .watchers
        case .fleet: detailScope = .fleet
        }
        mutateHistory { $0.setCurrent(destination) }     // bypasses record() deliberately, see NavigationHistory
    }

    private func isAlive(_ destination: HerdrDestination, model: HerdrAppModel) -> Bool {
        switch destination {
        case let .pane(id), let .git(id): model.pane(id: id) != nil
        case .home, .firstMate, .prReview, .watchers, .fleet: true
        }
    }

    func pruneHistory(for model: HerdrAppModel) {
        // A restored stack must survive the pre-load window: right after
        // relaunch the fleet hasn't been fetched yet, `model.workspaces` is
        // still empty, and every restored pane destination would look
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
        if prReviewComments.isPresentingComments { return "pr-review-comment" }
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
        case .home: return "home"
        case .prReview: return "pr-review"
        case .watchers: return "watchers"
        case .firstMate: return "first-mate"
        case .fleet: return "fleet"
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
            .modifier(ShellRefreshModifier(model: model, shell: shell))
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

    private var homeUtilities: some View {
        Menu("Chat tools", systemImage: "ellipsis") {
            Button("Fleet", systemImage: "desktopcomputer") { shell.show(.fleet, model: model) }
            Button("First Mate management", systemImage: "sailboat") { shell.show(.firstMate, model: model) }
            Button("Work inbox", systemImage: "tray") { shell.show(.session, model: model); shell.isInboxPresented = true }
            Button("Ask Agent…", systemImage: "sparkles") { shell.isAgentPresented = true }
                .disabled(!model.canControl)
            Divider()
            Button("Settings…", systemImage: "gearshape") { openSettings() }
            Button("New Note", systemImage: "note.text.badge.plus", action: hudController.createNote)
            Button("Summon HUD", action: hudController.summon)
            Button(herdPulse.isRunning ? "Stop Herd Pulse" : "Start Herd Pulse") { Task { await herdPulse.toggle() } }
                .disabled(herdPulse.isBusy)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 20, height: 30)
        .foregroundStyle(HomePalette.secondary)
        .accessibilityIdentifier("home-chats-tools")
    }

    private var rootContent: some View {
        Group {
            if model.hasCompletedSetup {
                HomeShellView(model: model, shell: shell, modelFavorites: modelFavorites,
                              updates: updates, utilities: AnyView(homeUtilities))
            } else {
                OnboardingView(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if updates.isBannerVisible, let version = updates.availableVersion {
                            HerdrUpdateBanner(version: version, updates: updates)
                                .padding(.top, HerdrTheme.ControlHeight.titleBar)
                        }
                    }
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
            if shell.homeChat == nil { shell.homeChat = HomeChatController(model: model, shell: shell) }
            if shell.homeQuickReply == nil { shell.homeQuickReply = HomeQuickReplyController(model: model, shell: shell) }
            driver.startPulse(model: model, pulse: herdPulse)
            // First Mate's fleet observation and Dock badge also belong to the
            // process, so the chat window keeps working after this one closes.
            shell.startFirstMateServices(model: model)
            model.prReviewIsOnScreen = { [weak shell] machineID, reviewID in
                guard let shell else { return false }
                return shell.detailScope == .prReview && shell.prReview.currentMachineID == machineID
                    && shell.prReview.selectedReviewID == reviewID
            }
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
        // Workspaces tab root; on the Mac's window root it only owns the
        // attention cue. Completion belongs to the process-owned coordinator
        // on `HerdrAppModel`, which keeps working while this window is closed
        // and deduplicates the fleet observation against committed Pi
        // settlement.
        .onChange(of: agentStatuses, initial: true) { _, statuses in
            if statusHapticTracker.observe(statuses) == .attention {
                hapticPulse.fire(.attention)
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
                    .padding(.top, HerdrTheme.ControlHeight.titleBar + 8)
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
        if url.scheme == "herdr", url.host == "watchers" {
            shell.show(.watchers, model: model)
            return
        }
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
