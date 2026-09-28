import Foundation
import Observation

/// The First Mate chat window's state.
///
/// The window owns its own `FirstMateStore` per machine, so choosing a chat,
/// an inspector tab, or a draft here never moves the main window's First Mate
/// screen, and the reverse. Composer drafts live in those stores and are
/// therefore per window: they are deliberately not shared with the main
/// window's First Mate screen.
///
/// The conversation list reads the process-wide fleet index (no second poller).
/// The main window normally observes that index; while it is closed, the
/// running chat window observes it instead, so the list, the badge, and read
/// markers keep working. Only the selected chat's store is refreshed, every
/// 2 s while the window runs.
@MainActor @Observable
final class FirstMateChatWindowSession {
    enum Selection: Hashable {
        case lead
        case feature(FirstMateFleetFeatureID)
    }

    static let demoMachineID = "demo"
    static let demoMachineName = "This Mac"
    static let refreshInterval: Duration = .seconds(2)
    /// How often a running window checks whether the fleet index still has an
    /// observer.
    static let fleetObserverCheckInterval: Duration = .seconds(2)

    @ObservationIgnored let model: HerdrAppModel
    @ObservationIgnored let shell: HerdrShellState

    var selection: Selection = .lead
    var search = ""
    /// nil follows the window width (open at 1280 pt and wider).
    var inspectorPreference: Bool? = nil
    /// A Dock-menu request that arrived before the window could apply it.
    var pendingOpen: FirstMateFleetFeatureID?

    private struct StoreEntry {
        let store: FirstMateStore
        let identity: FirstMateConnectionIdentity
    }

    @ObservationIgnored private var stores: [String: StoreEntry] = [:]
    @ObservationIgnored private var skimStates: [FirstMateFleetFeatureID: SkimDisplayState] = [:]
    @ObservationIgnored private let configurationProvider: @MainActor (String) -> ServerConfiguration?
    @ObservationIgnored private let makeClient: @MainActor (ServerConfiguration) -> any FirstMateClient
    @ObservationIgnored private let fleetSources: @MainActor () -> [FirstMateFleetSource]
    /// The demo's clock, fixed for the session so its times do not drift.
    @ObservationIgnored private let demoNow = Date()
    @ObservationIgnored private var cachedDemoFleet: [FirstMateFleetEntry]?
    @ObservationIgnored private var selectionGeneration = 0

    private struct ConversationCacheKey: Equatable {
        let hosts: [FirstMateFleetHost]
        let readState: FirstMateReadState
    }

    /// The last built list. Building renders every preview, and one update
    /// reads the list several times, so it is rebuilt only when the hosts or
    /// read markers change. A live key compares the index's own array, which
    /// is a storage identity check until the index publishes a change.
    @ObservationIgnored private var conversationCache: (key: ConversationCacheKey, value: [FirstMateConversation])?

    convenience init(model: HerdrAppModel, shell: HerdrShellState) {
        self.init(
            model: model,
            shell: shell,
            configuration: { [weak model] machineID in model?.firstMateConfiguration(machineID: machineID) },
            makeClient: { HerdrAPIClient(configuration: $0) }
        )
    }

    /// `fleetSources` is the roster the window observes when nothing else
    /// does. By default it is every machine with a First Mate configuration,
    /// like the main window's.
    init(
        model: HerdrAppModel,
        shell: HerdrShellState,
        configuration: @escaping @MainActor (String) -> ServerConfiguration?,
        makeClient: @escaping @MainActor (ServerConfiguration) -> any FirstMateClient,
        fleetSources: (@MainActor () -> [FirstMateFleetSource])? = nil
    ) {
        self.model = model
        self.shell = shell
        configurationProvider = configuration
        self.makeClient = makeClient
        self.fleetSources = fleetSources ?? { [weak model] in
            guard let model else { return [] }
            return model.machines.compactMap { machine in
                guard let connection = configuration(machine.id) else { return nil }
                return FirstMateFleetSource(machine: machine, configuration: connection, client: makeClient(connection))
            }
        }
    }

    var isDemo: Bool { model.isDemoMode }

    /// In demo mode, one synthetic host; otherwise every fleet host.
    var hosts: [FirstMateFleetHost] {
        isDemo ? [demoHost] : shell.firstMateFleet.hosts
    }

    var readState: FirstMateReadState { shell.firstMateFleet.readState }

    var conversations: [FirstMateConversation] {
        let key = ConversationCacheKey(hosts: hosts, readState: readState)
        if let cache = conversationCache, cache.key == key { return cache.value }
        let value = FirstMateConversationList.build(hosts: key.hosts, readState: key.readState)
        conversationCache = (key, value)
        return value
    }

