import Foundation
import Observation

struct HerdrHudAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let byteCount: Int
    let isImage: Bool
    var quote: ChatQuote? = nil
}

struct HerdrHudStep: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let isFailure: Bool
    let isRunning: Bool
}

struct HerdrHudExchange: Identifiable, Equatable, Sendable {
    let id: String
    let machineID: String
    let prompt: String
    let sentPrompt: String
    var response: String?
    var error: String?
    var status: HeadlessAgentRunStatus
    var costUSD: Double?
    let createdAt: Date
    var promotedPaneID: String?
    let attachmentFilenames: [String]
    /// The folder captured when this turn was created. A HUD session can show
    /// older turns from another machine, so retries and continuations must not
    /// read a mutable fresh-composer selection instead.
    let workingFolderPath: String
    var attachments: [HeadlessAgentAttachment] = []
    var localAttachments: [HerdrHudAttachment] = []
    var modelLabel: String = "default"
    /// True only when `modelLabel` came from an explicit submitted identifier
    /// or an authoritative run/history report. A catalog or composer fallback
    /// may name a different model than the one a machine's trusted project
    /// default executes, so an unproven label never contributes to bubble
    /// metadata.
    var modelLabelIsProven = false
    var steps: [HerdrHudStep] = []
    var stepsTruncated = false

    init(
        id: String,
        machineID: String,
        prompt: String,
        sentPrompt: String,
        response: String?,
        error: String?,
        status: HeadlessAgentRunStatus,
        costUSD: Double?,
        createdAt: Date,
        promotedPaneID: String?,
        attachmentFilenames: [String],
        workingFolderPath: String = HerdrHudWorkingFolder.homePath,
        attachments: [HeadlessAgentAttachment] = [],
        localAttachments: [HerdrHudAttachment] = [],
        modelLabel: String = "default",
        modelLabelIsProven: Bool = false,
        steps: [HerdrHudStep] = [],
        stepsTruncated: Bool = false
    ) {
        self.id = id
        self.machineID = machineID
        self.prompt = prompt
        self.sentPrompt = sentPrompt
        self.response = response
        self.error = error
        self.status = status
        self.costUSD = costUSD
        self.createdAt = createdAt
        self.promotedPaneID = promotedPaneID
        self.attachmentFilenames = attachmentFilenames
        self.workingFolderPath = HerdrHudWorkingFolder.normalizedPath(workingFolderPath)
            ?? HerdrHudWorkingFolder.homePath
        self.attachments = attachments
        self.localAttachments = localAttachments
        self.modelLabel = modelLabel
        self.modelLabelIsProven = modelLabelIsProven
        self.steps = steps
        self.stepsTruncated = stepsTruncated
    }
}

@MainActor
@Observable
final class HerdrHudSession {
    /// The live HUD thread. New chat detaches it without deleting server history.
    struct HerdrHudThread: Codable, Equatable, Sendable {
        var machineID: String
        var rootRunID: String
        var lastRunID: String
        var turnCount: Int
    }

    /// Which model rules govern this session. A genuinely new composer owns
    /// its own choice and starts in Machine default mode; a conversation that
    /// existed before this behavior (or was loaded from saved history) keeps
    /// following the shared legacy HUD preference exactly as before.
    enum ModelChoiceSource: Equatable, Sendable {
        case sessionOwned
        case sharedPreference
    }

    /// One checked "create in main workspace" send's state. A confirmed pane
    /// is retained whenever it is known so the UI can offer Open chat instead
    /// of repeating work that may already exist.
    enum WorkspaceLaunchState: Equatable, Sendable {
        case idle
        case launching
        case sent(HerdrHudWorkspaceLaunchReceipt)
        case needsRecovery(message: String, receipt: HerdrHudWorkspaceLaunchReceipt?)
    }

    /// Builds the network seam for one execution companion. The default uses
    /// the real per-machine client; tests inject a launcher with an isolated
    /// receipt store.
    typealias WorkspaceLauncherFactory = @MainActor (HerdrAppModel, String) throws -> HerdrHudWorkspaceLauncher
    /// Supplies this Mac's host evidence on first use. The production default
    /// is `HerdrHudHostIdentity.current()`; tests inject a provider so they can
    /// prove session creation never resolves it eagerly.
    typealias HostIdentityProvider = () -> HerdrHudHostIdentity

    static let machineIDDefaultsKey = "herdr.hud.machineID"
    static let maxAttachments = 4
    static let maxCombinedAttachmentBytes: Int64 = 21 * 1024 * 1024

    private let controller = HeadlessAgentController()
    private let userDefaults: UserDefaults
    @ObservationIgnored private let injectedHostIdentity: HerdrHudHostIdentity?
    @ObservationIgnored private let hostIdentityProvider: HostIdentityProvider?
    @ObservationIgnored private var cachedHostIdentity: HerdrHudHostIdentity?
    @ObservationIgnored private let mainWorkspaceStore: HerdrHudMainWorkspaceStore
    @ObservationIgnored private let workspaceLauncherFactory: WorkspaceLauncherFactory
    @ObservationIgnored private let workingFolderStore: HerdrHudWorkingFolderStore
    private let attachmentDirectory: URL
    private let storeURL: URL
    @ObservationIgnored private let agentSettings: AgentModelSettingsStore
    @ObservationIgnored private let promptSettings: HerdrPromptSettingsStore
    @ObservationIgnored let modelFavorites: ModelFavoritesStore
    @ObservationIgnored private let persistence: HerdrHudPersistenceStore
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var historyObservationTask: Task<Void, Never>?
    @ObservationIgnored private var terminalMetadataReconciliationTask: Task<Void, Never>?
    /// Promised-file drops in flight. Each batch removes its shared staging
    /// directory and then releases itself here; the session owns the batch for
    /// as long as any receiver has not reported yet.
    @ObservationIgnored var activePromiseBatches: [HerdrPromiseBatch] = []
    @ObservationIgnored private var hasStartedSessionActivity = false
    /// Fires after an accepted run or a history load establishes this session's
    /// durable conversation identity. The owning HUD collection uses it to
    /// attach a title that was created while the first turn was still an
    /// unaccepted placeholder. This is a notification seam only: it cannot
    /// change what the session does.
    @ObservationIgnored var onHistoryIdentityEstablished: (() -> Void)?

    let responseAudioPlayer = ResponseAudioPlayer()
    private(set) var exchanges: [HerdrHudExchange] = []
    private(set) var exchangesRevision = 0
    private(set) var latestPromotableExchangeID: String?
    private(set) var thread: HerdrHudThread?
    private var historyRootRunID: String?
    /// Model and cumulative reported cost for this conversation's bubble. It is
    /// fed from the runs the app already observes, survives the transcript
    /// caps, and is scoped to the exact machine/root, so a different
    /// conversation starts over instead of inheriting stale values.
    private(set) var chatMetadata = HerdrHudChatMetadataAccumulator()

    var bubbleMetadata: HerdrHudSessionMetadata { chatMetadata.metadata }
    /// The exact local submission placeholder whose accepted run established
    /// each durable history identity (`machineID:rootRunID`) this session has
    /// observed. Smart Rename's pending-title adoption consults this mapping so
    /// a remembered title can only attach to the submission that produced the
    /// root — a failed earlier submission still listed in the transcript or a
    /// later turn can never claim it. Not persisted: acceptance and history
    /// loading re-establish it within the owning session.
    @ObservationIgnored private(set) var acceptedSubmissionIDsByHistoryIdentity: [String: String] = [:]
    private(set) var isLoadingHistory = false
    private(set) var needsHistoryRefresh = false
    private(set) var isEnding = false
    private(set) var hasEnded = false
    @ObservationIgnored private var savedHistoryRunKeys: Set<String> = []
    var draft = ""
    var pendingAttachments: [HerdrHudAttachment] = []
    var pendingQuotes: [ChatQuote] = []
    private(set) var selectedWorkingFolder = HerdrHudWorkingFolder.home
    private(set) var workingFolderOptionsRevision = 0
    var selectedMachineID: String? {
        didSet {
            // Notes resolve their own machine from this shared fallback. Keep
            // the last explicit selection instead of erasing it when a fresh
            // composer starts unselected.
            if let selectedMachineID {
                userDefaults.set(selectedMachineID, forKey: Self.machineIDDefaultsKey)
            }
            guard oldValue != selectedMachineID else { return }
            // A fresh draft's explicit model belonged to the previous machine.
            // Return to the new machine's declared default instead of carrying
            // an override that machine may not offer.
            if isNewChat, modelChoiceSource == .sessionOwned, modelChoice.isExplicit,
               oldValue != nil, oldValue != selectedMachineID {
                modelChoice = .machineDefault
            }
            // A machine owns its filesystem. A fresh composer always returns
            // to that machine's home choice instead of carrying the previous
            // machine's path across the switch.
            selectedWorkingFolder = .home
            workingFolderOptionsRevision &+= 1
            mainWorkspaces = []
            loadedMainWorkspaceMachineID = nil
            mainWorkspaceErrorMessage = nil
            mainWorkspaceUnsupported = false
            // The catalog and its declared default are machine-specific. Drop
            // them on a real switch so a submission that outruns the new
            // machine's catalog (or a failed load) cannot capture the old
            // machine's model name as run metadata.
            if let selectedMachineID, modelsMachineID != selectedMachineID {
                availableModels = []
                defaultModel = nil
                modelsMachineID = nil
                didLoadCatalog = false
            }
        }
    }

    var workingFolderPath: String { selectedWorkingFolder.path }
    var workingDirectory: String? { selectedWorkingFolder.requestPath }
    var canEditWorkingFolder: Bool {
        exchanges.isEmpty && !isRunning && !isLoadingHistory && !isEnding && !hasEnded
            && promotingExchangeIDs.isEmpty
    }
    /// The HUD chip and Settings edit the same preference; @Observable
    /// propagation through the store keeps both surfaces honest.
    var selectedThinkingLevel: PiThinkingLevel {
        get { agentSettings.hudThinkingLevel }
        set { agentSettings.hudThinkingLevel = newValue }
    }

    /// Which model rules this session follows. New chats own their choice;
    /// existing conversations keep the legacy shared HUD preference.
    private(set) var modelChoiceSource: ModelChoiceSource = .sessionOwned
    /// The session-owned choice for a new chat. `.machineDefault` is the
    /// automatic selection and carries no identity until the execution
    /// companion's own catalog resolves it.
    private(set) var modelChoice: HerdrHudModelChoice = .machineDefault
    /// True only while this session has no accepted or restored conversation
    /// yet. The main-workspace checkbox and automatic local machine/model
    /// defaults apply here and nowhere else.
    var isNewChat: Bool { thread == nil && exchanges.isEmpty }

    /// Checkbox state for the current new chat. It deliberately does not leak
    /// to another composer or to an existing conversation.
    var createsInMainWorkspace = false {
        didSet {
            guard oldValue != createsInMainWorkspace else { return }
            validationError = nil
            if !createsInMainWorkspace { mainWorkspaceErrorMessage = nil }
        }
    }
    private(set) var workspaceLaunchState: WorkspaceLaunchState = .idle
    private(set) var mainWorkspaces: [HerdrWorkspace] = []
    private(set) var isLoadingMainWorkspaces = false
    private(set) var mainWorkspaceErrorMessage: String?
    private(set) var mainWorkspaceUnsupported = false
    @ObservationIgnored private var loadedMainWorkspaceMachineID: String?
    @ObservationIgnored private var modelsRequestRevision = 0
    /// True once a persisted new-scheme choice was restored. A legacy snapshot
    /// without one keeps the conversation on the shared preference.
    @ObservationIgnored private var ownsPersistedModelChoice = false
    @ObservationIgnored private var unresolvedWorkspaceRequestID: String?
    @ObservationIgnored private var unresolvedWorkspaceFingerprint: String?
    @ObservationIgnored private var unresolvedWorkspaceReceipt: HerdrHudWorkspaceLaunchReceipt?

    var selectedModel: String? {
        get {
            switch modelChoiceSource {
            case .sharedPreference:
                return agentSettings.hudModel.isEmpty ? nil : agentSettings.hudModel
            case .sessionOwned:
                return modelChoice.explicitIdentity?.fullID
            }
        }
        set {
            switch modelChoiceSource {
            case .sharedPreference:
                agentSettings.hudModel = newValue ?? ""
            case .sessionOwned:
                if let newValue, let identity = HerdrHudModelRouting.identity(fullID: newValue) {
                    modelChoice = .explicit(identity)
                } else {
                    modelChoice = .machineDefault
                }
            }
        }
    }
    var isCollapsed = true {
        didSet {
            if isCollapsed {
                responseAudioPlayer.stop()
            }
        }
    }
    private(set) var hasUnseenAnswer = false
    private(set) var elapsedSeconds = 0
    private(set) var liveStepCount = 0
    private(set) var liveSteps: [HerdrHudStep] = []
    private(set) var liveResponse: String?
    private(set) var validationError: String?
    private(set) var promoteErrorMessage: String?
    private(set) var audioErrorMessage: String?
    /// The session chip whose last answer is being spoken, and the transcript
    /// it is reading. Cached so pause/resume does not refetch.
    private(set) var sessionAudioPaneID: String?
    private(set) var loadingSessionAudioPaneID: String?
    @ObservationIgnored private var sessionAudioText: String?
    /// Which exchange the transcript-row player is speaking, so a completed
    /// playback resolves back to *that* exchange rather than whichever one
    /// happened to be promoted last.
    @ObservationIgnored private var speakingExchangeID: String?
    private(set) var voiceReplyTarget: String?
    /// The activity stamp of the answer that was read aloud. The reply offer
    /// belongs to *that* answer, so when the pane moves on the offer is stale —
    /// keying it on status alone would not notice, because a pane is `.done`
    /// both before and after it produces a new response.
    private(set) var voiceReplyTargetActivityAt: Date?
    @ObservationIgnored private var sessionAudioActivityAt: Date?
    private(set) var promotingExchangeIDs: Set<String> = []
    private(set) var availableModels: [PiAvailableModel] = []
    private(set) var defaultModel: PiModelIdentity?
    /// The machine whose catalog produced `availableModels` and `defaultModel`.
    /// A declared default is only trustworthy for that machine; metadata must
    /// keep the model unknown rather than borrow another machine's default.
    private(set) var modelsMachineID: String?
    private(set) var isLoadingModels = false
    private(set) var modelsError: String?
    private(set) var didLoadCatalog = false

