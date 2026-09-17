import Foundation
import Observation

struct HudChatThreadSnapshot: Sendable {
    let turns: [HeadlessAgentRun]
    let rootRunID: String
    let latestRunID: String
    let promotedPaneID: String?
}

@MainActor
@Observable
final class HudChatStore {
    private(set) var machineID = ""
    private(set) var query = ""
    private(set) var chats: [HudChatSummary] = []
    private(set) var nextCatalogOffset: Int?
    private(set) var capabilities: HudChatCapabilities?
    private(set) var modelCatalog: AgentModelCatalogResponse?
    private(set) var turns: [HeadlessAgentRun] = []
    private(set) var rootRunID: String?
    private(set) var latestRunID: String?
    private(set) var promotedPaneID: String?
    private(set) var isShowingConversation = false
    private(set) var isLoadingCatalog = false
    private(set) var isLoadingHistory = false
    private(set) var isSubmitting = false
    private(set) var isStopping = false
    private(set) var isObserving = false
    private(set) var errorMessage: String?

    var draft = "" {
        didSet {
            guard !isRestoringDraft, let key = displayedDraftKey else { return }
            storeDraft(draft, for: key)
        }
    }
    var usesCustomWorkingDirectory = false
    var newWorkingDirectory = ""

    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var drafts: [String: String] = [:]
    @ObservationIgnored private var draftGenerations: [String: Int] = [:]
    @ObservationIgnored private var nextDraftGeneration = 0
    @ObservationIgnored private var isRestoringDraft = false
    @ObservationIgnored private var catalogCache: [String: [HudChatSummary]] = [:]
    @ObservationIgnored private var catalogOffsets: [String: Int?] = [:]
    @ObservationIgnored private var catalogKeysWithLoadedMore: Set<String> = []
    @ObservationIgnored private var historyCache: [String: HudChatThreadSnapshot] = [:]
    @ObservationIgnored private var capabilityCache: [String: HudChatCapabilities] = [:]
    @ObservationIgnored private var modelCache: [String: AgentModelCatalogResponse] = [:]
    @ObservationIgnored private var catalogRequests: [String: RequestOwnership] = [:]
    @ObservationIgnored private var historyRequests: [String: UUID] = [:]
    @ObservationIgnored private var activeSubmissions: [String: UUID] = [:]
    @ObservationIgnored private var activeStops: [String: UUID] = [:]
    @ObservationIgnored private var conversationObservationID: UUID?
    @ObservationIgnored private var catalogObservationID: UUID?

    private struct RequestOwnership {
        let id: UUID
        let showsLoading: Bool
    }

    var latestRun: HeadlessAgentRun? {
        guard let latestRunID else { return turns.last }
        return turns.first(where: { $0.id == latestRunID }) ?? turns.last
    }