    /// Title, label, preview, or machine name, ignoring case.
    var filteredConversations: [FirstMateConversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.label.localizedCaseInsensitiveContains(query)
                || $0.previewText.localizedCaseInsensitiveContains(query)
                || $0.machineName.localizedCaseInsensitiveContains(query)
        }
    }

    /// ``FirstMateBadge/count(hosts:readState:)``, taken from the cached list.
    var badgeCount: Int { conversations.count(where: \.showsDot) }

    /// Whether conversations come from more than one machine, so headers name it.
    var showsMachineNames: Bool { Set(hosts.map(\.machineID)).count > 1 }

    // MARK: Stores

    /// The window's store for a machine, created and configured on first use.
    /// A credential or connection change rebuilds it. Returns nil for a
    /// machine without a configuration.
    func store(for machineID: String) -> FirstMateStore? {
        if isDemo {
            guard machineID == Self.demoMachineID else { return nil }
            let identity = FirstMateConnectionIdentity(configuration: nil, generation: 0, isDemo: true)
            if let entry = stores[machineID], entry.identity == identity { return entry.store }
            let store = FirstMateStore()
            store.configure(client: nil, demo: true, demoFeatures: FirstMateDemo.chatWindowFeatures(now: demoNow))
            stores = [machineID: StoreEntry(store: store, identity: identity)]
            return store
        }
        guard let configuration = configurationProvider(machineID) else { return nil }
        let identity = FirstMateConnectionIdentity(configuration: configuration, generation: model.connectionGeneration, isDemo: false)
        if let entry = stores[machineID], entry.identity == identity { return entry.store }
        stores[machineID]?.store.configure(client: nil, demo: false)
        stores[Self.demoMachineID] = nil
        let store = FirstMateStore()
        store.configure(client: makeClient(configuration), demo: false)
        stores[machineID] = StoreEntry(store: store, identity: identity)
        return store
    }

    var selectedConversationID: FirstMateFleetFeatureID? {
        guard case .feature(let id) = selection else { return nil }
        return id
    }

    var selectedStore: FirstMateStore? {
        selectedConversationID.flatMap { store(for: $0.machineID) }
    }

    var selectedSnapshot: FirstMateSnapshot? {
        guard let id = selectedConversationID else { return nil }
        return selectedStore?.snapshots[id.featureID]
    }

    var selectedConversation: FirstMateConversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    /// Per-feature Skim or Full choices, kept while the window lives.
    func skimState(for id: FirstMateFleetFeatureID) -> SkimDisplayState {
        if let state = skimStates[id] { return state }
        let state = SkimDisplayState()
        skimStates[id] = state
        return state
    }

    // MARK: Navigation

    /// Switches chats by selecting within the machine's store; a store is
    /// never reconfigured to switch, which would drop its drafts. Opening a
    /// different chat starts on the Overview tab.
    func select(_ selection: Selection) {
        if selection != self.selection {
            self.selection = selection
            selectionGeneration &+= 1
        }
        guard case .feature(let id) = selection, let store = store(for: id.machineID) else { return }
        if store.selectedFeatureID != id.featureID {
            store.select(id.featureID)
            store.inspector = .overview
        }
    }

    /// A capsule click: a feature opens its chat; an agent opens its feature
    /// with the inspector on Agents.
    func open(_ target: FirstMateMentionTarget, machineID: String) {
        select(.feature(FirstMateFleetFeatureID(machineID: machineID, featureID: target.featureID)))
        guard case .agent = target, let store = store(for: machineID) else { return }
        store.inspector = .agents
        inspectorPreference = true
    }

    /// Shows the inspector on a tab of the selected chat, as a file card
    /// (Documents) or an agent capsule (Agents) does.
    func showInspector(_ tab: FirstMateInspector) {
        inspectorPreference = true
        guard let store = selectedStore else { return }
        store.inspector = tab
        if tab == .documents { store.documentsMode = .documents }
    }

    // MARK: New feature

    /// The store whose create sheet is showing, if any. The window hosts
    /// `FirstMateCreateSheet(store:initialGoal:)` for it.
    private(set) var createStore: FirstMateStore?
    /// The goal the sheet opens with.
    private(set) var createGoal = ""

    /// Machines a new feature can start on, in roster order.
    var createMachineIDs: [String] {
        isDemo ? [Self.demoMachineID] : model.machines.map(\.id).filter { configurationProvider($0) != nil }
    }

    /// My First Mate's composer: opens the existing new-feature flow with the
    /// text as its goal, on `machineID` or the first machine that can create.
    func beginCreate(goal: String, machineID: String? = nil) {
        guard let machineID = machineID ?? createMachineIDs.first, let store = store(for: machineID) else { return }
        createGoal = goal
        createStore = store
        store.isCreating = true
    }

    /// Clears the create sheet's state once it closes.
    func endCreate() {
        createStore?.isCreating = false
        createStore = nil
        createGoal = ""
    }

    /// Applies a Dock-menu request once the window is running.
    func applyPendingOpen() {
        guard let id = pendingOpen else { return }
        pendingOpen = nil
        select(.feature(id))
    }

    // MARK: Lifecycle

    /// Runs while the window is mounted: refreshes the selected chat's store
    /// every 2 s, and at once when the selection changes. Other stores stay
    /// idle. Holds the control lease for the selected store so feedback and
    /// link editing work here. Also keeps the fleet index observed while no
    /// other window does.
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshSelectedStore() }
            group.addTask { await self.keepFleetObserved() }
        }
    }

    private func refreshSelectedStore() async {
        let lease = FirstMateWorkspaceControlLease()
        defer { lease.release() }
        while !Task.isCancelled {
            applyPendingOpen()
            let generation = selectionGeneration
            if let store = selectedStore {
                lease.update(store: store, available: true)
                await store.refresh()
            } else {
                lease.release()
            }
            await waitForNextRefresh(since: generation)
        }
    }

    /// Observes the fleet index whenever nothing else does, typically after
    /// the main window closes. The main window's observer supersedes this one
    /// when it returns, and cancelling the run stops only this window's own
    /// observer. Demo mode owns no live hosts.
    private func keepFleetObserved() async {
        let fleet = shell.firstMateFleet
        while !Task.isCancelled {
            if !isDemo, !fleet.hasObserver {
                let sources = fleetSources()
                if !sources.isEmpty {
                    await fleet.observe(sources: sources, connectionGeneration: model.connectionGeneration)
                }
            }
            do { try await Task.sleep(for: Self.fleetObserverCheckInterval) } catch { return }
        }
    }

    private func waitForNextRefresh(since generation: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.refreshInterval)
        while clock.now < deadline, generation == selectionGeneration, pendingOpen == nil {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    /// Marks the chat read when it shows in a key window, scrolled to its
    /// newest message. The marker is the newest First Mate message the
    /// transcript holds, which is what the dot compares against.
    func markReadIfNeeded(featureID: String, machineID: String, newestMessageID: String?, isKeyWindow: Bool, isAtBottom: Bool) {
        guard isKeyWindow, isAtBottom, let newestMessageID else { return }
        let id = FirstMateFleetFeatureID(machineID: machineID, featureID: featureID)
        guard let conversation = conversations.first(where: { $0.id == id }), conversation.isUnread else { return }
        let newestFirstMate = store(for: machineID)?.snapshots[featureID]?.messages
            .last { $0.role == "assistant" && $0.isConversation }?.id
        let through = newestFirstMate ?? newestMessageID
        let fleet = shell.firstMateFleet
        Task { await fleet.markRead(machineID: machineID, featureID: featureID, throughMessageID: through) }
    }

    /// After a send, action, archive, or read here, refreshes the main
    /// window's store for that machine and the fleet index, so the other
    /// window shows it within about a second.
    func didMutate(machineID: String) {
        let shell = shell
        Task {
            await shell.refreshFirstMateStore(machineID: machineID)
            await shell.firstMateFleet.refresh()
        }
    }

    // MARK: Demo

    /// The demo's one host: the chat demo's fleet summary, with each chat's
    /// newest message taken from the demo store so local sends show up.
    private var demoHost: FirstMateFleetHost {
        let snapshots = store(for: Self.demoMachineID)?.snapshots ?? [:]
        let fleet = cachedDemoFleet ?? FirstMateDemo.chatWindowFleet(now: demoNow)
        cachedDemoFleet = fleet
        return Self.demoHost(fleet: fleet, snapshots: snapshots, lastUpdated: demoNow)
    }

    static func demoHost(fleet: [FirstMateFleetEntry], snapshots: [String: FirstMateSnapshot], lastUpdated: Date) -> FirstMateFleetHost {
        var entries: [String: FirstMateFleetEntry] = [:]
        for var entry in fleet {
            if let snapshot = snapshots[entry.featureID],
               let latest = snapshot.messages.last(where: \.isConversation),
               latest.id != entry.latestMessage?.id {
                entry.latestMessage = FirstMateFleetLatestMessage(
                    id: latest.id, role: latest.role, text: String(latest.text.prefix(200)), createdAt: latest.createdAt
                )
                if latest.createdAt > (entry.activityAt ?? "") { entry.activityAt = latest.createdAt }
                if latest.role == "assistant", latest.id != entry.latestFirstMateMessageID {
                    entry.latestFirstMateMessageID = latest.id
                    entry.unread = true
                }
            }
            entries[entry.featureID] = entry
        }
        let features = fleet.compactMap { snapshots[$0.featureID]?.feature }
        return FirstMateFleetHost(
            machineID: demoMachineID,
            machineName: demoMachineName,
            features: features,
            isLoading: false,
            error: nil,
            unsupported: false,
            lastUpdated: lastUpdated,
            supportsFleet: true,
            fleetEntries: entries
        )
    }
}