    #if DEBUG
    private(set) var lastHeadlessRunForTesting: HeadlessAgentRun?
    #endif

    @ObservationIgnored private var submissionOwnerID: UUID?
    @ObservationIgnored private var cancelledSubmissionOwnerID: UUID?
    private var isPreparingSubmission: Bool { submissionOwnerID != nil }
    var isRunning: Bool { controller.isRunning || isPreparingSubmission }
    var errorMessage: String? { controller.errorMessage }

    init(
        userDefaults: UserDefaults = .standard,
        agentSettings: AgentModelSettingsStore? = nil,
        persistenceURL: URL? = nil,
        promptSettings: HerdrPromptSettingsStore? = nil,
        modelFavorites: ModelFavoritesStore? = nil,
        workingFolderStore: HerdrHudWorkingFolderStore? = nil,
        hostIdentity: HerdrHudHostIdentity? = nil,
        hostIdentityProvider: HostIdentityProvider? = nil,
        mainWorkspaceStore: HerdrHudMainWorkspaceStore? = nil,
        workspaceLauncherFactory: WorkspaceLauncherFactory? = nil
    ) {
        self.userDefaults = userDefaults
        self.injectedHostIdentity = hostIdentity
        self.hostIdentityProvider = hostIdentityProvider
        self.workingFolderStore = workingFolderStore ?? HerdrHudWorkingFolderStore(userDefaults: userDefaults)
        self.mainWorkspaceStore = mainWorkspaceStore ?? HerdrHudMainWorkspaceStore(userDefaults: userDefaults)
        self.workspaceLauncherFactory = workspaceLauncherFactory ?? { model, machineID in
            HerdrHudWorkspaceLauncher(client: try model.hudChatClient(machineID: machineID))
        }
        let storeURL = persistenceURL ?? HerdrHudPersistenceStore.defaultFileURL()
        self.storeURL = storeURL
        self.attachmentDirectory = storeURL.deletingPathExtension().appendingPathExtension("attachments")
        self.agentSettings = agentSettings ?? AgentModelSettingsStore(defaults: userDefaults)
        self.promptSettings = promptSettings ?? HerdrPromptSettingsStore(defaults: userDefaults)
        self.modelFavorites = modelFavorites ?? ModelFavoritesStore(userDefaults: userDefaults)
        self.persistence = HerdrHudPersistenceStore(
            fileURL: persistenceURL ?? HerdrHudPersistenceStore.defaultFileURL()
        )
        responseAudioPlayer.onPlaybackCompleted = { [weak self] in
            self?.captureVoiceReplyTarget()
        }
        let persistence = self.persistence
        restoreTask = Task { [weak self, persistence] in
            guard let snapshot = await persistence.load(), !Task.isCancelled else { return }
            self?.restore(snapshot)
        }
    }

    deinit {
        elapsedTask?.cancel()
        restoreTask?.cancel()
        historyObservationTask?.cancel()
        terminalMetadataReconciliationTask?.cancel()
    }

    func makeIndependentSession(id: String) -> HerdrHudSession {
        HerdrHudSession(userDefaults: userDefaults, agentSettings: agentSettings,
                        persistenceURL: storeURL.deletingLastPathComponent()
                            .appendingPathComponent("hud-chats", isDirectory: true)
                            .appendingPathComponent("\(id).json"),
                        promptSettings: promptSettings, modelFavorites: modelFavorites,
                        workingFolderStore: workingFolderStore,
                        hostIdentity: injectedHostIdentity,
                        hostIdentityProvider: hostIdentityProvider,
                        mainWorkspaceStore: mainWorkspaceStore,
                        workspaceLauncherFactory: workspaceLauncherFactory)
    }

    /// This Mac's host evidence, resolved at most once and only when a fresh
    /// composer actually needs to identify itself. Creating a session stays
    /// cheap, and a caller-provided identity is never re-resolved.
    private var hostIdentity: HerdrHudHostIdentity {
        if let cachedHostIdentity { return cachedHostIdentity }
        let identity = injectedHostIdentity ?? hostIdentityProvider?() ?? .current()
        cachedHostIdentity = identity
        return identity
    }

    func waitForPersistenceRestore() async { await restoreTask?.value }

    /// The built-in home choice is always first. A restored chat may retain a
    /// path that is no longer in the fresh-composer list, so keep that path
    /// visible while the chat is read-only.
    func workingFolderOptions(for machineID: String?) -> [HerdrHudWorkingFolder] {
        _ = workingFolderOptionsRevision
        guard let machineID, !machineID.isEmpty else { return [.home] }
        var options = [HerdrHudWorkingFolder.home]
        options.append(contentsOf: workingFolderStore.customFolders(for: machineID))
        if selectedMachineID == machineID, !options.contains(selectedWorkingFolder) {
            options.append(selectedWorkingFolder)
        }
        return options
    }

    func customWorkingFolders(for machineID: String) -> [HerdrHudWorkingFolder] {
        _ = workingFolderOptionsRevision
        return workingFolderStore.customFolders(for: machineID)
    }

    @discardableResult
    func selectWorkingFolder(path rawPath: String, for machineID: String? = nil) -> Bool {
        guard canEditWorkingFolder,
              selectedMachineID == nil || machineID == nil || selectedMachineID == machineID,
              let path = HerdrHudWorkingFolder.normalizedPath(rawPath)
        else { return false }
        let targetMachineID = machineID ?? selectedMachineID
        guard path == HerdrHudWorkingFolder.homePath
                || targetMachineID.map({ workingFolderStore.customFolders(for: $0).contains { $0.path == path } }) == true
        else { return false }
        if selectedMachineID == nil, let machineID {
            selectedMachineID = machineID
        }
        selectedWorkingFolder = HerdrHudWorkingFolder(path: path)
        return true
    }

    @discardableResult
    func addCustomWorkingFolder(path: String, machineID: String) throws -> HerdrHudWorkingFolder {
        let folder = try workingFolderStore.add(path: path, for: machineID)
        workingFolderOptionsRevision &+= 1
        if selectedMachineID == nil {
            selectedMachineID = machineID
        }
        if selectedMachineID == machineID, canEditWorkingFolder {
            selectedWorkingFolder = folder
        }
        return folder
    }

    @discardableResult
    func removeCustomWorkingFolder(path: String, machineID: String) -> Bool {
        guard workingFolderStore.remove(path: path, for: machineID) else { return false }
        workingFolderOptionsRevision &+= 1
        if canEditWorkingFolder, selectedMachineID == machineID, selectedWorkingFolder.path == path {
            selectedWorkingFolder = .home
        }
        return true
    }

    /// Starts every fresh composer at the target machine's home choice. This
    /// is intentionally not a "last used folder" preference.
    func resetWorkingFolderForNewChat() {
        guard exchanges.isEmpty else { return }
        selectedWorkingFolder = .home
    }

    /// The machine an existing conversation already belongs to, if any. A
    /// fresh composer has none and resolves this Mac instead.
    var conversationMachineID: String? {
        thread?.machineID ?? exchanges.first?.machineID
    }

    /// Chooses the initial machine for a genuinely new composer exactly once.
    /// A prior explicit choice is preserved; otherwise the uniquely identified
    /// local companion wins; otherwise the composer waits for an explicit
    /// choice instead of falling back to roster order.
    @discardableResult
    func applyLocalMachineDefaultIfNeeded(in model: HerdrAppModel) -> Bool {
        guard isNewChat else { return false }
        if let selectedMachineID, model.machines.contains(where: { $0.id == selectedMachineID }) {
            return false
        }
        guard let local = resolvedLocalMachine(in: model) else { return false }
        selectedMachineID = local.id
        return true
    }

    /// The unique configured machine that is this Mac, or nil when host
    /// evidence is missing or ambiguous. Demo mode is synthetic by definition.
    func resolvedLocalMachine(in model: HerdrAppModel) -> HerdrMachine? {
        if model.isDemoMode { return model.machines.first }
        return HerdrHudNewChatPolicy(hostIdentity: hostIdentity).localMachine(in: model.machines)
    }

    /// Resets a composer that has not been used yet: this Mac's machine, the
    /// selected machine's declared default model, home folder, and an
    /// unchecked workspace toggle. Never touches shared preferences.
    @discardableResult
    func resetForNewChat() -> Bool {
        guard isNewChat else { return false }
        modelChoiceSource = .sessionOwned
        modelChoice = .machineDefault
        ownsPersistedModelChoice = false
        createsInMainWorkspace = false
        workspaceLaunchState = .idle
        mainWorkspaces = []
        mainWorkspaceErrorMessage = nil
        mainWorkspaceUnsupported = false
        loadedMainWorkspaceMachineID = nil
        unresolvedWorkspaceRequestID = nil
        unresolvedWorkspaceFingerprint = nil
        unresolvedWorkspaceReceipt = nil
        selectedMachineID = nil
        selectedWorkingFolder = .home
        return true
    }

    /// The machine this session's composer or conversation displays. A fresh
    /// composer has no roster-order fallback, so an unidentified Mac asks the
    /// user instead of silently choosing the first machine.
    func selectedMachine(in model: HerdrAppModel) -> HerdrMachine? {
        if let selectedMachineID,
           let machine = model.machines.first(where: { $0.id == selectedMachineID }) {
            return machine
        }
        if let conversationMachineID,
           let machine = model.machines.first(where: { $0.id == conversationMachineID }) {
            return machine
        }
        return nil
    }

    /// The saved main-workspace designation for the selected companion, if the
    /// paired endpoint still matches.
    func mainWorkspaceDestination(in model: HerdrAppModel) -> HerdrHudMainWorkspaceDestination? {
        selectedMachine(in: model).flatMap { mainWorkspaceStore.destination(for: $0) }
    }

    /// The exact saved workspace while it is still present in the selected
    /// companion's current topology. Matching is by raw workspace ID.
    func mainWorkspace(in model: HerdrAppModel) -> HerdrWorkspace? {
        guard let machine = selectedMachine(in: model),
              let destination = mainWorkspaceStore.destination(for: machine) else { return nil }
        return mainWorkspaces.first {
            $0.workspaceID == destination.workspaceID
                && ($0.machineID.isEmpty || $0.machineID == machine.id)
        }
    }

    /// Records an explicit main-workspace choice for the selected companion.
    @discardableResult
    func selectMainWorkspace(_ workspace: HerdrWorkspace, in model: HerdrAppModel) -> Bool {
        guard isNewChat, let machine = selectedMachine(in: model) else { return false }
        return mainWorkspaceStore.remember(workspace: workspace, for: machine) != nil
    }

    /// Reads the selected companion's capability and workspace topology for
    /// the new-chat destination picker. This is a read-only preflight: nothing
    /// is created until Send, and a machine switch drops the previous
    /// machine's list instead of reusing it.
    func loadMainWorkspaces(model: HerdrAppModel, force: Bool = false) async {
        guard isNewChat, !model.isDemoMode else { return }
        guard let machineID = resolvedMachineIDReadOnly(in: model) else {
            mainWorkspaces = []
            loadedMainWorkspaceMachineID = nil
            mainWorkspaceErrorMessage = nil
            mainWorkspaceUnsupported = false
            return
        }
        if !force,
           loadedMainWorkspaceMachineID == machineID,
           !isLoadingMainWorkspaces,
           mainWorkspaceErrorMessage == nil {
            return
        }
        isLoadingMainWorkspaces = true
        mainWorkspaceErrorMessage = nil
        defer { isLoadingMainWorkspaces = false }
        do {
            let client = try model.hudChatClient(machineID: machineID)
            let capabilities = try await client.serverCapabilities()
            guard resolvedMachineIDReadOnly(in: model) == machineID else { return }
            guard capabilities.supportsQuickSessionLaunchOptions else {
                mainWorkspaces = []
                loadedMainWorkspaceMachineID = machineID
                mainWorkspaceUnsupported = true
                return
            }
            let response = try await client.fetchWorkspaces()
            guard resolvedMachineIDReadOnly(in: model) == machineID else { return }
            guard response.ok else {
                mainWorkspaceErrorMessage = "This machine's workspaces could not be read. Try again."
                return
            }
            mainWorkspaces = response.workspaces.filter {
                $0.machineID.isEmpty || $0.machineID == machineID
            }
            loadedMainWorkspaceMachineID = machineID
            mainWorkspaceUnsupported = false
        } catch {
            guard resolvedMachineIDReadOnly(in: model) == machineID else { return }
            mainWorkspaceErrorMessage = error.localizedDescription
            mainWorkspaceUnsupported = false
        }
    }

