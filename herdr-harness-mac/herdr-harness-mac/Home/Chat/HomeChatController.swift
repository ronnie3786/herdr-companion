import Foundation
import Observation

/// Owns the Home lead conversation beyond tray and tab lifetimes. Its target
/// comes from the existing lead policy and is held exactly while the user has
/// a draft or an unresolved operation. With nothing held, a changed connection
/// or lead re-resolves it. A missing owner never moves material to another lead.
@MainActor @Observable
final class HomeChatController {
    @ObservationIgnored let model: HerdrAppModel
    @ObservationIgnored let shell: HerdrShellState
    let store = FirstMateStore()
    let transcriptSession: FirstMateChatWindowSession
    var isPresented = false
    private(set) var target: HomeChatTarget?
    private(set) var owner: HomeChatOwner?
    private(set) var pendingTransfer: HomeChatTransfer?
    private(set) var statusMessage: String?
    private(set) var isOpening = false
    private var stagedDraft = ""
    private var stagedContext: HomeChatContext?
    private var contextByID: [UUID: HomeChatContext] = [:]
    @ObservationIgnored private let configurationProvider: @MainActor (String) -> ServerConfiguration?
    @ObservationIgnored private let makeClient: @MainActor (ServerConfiguration) -> any FirstMateClient
    @ObservationIgnored private let chooseMachine: @MainActor () -> String?
    @ObservationIgnored private let lease = FirstMateWorkspaceControlLease()
    @ObservationIgnored private var refreshOwner = UUID()

    convenience init(model: HerdrAppModel, shell: HerdrShellState) {
        self.init(model: model, shell: shell,
                  configuration: { [weak model] in model?.firstMateConfiguration(machineID: $0) },
                  makeClient: { HerdrAPIClient(configuration: $0) })
    }

    init(model: HerdrAppModel, shell: HerdrShellState,
         configuration: @escaping @MainActor (String) -> ServerConfiguration?,
         makeClient: @escaping @MainActor (ServerConfiguration) -> any FirstMateClient,
         chooseMachine: (@MainActor () -> String?)? = nil) {
        self.model = model
        self.shell = shell
        configurationProvider = configuration
        self.makeClient = makeClient
        self.chooseMachine = chooseMachine ?? { [weak model, weak shell] in
            guard let model, let shell else { return nil }
            if model.isDemoMode { return FirstMateChatWindowSession.demoMachineID }
            return FirstMateLeadMachine.current(hosts: shell.firstMateFleet.hosts, machines: model.machines)
        }
        transcriptSession = FirstMateChatWindowSession(model: model, shell: shell,
                                                       configuration: configuration, makeClient: makeClient)
    }

    var snapshot: FirstMateSnapshot? {
        guard let owner, store.leadFeatureID == owner.featureID else { return nil }
        return store.snapshots[owner.featureID]
    }

    var isOwnerCurrent: Bool {
        guard let target else { return false }
        return target.isCurrent(model: model, configuration: configurationProvider)
            && (owner == nil || store.leadFeatureID == owner?.featureID)
    }

    var isOwnerControllable: Bool {
        guard let target, isOwnerCurrent else { return false }
        return model.canControl(machineID: target.machineID)
    }

    var canControl: Bool { isPresented && isOwnerControllable && owner != nil && pendingTransfer == nil && store.controlAvailable }

    var machineName: String {
        guard let target else { return "your configured machine" }
        if target.isDemo { return FirstMateChatWindowSession.demoMachineName }
        return model.machines.first { $0.id == target.machineID }?.name ?? target.machineID
    }

    var contexts: [HomeChatContext] {
        guard let owner else { return stagedContext.map { [$0] } ?? [] }
        return store.composerDrafts.quotes(for: owner.featureID).compactMap { contextByID[$0.id] }
    }

    var availabilityMessage: String? {
        if target != nil, !isOwnerCurrent {
            return "This conversation's machine or connection changed. Your draft is kept here; it will not move to another lead."
        }
        if target != nil, isOwnerCurrent, !isOwnerControllable {
            return "This machine is disconnected or read-only. Your draft is kept here until control is available."
        }
        return statusMessage ?? store.error
    }

