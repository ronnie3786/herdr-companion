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
    /// Home feature actions carry an immutable source identity. They never
    /// use the Dock menu's fallback to another conversation.
    private(set) var exactOpenRequest: FirstMateChatExactOpenRequest?
    /// Explicit Home transfers retain their exact lead independently of the
    /// automatic policy, including when that owner becomes unavailable.
    private(set) var homeLeadOwner: HomeChatOwner?
    private var homeContextByID: [UUID: HomeChatContext] = [:]
    @ObservationIgnored private var consumedHomeTransferIDs: Set<UUID> = []
    @ObservationIgnored private var homeTransfersInFlight: Set<UUID> = []
    var search = ""
    var archiveCandidate: FirstMateFleetIndex.ArchiveTarget?
    var presentationEditTarget: FirstMateConversation?
    /// nil follows the window width (open at 1280 pt and wider).
    var inspectorPreference: Bool? = nil
    /// A Dock-menu request that arrived before the window could apply it.
    var pendingOpen: FirstMateFleetFeatureID?
    /// Whether the next composer to appear takes keyboard focus. Set by a
    /// pointer choice (``select(_:focusComposer:)``) and consumed by the
    /// composer; a keyboard move through the list clears it, so ↑/↓ and
    /// search typing never lose focus to the chat they land on. Starts set,
    /// so the window opens with its composer focused.
    @ObservationIgnored var pendingComposerFocus = true

    private struct StoreEntry {
        let store: FirstMateStore
        let identity: FirstMateConnectionIdentity
    }

    @ObservationIgnored private var stores: [String: StoreEntry] = [:]
    /// Keep the transferred draft even when explicit feature navigation needs
    /// a new store for the same machine's replacement connection.
    private struct HomeLeadConversation {
        let owner: HomeChatOwner
        let store: FirstMateStore
        let draftContext: FirstMateStore.OperationContext
    }
    @ObservationIgnored private var retainedHomeLead: HomeLeadConversation?
    @ObservationIgnored private var skimStates: [FirstMateFleetFeatureID: SkimDisplayState] = [:]
    @ObservationIgnored private let configurationProvider: @MainActor (String) -> ServerConfiguration?
    @ObservationIgnored private let makeClient: @MainActor (ServerConfiguration) -> any FirstMateClient
    @ObservationIgnored private let fleetSources: @MainActor () -> [FirstMateFleetSource]
    @ObservationIgnored private var selectionGeneration = 0
    /// The header's machine choice lives in UserDefaults; this publishes it.
    private var leadPinRevision = 0
    /// Selection wakes are independent of network completion. Cancelling a
    /// slow read must never make the next conversation wait for its transport.
    @ObservationIgnored private var refreshWake: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var refreshOwner = UUID()

    private struct ConversationCacheKey: Equatable {
        let hosts: [FirstMateFleetHost]
        let readState: FirstMateReadState
    }

    /// The last fleet-built list. Building renders every preview, and one update
    /// reads the list several times, so it is rebuilt only when the hosts or
    /// read markers change. Local reply progress is projected on every read,
    /// without caching store state or changing the fleet-built rows.
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

    /// Fleet rows with window-local reply progress, including sends before
    /// the fleet poll catches up. Reading existing stores here observes their
    /// outgoing messages and snapshots without creating a store for every row.
    var conversations: [FirstMateConversation] {
        let key = ConversationCacheKey(hosts: hosts, readState: readState)
        let value: [FirstMateConversation]
        if let cache = conversationCache, cache.key == key {
            value = cache.value
        } else {
            value = FirstMateConversationList.build(hosts: key.hosts, readState: key.readState)
            conversationCache = (key, value)
        }
        return value.map { conversation in
            let localPending: Bool
            if let store = stores[conversation.machineID]?.store {
                let featureID = conversation.featureID
                let hostUpdatedAt = key.hosts.first { $0.machineID == conversation.machineID }?
                    .features.first { $0.id == featureID }?.updatedAt
                localPending = FirstMateReplyProgress.isLocalReplyPending(
                    outgoing: store.outgoingMessages(for: featureID),
                    snapshot: store.snapshots[featureID],
                    hostFeatureUpdatedAt: hostUpdatedAt,
                    fleetLatestFirstMateMessageID: conversation.latestFirstMateMessageID
                )
            } else {
                localPending = false
            }
            return FirstMateReplyProgress.presenting(conversation, workingOnReply: conversation.isWorkingOnReply || localPending)
        }
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

    /// The window's need-you count, after local reply progress is applied.
    /// The process-wide Dock badge still uses the unprojected fleet list.
    var badgeCount: Int { conversations.count(where: \.showsDot) }

    /// Whether conversations come from more than one machine, so headers name it.
    var showsMachineNames: Bool { Set(hosts.map(\.machineID)).count > 1 }

    // MARK: Stores

    /// The window's store for a machine, created and configured on first use.
    /// A credential or connection change rebuilds it. Returns nil for a
    /// machine without a configuration.
    func store(for machineID: String, overridingRoute: Bool = false) -> FirstMateStore? {
        if !overridingRoute, let request = exactOpenRequest, request.target.machineID == machineID,
           !exactOwnerIsCurrent { return nil }
        if !overridingRoute, selection == .lead, let owner = homeLeadOwner, owner.target.machineID == machineID,
           !owner.target.isCurrent(model: model, configuration: configurationProvider) { return nil }
        if isDemo {
            guard machineID == Self.demoMachineID else { return nil }
            let identity = FirstMateConnectionIdentity(configuration: nil, generation: 0, isDemo: true)
            if let entry = stores[machineID], entry.identity == identity { return entry.store }
            // The process's chat demo, shared with the Dock badge and menu.
            let store = shell.firstMateChatDemo.store
            stores = [machineID: StoreEntry(store: store, identity: identity)]
            return store
        }
        guard let configuration = configurationProvider(machineID) else { return nil }
        let identity = FirstMateConnectionIdentity(configuration: configuration, generation: model.connectionGeneration, isDemo: false)
        if let entry = stores[machineID], entry.identity == identity { return entry.store }
        if let previous = stores[machineID]?.store, previous !== retainedHomeLead?.store {
            previous.configure(client: nil, demo: false)
        }
        stores[Self.demoMachineID] = nil
        let store = FirstMateStore()
        store.configure(client: makeClient(configuration), demo: false)
        // Messages to this machine's lead carry a snapshot of the machines it
        // does not reach itself.
        store.leadContextProvider = { [weak self] in
            guard let self else { return nil }
            return FirstMateLeadMachine.context(hosts: self.hosts, machines: self.model.machines, excluding: machineID)
        }
        // A rebuilt store keeps the open chat, so its next refresh fetches
        // that snapshot instead of the machine's first feature. If the store
        // rejects it, `selectionIsUnresolvable` still falls back.
        if case .feature(let id) = selection, id.machineID == machineID { store.select(id.featureID) }
        stores[machineID] = StoreEntry(store: store, identity: identity)
        return store
    }

    var selectedConversationID: FirstMateFleetFeatureID? {
        guard case .feature(let id) = selection else { return nil }
        return id
    }

    /// The selected chat's store: a feature's machine, or the lead's while
    /// My First Mate is a real lead conversation.
    var selectedStore: FirstMateStore? {
        switch selection {
        case .feature(let id): store(for: id.machineID)
        case .lead: leadStore
        }
    }

    // MARK: Lead First Mate

    /// The machine whose lead First Mate "My First Mate" talks to, or nil when
    /// no machine has a lead: My First Mate then keeps the Phase 1 briefing
    /// and starts features.
    var leadMachineID: String? {
        if let homeLeadOwner { return homeLeadOwner.target.machineID }
        if isDemo {
            return store(for: Self.demoMachineID)?.leadSupported == true ? Self.demoMachineID : nil
        }
        return leadChoice.current
    }

    /// Where the lead lives and where it is now (see ``FirstMateLeadMachine``).
    var leadChoice: FirstMateLeadMachine.Choice {
        _ = leadPinRevision
        return FirstMateLeadMachine.choice(hosts: hosts, machines: model.machines)
    }

    /// The machine chosen in the header, while it still has a lead.
    var leadPinnedMachineID: String? {
        _ = leadPinRevision
        return FirstMateLeadMachine.pinned().flatMap { leadMachineIDs.contains($0) ? $0 : nil }
    }

    /// Where Automatic puts the lead right now, for the header's menu.
    var automaticLeadMachineID: String? {
        FirstMateLeadMachine.choose(capable: FirstMateLeadMachine.capable(hosts: hosts), pinned: nil,
                                    local: FirstMateLeadMachine.home(FirstMateLeadMachine.localMachineID(machines: model.machines),
                                                                     hosts: hosts),
                                    withConversation: Set(hosts.filter { $0.lead != nil }.map(\.machineID)),
                                    activeCounts: FirstMateLeadMachine.activeCounts(hosts: hosts)).preferred
    }

    /// Machines with a lead, for the header's switcher.
    var leadMachineIDs: [String] {
        isDemo ? leadMachineID.map { [$0] } ?? [] : FirstMateLeadMachine.capable(hosts: hosts)
    }

    var leadStore: FirstMateStore? {
        if let owner = homeLeadOwner {
            guard owner.target.isCurrent(model: model, configuration: configurationProvider),
                  let store = retainedHomeLead?.store ?? store(for: owner.target.machineID),
                  store.leadFeatureID == nil || store.leadFeatureID == owner.featureID else { return nil }
            return store
        }
        return leadMachineID.flatMap { store(for: $0) }
    }

    var leadOwnerIsCurrent: Bool {
        guard let owner = homeLeadOwner else { return true }
        return owner.target.isCurrent(model: model, configuration: configurationProvider)
            && (retainedHomeLead?.store.leadFeatureID == nil
                || retainedHomeLead?.store.leadFeatureID == owner.featureID)
    }

    var leadUnavailableReason: String? {
        guard let owner = homeLeadOwner else { return nil }
        if !owner.target.isCurrent(model: model, configuration: configurationProvider) {
            return "The lead opened from Home is no longer on the same connection. Its draft stays with that conversation."
        }
        if let store = retainedHomeLead?.store,
           let featureID = store.leadFeatureID, featureID != owner.featureID {
            return "This machine's lead changed. The draft from Home has not been moved to another conversation."
        }
        return nil
    }

    var unavailableHomeDraft: String? {
        guard leadUnavailableReason != nil, let retainedHomeLead else { return nil }
        let draft = retainedHomeLead.store.composerDraft(for: retainedHomeLead.draftContext)
        return draft.isEmpty ? nil : draft
    }

    var homeContexts: [HomeChatContext] {
        guard let owner = homeLeadOwner, let store = retainedHomeLead?.store else { return [] }
        return store.composerDrafts.quotes(for: owner.featureID).compactMap { homeContextByID[$0.id] }
    }

    /// Home's transcript reuses this presentation helper without starting the
    /// window's polling loop or sharing the actual window's selected store.
    func installHomeConversationStore(_ store: FirstMateStore, owner: HomeChatOwner) {
        let identity = FirstMateConnectionIdentity(configuration: owner.target.configuration,
            generation: owner.target.isDemo ? 0 : owner.target.generation, isDemo: owner.target.isDemo)
        stores[owner.target.machineID] = StoreEntry(store: store, identity: identity)
        homeLeadOwner = owner
        retainedHomeLead = .init(owner: owner, store: store, draftContext: store.operationContext)
    }

    @discardableResult
    func consumeHomeTransfer(from source: HomeChatController) async -> Bool {
        guard let transfer = source.pendingTransfer else { return false }
        if consumedHomeTransferIDs.contains(transfer.id) { source.acknowledgeTransfer(transfer); return true }
        guard homeTransfersInFlight.insert(transfer.id).inserted else { return false }
        defer { homeTransfersInFlight.remove(transfer.id) }
        func reject(_ message: String) -> Bool { source.failTransfer(transfer.id, message: message); return false }
        guard source.validates(transfer), transfer.owner.target.isCurrent(model: model, configuration: configurationProvider) else {
            return reject("The lead's machine or connection changed. Your draft remains on Home.")
        }
        if let retainedHomeLead, retainedHomeLead.owner != transfer.owner,
           retainedHomeLead.store.hasUnsentDrafts || retainedHomeLead.store.isSending
                || retainedHomeLead.store.outgoingMessages(for: retainedHomeLead.owner.featureID).contains(where: {
                    $0.state.isPending || $0.state.isFailure
                }) {
            return reject("The First Mate window still has a draft for a different lead connection. Resolve that draft before transferring this one.")
        }
        let target = transfer.owner.target
        let identity = FirstMateConnectionIdentity(configuration: target.configuration,
            generation: target.isDemo ? 0 : target.generation, isDemo: target.isDemo)
        if let entry = stores[target.machineID], entry.identity != identity,
           entry.store.hasUnsentDrafts || entry.store.isSending || entry.store.snapshots.keys.contains(where: {
               entry.store.outgoingMessages(for: $0).contains { $0.state.isPending || $0.state.isFailure }
           }) {
            return reject("The First Mate window has a draft on an older connection. Keep or resolve that draft before transferring this one.")
        }
        guard let destination = store(for: target.machineID, overridingRoute: true) else {
            return reject("That machine is unavailable in First Mate. Your draft remains on Home.")
        }
        let lifecycle = destination.lifecycle
        guard !destination.isSending,
              !destination.outgoingMessages(for: transfer.owner.featureID).contains(where: { $0.state.isPending || $0.state.isFailure }) else {
            return reject("Resolve the current send in the First Mate window before transferring this draft.")
        }
        let navigationGeneration = selectionGeneration
        _ = await destination.openLead()
        guard !Task.isCancelled else {
            return reject("Opening the First Mate window was cancelled. Your draft remains on Home; you can try again.")
        }
        guard source.validates(transfer), target.isCurrent(model: model, configuration: configurationProvider),
              destination.lifecycle == lifecycle, selectionGeneration == navigationGeneration else {
            return reject("The conversation changed while opening. Your draft remains on Home.")
        }
        // The window's normal refresh may have opened this same lead while
        // our request was suspended. Verify the actual destination instead
        // of treating that operation-context cancellation as a missing lead.
        guard destination.leadFeatureID == transfer.owner.featureID,
              destination.leadSnapshot?.feature.id == transfer.owner.featureID else {
            return reject("The requested lead conversation is unavailable. Your draft remains on Home.")
        }
        guard !destination.isSending,
              !destination.outgoingMessages(for: transfer.owner.featureID).contains(where: { $0.state.isPending || $0.state.isFailure }),
              !destination.composerDrafts.attachments(for: transfer.owner.featureID).contains(where: { $0.status == .uploading }) else {
            return reject("Wait for the First Mate window's send or upload to finish before transferring this draft.")
        }
        let wasShowingLead = selection == .lead
        homeLeadOwner = transfer.owner
        retainedHomeLead = .init(owner: transfer.owner, store: destination, draftContext: destination.operationContext)
        select(.lead, focusComposer: true)
        if wasShowingLead {
            selectionGeneration &+= 1
            wakeRefresh()
        }
        let featureID = transfer.owner.featureID
        let context = destination.operationContext
        let existing = destination.composerDraft(for: context)
        destination.setComposerDraft(HomeChatController.appending(transfer.draft, to: existing), for: context)
        destination.composerDrafts.noteDraftEdit(for: featureID)
        var attachments = destination.composerDrafts.attachments(for: featureID)
        let existingAttachmentIDs = Set(attachments.map(\.id))
        attachments += transfer.attachments.filter { !existingAttachmentIDs.contains($0.id) }
        destination.composerDrafts.setAttachments(attachments, for: featureID)
        var quotes = destination.composerDrafts.quotes(for: featureID)
        let existingQuoteIDs = Set(quotes.map(\.id))
        quotes += transfer.quotes.filter { !existingQuoteIDs.contains($0.id) }
        destination.composerDrafts.setQuotes(quotes, for: featureID)
        destination.composerDrafts.setContainsDictation(destination.composerDrafts.containsDictation(for: featureID) || transfer.containsDictation, for: featureID)
        for homeContext in transfer.contexts { homeContextByID[homeContext.id] = homeContext }
        if let inspector = transfer.inspector {
            destination.inspector = inspector
            inspectorPreference = true
        }
        consumedHomeTransferIDs.insert(transfer.id)
        // There is no suspension between destination mutation and source ack.
        source.acknowledgeTransfer(transfer)
        return true
    }

    /// The lead's summary from the fleet index: its newest message and
    /// whether it is unread or replying.
    var leadSummary: FirstMateLeadSummary? {
        guard let id = leadMachineID else { return nil }
        return hosts.first { $0.machineID == id }?.lead
    }

    func machineName(_ machineID: String) -> String {
        if isDemo { return Self.demoMachineName }
        return hosts.first { $0.machineID == machineID }?.machineName
            ?? model.machines.first { $0.id == machineID }?.name ?? machineID
    }

    /// Talks to another machine's lead from now on, or with nil returns to
    /// Automatic.
    func setLeadMachine(_ machineID: String?) {
        if let machineID, !leadMachineIDs.contains(machineID) { return }
        homeLeadOwner = nil
        FirstMateLeadMachine.pin(machineID)
        leadPinRevision &+= 1
        if selection == .lead {
            selectionGeneration &+= 1
            wakeRefresh()
        }
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

    /// Editing a row does not change the selected conversation.
    func requestPresentationEdit(_ id: FirstMateFleetFeatureID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        presentationEditTarget = conversation
    }

    /// Returns nil after a successful save (or an unchanged draft), otherwise
    /// an error for the sheet to display without dismissing it.
    func savePresentation(_ id: FirstMateFleetFeatureID, label: String?, emoji: String?) async -> String? {
        guard conversations.contains(where: { $0.id == id }) else { return "This conversation is no longer available. Refresh the list and try again." }
        guard label != nil || emoji != nil else { return nil }
        if isDemo {
            shell.firstMateChatDemo.setPresentation(featureID: id.featureID, label: label, emoji: emoji)
            conversationCache = nil
            return nil
        }
        guard let configuration = configurationProvider(id.machineID) else {
            return "This companion is not configured. Reconnect its machine and try again."
        }
        do {
            let entry = try await makeClient(configuration).updateFirstMateHud(featureID: id.featureID, label: label, emoji: emoji)
            guard entry.featureID == id.featureID else { throw APIError.invalidResponse }
            shell.firstMateFleet.applyPresentation(entry, machineID: id.machineID)
            didMutate(machineID: id.machineID)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Capture the row's exact machine and feature, independent of selection.
    func requestArchive(_ id: FirstMateFleetFeatureID) {
        guard let feature = hosts.first(where: { $0.machineID == id.machineID })?.features.first(where: { $0.id == id.featureID }),
              !feature.isArchived, !feature.isLead else { return }
        archiveCandidate = shell.firstMateFleet.archiveTarget(machineID: id.machineID, feature: feature)
    }

    /// Keep the blocking sheet mounted while both windows reconcile the archived row.
    func didArchive(_ target: FirstMateFleetIndex.ArchiveTarget) {
        if selection == .feature(target.id) { select(.lead) }
        didMutate(machineID: target.machineID)
        Task { await store(for: target.machineID)?.refresh() }
    }

    func archive(_ target: FirstMateFleetIndex.ArchiveTarget, reason: FirstMateArchiveReason?) async -> String? {
        if isDemo {
            guard let store = store(for: target.machineID),
                  await store.setArchived(featureID: target.feature.id, archived: true, reason: reason) else {
                return "Could not archive this feature. Try again."
            }
        } else {
            if let error = await shell.firstMateFleet.archive(target, reason: reason) { return error }
            // The chat window owns a separate store. Its next poll also sees
            // the persisted archive, including when another row was selected.
            await store(for: target.machineID)?.refresh()
        }
        if selection == .feature(target.id) { select(.lead) }
        return nil
    }

    // MARK: Navigation

    /// Switches chats by selecting within the machine's store; a store is
    /// never reconfigured to switch, which would drop its drafts. Opening a
    /// different chat starts on the Overview tab.
    ///
    /// `focusComposer` is true for pointer choices (a row click, a capsule,
    /// the ＋, an open request): the new chat's composer takes focus when it
    /// appears. A keyboard move leaves it false and cancels any pending focus.
    func select(_ selection: Selection, focusComposer: Bool = false) {
        exactOpenRequest = nil
        if selection != self.selection {
            pendingComposerFocus = focusComposer
            self.selection = selection
            selectionGeneration &+= 1
            wakeRefresh()
        }
        if case .lead = selection {
            // The refresh loop opens the lead on first use.
            if let store = leadStore, let lead = store.leadFeatureID, store.selectedFeatureID != lead {
                store.select(lead)
            }
            return
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
        select(.feature(FirstMateFleetFeatureID(machineID: machineID, featureID: target.featureID)), focusComposer: true)
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
    /// Returns false, changing nothing, when no machine can create one.
    @discardableResult
    func beginCreate(goal: String, machineID: String? = nil) -> Bool {
        guard let machineID = machineID ?? createMachineIDs.first, let store = store(for: machineID) else { return false }
        createGoal = goal
        createStore = store
        store.isCreating = true
        return true
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
        select(.feature(id), focusComposer: true)
    }

    /// Wakes the refresh loop at once (a selection change or an open request).
    private(set) var pollingInterval: Duration = .seconds(2)

    func setActivity(isKey: Bool, isBackground: Bool) {
        let interval: Duration = .seconds(isBackground ? 30 : isKey ? 2 : 10)
        guard interval != pollingInterval else { return }
        pollingInterval = interval
        wakeRefresh()
    }

    func wakeRefresh() {
        refreshWake?.yield(())
    }

    // MARK: Exact feature routing

    /// Applies immediately, including before the fleet list loads. A new
    /// request wakes hydration even if this feature is already selected.
    func applyExactOpenRequest(_ request: FirstMateChatExactOpenRequest) {
        pendingOpen = nil
        exactOpenRequest = request
        selection = .feature(request.target)
        pendingComposerFocus = true
        selectionGeneration &+= 1
        if let store = selectedStore {
            store.select(request.target.featureID)
            store.inspector = .overview
        }
        wakeRefresh()
    }

    var exactOwnerIsCurrent: Bool {
        guard let request = exactOpenRequest else { return true }
        let target = request.target
        let current = FirstMateConnectionIdentity(
            configuration: isDemo ? nil : configurationProvider(target.machineID),
            generation: model.connectionGeneration, isDemo: isDemo)
        guard current == request.identity else { return false }
        if isDemo { return target.machineID == Self.demoMachineID }
        return current.configuration != nil && model.machines.contains { $0.id == target.machineID }
    }

    var exactSelectionUnavailableReason: String? {
        guard let request = exactOpenRequest, selection == .feature(request.target) else { return nil }
        let destination = "\(request.target.featureID) on \(request.target.machineID)"
        guard exactOwnerIsCurrent else {
            return "\(destination) is unavailable because its machine or connection changed. Reopen it from Home after the source reconnects."
        }
        guard let store = selectedStore else { return "\(destination) is unavailable because its machine cannot be reached." }
        if store.snapshots[request.target.featureID] != nil { return nil }
        if let error = store.error { return "\(destination) could not be opened: \(error)" }
        if store.hasLoaded || isDemo {
            return "\(destination) is no longer available."
        }
        return nil
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
        let owner = UUID()
        refreshOwner = owner
        let (wakes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        refreshWake = continuation
        var request: Task<Void, Never>?
        defer {
            request?.cancel()
            continuation.finish()
            if refreshOwner == owner { refreshWake = nil }
            lease.release()
        }
        continuation.yield(())
        for await _ in wakes {
            guard !Task.isCancelled else { return }
            request?.cancel()
            applyPendingOpen()
            let generation = selectionGeneration
            lease.release()
            request = Task {
                while !Task.isCancelled, generation == selectionGeneration {
                    guard let store = selectedStore else {
                        lease.release()
                        do { try await Task.sleep(for: pollingInterval) } catch { return }
                        continue
                    }
                    lease.update(store: store, available: true)
                    if case .lead = selection, store.leadFeatureID == nil || store.selectedFeatureID != store.leadFeatureID {
                        // Opening already fetches the snapshot. Do not fetch it
                        // a second time immediately after that succeeds.
                        _ = await store.openLead()
                    } else {
                        await store.refreshConversation()
                    }
                    do { try await Task.sleep(for: pollingInterval) } catch { return }
                }
            }
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

    /// Marks the chat read when it shows in a key window, scrolled to its
    /// newest message. The marker is the newest First Mate message the
    /// transcript holds, which is what the dot compares against.
    func markReadIfNeeded(featureID: String, machineID: String, newestMessageID: String?, isKeyWindow: Bool, isAtBottom: Bool,
                          validateOwner: (@MainActor () -> Bool)? = nil) {
        guard validateOwner?() ?? true, isKeyWindow, isAtBottom, let newestMessageID else { return }
        if let lead = leadSummary, lead.feature.id == featureID, machineID == leadMachineID {
            guard lead.unread,
                  let through = store(for: machineID)?.snapshots[featureID]?.messages
                      .last(where: { $0.role == "assistant" && $0.isConversation })?.id else { return }
            let fleet = shell.firstMateFleet
            Task {
                guard validateOwner?() ?? true else { return }
                await fleet.markLeadRead(machineID: machineID, throughMessageID: through)
            }
            return
        }
        let id = FirstMateFleetFeatureID(machineID: machineID, featureID: featureID)
        guard let conversation = conversations.first(where: { $0.id == id }), conversation.isUnread else { return }
        let newestFirstMate = store(for: machineID)?.snapshots[featureID]?.messages
            .last { $0.role == "assistant" && $0.isConversation }?.id
        let through = newestFirstMate ?? newestMessageID
        let fleet = shell.firstMateFleet
        Task {
            guard validateOwner?() ?? true else { return }
            await fleet.markRead(machineID: machineID, featureID: featureID, throughMessageID: through)
        }
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
    /// newest message taken from the demo store so local sends show up. The
    /// Dock badge and menu count the same host (`HerdrShellState.firstMateChatDemo`).
    private var demoHost: FirstMateFleetHost {
        _ = store(for: Self.demoMachineID)
        return shell.firstMateChatDemo.host
    }

    static func demoHost(fleet: [FirstMateFleetEntry], snapshots: [String: FirstMateSnapshot], lastUpdated: Date) -> FirstMateFleetHost {
        FirstMateChatDemoProjection.host(fleet: fleet, snapshots: snapshots, lastUpdated: lastUpdated,
                                         machineID: demoMachineID, machineName: demoMachineName)
    }
}