    /// The pane that should be opened for a confirmed workspace launch, if the
    /// companion ever named one.
    func workspaceLaunchPaneIDForOpening() -> String? {
        switch workspaceLaunchState {
        case let .sent(receipt): receipt.scopedPaneID
        case let .needsRecovery(_, receipt): receipt?.scopedPaneID
        case .idle, .launching: nil
        }
    }

    var workspaceLaunchReceipt: HerdrHudWorkspaceLaunchReceipt? {
        switch workspaceLaunchState {
        case let .sent(receipt): receipt
        case let .needsRecovery(_, receipt): receipt
        case .idle, .launching: nil
        }
    }

    var workspaceLaunchRecoveryMessage: String? {
        guard case let .needsRecovery(message, _) = workspaceLaunchState else { return nil }
        return message
    }

    /// Clears a recovery banner without consuming the draft. An unconfirmed
    /// create stays retryable with its original request ID; a confirmed pane
    /// keeps the launcher's refusal to resend the uncertain prompt.
    func dismissWorkspaceLaunchRecovery() {
        guard case .needsRecovery = workspaceLaunchState else { return }
        workspaceLaunchState = .idle
        validationError = nil
    }

    /// Explicitly abandons an unresolved workspace launch. The durable
    /// launcher receipt remains, so callers present this as a deliberate
    /// discard rather than a retry.
    func discardUnresolvedWorkspaceLaunch() {
        workspaceLaunchState = .idle
        unresolvedWorkspaceRequestID = nil
        unresolvedWorkspaceFingerprint = nil
        unresolvedWorkspaceReceipt = nil
        draft = ""
        pendingAttachments = []
        pendingQuotes = []
        pruneStoredAttachments()
        validationError = nil
    }

    var historyIdentity: String? {
        if let thread { return "\(thread.machineID):\(thread.rootRunID)" }
        guard let exchange = exchanges.first, !exchange.id.hasPrefix("hud-") else { return nil }
        return "\(exchange.machineID):\(historyRootRunID ?? exchange.id)"
    }

    /// The submission placeholder whose accepted run established
    /// `historyIdentity`, if this session observed that acceptance or adopted
    /// the placeholder from saved history. Pending-title adoption may attach a
    /// title only to this exact submission.
    func acceptedSubmissionID(forHistoryIdentity historyIdentity: String) -> String? {
        acceptedSubmissionIDsByHistoryIdentity[historyIdentity]
    }

    private enum HistoryRefreshKind {
        case forced
        case passive
    }

    @discardableResult
    func refreshSavedHistory(model: HerdrAppModel) async -> Bool {
        await refreshSavedHistory(model: model, kind: .forced, submissionOwnerID: nil)
    }

    #if DEBUG
    @discardableResult
    func refreshSavedHistoryPassivelyForTesting(model: HerdrAppModel) async -> Bool {
        await refreshSavedHistory(model: model, kind: .passive, submissionOwnerID: nil)
    }
    #endif

    private func refreshSavedHistory(
        model: HerdrAppModel,
        kind: HistoryRefreshKind,
        submissionOwnerID ownerID: UUID?
    ) async -> Bool {
        let ownsSubmission = ownerID != nil && ownerID == submissionOwnerID
        guard !hasEnded, !model.isDemoMode, (!isRunning || ownsSubmission), !isLoadingHistory,
              promotingExchangeIDs.isEmpty, let thread,
              model.canControl(machineID: thread.machineID) else { return false }
        do {
            try await openHistory(
                id: thread.rootRunID,
                machineID: thread.machineID,
                model: model,
                kind: kind,
                submissionOwnerID: ownerID
            )
            if kind == .forced { validationError = nil }
            return true
        } catch {
            if kind == .forced || validationError == nil {
                validationError = "Couldn’t refresh this saved chat: \(error.localizedDescription)"
            }
            return false
        }
    }