    var transferBlockReason: String? {
        guard isOwnerCurrent, let owner, snapshot != nil else {
            return availabilityMessage ?? "Open the lead conversation before moving it to First Mate."
        }
        guard isOwnerControllable else { return availabilityMessage }
        if store.isSending || store.isSubmitting(featureID: owner.featureID) {
            return "Wait for the current send to finish before opening this draft in First Mate."
        }
        if store.outgoingMessages(for: owner.featureID).contains(where: { $0.state.isFailure }) {
            return "Resolve the send error here first. An unconfirmed delivery stays with its original conversation."
        }
        let attachments = store.composerDrafts.attachments(for: owner.featureID)
        if attachments.contains(where: { $0.status == .uploading }) {
            return "Wait for the upload to finish before opening this draft in First Mate."
        }
        if attachments.contains(where: { $0.status != .uploaded || $0.uploadedPath == nil }) {
            return "Retry or remove failed attachments before opening this draft in First Mate."
        }
        return nil
    }

    func open(context: HomeChatContext? = nil, draft: String? = nil) {
        isPresented = true
        releaseTargetIfIdle()
        if target == nil { configureInitialTarget() }
        if let context { stage(context) }
        if let draft, !draft.isEmpty { appendDraft(draft) }
    }

    func dismiss() {
        isPresented = false
        lease.release()
        // Unmounting FirstMatePromptComposer cancels dictation. Its existing
        // outgoing operation retains its own lifecycle and frozen payload.
    }

    func setDraft(_ text: String) {
        guard owner != nil else { stagedDraft = text; return }
        store.setComposerDraft(text, for: store.operationContext)
        if let owner { store.composerDrafts.noteDraftEdit(for: owner.featureID) }
    }

    var draft: String { owner == nil ? stagedDraft : store.composerDraft(for: store.operationContext) }

    func appendDraft(_ text: String) {
        guard draft != text else { return }
        setDraft(Self.appending(text, to: draft))
    }

    func removeContext(_ id: UUID) {
        if stagedContext?.id == id { stagedContext = nil }
        guard let owner else { return }
        store.composerDrafts.setQuotes(store.composerDrafts.quotes(for: owner.featureID).filter { $0.id != id }, for: owner.featureID)
    }

    func prepare() async {
        releaseTargetIfIdle()
        if target == nil { configureInitialTarget() }
        guard let target, isOwnerCurrent, !isOpening, !Task.isCancelled else { return }
        let lifecycle = store.lifecycle
        isOpening = true
        defer { if store.lifecycle == lifecycle { isOpening = false } }
        let opened = owner == nil ? await store.openLead() : true
        guard !Task.isCancelled, self.target == target, isOwnerCurrent, store.lifecycle == lifecycle else { return }
        guard opened, let snapshot = store.leadSnapshot, snapshot.feature.isLead else {
            statusMessage = store.error ?? "This companion needs lead First Mate support before Home chat is available."
            return
        }
        if let owner, owner.featureID != snapshot.feature.id {
            statusMessage = "This machine's lead conversation changed. Your draft is kept with the original conversation."
            return
        }
        let resolvedOwner = HomeChatOwner(target: target, featureID: snapshot.feature.id)
        owner = resolvedOwner
        transcriptSession.installHomeConversationStore(store, owner: resolvedOwner)
        if !stagedDraft.isEmpty { let text = stagedDraft; stagedDraft = ""; appendDraft(text) }
        if let context = stagedContext { stagedContext = nil; stage(context) }
        statusMessage = nil
        lease.update(store: store, available: isPresented && isOwnerControllable && pendingTransfer == nil)
    }