    var isNewChat: Bool { isShowingConversation && rootRunID == nil }
    var hasActiveRun: Bool { latestRun?.status.isTerminal == false }
    var canSubmit: Bool {
        isShowingConversation && !isSubmitting && !isStopping && !hasActiveRun && promotedPaneID == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load(machineID: String, query: String, transport: any HudChatTransport) async {
        let machineChanged = self.machineID != machineID
        let queryChanged = self.query != query
        if machineChanged || queryChanged { advanceDisplayRevision() }
        if machineChanged {
            self.machineID = machineID
            isShowingConversation = false
            rootRunID = nil
            latestRunID = nil
            promotedPaneID = nil
            turns = []
            capabilities = capabilityCache[machineID]
            modelCatalog = modelCache[machineID]
            restoreDraft(for: draftKey(machineID: machineID, rootRunID: nil))
        }
        self.query = query
        let key = catalogKey(machineID: machineID, query: query)
        chats = catalogCache[key] ?? []
        nextCatalogOffset = catalogOffsets[key] ?? nil

        let owner = beginCatalogRequest(key: key, showsLoading: true)
        errorMessage = nil
        defer { finishCatalogRequest(key: key, owner: owner) }

        do {
            let fetchedCapabilities = try await transport.fetchHudChatCapabilities(machineID: machineID)
            try Task.checkCancellation()
            guard ownsCatalogRequest(key: key, owner: owner), self.machineID == machineID else { return }
            capabilities = fetchedCapabilities
            capabilityCache[machineID] = fetchedCapabilities
            guard fetchedCapabilities.supportsHudChats else {
                errorMessage = Self.upgradeMessage
                return
            }

            let page = try await transport.fetchHudChatCatalog(machineID: machineID, query: query, offset: 0)
            try Task.checkCancellation()
            guard ownsCatalogRequest(key: key, owner: owner), isDisplayedCatalog(machineID: machineID, query: query) else {
                return
            }
            chats = Self.unique(page.chats)
            nextCatalogOffset = page.nextOffset
            catalogCache[key] = chats
            catalogOffsets[key] = page.nextOffset
            catalogKeysWithLoadedMore.remove(key)

            do {
                let fetchedModels = try await transport.fetchHudChatModels(machineID: machineID)
                guard ownsCatalogRequest(key: key, owner: owner), self.machineID == machineID else { return }
                modelCatalog = fetchedModels
                modelCache[machineID] = fetchedModels
            } catch {
                // Model discovery is optional. A machine default can still run.
            }
        } catch {
            guard !HerdrCancellation.isCancellation(error), ownsCatalogRequest(key: key, owner: owner) else { return }
            if isDisplayedCatalog(machineID: machineID, query: query) {
                errorMessage = Self.message(for: error, capabilityRequest: true)
            }
        }
    }

    func loadMore(transport: any HudChatTransport) async {
        guard let offset = nextCatalogOffset, !isLoadingCatalog, !machineID.isEmpty else { return }
        let requestedMachine = machineID
        let requestedQuery = query
        let key = catalogKey(machineID: requestedMachine, query: requestedQuery)
        let owner = beginCatalogRequest(key: key, showsLoading: true)
        defer { finishCatalogRequest(key: key, owner: owner) }
        do {
            let page = try await transport.fetchHudChatCatalog(
                machineID: requestedMachine,
                query: requestedQuery,
                offset: offset
            )
            try Task.checkCancellation()
            guard ownsCatalogRequest(key: key, owner: owner), isDisplayedCatalog(machineID: requestedMachine, query: requestedQuery) else {
                return
            }
            chats = Self.unique((catalogCache[key] ?? chats) + page.chats)
            nextCatalogOffset = page.nextOffset
            catalogCache[key] = chats
            catalogOffsets[key] = page.nextOffset
            catalogKeysWithLoadedMore.insert(key)
            errorMessage = nil
        } catch {
            guard !HerdrCancellation.isCancellation(error), ownsCatalogRequest(key: key, owner: owner) else { return }
            if isDisplayedCatalog(machineID: requestedMachine, query: requestedQuery) {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Quietly reconciles the first catalog page. This keeps already loaded
    /// pages in place and deliberately does not flash loading or polling errors.
    func syncCatalog(transport: any HudChatTransport) async {
        guard !isShowingConversation, !machineID.isEmpty else { return }
        let requestedMachine = machineID
        let requestedQuery = query
        let key = catalogKey(machineID: requestedMachine, query: requestedQuery)
        guard catalogRequests[key] == nil else { return }
        let owner = beginCatalogRequest(key: key, showsLoading: false)
        defer { finishCatalogRequest(key: key, owner: owner) }
        do {
            let page = try await transport.fetchHudChatCatalog(
                machineID: requestedMachine,
                query: requestedQuery,
                offset: 0
            )
            try Task.checkCancellation()
            guard ownsCatalogRequest(key: key, owner: owner), isDisplayedCatalog(machineID: requestedMachine, query: requestedQuery) else {
                return
            }
            let cached = catalogCache[key] ?? chats
            let firstPageIDs = Set(page.chats.map(\.id))
            let reconciled = Self.unique(page.chats + cached.filter { !firstPageIDs.contains($0.id) })
            chats = reconciled
            catalogCache[key] = reconciled
            if catalogKeysWithLoadedMore.contains(key) {
                nextCatalogOffset = catalogOffsets[key] ?? nil
            } else {
                nextCatalogOffset = page.nextOffset
                catalogOffsets[key] = page.nextOffset
            }
        } catch {
            // Foreground synchronization is intentionally quiet. Cached content,
            // a dismissed error, and explicit loading UI remain undisturbed.
        }
    }

    func beginNewChat() {
        advanceDisplayRevision()
        isShowingConversation = true
        rootRunID = nil
        latestRunID = nil
        promotedPaneID = nil
        turns = []
        usesCustomWorkingDirectory = false
        newWorkingDirectory = ""
        restoreDraft(for: draftKey(machineID: machineID, rootRunID: nil))
        errorMessage = nil
        syncVisibleActivity()
    }

    func showCatalog() {
        advanceDisplayRevision()
        isShowingConversation = false
        rootRunID = nil
        latestRunID = nil
        promotedPaneID = nil
        turns = []
        let key = catalogKey(machineID: machineID, query: query)
        chats = catalogCache[key] ?? chats
        nextCatalogOffset = catalogOffsets[key] ?? nil
        restoreDraft(for: draftKey(machineID: machineID, rootRunID: nil))
        errorMessage = nil
        syncVisibleActivity()
    }

    func open(_ chat: HudChatSummary, transport: any HudChatTransport) async {
        advanceDisplayRevision()
        let requestRevision = revision
        isShowingConversation = true
        rootRunID = chat.id
        latestRunID = chat.latestRunId
        promotedPaneID = chat.promotedPaneId
        if let cached = historyCache[historyKey(machineID: machineID, rootRunID: chat.id)] {
            apply(cached)
        } else {
            turns = []
        }
        restoreDraft(for: draftKey(machineID: machineID, rootRunID: chat.id))
        errorMessage = nil
        syncVisibleActivity()
        _ = await refreshConversation(
            machineID: machineID,
            rootRunID: chat.id,
            transport: transport,
            expectedRevision: requestRevision
        )
    }

    @discardableResult
    func refreshConversation(transport: any HudChatTransport) async -> Bool {
        guard let requestedRoot = rootRunID else { return false }
        let mutationKey = draftKey(machineID: machineID, rootRunID: requestedRoot)
        guard activeSubmissions[mutationKey] == nil, activeStops[mutationKey] == nil else { return false }
        return await refreshConversation(
            machineID: machineID,
            rootRunID: requestedRoot,
            transport: transport,
            expectedRevision: revision
        )
    }

    func submit(model: String?, thinkingLevel: String?, transport: any HudChatTransport) async {
        let rawDraft = draft
        let prompt = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !machineID.isEmpty else { return }
        guard let capabilities, capabilities.supportsHudChats else {
            errorMessage = Self.upgradeMessage
            return
        }

        let requestedMachine = machineID
        let requestRevision = revision
        let originalRoot = rootRunID
        let operationKey = draftKey(machineID: requestedMachine, rootRunID: originalRoot)
        guard activeSubmissions[operationKey] == nil, activeStops[operationKey] == nil else { return }
        let operationID = UUID()
        activeSubmissions[operationKey] = operationID
        let submittedDraftGeneration = draftGenerations[operationKey] ?? 0
        syncVisibleActivity()
        errorMessage = nil
        defer {
            if activeSubmissions[operationKey] == operationID {
                activeSubmissions.removeValue(forKey: operationKey)
            }
            syncVisibleActivity()
        }

        var cwd: String?
        var baseSnapshot: HudChatThreadSnapshot?
        if originalRoot == nil, usesCustomWorkingDirectory {
            let path = newWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path.hasPrefix("/") else {
                setErrorIfDisplayed(
                    "Enter an absolute path beginning with /, or choose Home (~).",
                    machineID: requestedMachine,
                    rootRunID: originalRoot,
                    revision: requestRevision
                )
                return
            }
            guard capabilities.hudChatWorkingDirectory else {
                setErrorIfDisplayed(
                    "Update the Companion server on this machine before starting a HUD chat in a custom folder. Your draft was kept.",
                    machineID: requestedMachine,
                    rootRunID: originalRoot,
                    revision: requestRevision
                )
                return
            }
            cwd = path
        } else if let originalRoot {
            let expectedLatest = latestRunID
            let refreshed = await refreshConversation(
                machineID: requestedMachine,
                rootRunID: originalRoot,
                transport: transport,
                expectedRevision: requestRevision,
                mutationOwned: true
            )
            guard refreshed else { return }
            guard isDisplayedConversation(machineID: requestedMachine, rootRunID: originalRoot, revision: requestRevision) else {
                return
            }
            guard latestRunID == expectedLatest else {
                errorMessage = "This chat has a newer reply. It was refreshed; review it before sending again. Your draft was kept."
                return
            }
            guard promotedPaneID == nil else {
                errorMessage = "This chat continued in a terminal. Open that pane to reply."
                return
            }
            guard !hasActiveRun else {
                errorMessage = "A reply is already running in this HUD chat."
                return
            }
            baseSnapshot = currentSnapshot()
        }

        do {
            let started = try await transport.startHudChat(
                machineID: requestedMachine,
                prompt: prompt,
                cwd: cwd,
                model: model,
                thinkingLevel: thinkingLevel,
                continueFromRunId: originalRoot == nil ? nil : baseSnapshot?.latestRunID
            )
            let root = started.threadRootRunId ?? originalRoot ?? started.id
            let accepted = Self.snapshot(appending: started, to: baseSnapshot, rootRunID: root)
            if let originalRoot {
                supersedeHistoryRequest(machineID: requestedMachine, rootRunID: originalRoot)
            }
            if root != originalRoot {
                supersedeHistoryRequest(machineID: requestedMachine, rootRunID: root)
            }
            historyCache[historyKey(machineID: requestedMachine, rootRunID: root)] = accepted
            reconcileCatalog(with: accepted, acceptedRun: started, machineID: requestedMachine)
            let isStillDisplayed = isDisplayedConversation(
                machineID: requestedMachine,
                rootRunID: originalRoot,
                revision: requestRevision
            )
            let laterDisplayedDraft = isStillDisplayed && draftGenerations[operationKey] != submittedDraftGeneration
                ? draft
                : nil
            clearSubmittedDraftIfUnchanged(
                key: operationKey,
                submittedGeneration: submittedDraftGeneration
            )

            guard isStillDisplayed else { return }
            advanceDisplayRevision(preservingConversationObservation: originalRoot != nil)
            apply(accepted)
            let acceptedDraftKey = draftKey(machineID: requestedMachine, rootRunID: root)
            if originalRoot == nil, let laterDisplayedDraft {
                storeDraft("", for: operationKey)
                storeDraft(laterDisplayedDraft, for: acceptedDraftKey)
            }
            restoreDraft(for: acceptedDraftKey)
            errorMessage = nil
            syncVisibleActivity()
        } catch {
            guard !HerdrCancellation.isCancellation(error) else { return }
            guard isDisplayedConversation(
                machineID: requestedMachine,
                rootRunID: originalRoot,
                revision: requestRevision
            ) else { return }
            if Self.isConflict(error), let originalRoot {
                _ = await refreshConversation(
                    machineID: requestedMachine,
                    rootRunID: originalRoot,
                    transport: transport,
                    expectedRevision: requestRevision,
                    clearErrorOnSuccess: false,
                    mutationOwned: true
                )
                if isDisplayedConversation(machineID: requestedMachine, rootRunID: originalRoot, revision: requestRevision) {
                    errorMessage = "The chat changed on another device. It was refreshed and your draft was kept. Send again only after reviewing it."
                }
            } else {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func stop(transport: any HudChatTransport) async {
        guard let requestedRoot = rootRunID, !machineID.isEmpty else { return }
        let requestedMachine = machineID
        let requestRevision = revision
        let operationKey = draftKey(machineID: requestedMachine, rootRunID: requestedRoot)
        guard activeStops[operationKey] == nil, activeSubmissions[operationKey] == nil else { return }
        let operationID = UUID()
        activeStops[operationKey] = operationID
        syncVisibleActivity()
        errorMessage = nil
        defer {
            if activeStops[operationKey] == operationID {
                activeStops.removeValue(forKey: operationKey)
            }
            syncVisibleActivity()
        }

        let refreshed = await refreshConversation(
            machineID: requestedMachine,
            rootRunID: requestedRoot,
            transport: transport,
            expectedRevision: requestRevision,
            mutationOwned: true
        )
        guard refreshed else { return }
        guard isDisplayedConversation(machineID: requestedMachine, rootRunID: requestedRoot, revision: requestRevision) else {
            return
        }
        guard let run = latestRun, !run.status.isTerminal else {
            errorMessage = "There is no active HUD chat run to stop."
            return
        }
        let baseSnapshot = currentSnapshot()
        do {
            let stopped = try await transport.stopHudChat(machineID: requestedMachine, runID: run.id)
            let accepted = Self.snapshot(appending: stopped, to: baseSnapshot, rootRunID: requestedRoot)
            supersedeHistoryRequest(machineID: requestedMachine, rootRunID: requestedRoot)
            historyCache[historyKey(machineID: requestedMachine, rootRunID: requestedRoot)] = accepted
            reconcileCatalog(with: accepted, acceptedRun: stopped, machineID: requestedMachine)
            guard isDisplayedConversation(machineID: requestedMachine, rootRunID: requestedRoot, revision: requestRevision) else {
                return
            }
            advanceDisplayRevision(preservingConversationObservation: true)
            apply(accepted)
            syncVisibleActivity()
        } catch {
            guard !HerdrCancellation.isCancellation(error) else { return }
            if isDisplayedConversation(machineID: requestedMachine, rootRunID: requestedRoot, revision: requestRevision) {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Called from a SwiftUI `.task`; cancellation on dismissal/background is
    /// the lifecycle, and never maps to a server stop or delete.
    func observe(
        transport: any HudChatTransport,
        waitForNextPoll: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(3))
        }
    ) async {
        guard isShowingConversation, let observedRoot = rootRunID else { return }
        let observedMachine = machineID
        let observationID = UUID()
        conversationObservationID = observationID
        isObserving = true
        defer {
            if conversationObservationID == observationID {
                conversationObservationID = nil
                isObserving = false
            }
        }
        while !Task.isCancelled,
              conversationObservationID == observationID,
              isDisplayedConversation(machineID: observedMachine, rootRunID: observedRoot) {
            let key = draftKey(machineID: observedMachine, rootRunID: observedRoot)
            if activeSubmissions[key] == nil, activeStops[key] == nil {
                _ = await refreshConversation(
                    machineID: observedMachine,
                    rootRunID: observedRoot,
                    transport: transport,
                    expectedRevision: revision,
                    clearErrorOnSuccess: false
                )
            }
            do {
                try await waitForNextPoll()
            } catch {
                return
            }
        }
    }

    /// Foreground/view-scoped catalog synchronization. SwiftUI cancellation is
    /// the only lifecycle; no hidden/global polling task is retained.
    func observeCatalog(transport: any HudChatTransport) async {
        guard !isShowingConversation, !machineID.isEmpty else { return }
        let observedMachine = machineID
        let observedQuery = query
        let observationID = UUID()
        catalogObservationID = observationID
        defer {
            if catalogObservationID == observationID {
                catalogObservationID = nil
            }
        }
        while !Task.isCancelled,
              catalogObservationID == observationID,
              isDisplayedCatalog(machineID: observedMachine, query: observedQuery) {
            await syncCatalog(transport: transport)
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    @discardableResult
    private func refreshConversation(
        machineID requestedMachine: String,
        rootRunID requestedRoot: String,
        transport: any HudChatTransport,
        expectedRevision: Int,
        clearErrorOnSuccess: Bool = true,
        mutationOwned: Bool = false
    ) async -> Bool {
        let key = historyKey(machineID: requestedMachine, rootRunID: requestedRoot)
        if !mutationOwned {
            let operationKey = draftKey(machineID: requestedMachine, rootRunID: requestedRoot)
            guard activeSubmissions[operationKey] == nil, activeStops[operationKey] == nil else { return false }
        }
        let owner = UUID()
        historyRequests[key] = owner
        syncVisibleActivity()
        defer {
            if historyRequests[key] == owner {
                historyRequests.removeValue(forKey: key)
            }
            syncVisibleActivity()
        }
        do {
            let snapshot = try await fetchAllHistory(
                machineID: requestedMachine,
                id: requestedRoot,
                transport: transport
            )
            try Task.checkCancellation()
            guard historyRequests[key] == owner else { return false }
            historyCache[key] = snapshot
            historyCache[historyKey(machineID: requestedMachine, rootRunID: snapshot.rootRunID)] = snapshot
            guard isDisplayedConversation(
                machineID: requestedMachine,
                rootRunID: requestedRoot,
                revision: expectedRevision
            ) else { return false }
            apply(snapshot)
            if clearErrorOnSuccess { errorMessage = nil }
            return true
        } catch {
            guard !HerdrCancellation.isCancellation(error), historyRequests[key] == owner else { return false }
            if isDisplayedConversation(
                machineID: requestedMachine,
                rootRunID: requestedRoot,
                revision: expectedRevision
            ) {
                errorMessage = Self.message(for: error)
            }
            return false
        }
    }

    private func fetchAllHistory(
        machineID: String,
        id: String,
        transport: any HudChatTransport
    ) async throws -> HudChatThreadSnapshot {
        var page = try await transport.fetchHudChatHistory(machineID: machineID, id: id, offset: 0)
        let root = page.rootRunId
        let latest = page.latestRunId
        let promoted = page.promotedPaneId
        var allTurns = page.turns
        var seenOffsets: Set<Int> = []
        while let offset = page.nextOffset {
            guard seenOffsets.insert(offset).inserted else { throw APIError.invalidResponse }
            try Task.checkCancellation()
            page = try await transport.fetchHudChatHistory(machineID: machineID, id: root, offset: offset)
            guard page.rootRunId == root, page.latestRunId == latest, page.promotedPaneId == promoted else {
                throw APIError.server(
                    status: 409,
                    message: "The HUD chat changed while loading. Refresh it and try again."
                )
            }
            allTurns.append(contentsOf: page.turns)
        }
        return HudChatThreadSnapshot(
            turns: Self.uniqueRuns(allTurns),
            rootRunID: root,
            latestRunID: latest,
            promotedPaneID: promoted
        )
    }

    private func apply(_ snapshot: HudChatThreadSnapshot) {
        turns = snapshot.turns
        rootRunID = snapshot.rootRunID
        latestRunID = snapshot.latestRunID
        promotedPaneID = snapshot.promotedPaneID
    }

    private func currentSnapshot() -> HudChatThreadSnapshot {
        HudChatThreadSnapshot(
            turns: turns,
            rootRunID: rootRunID ?? turns.first?.threadRootRunId ?? turns.first?.id ?? "",
            latestRunID: latestRunID ?? turns.last?.id ?? "",
            promotedPaneID: promotedPaneID
        )
    }

    private func advanceDisplayRevision(preservingConversationObservation: Bool = false) {
        revision += 1
        if !preservingConversationObservation {
            conversationObservationID = nil
            isObserving = false
        }
        catalogObservationID = nil
        syncVisibleActivity()
    }

    private func supersedeHistoryRequest(machineID: String, rootRunID: String) {
        historyRequests.removeValue(forKey: historyKey(machineID: machineID, rootRunID: rootRunID))
    }

    private func beginCatalogRequest(key: String, showsLoading: Bool) -> UUID {
        let owner = UUID()
        catalogRequests[key] = RequestOwnership(id: owner, showsLoading: showsLoading)
        syncVisibleActivity()
        return owner
    }

    private func finishCatalogRequest(key: String, owner: UUID) {
        if catalogRequests[key]?.id == owner {
            catalogRequests.removeValue(forKey: key)
        }
        syncVisibleActivity()
    }

    private func ownsCatalogRequest(key: String, owner: UUID) -> Bool {
        catalogRequests[key]?.id == owner
    }

    private func syncVisibleActivity() {
        let catalogKey = catalogKey(machineID: machineID, query: query)
        isLoadingCatalog = !isShowingConversation && catalogRequests[catalogKey]?.showsLoading == true
        if let rootRunID {
            let historyKey = historyKey(machineID: machineID, rootRunID: rootRunID)
            let operationKey = draftKey(machineID: machineID, rootRunID: rootRunID)
            isLoadingHistory = isShowingConversation && historyRequests[historyKey] != nil
            isSubmitting = isShowingConversation && activeSubmissions[operationKey] != nil
            isStopping = isShowingConversation && activeStops[operationKey] != nil
        } else {
            let operationKey = draftKey(machineID: machineID, rootRunID: nil)
            isLoadingHistory = false
            isSubmitting = isShowingConversation && activeSubmissions[operationKey] != nil
            isStopping = false
        }
    }

    private var displayedDraftKey: String? {
        guard !machineID.isEmpty else { return nil }
        return draftKey(machineID: machineID, rootRunID: rootRunID)
    }

    private func storeDraft(_ value: String, for key: String) {
        nextDraftGeneration += 1
        drafts[key] = value
        draftGenerations[key] = nextDraftGeneration
    }

    private func restoreDraft(for key: String) {
        isRestoringDraft = true
        draft = drafts[key] ?? ""
        isRestoringDraft = false
    }

    private func clearSubmittedDraftIfUnchanged(key: String, submittedGeneration: Int) {
        guard draftGenerations[key] == submittedGeneration else { return }
        storeDraft("", for: key)
        if displayedDraftKey == key {
            isRestoringDraft = true
            draft = ""
            isRestoringDraft = false
        }
    }

    private func setErrorIfDisplayed(
        _ message: String,
        machineID: String,
        rootRunID: String?,
        revision: Int
    ) {
        guard isDisplayedConversation(machineID: machineID, rootRunID: rootRunID, revision: revision) else { return }
        errorMessage = message
    }

    private func isDisplayedCatalog(machineID: String, query: String) -> Bool {
        !isShowingConversation && self.machineID == machineID && self.query == query
    }

    private func isDisplayedConversation(machineID: String, rootRunID: String?, revision: Int? = nil) -> Bool {
        guard isShowingConversation, self.machineID == machineID, self.rootRunID == rootRunID else { return false }
        return revision.map { $0 == self.revision } ?? true
    }

    private func reconcileCatalog(
        with snapshot: HudChatThreadSnapshot,
        acceptedRun: HeadlessAgentRun,
        machineID: String
    ) {
        let prefix = "\(machineID)\u{0}"
        let keys = catalogCache.keys.filter { $0.hasPrefix(prefix) }
        var updatedExisting = false
        for key in keys {
            guard var cached = catalogCache[key],
                  let index = cached.firstIndex(where: { $0.id == snapshot.rootRunID }) else { continue }
            cached[index] = Self.summary(
                replacing: cached[index],
                snapshot: snapshot,
                acceptedRun: acceptedRun
            )
            catalogCache[key] = cached
            updatedExisting = true
        }

        let unfilteredKey = catalogKey(machineID: machineID, query: "")
        if !updatedExisting || catalogCache[unfilteredKey]?.contains(where: { $0.id == snapshot.rootRunID }) != true {
            let created = HudChatSummary(
                id: snapshot.rootRunID,
                title: Self.title(for: snapshot.turns.first?.prompt ?? acceptedRun.prompt),
                updatedAt: acceptedRun.createdAt,
                latestRunId: snapshot.latestRunID,
                turnCount: snapshot.turns.count,
                status: acceptedRun.status,
                sessionId: acceptedRun.sessionID,
                promotedPaneId: snapshot.promotedPaneID,
                cwd: snapshot.turns.lazy.compactMap(\.cwd).first ?? acceptedRun.cwd
            )
            catalogCache[unfilteredKey] = Self.unique([created] + (catalogCache[unfilteredKey] ?? []))
        }

        if isDisplayedCatalog(machineID: machineID, query: query),
           let cached = catalogCache[catalogKey(machineID: machineID, query: query)] {
            chats = cached
        }
    }

    private func draftKey(machineID: String, rootRunID: String?) -> String {
        MachineScopedID.compose(machineID: machineID, rawID: rootRunID ?? "new")
    }

    private func catalogKey(machineID: String, query: String) -> String {
        "\(machineID)\u{0}\(query)"
    }

    private func historyKey(machineID: String, rootRunID: String) -> String {
        MachineScopedID.compose(machineID: machineID, rawID: rootRunID)
    }

    private static func snapshot(
        appending run: HeadlessAgentRun,
        to base: HudChatThreadSnapshot?,
        rootRunID: String
    ) -> HudChatThreadSnapshot {
        var turns = base?.turns ?? []
        if let index = turns.firstIndex(where: { $0.id == run.id }) {
            turns[index] = run
        } else {
            turns.append(run)
        }
        return HudChatThreadSnapshot(
            turns: turns,
            rootRunID: rootRunID,
            latestRunID: run.id,
            promotedPaneID: run.promotedPaneID ?? base?.promotedPaneID
        )
    }

    private static func summary(
        replacing existing: HudChatSummary,
        snapshot: HudChatThreadSnapshot,
        acceptedRun: HeadlessAgentRun
    ) -> HudChatSummary {
        HudChatSummary(
            id: existing.id,
            title: existing.title,
            updatedAt: acceptedRun.createdAt,
            latestRunId: snapshot.latestRunID,
            turnCount: snapshot.turns.count,
            status: acceptedRun.status,
            sessionId: acceptedRun.sessionID ?? existing.sessionId,
            promotedPaneId: snapshot.promotedPaneID,
            cwd: snapshot.turns.lazy.compactMap(\.cwd).first ?? existing.cwd
        )
    }

    private static func title(for prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Saved HUD chat" : String(trimmed.prefix(80))
    }

    private static func unique(_ summaries: [HudChatSummary]) -> [HudChatSummary] {
        var seen: Set<String> = []
        return summaries.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueRuns(_ runs: [HeadlessAgentRun]) -> [HeadlessAgentRun] {
        var seen: Set<String> = []
        return runs.filter { seen.insert($0.id).inserted }
    }

    private static let upgradeMessage =
        "Update the Companion server on this machine to use saved HUD chats. Existing terminal chats were left unchanged."

    private static func isConflict(_ error: any Error) -> Bool {
        if case let APIError.server(status, _) = error { return status == 409 }
        return false
    }

    private static func message(for error: any Error, capabilityRequest: Bool = false) -> String {
        if case let APIError.server(status, message) = error {
            if status == 401 || status == 403 {
                return "Authentication failed for this machine. Check its saved server token in Settings."
            }
            if capabilityRequest && (status == 404 || status == 426) {
                return upgradeMessage
            }
            if !message.isEmpty { return message }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return "This machine is offline or unreachable. Cached chats and your draft were kept."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