    /// A selected HUD card owns this task through SwiftUI. Leaving or switching
    /// cards cancels it, so saved chats never create a process-wide poller.
    func observeSavedHistoryWhileVisible(
        model: HerdrAppModel,
        interval: Duration = .seconds(5)
    ) async {
        guard thread != nil, !model.isDemoMode else { return }
        while !Task.isCancelled {
            guard thread != nil, !isEnding, !hasEnded else { return }
            _ = await refreshSavedHistory(model: model, kind: .passive, submissionOwnerID: nil)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    func markSeen() {
        guard hasUnseenAnswer else { return }
        hasUnseenAnswer = false
        Task { await schedulePersistenceSave() }
    }

    func addAttachments(_ urls: [URL]) {
        validationError = nil
        for url in urls {
            guard pendingAttachments.count < Self.maxAttachments else {
                validationError = "You can attach up to 4 files."
                return
            }

            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let fileSize = values.fileSize else {
                    validationError = "\(url.lastPathComponent) is not a readable file."
                    continue
                }
                guard HerdrAttachmentTypes.isAllowed(url) else {
                    validationError = "\(url.lastPathComponent) isn't a supported file type."
                    continue
                }
                guard fileSize > 0 else {
                    validationError = "\(url.lastPathComponent) is empty."
                    continue
                }
                guard Int64(fileSize) <= AttachmentPolicy.maximumFileBytes else {
                    validationError = "\(url.lastPathComponent) is larger than 20 MB."
                    continue
                }
                let currentTotal = pendingAttachments.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
                guard currentTotal + Int64(fileSize) <= Self.maxCombinedAttachmentBytes else {
                    validationError = "Attachments can total up to 21 MB per message."
                    continue
                }
                let attachmentID = UUID()
                let directory = attachmentDirectory.appendingPathComponent(attachmentID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let retainedURL = directory.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: retainedURL)
                pendingAttachments.append(
                    HerdrHudAttachment(
                        id: attachmentID,
                        url: retainedURL,
                        filename: url.lastPathComponent,
                        byteCount: fileSize,
                        isImage: HerdrAttachmentTypes.isImage(url)
                    )
                )
            } catch {
                validationError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func addQuote(_ quote: ChatQuote) {
        pendingQuotes.append(quote)
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        pruneStoredAttachments()
    }

    func reportAttachmentError(_ message: String) {
        validationError = message
    }

    #if DEBUG
    func seedExchangesForTesting(_ exchanges: [HerdrHudExchange]) {
        self.exchanges = exchanges
        markExchangesChanged()
    }

    func appendExchangeForTesting(_ exchange: HerdrHudExchange) {
        append(exchange)
    }

    func seedThreadForTesting(_ thread: HerdrHudThread?) {
        self.thread = thread
    }

    func waitForPersistenceRestoreForTesting() async {
        await restoreTask?.value
    }

    /// Awaits the bounded terminal reconciliation window, so a test can prove
    /// the window ended instead of inferring its bound from elapsed time.
    func awaitTerminalMetadataReconciliationForTesting() async {
        await terminalMetadataReconciliationTask?.value
    }

    /// The exact file this session debounces into, so a test can prove a
    /// corrected metadata aggregate reached disk rather than only memory.
    var persistenceURLForTesting: URL { storeURL }

    func seedModelsForTesting(
        _ models: [PiAvailableModel],
        default defaultModel: PiModelIdentity?,
        machineID: String? = nil
    ) {
        availableModels = models
        self.defaultModel = defaultModel
        modelsMachineID = machineID ?? selectedMachineID
        didLoadCatalog = true
    }

    func seedMainWorkspacesForTesting(_ workspaces: [HerdrWorkspace]) {
        mainWorkspaces = workspaces
        loadedMainWorkspaceMachineID = selectedMachineID
    }

    func setWorkspaceLaunchStateForTesting(_ state: WorkspaceLaunchState) {
        workspaceLaunchState = state
    }
    #endif

    func submit(model: HerdrAppModel, onStarted: () -> Void = {}) async {
        guard !isEnding, !hasEnded else { return }
        if createsInMainWorkspace, isNewChat {
            await submitToMainWorkspace(model: model, onStarted: onStarted)
            return
        }
        let draftSnapshot = draft
        let enteredPrompt = draftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        let quotesToSend = pendingQuotes
        guard !enteredPrompt.isEmpty || !attachmentsToSend.isEmpty || !quotesToSend.isEmpty else { return }
        guard !isRunning, !isLoadingHistory, promotingExchangeIDs.isEmpty,
              !exchanges.contains(where: { $0.promotedPaneID != nil }) else {
            if isRunning, !isPreparingSubmission {
                validationError = "Wait for this saved chat’s current reply before sending another message."
            }
            return
        }
        guard let machineID = resolvedMachineID(in: model) else {
            validationError = isNewChat
                ? "Choose the machine that should run this chat."
                : "No machine is available for the HUD."
            return
        }
        guard model.canControl(machineID: machineID) else {
            validationError = "This machine is not connected."
            return
        }
        let ownerID = UUID()
        submissionOwnerID = ownerID
        defer {
            if submissionOwnerID == ownerID { submissionOwnerID = nil }
            if cancelledSubmissionOwnerID == ownerID { cancelledSubmissionOwnerID = nil }
        }

        beginSessionActivity()
        validationError = nil
        promoteErrorMessage = nil
        audioErrorMessage = nil

        var refreshedHistory = false
        if !model.isDemoMode && (needsHistoryRefresh || thread?.machineID == machineID) {
            guard await refreshSavedHistory(
                model: model,
                kind: .forced,
                submissionOwnerID: ownerID
            ) else {
                validationError = validationError
                    ?? "Reconnect to this chat’s machine to check its previous run before replying."
                return
            }
            refreshedHistory = true
            guard !submissionWasCancelled(ownerID) else { return }
            guard !isLoadingHistory, promotingExchangeIDs.isEmpty,
                  !exchanges.contains(where: { $0.promotedPaneID != nil }),
                  controller.isRunning == false else {
                if controller.isRunning {
                    validationError = "Another device is already waiting for a reply in this saved chat. Your draft is unchanged."
                }
                return
            }
        }
        if needsHistoryRefresh && !refreshedHistory {
            validationError = "Reconnect to this chat’s machine to check its previous run before replying."
            return
        }
        guard selectedMachineID == machineID else {
            validationError = "The selected machine changed while preparing this message. Your draft is unchanged."
            return
        }

        let isNewRoot = thread?.machineID != machineID
        let workingFolder = submissionWorkingFolder(for: machineID)
        if isNewRoot && !workingFolder.isHome {
            do {
                try await model.requireDurableHUD(
                    machineID: machineID,
                    requiresWorkingDirectory: true
                )
            } catch {
                if !submissionWasCancelled(ownerID) { validationError = error.localizedDescription }
                return
            }
            guard !submissionWasCancelled(ownerID) else { return }
            guard selectedMachineID == machineID else {
                validationError = "The selected machine changed while preparing this message. Your draft is unchanged."
                return
            }
        }
        guard attachmentsToSend.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= Self.maxCombinedAttachmentBytes else {
            validationError = "Attachments can total up to 21 MB per message."
            return
        }

        let basePrompt = enteredPrompt.isEmpty && quotesToSend.isEmpty ? "Please review the attached files." : enteredPrompt
        let prompt = ChatQuote.prompt(basePrompt, quotes: quotesToSend)
        let attachmentFilenames = attachmentsToSend.map(\.filename)
        let hasAttachments = !attachmentsToSend.isEmpty
        let hasImageAttachments = attachmentsToSend.contains(where: \.isImage)
        let agentModel: String?
        let metadataModelName: String?
        if modelChoiceSource == .sessionOwned {
            // Fresh and session-owned chats pin the selected machine's own
            // declared default (or the exact override) before dispatch. An
            // image-bearing new chat never silently reroutes to the global
            // vision model.
            do {
                let resolved = try await resolveModelForSession(
                    machineID: machineID,
                    model: model,
                    hasImageAttachments: hasImageAttachments
                )
                agentModel = resolved.identity.fullID
                metadataModelName = resolved.displayName
                    ?? PiModelDisplayName.short(fullID: resolved.identity.fullID)
            } catch {
                if !submissionWasCancelled(ownerID) { validationError = error.localizedDescription }
                return
            }
            guard !submissionWasCancelled(ownerID) else { return }
            guard selectedMachineID == machineID, model.canControl(machineID: machineID) else {
                validationError = "The selected machine changed while preparing this message. Your draft is unchanged."
                return
            }
        } else {
            let catalogIsForMachine = modelsMachineID == machineID
            let resolution = AgentModelResolver.resolve(
                preference: selectedModel,
                catalog: catalogIsForMachine ? availableModels : [],
                isCatalogAuthoritative: catalogIsForMachine && didLoadCatalog
            )
            agentModel = HerdrHudModelRouting.model(
                selection: resolution.modelID,
                selectionSupportsImages: selectedModelSupportsImages(on: machineID),
                hasImageAttachments: hasImageAttachments,
                visionModel: agentSettings.effectiveVisionModel
            )
            if resolution.preferenceIsUnavailable {
                validationError = "\(selectedModel ?? "") isn't offered by this machine — using its default model."
            }
            metadataModelName = modelLabel(for: agentModel, on: machineID)
        }
        let thinkingLevel = agentSettings.hudThinkingLevel.rawValue
        let label = metadataModelName ?? "default"
        let pendingID = "hud-pending-\(UUID().uuidString)"
        let submittedAt = Date.now
        let continueFromRunId = thread?.machineID == machineID ? thread?.lastRunID : nil
        append(
            HerdrHudExchange(
                id: pendingID,
                machineID: machineID,
                prompt: prompt,
                sentPrompt: prompt,
                response: nil,
                error: nil,
                status: .running,
                costUSD: nil,
                createdAt: submittedAt,
                promotedPaneID: nil,
                attachmentFilenames: attachmentFilenames,
                workingFolderPath: workingFolder.path,
                localAttachments: attachmentsToSend,
                modelLabel: label,
                modelLabelIsProven: metadataModelName != nil
            )
        )
        consumeComposerSnapshot(
            draft: draftSnapshot,
            attachments: attachmentsToSend,
            quotes: quotesToSend
        )
        hasUnseenAnswer = false
        onStarted()

        let wireAttachments: [HeadlessAgentAttachment]
        do {
            wireAttachments = attachmentsToSend.isEmpty ? [] : try await Task.detached(priority: .userInitiated) {
                try attachmentsToSend.map { attachment in
                    let accessed = attachment.url.startAccessingSecurityScopedResource()
                    defer { if accessed { attachment.url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: attachment.url)
                    return HeadlessAgentAttachment(
                        filename: attachment.filename,
                        dataBase64: data.base64EncodedString()
                    )
                }
            }.value
        } catch {
            guard let index = exchanges.firstIndex(where: { $0.id == pendingID }) else {
                controller.reset()
                return
            }
            exchanges[index].status = .failed
            hasUnseenAnswer = isCollapsed
            exchanges[index].error = "Couldn't read \(attachmentsToSend.first?.filename ?? "attachment"): \(error.localizedDescription)"
            markExchangesChanged()
            restoreDraftAfterFailedStart(enteredPrompt, quotes: quotesToSend, attachments: attachmentsToSend)
            controller.reset()
            await schedulePersistenceSave()
            return
        }
        guard !submissionWasCancelled(ownerID) else {
            if let index = exchanges.firstIndex(where: { $0.id == pendingID }) {
                exchanges.remove(at: index)
                markExchangesChanged()
            }
            restoreDraftAfterFailedStart(enteredPrompt, quotes: quotesToSend, attachments: attachmentsToSend)
            await schedulePersistenceSave()
            return
        }

        let run = await submitAndWait(
            prompt: prompt,
            machineID: machineID,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: hasAttachments ? wireAttachments : nil,
            continueFromRunId: continueFromRunId,
            workingFolderPath: workingFolder.path,
            includesWorkingDirectory: isNewRoot,
            capabilitiesChecked: isNewRoot && !workingFolder.isHome,
            submissionOwnerID: ownerID,
            submissionID: pendingID,
            submissionModelName: metadataModelName,
            model: model
        )
        guard let index = exchanges.firstIndex(where: { $0.id == pendingID }) else {
            controller.reset()
            return
        }
        if run == nil, submissionWasCancelled(ownerID) {
            controller.reset()
            exchanges.remove(at: index)
            markExchangesChanged()
            restoreDraftAfterFailedStart(enteredPrompt, quotes: quotesToSend, attachments: attachmentsToSend)
            await schedulePersistenceSave()
            return
        }
        guard let run else {
            let submissionStatus = controller.lastErrorStatus
            let message = controller.errorMessage ?? validationError ?? "The run failed to start."
            controller.reset()
            restoreDraftAfterFailedStart(enteredPrompt, quotes: quotesToSend, attachments: attachmentsToSend)
            if submissionStatus == 409 && continueFromRunId != nil {
                exchanges.remove(at: index)
                markExchangesChanged()
                needsHistoryRefresh = true
                if await refreshSavedHistory(model: model, kind: .forced, submissionOwnerID: ownerID) {
                    validationError = "This saved chat changed on another device. Latest messages were loaded and your draft was kept; review it before sending again."
                }
            } else {
                hasUnseenAnswer = isCollapsed
                exchanges[index] = HerdrHudExchange(
                    id: pendingID,
                    machineID: machineID,
                    prompt: prompt,
                    sentPrompt: prompt,
                    response: nil,
                    error: message,
                    status: .failed,
                    costUSD: nil,
                    createdAt: submittedAt,
                    promotedPaneID: nil,
                    attachmentFilenames: attachmentFilenames,
                    workingFolderPath: workingFolder.path,
                    attachments: wireAttachments,
                    localAttachments: attachmentsToSend,
                    modelLabel: label,
                    modelLabelIsProven: metadataModelName != nil
                )
                markExchangesChanged()
                await schedulePersistenceSave()
            }
            return
        }

        #if DEBUG
        lastHeadlessRunForTesting = run
        #endif

        let isSuccess = run.status == .completed || run.status == .promoted
        let retainedAttachments = isSuccess ? [] : wireAttachments
        let resolvedWorkingFolderPath = run.cwd.flatMap(HerdrHudWorkingFolder.normalizedPath)
            ?? workingFolder.path
        exchanges[index] = HerdrHudExchange(
            id: run.id,
            machineID: machineID,
            prompt: prompt,
            sentPrompt: prompt,
            response: run.response,
            error: run.error,
            status: run.status,
            costUSD: run.costUSD,
            createdAt: submittedAt,
            promotedPaneID: run.promotedPaneID,
            attachmentFilenames: attachmentFilenames,
            workingFolderPath: resolvedWorkingFolderPath,
            attachments: retainedAttachments,
            localAttachments: attachmentsToSend,
            modelLabel: label,
            modelLabelIsProven: metadataModelName != nil,
            steps: Self.hudSteps(from: run.steps ?? []),
            stepsTruncated: run.stepsTruncated == true
        )
        selectedWorkingFolder = HerdrHudWorkingFolder(path: resolvedWorkingFolderPath)
        markExchangesChanged()
        savedHistoryRunKeys.insert("\(machineID):\(run.id)")
        if run.status != .promoted {
            let rootRunID = run.threadRootRunId ?? run.id
            let turnCount: Int
            if let thread,
               thread.machineID == machineID,
               thread.rootRunID == rootRunID {
                turnCount = thread.turnCount + (thread.lastRunID == run.id ? 0 : 1)
            } else {
                turnCount = 1
            }
            thread = HerdrHudThread(
                machineID: machineID,
                rootRunID: rootRunID,
                lastRunID: run.id,
                turnCount: turnCount
            )
        }
        if let root = thread?.rootRunID {
            workingFolderStore.remember(
                folder: selectedWorkingFolder,
                for: machineID,
                chatID: root
            )
        }
        if run.status.isTerminal, isCollapsed {
            hasUnseenAnswer = true
        }
        controller.reset()
        await schedulePersistenceSave()
    }

    /// Creates a new chat directly in the user's remembered main workspace on
    /// the selected companion, then submits the initial text, quotes, and
    /// uploaded attachments there exactly once. No headless HUD conversation
    /// is created and no later promotion is needed.
    private func submitToMainWorkspace(model: HerdrAppModel, onStarted: () -> Void) async {
        guard isNewChat, !isEnding, !hasEnded else { return }
        let draftSnapshot = draft
        let enteredPrompt = draftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        let quotesToSend = pendingQuotes
        guard !enteredPrompt.isEmpty || !attachmentsToSend.isEmpty || !quotesToSend.isEmpty else { return }
        guard !isRunning, !isLoadingHistory, promotingExchangeIDs.isEmpty,
              !exchanges.contains(where: { $0.promotedPaneID != nil }) else {
            if isRunning, !isPreparingSubmission {
                validationError = "Wait for this saved chat’s current reply before sending another message."
            }
            return
        }
        guard let machineID = resolvedMachineID(in: model),
              let machine = model.machines.first(where: { $0.id == machineID }) else {
            validationError = "Choose the machine that should create this chat."
            return
        }
        guard model.canControl(machineID: machineID) else {
            validationError = "This machine is not connected."
            return
        }
        guard attachmentsToSend.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= Self.maxCombinedAttachmentBytes else {
            validationError = "Attachments can total up to 21 MB per message."
            return
        }

        let ownerID = UUID()
        submissionOwnerID = ownerID
        defer {
            if submissionOwnerID == ownerID { submissionOwnerID = nil }
            if cancelledSubmissionOwnerID == ownerID { cancelledSubmissionOwnerID = nil }
        }
        beginSessionActivity()
        validationError = nil
        promoteErrorMessage = nil
        audioErrorMessage = nil
        workspaceLaunchState = .launching

        // The picker's cached topology is used without another request when it
        // already describes this machine; otherwise read it before dispatch.
        await loadMainWorkspaces(model: model, force: loadedMainWorkspaceMachineID != machineID)
        guard !submissionWasCancelled(ownerID) else {
            workspaceLaunchState = .idle
            return
        }
        guard selectedMachineID == machineID else {
            workspaceLaunchState = .idle
            validationError = "The selected machine changed while preparing this message. Your draft is unchanged."
            return
        }
        if mainWorkspaceUnsupported {
            workspaceLaunchState = .idle
            validationError = HerdrHudWorkspaceLaunchError
                .unsupportedCompanion(machineName: machine.name).localizedDescription
            return
        }
        if let mainWorkspaceErrorMessage {
            workspaceLaunchState = .idle
            validationError = mainWorkspaceErrorMessage
            return
        }
        guard let destination = mainWorkspaceStore.destination(for: machine) else {
            workspaceLaunchState = .idle
            validationError = "Choose the main workspace for this machine before sending."
            return
        }
        guard let workspace = mainWorkspaces.first(where: { candidate in
            candidate.workspaceID == destination.workspaceID
                && (candidate.machineID.isEmpty || candidate.machineID == machine.id)
        }) else {
            workspaceLaunchState = .idle
            validationError = HerdrHudWorkspaceLaunchError.workspaceUnavailable.localizedDescription
            return
        }

        let hasImageAttachments = attachmentsToSend.contains(where: \.isImage)
        let resolved: (identity: PiModelIdentity, displayName: String?)
        do {
            resolved = try await resolveModelForSession(
                machineID: machineID,
                model: model,
                hasImageAttachments: hasImageAttachments
            )
        } catch {
            workspaceLaunchState = .idle
            if !submissionWasCancelled(ownerID) { validationError = error.localizedDescription }
            return
        }
        guard !submissionWasCancelled(ownerID) else {
            workspaceLaunchState = .idle
            return
        }
        guard selectedMachineID == machineID, model.canControl(machineID: machineID) else {
            workspaceLaunchState = .idle
            validationError = "The selected machine changed while preparing this message. Your draft is unchanged."
            return
        }

        let basePrompt = enteredPrompt.isEmpty && quotesToSend.isEmpty ? "Please review the attached files." : enteredPrompt
        let prompt = ChatQuote.prompt(basePrompt, quotes: quotesToSend)
        let requestID = unresolvedWorkspaceRequestID ?? UUID().uuidString
        let submission = HerdrHudWorkspaceLaunchSubmission(
            machineID: machineID,
            endpoint: machine.urlString,
            machineName: machine.name,
            workspaceID: workspace.workspaceID,
            workspaceLabel: workspace.label,
            requestID: requestID,
            label: Self.workspaceChatLabel(for: enteredPrompt),
            folder: selectedWorkingFolder,
            model: resolved.identity,
            thinkingLevel: selectedThinkingLevel,
            prompt: prompt,
            attachments: attachmentsToSend
        )
        if let unresolvedWorkspaceFingerprint,
           unresolvedWorkspaceFingerprint != submission.fingerprint {
            // The previous attempt's content is frozen: resending changed
            // content under a new request ID could duplicate an unconfirmed
            // create. The user must open the possible chat or start over.
            workspaceLaunchState = .needsRecovery(
                message: "A previous send from this draft used different content. Open the chat it may have created, or start a new chat instead of sending again.",
                receipt: unresolvedWorkspaceReceipt
            )
            return
        }
        unresolvedWorkspaceRequestID = requestID
        unresolvedWorkspaceFingerprint = submission.fingerprint

        let launcher: HerdrHudWorkspaceLauncher
        do {
            launcher = try workspaceLauncherFactory(model, machineID)
        } catch {
            workspaceLaunchState = .idle
            if !submissionWasCancelled(ownerID) { validationError = error.localizedDescription }
            return
        }
        do {
            let receipt = try await launcher.launch(submission)
            guard !submissionWasCancelled(ownerID) else {
                workspaceLaunchState = .idle
                return
            }
            unresolvedWorkspaceRequestID = nil
            unresolvedWorkspaceFingerprint = nil
            unresolvedWorkspaceReceipt = nil
            workspaceLaunchState = .sent(receipt)
            consumeComposerSnapshot(
                draft: draftSnapshot,
                attachments: attachmentsToSend,
                quotes: quotesToSend
            )
            hasUnseenAnswer = false
            onStarted()
        } catch let error as HerdrHudWorkspaceLaunchError {
            if let receipt = error.confirmedReceipt {
                unresolvedWorkspaceReceipt = receipt
                workspaceLaunchState = .needsRecovery(
                    message: error.localizedDescription,
                    receipt: receipt
                )
            } else {
                workspaceLaunchState = .idle
                validationError = error.localizedDescription
            }
        } catch {
            workspaceLaunchState = .idle
            validationError = error.localizedDescription
        }
    }

    private static func workspaceChatLabel(for prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HUD chat" : String(trimmed.prefix(120))
    }

    func stop(model: HerdrAppModel) async {
        guard !isEnding, !hasEnded else { return }
        if let ownerID = submissionOwnerID, controller.run == nil {
            cancelledSubmissionOwnerID = ownerID
            return
        }
        await controller.cancel(model: model)
    }

    /// Ending is not deletion or promotion. Confirm a terminal run and retain
    /// server history before the collection removes this chat's local bubble.
    func endChat(model: HerdrAppModel, timeout: Duration = .seconds(30)) async throws {
        guard !hasEnded else { return }
        guard !isEnding, promotingExchangeIDs.isEmpty else {
            throw HerdrHudChatEndError.busy
        }
        isEnding = true
        validationError = nil
        defer { isEnding = false }
        do {
            try await finishForEndChat(model: model, timeout: timeout)
        } catch {
            validationError = error.localizedDescription
            throw error
        }
    }

    private func finishForEndChat(model: HerdrAppModel, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while isLoadingHistory && !isPreparingSubmission {
            guard ContinuousClock.now < deadline else { throw HerdrHudChatEndError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Submission owns preflight through acceptance. End Chat waits for an
        // accepted identity before cancelling, rather than racing a second
        // history load or letting a late POST escape after the card disappears.
        while isPreparingSubmission && controller.run == nil {
            guard ContinuousClock.now < deadline else { throw HerdrHudChatEndError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        if controller.isRunning {
            guard let machineID = controller.machineID,
                  model.canControl(machineID: machineID) else {
                throw HerdrHudChatEndError.statusUnavailable
            }
            await controller.cancel(model: model)
            guard !controller.isRunning else {
                throw HerdrHudChatEndError.stopFailed(controller.errorMessage ?? "The run is still active.")
            }
        }
        while isPreparingSubmission {
            guard ContinuousClock.now < deadline else { throw HerdrHudChatEndError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        if needsHistoryRefresh { await refreshSavedHistory(model: model) }
        guard !needsHistoryRefresh else { throw HerdrHudChatEndError.statusUnavailable }
        try Task.checkCancellation()
        try await saveHistory(model: model)
        responseAudioPlayer.stop()
        draft = ""
        pendingAttachments = []
        pendingQuotes = []
        pruneStoredAttachments()
        markSeen()
        hasEnded = true
    }

    func loadAudioCapabilities(model: HerdrAppModel) async {
        audioErrorMessage = nil
        guard let machineID = resolvedMachineIDReadOnly(in: model) else { return }
        await responseAudioPlayer.loadCapabilities {
            try await model.fetchResponseAudioCapabilities(forMachine: machineID)
        }
    }

    func loadModels(model: HerdrAppModel) async {
        modelsError = nil
        guard let machineID = resolvedMachineIDReadOnly(in: model) else { return }
        await refreshCatalog(for: machineID, model: model)
    }

    /// Fetches one machine's catalog and tags it with that exact machine. A
    /// newer request always wins over a delayed older response, and a response
    /// for a machine the composer has left is dropped rather than published.
    @discardableResult
    private func refreshCatalog(for machineID: String, model: HerdrAppModel) async -> Bool {
        modelsRequestRevision &+= 1
        let revision = modelsRequestRevision
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let response = try await model.fetchAgentModels(machineID: machineID)
            guard revision == modelsRequestRevision,
                  resolvedMachineIDReadOnly(in: model) == machineID else { return false }
            availableModels = response.models
            defaultModel = response.defaultModel
            modelsMachineID = machineID
            didLoadCatalog = true
            modelsError = nil
            return true
        } catch {
            guard revision == modelsRequestRevision else { return false }
            modelsError = error.localizedDescription
            return false
        }
    }

    private func catalog(for machineID: String) -> HerdrHudMachineModelCatalog? {
        guard modelsMachineID == machineID, didLoadCatalog else { return nil }
        return HerdrHudMachineModelCatalog(
            machineID: machineID,
            isAvailable: true,
            models: availableModels,
            defaultModel: defaultModel
        )
    }

    private func ensureCatalog(
        for machineID: String,
        model: HerdrAppModel
    ) async -> HerdrHudMachineModelCatalog? {
        if let catalog = catalog(for: machineID) { return catalog }
        _ = await refreshCatalog(for: machineID, model: model)
        return catalog(for: machineID)
    }

    /// Resolves this session's model choice against the execution companion's
    /// own catalog. A declared default is pinned exactly; an explicit override
    /// is preserved and validated; images require a compatible model and never
    /// reroute to another machine's or the global vision model.
    private func resolveModelForSession(
        machineID: String,
        model: HerdrAppModel,
        hasImageAttachments: Bool
    ) async throws -> (identity: PiModelIdentity, displayName: String?) {
        guard let catalog = await ensureCatalog(for: machineID, model: model) else {
            throw HerdrHudNewChatPolicyError.catalogUnavailable
        }
        guard resolvedMachineIDReadOnly(in: model) == machineID else {
            throw HerdrHudNewChatPolicyError.staleCatalog
        }
        let policy = HerdrHudNewChatPolicy(hostIdentity: hostIdentity)
        let identity = try policy.resolve(modelChoice, for: machineID, catalog: catalog)
        if hasImageAttachments,
           catalog.models.first(where: { $0.id == identity.fullID })?.supportsImages != true {
            throw HerdrHudFreshChatError.incompatibleImageModel(identity)
        }
        return (identity, catalog.models.first(where: { $0.id == identity.fullID })?.displayName)
    }

    func setSelectedModel(_ candidate: PiAvailableModel?) {
        selectedModel = candidate?.id
    }

    func isSpeakingSession(_ paneID: String) -> Bool {
        sessionAudioPaneID == paneID && responseAudioPlayer.phase.activeAction != nil
    }

    func isPreparingSessionAudio(_ paneID: String) -> Bool {
        guard sessionAudioPaneID == paneID else { return false }
        if loadingSessionAudioPaneID == paneID { return true }
        return responseAudioPlayer.phase == .preparing(.tldr)
    }

    /// Speak a finished session's last answer from its HUD chip.
    ///
    /// The chip has no conversation store behind it — that only exists while a
    /// pane's session view is on screen — so the transcript is fetched on
    /// demand and cached for the length of this playback. Playback itself is
    /// the same `.tldr` path the chat composer uses, so a second press
    /// pauses/resumes exactly like the in-chat control.
    func toggleSessionAudio(paneID: String, model: HerdrAppModel) async {
        audioErrorMessage = nil
        guard let pane = model.pane(id: paneID) else { return }

        if sessionAudioPaneID == paneID,
           let text = sessionAudioText,
           responseAudioPlayer.phase.activeAction != nil {
            activateSessionAudio(text: text, pane: pane, model: model)
            return
        }

        responseAudioPlayer.stop()
        sessionAudioPaneID = paneID
        sessionAudioText = nil
        sessionAudioActivityAt = pane.lastActivityAt
        speakingExchangeID = nil
        loadingSessionAudioPaneID = paneID
        defer {
            if loadingSessionAudioPaneID == paneID { loadingSessionAudioPaneID = nil }
        }

        if !responseAudioPlayer.capabilities.available {
            await responseAudioPlayer.loadCapabilities {
                try await model.fetchResponseAudioCapabilities(for: pane)
            }
        }
        guard responseAudioPlayer.capabilities.supports(.tldr) else {
            audioErrorMessage = "This machine can't read responses aloud."
            sessionAudioPaneID = nil
            return
        }

        do {
            guard let text = try await model.latestCompletedAssistantResponse(for: pane) else {
                audioErrorMessage = "\(pane.displayTitle) hasn't answered yet."
                sessionAudioPaneID = nil
                return
            }
            guard sessionAudioPaneID == paneID else { return }
            sessionAudioText = text
            activateSessionAudio(text: text, pane: pane, model: model)
        } catch {
            audioErrorMessage = error.localizedDescription
            sessionAudioPaneID = nil
        }
    }

    private func activateSessionAudio(text: String, pane: HerdrPane, model: HerdrAppModel) {
        responseAudioPlayer.activate(
            .tldr,
            text: text,
            prepare: { action, text in
                try await model.prepareResponseAudio(action: action, text: text, for: pane)
            },
            synthesize: { text in
                try await model.synthesizeResponseAudio(text: text, for: pane)
            },
            failure: { [weak self] message in
                self?.audioErrorMessage = message
                self?.sessionAudioPaneID = nil
            }
        )
    }

    func activateResponseAudio(
        _ action: ResponseAudioAction,
        text: String,
        exchangeID: String? = nil,
        model: HerdrAppModel
    ) {
        sessionAudioPaneID = nil
        sessionAudioText = nil
        speakingExchangeID = exchangeID
        audioErrorMessage = nil
        guard let machineID = resolvedMachineIDReadOnly(in: model) else { return }
        responseAudioPlayer.activate(
            action,
            text: text,
            prepare: { action, text in
                try await model.prepareResponseAudio(action: action, text: text, forMachine: machineID)
            },
            synthesize: { text in
                try await model.synthesizeResponseAudio(text: text, forMachine: machineID)
            },
            failure: { [weak self] message in
                self?.audioErrorMessage = message
            }
        )
    }

    /// Runs when playback reaches its natural end. The target is captured here
    /// rather than read later because collapsing the HUD, switching machines and
    /// appending a run all call `stop()`, which tears the audio state down.
    private func captureVoiceReplyTarget() {
        if let sessionAudioPaneID {
            voiceReplyTarget = sessionAudioPaneID
            voiceReplyTargetActivityAt = sessionAudioActivityAt
            return
        }
        // A headless HUD exchange only has a pi session once it was promoted.
        // `promotedPaneID` is a raw id while panes are addressed machine-scoped.
        if let speakingExchangeID,
           let exchange = exchanges.first(where: { $0.id == speakingExchangeID }),
           let promotedPaneID = exchange.promotedPaneID {
            voiceReplyTarget = MachineScopedID.compose(
                machineID: exchange.machineID,
                rawID: promotedPaneID
            )
            return
        }
        voiceReplyTarget = nil
        voiceReplyTargetActivityAt = nil
    }

    func clearVoiceReplyTarget() {
        voiceReplyTarget = nil
        voiceReplyTargetActivityAt = nil
    }

    /// Retires a reply offer whose answer has been superseded, so the chip goes
    /// back to offering the speaker for the newer response.
    ///
    /// Skipped while a reply is actually being spoken or edited: the pane can
    /// tick its activity underneath the user, and pulling the composer out from
    /// under them mid-sentence would be worse than a stale offer.
    func expireVoiceReplyTargetIfStale(pane: HerdrPane?, isReplyInFlight: Bool) {
        guard !isReplyInFlight, voiceReplyTarget != nil else { return }
        guard let pane, pane.id == voiceReplyTarget else {
            clearVoiceReplyTarget()
            return
        }
        guard pane.lastActivityAt == voiceReplyTargetActivityAt else {
            clearVoiceReplyTarget()
            return
        }
    }

    #if DEBUG
    func setVoiceReplyTargetForTesting(_ paneID: String?, activityAt: Date? = nil) {
        voiceReplyTarget = paneID
        voiceReplyTargetActivityAt = activityAt
    }
    #endif

    func promote(exchange: HerdrHudExchange, model: HerdrAppModel) async -> HerdrPane? {
        guard !isEnding, !hasEnded, !isRunning, !isLoadingHistory, !needsHistoryRefresh, promotingExchangeIDs.isEmpty else { return nil }
        beginSessionActivity()
        promoteErrorMessage = nil
        promotingExchangeIDs.insert(exchange.id)
        defer { promotingExchangeIDs.remove(exchange.id) }
        do {
            let result = try await model.promoteHeadlessAgent(
                runID: exchange.id,
                machineID: exchange.machineID,
                workspaceID: nil,
                cwd: HerdrHudWorkingFolder(path: exchange.workingFolderPath).requestPath
            )
            if let index = exchanges.firstIndex(where: { $0.id == exchange.id }) {
                exchanges[index].promotedPaneID = result.pane.paneID
                exchanges[index].status = result.run.status
                markExchangesChanged()
            }
            thread = nil
            await schedulePersistenceSave()
            return result.pane
        } catch {
            promoteErrorMessage = error.localizedDescription
            return nil
        }
    }

    func retry(_ exchange: HerdrHudExchange, model: HerdrAppModel) async {
        guard !isEnding, !hasEnded, !isRunning, !isLoadingHistory, !needsHistoryRefresh,
              promotingExchangeIDs.isEmpty,
              !exchanges.contains(where: { $0.promotedPaneID != nil }) else { return }
        let isUnacceptedPlaceholder = exchange.id.hasPrefix("hud-pending-")
        guard isUnacceptedPlaceholder || thread != nil else {
            validationError = "This saved chat is no longer attached to its server conversation. Start a new chat instead."
            return
        }
        let ownerID = UUID()
        submissionOwnerID = ownerID
        defer {
            if submissionOwnerID == ownerID { submissionOwnerID = nil }
            if cancelledSubmissionOwnerID == ownerID { cancelledSubmissionOwnerID = nil }
        }

        beginSessionActivity()
        hasUnseenAnswer = false
        validationError = nil
        promoteErrorMessage = nil
        audioErrorMessage = nil

        if thread != nil, !model.isDemoMode {
            guard await refreshSavedHistory(
                model: model,
                kind: .forced,
                submissionOwnerID: ownerID
            ) else { return }
            guard !submissionWasCancelled(ownerID) else { return }
            guard thread != nil, !exchanges.contains(where: { $0.promotedPaneID != nil }),
                  controller.isRunning == false else {
                validationError = "This saved chat changed before Retry. Latest messages were loaded; review them before trying again."
                return
            }
        }

        let retryAttachments: [HeadlessAgentAttachment]
        do {
            if !exchange.attachments.isEmpty {
                retryAttachments = exchange.attachments
            } else {
                let files = exchange.localAttachments
                retryAttachments = try await Task.detached(priority: .userInitiated) {
                    try files.map { attachment in
                        let data = try Data(contentsOf: attachment.url)
                        return HeadlessAgentAttachment(filename: attachment.filename, dataBase64: data.base64EncodedString())
                    }
                }.value
            }
        } catch {
            if !submissionWasCancelled(ownerID) {
                validationError = "Couldn't read the saved attachments: \(error.localizedDescription)"
            }
            return
        }
        guard !submissionWasCancelled(ownerID) else { return }

        let workingFolder = HerdrHudWorkingFolder(
            path: HerdrHudWorkingFolder.normalizedPath(exchange.workingFolderPath)
                ?? HerdrHudWorkingFolder.homePath
        )
        let continueFromRunID = thread?.machineID == exchange.machineID ? thread?.lastRunID : nil
        let startsNewRoot = continueFromRunID == nil
        if startsNewRoot && !workingFolder.isHome {
            do {
                try await model.requireDurableHUD(
                    machineID: exchange.machineID,
                    requiresWorkingDirectory: true
                )
            } catch {
                if !submissionWasCancelled(ownerID) { validationError = error.localizedDescription }
                return
            }
            guard !submissionWasCancelled(ownerID) else { return }
        }

        let hasAttachments = !retryAttachments.isEmpty
        let hasImageAttachments = retryAttachments.contains {
            HerdrAttachmentTypes.isImage(URL(fileURLWithPath: $0.filename))
        }
        let catalogIsForMachine = modelsMachineID == exchange.machineID
        let resolution = AgentModelResolver.resolve(
            preference: selectedModel,
            catalog: catalogIsForMachine ? availableModels : [],
            isCatalogAuthoritative: catalogIsForMachine && didLoadCatalog
        )
        let agentModel = HerdrHudModelRouting.model(
            selection: resolution.modelID,
            selectionSupportsImages: selectedModelSupportsImages(on: exchange.machineID),
            hasImageAttachments: hasImageAttachments,
            visionModel: agentSettings.effectiveVisionModel
        )
        let thinkingLevel = agentSettings.hudThinkingLevel.rawValue
        if resolution.preferenceIsUnavailable {
            validationError = "\(selectedModel ?? "") isn't offered by this machine — using its default model."
        }
        let metadataModelName = modelLabel(for: agentModel, on: exchange.machineID)
        let label = metadataModelName ?? "default"
        guard let run = await submitAndWait(
            prompt: exchange.sentPrompt,
            machineID: exchange.machineID,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: hasAttachments ? retryAttachments : nil,
            continueFromRunId: continueFromRunID,
            workingFolderPath: workingFolder.path,
            includesWorkingDirectory: startsNewRoot,
            capabilitiesChecked: startsNewRoot && !workingFolder.isHome,
            submissionOwnerID: ownerID,
            submissionID: isUnacceptedPlaceholder ? exchange.id : nil,
            submissionModelName: metadataModelName,
            model: model
        ) else {
            if submissionWasCancelled(ownerID) {
                controller.reset()
                return
            }
            let status = controller.lastErrorStatus
            let message = controller.errorMessage ?? validationError
            controller.reset()
            if status == 409 && continueFromRunID != nil {
                needsHistoryRefresh = true
                if await refreshSavedHistory(model: model, kind: .forced, submissionOwnerID: ownerID) {
                    validationError = "This saved chat changed on another device. Latest messages were loaded; Retry was not sent again."
                }
            } else {
                validationError = message
            }
            return
        }
        #if DEBUG
        lastHeadlessRunForTesting = run
        #endif
        let isSuccess = run.status == .completed || run.status == .promoted
        let retainedAttachments = isSuccess ? [] : retryAttachments
        let resolvedWorkingFolderPath = run.cwd.flatMap(HerdrHudWorkingFolder.normalizedPath)
            ?? workingFolder.path
        append(
            HerdrHudExchange(
                id: run.id,
                machineID: exchange.machineID,
                prompt: exchange.prompt,
                sentPrompt: exchange.sentPrompt,
                response: run.response,
                error: run.error,
                status: run.status,
                costUSD: run.costUSD,
                createdAt: .now,
                promotedPaneID: run.promotedPaneID,
                attachmentFilenames: exchange.attachmentFilenames,
                workingFolderPath: resolvedWorkingFolderPath,
                attachments: retainedAttachments,
                localAttachments: exchange.localAttachments,
                modelLabel: label,
                modelLabelIsProven: metadataModelName != nil,
                steps: Self.hudSteps(from: run.steps ?? []),
                stepsTruncated: run.stepsTruncated == true
            )
        )
        selectedWorkingFolder = HerdrHudWorkingFolder(path: resolvedWorkingFolderPath)
        savedHistoryRunKeys.insert("\(exchange.machineID):\(run.id)")
        if run.status.isTerminal, isCollapsed { hasUnseenAnswer = true }
        controller.reset()
        await schedulePersistenceSave()
    }

    private func submissionWasCancelled(_ ownerID: UUID) -> Bool {
        Task.isCancelled || cancelledSubmissionOwnerID == ownerID
    }

    private func consumeComposerSnapshot(
        draft draftSnapshot: String,
        attachments: [HerdrHudAttachment],
        quotes: [ChatQuote]
    ) {
        if draft == draftSnapshot { draft = "" }
        let attachmentIDs = Set(attachments.map(\.id))
        pendingAttachments.removeAll { attachmentIDs.contains($0.id) }
        let quoteIDs = Set(quotes.map(\.id))
        pendingQuotes.removeAll { quoteIDs.contains($0.id) }
    }

    private func restoreDraftAfterFailedStart(_ enteredPrompt: String, quotes: [ChatQuote], attachments: [HerdrHudAttachment]) {
        if draft.isEmpty { draft = enteredPrompt }
        let existingAttachmentIDs = Set(pendingAttachments.map(\.id))
        pendingAttachments.insert(
            contentsOf: attachments.filter { !existingAttachmentIDs.contains($0.id) },
            at: 0
        )
        let existingQuoteIDs = Set(pendingQuotes.map(\.id))
        pendingQuotes.insert(contentsOf: quotes.filter { !existingQuoteIDs.contains($0.id) }, at: 0)
    }

    /// Save legacy visible runs as well as the root before detaching the view.
    /// New durable runs already live indefinitely in the server catalog.
    func saveHistory(model: HerdrAppModel) async throws {
        await restoreTask?.value
        if model.isDemoMode { return }
        for exchange in exchanges where !exchange.id.hasPrefix("hud-") && exchange.status.isTerminal {
            let key = "\(exchange.machineID):\(exchange.id)"
            guard !savedHistoryRunKeys.contains(key) else { continue }
            let client = try model.hudChatClient(machineID: exchange.machineID)
            try await client.saveHudChat(id: exchange.id)
            savedHistoryRunKeys.insert(key)
        }
    }

    func openHistory(_ chat: HudChatSummary, machineID: String, model: HerdrAppModel) async throws {
        try await openHistory(
            id: chat.id,
            machineID: machineID,
            model: model,
            kind: .forced,
            submissionOwnerID: nil
        )
        validationError = nil
    }

    func openHistory(id: String, machineID: String, model: HerdrAppModel) async throws {
        try await openHistory(
            id: id,
            machineID: machineID,
            model: model,
            kind: .forced,
            submissionOwnerID: nil
        )
    }

    private func openHistory(
        id: String,
        machineID: String,
        model: HerdrAppModel,
        kind: HistoryRefreshKind,
        submissionOwnerID ownerID: UUID?
    ) async throws {
        let ownsSubmission = ownerID != nil && ownerID == submissionOwnerID
        guard !hasEnded, (!isRunning || ownsSubmission), !isLoadingHistory,
              promotingExchangeIDs.isEmpty else { return }
        // Loading saved history into a previously unused session is a legacy
        // conversation: its model keeps following the shared HUD preference
        // exactly as existing conversations did. A new-scheme session that
        // already owns a persisted choice keeps it.
        if exchanges.isEmpty, thread == nil, !ownsPersistedModelChoice {
            modelChoiceSource = .sharedPreference
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let client = try model.hudChatClient(machineID: machineID)
        var page = try await client.hudChat(id: id)
        try Task.checkCancellation()
        if kind == .passive, historyResponseIsUnchanged(page, machineID: machineID, rootRunID: id) {
            return
        }

        try await saveHistory(model: model)
        var turns = page.turns
        while let offset = page.nextOffset {
            try Task.checkCancellation()
            page = try await client.hudChat(id: id, offset: offset)
            turns += page.turns
        }
        try Task.checkCancellation()

        let isSameConversation = historyIdentity == "\(machineID):\(id)"
        let previousWorkingFolder = selectedWorkingFolder
        let historyWorkingFolder = turns.lazy.compactMap(\.cwd).first.flatMap {
            HerdrHudWorkingFolder.normalizedPath($0)
        } ?? workingFolderStore.rememberedFolder(for: machineID, chatID: id)?.path
            ?? (isSameConversation ? previousWorkingFolder.path : HerdrHudWorkingFolder.homePath)
        let wasAwaitingAnswer = needsHistoryRefresh || exchanges.last?.id.hasPrefix("hud-") == true
            || exchanges.last?.status.isTerminal == false
        let localByID = Dictionary(uniqueKeysWithValues: exchanges.map { ($0.id, $0) })
        let serverRunIDs = Set(turns.map(\.id))
        let newestLocalExchangeID = exchanges.last?.id
        let acceptedPendingExchange = isSameConversation && thread?.lastRunID == page.latestRunId
            ? exchanges.last(where: { local in
                local.id.hasPrefix("hud-pending-")
                    && turns.last(where: { $0.id == page.latestRunId })?.prompt == local.sentPrompt
            })
            : nil
        let localPlaceholders = isSameConversation ? exchanges.filter {
            $0.id.hasPrefix("hud-pending-")
                && $0.id != acceptedPendingExchange?.id
                && !serverRunIDs.contains($0.id)
        } : []
        needsHistoryRefresh = false
        beginSessionActivity()
        exchanges = turns.map { run in
            let local = localByID[run.id]
                ?? (run.id == page.latestRunId ? acceptedPendingExchange : nil)
            let restoredModelName = run.model.map(PiModelDisplayName.short(fullID:))
                ?? Self.provenLocalModelName(local)
            return HerdrHudExchange(
                id: run.id,
                machineID: machineID,
                prompt: run.prompt,
                sentPrompt: local?.sentPrompt ?? run.prompt,
                response: run.response,
                error: run.error,
                status: run.status,
                costUSD: run.costUSD,
                createdAt: HerdrTimestamp.date(from: run.createdAt) ?? local?.createdAt ?? .now,
                promotedPaneID: run.promotedPaneID ?? page.promotedPaneId,
                attachmentFilenames: run.attachments ?? local?.attachmentFilenames ?? [],
                workingFolderPath: historyWorkingFolder,
                attachments: local?.attachments ?? [],
                localAttachments: local?.localAttachments ?? [],
                modelLabel: restoredModelName ?? "default",
                modelLabelIsProven: restoredModelName != nil,
                steps: Self.hudSteps(from: run.steps ?? []),
                stepsTruncated: run.stepsTruncated == true
            )
        } + localPlaceholders
        mutateChatMetadata { metadata in
            metadata.reconcile(
                machineID: machineID,
                rootRunID: page.rootRunId,
                expectedTurnCount: turns.count,
                samples: turns.map { run in
                    let local = localByID[run.id]
                        ?? (run.id == page.latestRunId ? acceptedPendingExchange : nil)
                    return HerdrHudChatMetadataAccumulator.RunSample(
                        id: run.id,
                        costUSD: run.costUSD,
                        modelName: run.model.map(PiModelDisplayName.short(fullID:))
                            ?? Self.provenLocalModelName(local)
                    )
                }
            )
        }
        savedHistoryRunKeys.formUnion(turns.map { "\(machineID):\($0.id)" })
        historyRootRunID = page.rootRunId
        if let latest = turns.last, latest.status.isTerminal, isCollapsed, wasAwaitingAnswer {
            hasUnseenAnswer = true
        }
        thread = page.promotedPaneId == nil ? HerdrHudThread(
            machineID: machineID,
            rootRunID: page.rootRunId,
            lastRunID: page.latestRunId,
            turnCount: turns.count
        ) : nil
        if let acceptedPendingExchange,
           acceptedPendingExchange.id == newestLocalExchangeID,
           acceptedSubmissionIDsByHistoryIdentity["\(machineID):\(page.rootRunId)"] == nil {
            // Record the exact submission whose accepted run owns this root.
            // Pending-title adoption matches this mapping instead of any
            // placeholder that happens to remain in the transcript. Only the
            // newest local turn can be the accepted run; an older retained
            // placeholder with the same prompt text never is.
            acceptedSubmissionIDsByHistoryIdentity["\(machineID):\(page.rootRunId)"] = acceptedPendingExchange.id
        }
        onHistoryIdentityEstablished?()
        selectedMachineID = machineID
        selectedWorkingFolder = HerdrHudWorkingFolder(path: historyWorkingFolder)
        workingFolderStore.remember(
            folder: selectedWorkingFolder,
            for: machineID,
            chatID: id
        )
        if !isSameConversation { pendingQuotes = [] }
        markExchangesChanged()
        await schedulePersistenceSave()
        if let latest = turns.last, !latest.status.isTerminal {
            controller.observe(latest, machineID: machineID, model: model)
            historyObservationTask?.cancel()
            historyObservationTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let run = self.controller.run, run.id == latest.id,
                          let index = self.exchanges.firstIndex(where: { $0.id == run.id }) else { return }
                    let changed = self.exchanges[index].response != run.response
                        || self.exchanges[index].error != run.error
                        || self.exchanges[index].status != run.status
                        || self.exchanges[index].costUSD != run.costUSD
                        || self.exchanges[index].steps != Self.hudSteps(from: run.steps ?? [])
                    self.recordObservedMetadataSample(run)
                    if changed {
                        self.exchanges[index].response = run.response
                        self.exchanges[index].error = run.error
                        self.exchanges[index].status = run.status
                        self.exchanges[index].costUSD = run.costUSD
                        self.exchanges[index].steps = Self.hudSteps(from: run.steps ?? [])
                        self.markExchangesChanged()
                    }
                    if run.status.isTerminal {
                        self.hasUnseenAnswer = !self.hasEnded && self.isCollapsed
                        if let identity = self.chatMetadata.identity {
                            self.scheduleTerminalMetadataReconciliation(
                                run: run,
                                machineID: identity.machineID,
                                rootRunID: identity.rootRunID,
                                model: model
                            )
                        }
                        await self.schedulePersistenceSave()
                        if self.controller.run?.id == run.id { self.controller.reset() }
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                }
            }
        } else if let latest = turns.last {
            // A run that was already terminal when history loaded can still
            // receive its drained cost later, so schedule the same bounded
            // reconciliation without waiting for the card to reopen.
            scheduleTerminalMetadataReconciliation(
                run: latest,
                machineID: machineID,
                rootRunID: page.rootRunId,
                model: model
            )
        }
    }

    private func historyResponseIsUnchanged(
        _ page: HudChatHistory,
        machineID: String,
        rootRunID: String
    ) -> Bool {
        guard historyIdentity == "\(machineID):\(rootRunID)",
              page.promotedPaneId == nil,
              page.nextOffset == nil,
              chatMetadata.isComplete,
              chatMetadata.latestRunID == page.latestRunId,
              let thread,
              thread.machineID == machineID,
              thread.rootRunID == page.rootRunId,
              thread.lastRunID == page.latestRunId,
              let localLatest = exchanges.first(where: { $0.id == page.latestRunId }),
              localLatest.status.isTerminal,
              let remoteLatest = page.turns.first(where: { $0.id == page.latestRunId }) else {
            // Only the complete page covers every turn. A page with more
            // offsets, or an aggregate with an unresolved historical
            // component, cannot prove the metadata is unchanged. Fall through
            // to the full paginated fetch so the refresh task reconciles every
            // turn.
            return false
        }
        guard remoteLatest.status == localLatest.status
            && remoteLatest.response == localLatest.response
            && remoteLatest.error == localLatest.error
            && remoteLatest.promotedPaneID == localLatest.promotedPaneID
        else { return false }
        // A terminal report is not immutable: the server marks a cancelled run
        // terminal before its stdout consumer drains, so an earlier turn's cost
        // can be revised without the latest run changing. Reconcile the
        // complete page into a scratch aggregate and compare every accepted
        // turn against the live one, rather than trusting the latest sample
        // alone. A model that finally resolved on the server also falls out of
        // this comparison, replacing the submission-time fallback.
        var authoritative = HerdrHudChatMetadataAccumulator()
        authoritative.reconcile(
            machineID: machineID,
            rootRunID: page.rootRunId,
            expectedTurnCount: page.turns.count,
            samples: page.turns.map { run in
                Self.metadataRunSample(
                    for: run,
                    fallbackModelName: Self.provenLocalModelName(
                        exchanges.first(where: { $0.id == run.id })
                    )
                )
            }
        )
        return authoritative == chatMetadata
    }

    func clear(model: HerdrAppModel) async {
        guard !isEnding, !hasEnded, !isRunning, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            try await saveHistory(model: model)
        } catch {
            validationError = "Couldn’t save this chat to history: \(error.localizedDescription)"
            return
        }
        beginSessionActivity()
        terminalMetadataReconciliationTask?.cancel()
        terminalMetadataReconciliationTask = nil
        exchanges = []
        pendingQuotes = []
        markExchangesChanged()
        thread = nil
        historyRootRunID = nil
        acceptedSubmissionIDsByHistoryIdentity = [:]
        chatMetadata = HerdrHudChatMetadataAccumulator()
        needsHistoryRefresh = false
        selectedWorkingFolder = .home
        modelChoiceSource = .sessionOwned
        modelChoice = .machineDefault
        ownsPersistedModelChoice = false
        createsInMainWorkspace = false
        workspaceLaunchState = .idle
        mainWorkspaces = []
        mainWorkspaceErrorMessage = nil
        mainWorkspaceUnsupported = false
        loadedMainWorkspaceMachineID = nil
        unresolvedWorkspaceRequestID = nil
        unresolvedWorkspaceFingerprint = nil
        unresolvedWorkspaceReceipt = nil
        await persistence.remove()
        pruneStoredAttachments()
    }

    private func submissionWorkingFolder(for machineID: String) -> HerdrHudWorkingFolder {
        guard let thread, thread.machineID == machineID,
              let exchange = exchanges.last(where: { $0.machineID == machineID }) else {
            return selectedWorkingFolder
        }
        return HerdrHudWorkingFolder(
            path: HerdrHudWorkingFolder.normalizedPath(exchange.workingFolderPath)
                ?? HerdrHudWorkingFolder.homePath
        )
    }

    private func resolvedMachineID(in model: HerdrAppModel) -> String? {
        if let selectedMachineID,
           model.machines.contains(where: { $0.id == selectedMachineID }) {
            return selectedMachineID
        }
        if let conversationMachineID,
           model.machines.contains(where: { $0.id == conversationMachineID }) {
            selectedMachineID = conversationMachineID
            return conversationMachineID
        }
        if isNewChat, let local = resolvedLocalMachine(in: model) {
            selectedMachineID = local.id
            return local.id
        }
        return nil
    }

    private func resolvedMachineIDReadOnly(in model: HerdrAppModel) -> String? {
        if let selectedMachineID,
           model.machines.contains(where: { $0.id == selectedMachineID }) {
            return selectedMachineID
        }
        if let conversationMachineID,
           model.machines.contains(where: { $0.id == conversationMachineID }) {
            return conversationMachineID
        }
        return nil
    }

    private func selectedModelSupportsImages(on machineID: String) -> Bool {
        guard let selectedModel, modelsMachineID == machineID else { return false }
        return availableModels.first(where: { $0.id == selectedModel })?.supportsImages ?? false
    }

    /// The display name captured for an explicitly submitted model, or nil
    /// while the executed model is genuinely unknown. Only the identifier in
    /// the request — or the catalog entry naming that exact identifier — proves
    /// what may run. A declared catalog default is never attribution: a
    /// trusted project default can override it, so an implicit submission
    /// stays unknown until the server reports the run's model. A cached
    /// default from another machine is likewise never promoted. Dispatch is
    /// unaffected; only the label is withheld.
    private func modelLabel(for requestedModel: String?, on machineID: String) -> String? {
        guard let requestedModel else { return nil }
        if modelsMachineID == machineID,
           let available = availableModels.first(where: { $0.id == requestedModel }) {
            return available.displayName
        }
        return PiModelDisplayName.short(fullID: requestedModel)
    }

    /// A restored exchange's own label is usable only when it was captured from
    /// an explicit submission or an authoritative run report. A transcript or
    /// cache written before that distinction existed may hold a catalog guess,
    /// so its provenance flag alone decides whether metadata may adopt it.
    private static func provenLocalModelName(_ exchange: HerdrHudExchange?) -> String? {
        guard let exchange, exchange.modelLabelIsProven else { return nil }
        return exchange.modelLabel
    }

    private func append(_ exchange: HerdrHudExchange) {
        exchanges.append(exchange)
        trimExceedingCap()
        pruneStoredAttachments()
        markExchangesChanged()
    }

    private func trimExceedingCap() {
        guard exchanges.count > 20 else { return }
        var overflow = exchanges.count - 20
        var index = 0
        while overflow > 0, index < exchanges.count {
            if !exchanges[index].status.isTerminal {
                index += 1
                continue
            }
            exchanges.remove(at: index)
            overflow -= 1
        }
    }

    /// Attachment bytes follow the same retention policy as the transcript.
    private func pruneStoredAttachments() {
        let retained = Set((pendingAttachments + exchanges.flatMap(\.localAttachments)).map { $0.id.uuidString })
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: attachmentDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil
            && !retained.contains(directory.lastPathComponent) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func markExchangesChanged() {
        let latestPromotableExchangeID = exchanges.last(where: { $0.status == .completed })?.id
        if latestPromotableExchangeID != self.latestPromotableExchangeID {
            self.latestPromotableExchangeID = latestPromotableExchangeID
        }
        exchangesRevision += 1
    }

    private func restore(_ snapshot: HerdrHudPersistenceSnapshot) {
        guard !hasStartedSessionActivity, exchanges.isEmpty, thread == nil else { return }
        let restored = snapshot.restoredValues()
        exchanges = restored.exchanges
        hasUnseenAnswer = isCollapsed && snapshot.hasUnseenAnswer == true
        needsHistoryRefresh = snapshot.exchanges.last?.status.isTerminal == false
            || (restored.thread != nil && restored.thread?.lastRunID != snapshot.exchanges.last?.id)
        thread = restored.thread
        historyRootRunID = snapshot.historyRootRunID ?? thread?.rootRunID
        if let persistedChoice = snapshot.modelChoice {
            modelChoiceSource = .sessionOwned
            modelChoice = persistedChoice.choice
            ownsPersistedModelChoice = true
        } else if !restored.exchanges.isEmpty || restored.thread != nil {
            // A version-1 cache has no model-choice record, so it can only be
            // a conversation created under the legacy shared preference.
            modelChoiceSource = .sharedPreference
        }
        let restoredMachineID = thread?.machineID ?? exchanges.first?.machineID
        selectedMachineID = restoredMachineID ?? selectedMachineID
        restoreChatMetadata(snapshot, exchanges: restored.exchanges)
        let restoredFolderPath = restored.exchanges.last(where: { exchange in
            exchange.machineID == restoredMachineID
        })?.workingFolderPath ?? HerdrHudWorkingFolder.homePath
        selectedWorkingFolder = HerdrHudWorkingFolder(path: restoredFolderPath)
        if let root = thread?.rootRunID {
            workingFolderStore.remember(folder: selectedWorkingFolder, for: restoredMachineID ?? "", chatID: root)
        }
        pruneStoredAttachments()
        markExchangesChanged()
    }

    /// A persisted aggregate is trusted only for the exact restored identity.
    /// A version-1 cache without one is rebuilt from its transcript only when
    /// the retained turns provably belong to this machine and root, starting
    /// at the root run and ending at the thread's last accepted run; otherwise
    /// the cost stays unknown until full history establishes coverage.
    private func restoreChatMetadata(
        _ snapshot: HerdrHudPersistenceSnapshot,
        exchanges: [HerdrHudExchange]
    ) {
        guard let identity = chatMetadataIdentity else {
            chatMetadata = HerdrHudChatMetadataAccumulator()
            return
        }
        if let persisted = snapshot.chatMetadata, persisted.isScoped(to: identity) {
            chatMetadata = persisted
            return
        }
        // A persisted run that was still in flight when the cache was written
        // has a partial cost; its aggregate is unproven until history reloads.
        let hasInterruptedExchange = snapshot.exchanges.contains { !$0.status.isTerminal }
        let legacy = Self.legacyChatMetadataSamples(
            exchanges: exchanges,
            identity: identity,
            lastRunID: thread?.lastRunID
        )
        chatMetadata = HerdrHudChatMetadataAccumulator()
        chatMetadata.reconcile(
            machineID: identity.machineID,
            rootRunID: identity.rootRunID,
            expectedTurnCount: hasInterruptedExchange || !legacy.coverageIsProvable
                ? nil
                : thread?.turnCount,
            samples: legacy.samples
        )
    }

    /// A version-1 cache has no identity of its own, so its retained turns may
    /// contain previous roots or machines. Only the range that begins at the
    /// conversation's root run, stays on the restored machine, and ends at the
    /// thread's last accepted run is provably part of this conversation and can
    /// establish coverage. When that range is unavailable, at most the
    /// thread's own last run is kept: older retained turns may belong to a
    /// replaced root, and sealing them could later be summed into an accepted
    /// run's total.
    private static func legacyChatMetadataSamples(
        exchanges: [HerdrHudExchange],
        identity: HerdrHudChatMetadataAccumulator.Identity,
        lastRunID: String?
    ) -> (samples: [HerdrHudChatMetadataAccumulator.RunSample], coverageIsProvable: Bool) {
        let sameMachine = exchanges.filter {
            $0.machineID == identity.machineID && !$0.id.hasPrefix("hud-pending-")
        }
        let rootScoped = sameMachine.firstIndex { $0.id == identity.rootRunID }
            .map { Array(sameMachine[$0...]) } ?? []
        let scoped: [HerdrHudExchange]
        let coverageIsProvable: Bool
        if !rootScoped.isEmpty, let lastRunID, rootScoped.last?.id == lastRunID {
            scoped = rootScoped
            coverageIsProvable = true
        } else if !rootScoped.isEmpty, lastRunID == nil {
            // Without an accepted-turn count the total stays unknown, but the
            // retained suffix is still provably same-machine and after the root.
            scoped = rootScoped
            coverageIsProvable = false
        } else if let lastRunID, let last = sameMachine.first(where: { $0.id == lastRunID }) {
            scoped = [last]
            coverageIsProvable = false
        } else {
            scoped = []
            coverageIsProvable = false
        }
        let samples = scoped.map {
            HerdrHudChatMetadataAccumulator.RunSample(
                id: $0.id,
                costUSD: $0.costUSD,
                modelName: $0.modelLabelIsProven ? $0.modelLabel : nil
            )
        }
        return (samples, coverageIsProvable)
    }

    /// Mirrors `historyIdentity`, so persisted metadata is only trusted for the
    /// same machine and root the rest of the session already agrees on.
    private var chatMetadataIdentity: HerdrHudChatMetadataAccumulator.Identity? {
        if let thread {
            return HerdrHudChatMetadataAccumulator.Identity(
                machineID: thread.machineID,
                rootRunID: thread.rootRunID
            )
        }
        guard let first = exchanges.first, !first.id.hasPrefix("hud-") else { return nil }
        return HerdrHudChatMetadataAccumulator.Identity(
            machineID: first.machineID,
            rootRunID: historyRootRunID ?? first.id
        )
    }

    /// Startup restoration is allowed only until the user initiates real HUD work.
    private func beginSessionActivity() {
        hasStartedSessionActivity = true
        restoreTask?.cancel()
    }

    private func schedulePersistenceSave() async {
        // Keep the accepted running snapshot until the server tells us its real
        // outcome; the legacy cache decoder marks interrupted rows as failed.
        guard !needsHistoryRefresh else { return }
        let snapshot = HerdrHudPersistenceSnapshot(
            thread: thread,
            exchanges: exchanges,
            hasUnseenAnswer: hasUnseenAnswer,
            historyRootRunID: historyRootRunID,
            chatMetadata: chatMetadata,
            modelChoice: modelChoiceSource == .sessionOwned
                ? HerdrHudPersistedModelChoice(modelChoice)
                : nil
        )
        await persistence.scheduleSave(snapshot)
    }

    private func submitAndWait(
        prompt: String,
        machineID: String,
        agentModel: String?,
        thinkingLevel: String?,
        attachments: [HeadlessAgentAttachment]?,
        continueFromRunId: String? = nil,
        workingFolderPath: String = HerdrHudWorkingFolder.homePath,
        includesWorkingDirectory: Bool = true,
        capabilitiesChecked: Bool = false,
        submissionOwnerID ownerID: UUID? = nil,
        submissionID: String? = nil,
        submissionModelName: String? = nil,
        model: HerdrAppModel
    ) async -> HeadlessAgentRun? {
        elapsedSeconds = 0
        liveStepCount = 0
        liveSteps = []
        liveResponse = nil
        do {
            if !capabilitiesChecked {
                try await model.requireDurableHUD(
                    machineID: machineID,
                    requiresWorkingDirectory: includesWorkingDirectory
                        && workingFolderPath != HerdrHudWorkingFolder.homePath
                )
            }
            if let continueFromRunId, !model.isDemoMode {
                try await model.hudChatClient(machineID: machineID).saveHudChat(id: continueFromRunId)
            }
            if let ownerID {
                guard !submissionWasCancelled(ownerID) else { return nil }
            } else {
                try Task.checkCancellation()
            }
        } catch {
            let wasCancelled = ownerID.map { submissionWasCancelled($0) } ?? Task.isCancelled
            if !wasCancelled { validationError = error.localizedDescription }
            return nil
        }
        var systemPrompt: String?
        if let override = promptSettings.override(for: .hudActCharter) {
            if await model.supportsPromptOverrides(machineID: machineID) {
                systemPrompt = override
            } else if validationError == nil {
                validationError = "Custom instructions skipped — this machine's harness doesn't support them yet."
            }
        }
        if let ownerID {
            guard !submissionWasCancelled(ownerID) else { return nil }
        } else if Task.isCancelled {
            return nil
        }
        await controller.submit(
            prompt: prompt,
            machineID: machineID,
            mode: .act,
            cwd: includesWorkingDirectory
                ? HerdrHudWorkingFolder(path: workingFolderPath).requestPath
                : nil,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: attachments,
            continueFromRunId: continueFromRunId,
            systemPrompt: systemPrompt,
            profile: "hud-chat-v1",
            model: model
        )
        if let ownerID, submissionWasCancelled(ownerID), controller.run != nil {
            await controller.cancel(model: model)
        }
        // Persist the accepted durable identity before waiting for completion so
        // a relaunched app can observe the real run rather than resubmit it.
        if let run = controller.run {
            let root = run.threadRootRunId ?? run.id
            let isNewRoot = thread?.rootRunID != root
            historyRootRunID = root
            let count = isNewRoot ? 1 : (thread?.turnCount ?? 0) + 1
            thread = HerdrHudThread(machineID: machineID, rootRunID: root,
                                   lastRunID: run.id, turnCount: count)
            mutateChatMetadata { metadata in
                metadata.recordAcceptedRun(
                    machineID: machineID,
                    rootRunID: root,
                    expectedTurnCount: count,
                    sample: Self.metadataRunSample(for: run, fallbackModelName: submissionModelName)
                )
            }
            if isNewRoot, let submissionID {
                // Bind the new root to the exact submission that established
                // it so a pending title is adopted only by that submission.
                acceptedSubmissionIDsByHistoryIdentity["\(machineID):\(root)"] = submissionID
            }
            onHistoryIdentityEstablished?()
            workingFolderStore.remember(
                folder: HerdrHudWorkingFolder(path: workingFolderPath),
                for: machineID,
                chatID: root
            )
            await schedulePersistenceSave()
        }
        beginElapsedTimer()
        defer { endElapsedTimer() }
        while controller.isRunning {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                await controller.cancel(model: model)
                recordObservedMetadataSample(controller.run)
                return controller.run
            }
            let run = controller.run
            let count = run?.steps?.count ?? 0
            if count != liveStepCount {
                liveStepCount = count
            }
            let steps = Self.hudSteps(from: run?.steps ?? [])
            if steps != liveSteps { liveSteps = steps }
            if run?.response != liveResponse { liveResponse = run?.response }
            recordObservedMetadataSample(run)
        }
        recordObservedMetadataSample(controller.run)
        if let finishedRun = controller.run, finishedRun.status.isTerminal {
            scheduleTerminalMetadataReconciliation(
                run: finishedRun,
                machineID: machineID,
                rootRunID: finishedRun.threadRootRunId ?? finishedRun.id,
                model: model
            )
        }
        return controller.run
    }

    private static func metadataRunSample(
        for run: HeadlessAgentRun,
        fallbackModelName: String? = nil
    ) -> HerdrHudChatMetadataAccumulator.RunSample {
        HerdrHudChatMetadataAccumulator.RunSample(
            id: run.id,
            costUSD: run.costUSD,
            modelName: run.model.map(PiModelDisplayName.short(fullID:)) ?? fallbackModelName
        )
    }

    private func recordObservedMetadataSample(_ run: HeadlessAgentRun?) {
        guard let run else { return }
        mutateChatMetadata { metadata in
            metadata.updateObservedRun(
                id: run.id,
                costUSD: run.costUSD,
                modelName: run.model.map(PiModelDisplayName.short(fullID:))
            )
        }
    }

    /// How many extra checks one terminal run gets, and how far apart. The
    /// server marks a cancellation terminal before the run's stdout (and its
    /// cost report) finishes draining, so the first terminal sample can be
    /// incomplete or later revised. A handful of spaced reports closes that
    /// gap and then stops; this is deliberately not a presentation poller.
    private static let terminalMetadataReconciliationAttempts = 6
    private static let terminalMetadataReconciliationInterval = Duration.milliseconds(700)

    /// Re-checks one already-observed terminal run for a late or revised
    /// report so a collapsed bubble does not wait for the next card refresh.
    /// Every attempt revalidates the aggregate identity and the exact run, so
    /// a replaced conversation or a newer accepted turn stops the task instead
    /// of letting an old report leak into the new aggregate. Only a latest run
    /// that can still gain a cost is scheduled: a cancellation is always
    /// rechecked for the whole bounded window because its report may be
    /// revised after two matching samples, and any other terminal run only
    /// while its cost is still unknown.
    private func scheduleTerminalMetadataReconciliation(
        run: HeadlessAgentRun,
        machineID: String,
        rootRunID: String,
        model: HerdrAppModel
    ) {
        guard !model.isDemoMode, run.status.isTerminal else { return }
        let identity = HerdrHudChatMetadataAccumulator.Identity(machineID: machineID, rootRunID: rootRunID)
        guard chatMetadata.isScoped(to: identity), chatMetadata.latestRunID == run.id else { return }
        guard run.status == .cancelled || chatMetadata.latestRunCostUSD == nil else { return }
        terminalMetadataReconciliationTask?.cancel()
        terminalMetadataReconciliationTask = Task { [weak self] in
            guard let self else { return }
            var settledCost: Double?
            for attempt in 0..<Self.terminalMetadataReconciliationAttempts {
                if attempt > 0 {
                    do {
                        try await Task.sleep(for: Self.terminalMetadataReconciliationInterval)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      !self.hasEnded,
                      self.chatMetadata.isScoped(to: identity),
                      self.chatMetadata.latestRunID == run.id else { return }
                guard let report = try? await model.fetchHeadlessAgent(
                    runID: run.id,
                    machineID: machineID
                ), report.status.isTerminal else { continue }
                if self.applyReconciledTerminalRun(report, identity: identity) {
                    await self.schedulePersistenceSave()
                }
                // For any non-cancelled terminal run, two consecutive reports
                // that agree on the cost prove the record has settled, so the
                // full bound is unnecessary. A cancellation never leaves on
                // agreement: the server marks it terminal before stdout (and
                // its cost report) finishes draining, so two equal early
                // samples can still be revised (for example $0.05, $0.05,
                // then $0.11). It always uses the bounded window instead.
                if run.status != .cancelled,
                   let cost = report.costUSD,
                   let settledCost,
                   cost == settledCost {
                    return
                }
                settledCost = report.costUSD
            }
        }
    }

    /// Merges one authoritative terminal report into the aggregate and its
    /// transcript row. The caller scoped the fetch to this conversation, but
    /// the aggregate can still be replaced while the report is in flight, so
    /// the exact identity and run are revalidated here as well before a late
    /// cost can touch its accepted turn.
    @discardableResult
    private func applyReconciledTerminalRun(
        _ run: HeadlessAgentRun,
        identity: HerdrHudChatMetadataAccumulator.Identity
    ) -> Bool {
        guard run.status.isTerminal,
              chatMetadata.isScoped(to: identity),
              chatMetadata.latestRunID == run.id else { return false }
        let modelName = run.model.map(PiModelDisplayName.short(fullID:))
        var changed = false
        mutateChatMetadata { metadata in
            let updated = metadata.updateObservedRun(
                id: run.id,
                costUSD: run.costUSD,
                modelName: modelName
            )
            changed = updated
            return updated
        }
        if let index = exchanges.firstIndex(where: { $0.id == run.id }) {
            if exchanges[index].costUSD != run.costUSD {
                exchanges[index].costUSD = run.costUSD
                changed = true
            }
            if exchanges[index].status != run.status {
                exchanges[index].status = run.status
                changed = true
            }
            if changed { markExchangesChanged() }
        }
        return changed
    }

    private func mutateChatMetadata(
        _ mutate: (inout HerdrHudChatMetadataAccumulator) -> Bool
    ) {
        var updated = chatMetadata
        guard mutate(&updated) else { return }
        chatMetadata = updated
    }

    private func beginElapsedTimer() {
        elapsedTask?.cancel()
        guard controller.isRunning else { return }
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.controller.isRunning {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.controller.isRunning else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func endElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
        elapsedSeconds = 0
        liveStepCount = 0
        liveSteps = []
        liveResponse = nil
    }

    static func hudSteps(from steps: [HeadlessAgentStep]) -> [HerdrHudStep] {
        steps.enumerated().map { index, step in
            let toolName = step.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? "Tool"
            let presentation = PiToolPresentation.details(forToolName: toolName)
            let identifier = step.toolCallId.flatMap { $0.isEmpty ? nil : $0 } ?? "hud-step-\(index)"
            return HerdrHudStep(
                id: identifier,
                title: presentation.title,
                detail: Self.hudStepDetail(for: step, isCommand: presentation.title == "Command"),
                symbol: presentation.symbol,
                isFailure: step.isError == true,
                isRunning: step.finishedAt == nil
            )
        }
    }

    private static func hudStepDetail(
        for step: HeadlessAgentStep,
        isCommand: Bool
    ) -> String {
        let preview: String?
        if isCommand {
            preview = commandPreview(from: step.argsPreview) ?? step.argsPreview ?? step.resultPreview
        } else {
            preview = step.argsPreview ?? step.resultPreview
        }
        return singleLinePreview(preview ?? "")
    }

    private static func commandPreview(from preview: String?) -> String? {
        guard let preview,
              let data = preview.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return ["command", "cmd", "script"].lazy.compactMap { object[$0] as? String }.first
    }

    private static func singleLinePreview(_ preview: String) -> String {
        let singleLine = preview.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limit = 120
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}