    func run() async {
        let run = UUID()
        refreshOwner = run
        defer { if refreshOwner == run { lease.release() } }
        while !Task.isCancelled, isPresented {
            await prepare()
            guard !Task.isCancelled else { return }
            // Keep looping while not current: an idle chat recovers once the
            // fleet or connection settles, and held material stays put.
            if owner != nil, isOwnerCurrent { await store.refreshLead() }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    @discardableResult
    func requestTransfer(inspector: FirstMateInspector? = nil) -> Bool {
        if pendingTransfer != nil { return true }
        if let reason = transferBlockReason { statusMessage = reason; return false }
        guard let owner else { return false }
        pendingTransfer = HomeChatTransfer(
            id: UUID(), owner: owner, draft: draft,
            draftRevision: store.composerDrafts.revision(for: owner.featureID),
            attachments: store.composerDrafts.attachments(for: owner.featureID),
            quotes: store.composerDrafts.quotes(for: owner.featureID),
            containsDictation: store.composerDrafts.containsDictation(for: owner.featureID),
            contexts: contexts,
            inspector: inspector
        )
        lease.update(store: store, available: false)
        statusMessage = nil
        return true
    }

    func validates(_ transfer: HomeChatTransfer) -> Bool {
        pendingTransfer?.id == transfer.id && owner == transfer.owner && isOwnerCurrent
            && transferBlockReason == nil
    }

    func failTransfer(_ id: UUID, message: String) {
        guard pendingTransfer?.id == id else { return }
        pendingTransfer = nil
        statusMessage = message
        lease.update(store: store, available: isPresented && isOwnerControllable)
    }

    /// Called synchronously after the receiving window appended the frozen
    /// material. Newer text or edited attachments are never cleared by an ack.
    func acknowledgeTransfer(_ transfer: HomeChatTransfer) {
        guard pendingTransfer?.id == transfer.id, owner == transfer.owner else { return }
        let featureID = transfer.owner.featureID
        if draft == transfer.draft, store.composerDrafts.revision(for: featureID) == transfer.draftRevision {
            setDraft("")
            store.composerDrafts.setContainsDictation(false, for: featureID)
        }
        store.composerDrafts.setAttachments(store.composerDrafts.attachments(for: featureID).filter { current in
            !transfer.attachments.contains(current)
        }, for: featureID)
        store.composerDrafts.setQuotes(store.composerDrafts.quotes(for: featureID).filter { current in
            !transfer.quotes.contains(current)
        }, for: featureID)
        pendingTransfer = nil
        statusMessage = nil
        dismiss()
    }

    /// Drafts, attachments, quotes, dictation, sends and transfers belong to
    /// the conversation they started in. Home contexts are re-staged instead.
    private var holdsMaterial: Bool {
        if pendingTransfer != nil || !stagedDraft.isEmpty { return true }
        guard let owner else { return false }
        let drafts = store.composerDrafts
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !drafts.attachments(for: owner.featureID).isEmpty
            || drafts.quotes(for: owner.featureID).contains { contextByID[$0.id] == nil }
            || drafts.containsDictation(for: owner.featureID)
            || store.isSending
            || !store.outgoingMessages(for: owner.featureID).isEmpty
    }

    /// With nothing held, a replaced connection or a different lead (failover
    /// or a new pin) starts over with the current lead policy.
    private func releaseTargetIfIdle() {
        guard let target, !holdsMaterial else { return }
        let lead = chooseMachine()
        let moved = lead != nil && lead != target.machineID
        guard moved || !target.isCurrent(model: model, configuration: configurationProvider) else { return }
        stagedContext = contexts.last ?? stagedContext
        lease.release()
        self.target = nil
        owner = nil
        statusMessage = nil
    }

    private func configureInitialTarget() {
        guard let machineID = chooseMachine() else {
            setStatusMessage("Connect a companion with lead First Mate support to use Home chat.")
            return
        }
        let demo = model.isDemoMode
        let configuration = demo ? nil : configurationProvider(machineID)
        guard demo || configuration != nil else {
            setStatusMessage("This lead's machine is not configured. Your draft is kept here.")
            return
        }
        target = .init(machineID: machineID, generation: model.connectionGeneration, isDemo: demo, configuration: configuration)
        if demo {
            store.configure(client: nil, demo: true, demoFeatures: [FirstMateDemo.chatWindowLead(now: .now)])
        } else if let configuration {
            store.configure(client: makeClient(configuration), demo: false)
        }
        store.leadContextProvider = { [weak model, weak shell] in
            guard let model, let shell else { return nil }
            return FirstMateLeadMachine.context(hosts: shell.firstMateFleet.hosts, machines: model.machines, excluding: machineID)
        }
    }

    private func stage(_ context: HomeChatContext) {
        contextByID[context.id] = context
        guard let owner else { stagedContext = context; return }
        var quotes = store.composerDrafts.quotes(for: owner.featureID)
        quotes.removeAll { contextByID[$0.id] != nil }
        quotes.append(context.quote)
        store.composerDrafts.setQuotes(quotes, for: owner.featureID)
    }

    /// The run loop retries while unconfigured; repeating a message must not republish.
    private func setStatusMessage(_ message: String) {
        if statusMessage != message { statusMessage = message }
    }

    static func appending(_ incoming: String, to existing: String) -> String {
        if incoming.isEmpty { return existing }
        return existing.isEmpty ? incoming : existing + "\n\n" + incoming
    }
}
