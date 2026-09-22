import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class FirstMateStore {
    struct OperationContext: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let featureID: String?
    }

    /// Capture when the human acts, before scheduling an asynchronous UI task.
    var operationContext: OperationContext { .init(generation: generation, featureID: selectedFeatureID) }

    private(set) var features: [FirstMateFeature] = []
    private(set) var snapshots: [String: FirstMateSnapshot] = [:]
    var selectedFeatureID: String?
    var inspector = FirstMateInspector.overview
    var graphMode = false
    var selectedVisitID: String?
    var draft = ""
    var search = ""
    var showArchived = false
    var isCreating = false
    #if os(macOS)
    var isDark = true
    #else
    var isDark = ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateDark")
    #endif
    private(set) var isDemo = false
    private(set) var isRefreshing = false
    private(set) var isSending = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var unsupported = false
    private(set) var archiveSupported = false
    private(set) var lastUpdated: Date?
    var openedResource: FirstMateResource?
    var resourcePresentation: FirstMateResourcePresentation?
    private(set) var resourceText = ""
    private(set) var resourceLoading = false
    private(set) var resourceError: String?
    private(set) var resourceUsage: FirstMateUsage?
    private(set) var sessionNextBefore: Int?
    private(set) var sessionTotalMessages: Int?
    private(set) var sessionLoadedMessages = 0
    private(set) var isLoadingEarlier = false
    private(set) var sessionPageError: String?
    private var generation = 0
    private var resourceGeneration = 0
    private var drafts: [String: String] = [:]
    private var pendingMessages: [String: (text: String, requestID: String)] = [:]
    private var demoStep = 0
    @ObservationIgnored private var client: (any FirstMateClient)?

    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var snapshot: FirstMateSnapshot? { selectedFeatureID.flatMap { snapshots[$0] } }
    var hasUnsentDrafts: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || drafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var filteredFeatures: [FirstMateFeature] {
        features.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.goal.localizedCaseInsensitiveContains(search) }
    }
    var activeFeatures: [FirstMateFeature] { filteredFeatures.filter { !$0.isArchived } }
    var archivedFeatures: [FirstMateFeature] { filteredFeatures.filter(\.isArchived) }

    func configure(client: (any FirstMateClient)?, demo: Bool) {
        generation += 1
        resourceGeneration += 1
        self.client = client
        isDemo = demo
        features = []
        snapshots = [:]
        selectedFeatureID = nil
        selectedVisitID = nil
        draft = ""
        drafts = [:]
        pendingMessages = [:]
        openedResource = nil
        resourcePresentation = nil
        resourceText = ""
        resourceLoading = false
        resourceError = nil
        resourceUsage = nil
        resetSessionPagination()
        error = nil
        unsupported = false
        archiveSupported = demo
        isRefreshing = false
        isSending = false
        isCreating = false
        showArchived = false
        hasLoaded = false
        lastUpdated = nil
        if demo {
            demoStep = 0
            for value in FirstMateDemo.features(step: 0) { receive(value) }
            selectedFeatureID = features.first?.id
            hasLoaded = true
        }
    }

    func select(_ id: String) {
        if let old = selectedFeatureID { drafts[old] = draft }
        selectedFeatureID = id
        draft = drafts[id] ?? ""
        selectedVisitID = snapshots[id]?.feature.currentVisitID
        error = nil
        closeResource()
    }

    func receive(_ value: FirstMateSnapshot) {
        guard value.ok else { return }
        if let existing = snapshots[value.feature.id],
           existing.feature.revision > value.feature.revision ||
           (existing.feature.modelSettingsRevision ?? 0) > (value.feature.modelSettingsRevision ?? 0) { return }
        if value.hasDetails, let existing = snapshots[value.feature.id], existing.feature.revision == value.feature.revision,
           (existing.events.map(\.sequence).max() ?? 0) > (value.events.map(\.sequence).max() ?? 0) { return }
        if !value.hasDetails, var existing = snapshots[value.feature.id] {
            // Mutations acknowledge the feature; their omitted arrays and usage are not deletions.
            var feature = value.feature
            if feature.usage == nil { feature.usage = existing.feature.usage }
            existing.feature = feature
            snapshots[value.feature.id] = existing
        } else { snapshots[value.feature.id] = value }
        let acceptedFeature = snapshots[value.feature.id]?.feature ?? value.feature
        if let index = features.firstIndex(where: { $0.id == value.feature.id }) {
            features[index] = acceptedFeature
        } else { features.append(acceptedFeature) }
        lastUpdated = .now
    }

    func refresh() async {
        guard !isRefreshing else { return }
        if isDemo {
            features = snapshots.values.map(\.feature)
                .filter { showArchived || !$0.isArchived }
                .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            reconcileSelection()
            return
        }
        guard let client else { return }
        let capturedGeneration = generation
        isRefreshing = true
        defer { if capturedGeneration == generation { isRefreshing = false } }
        do {
            do {
                let capabilities = try await client.fetchFirstMateCapabilities()
                guard capturedGeneration == generation else { return }
                archiveSupported = capabilities.ok && capabilities.supportsArchive
            } catch {
                guard capturedGeneration == generation else { return }
                archiveSupported = false
            }
            let list = try await client.fetchFirstMateFeatures(scope: showArchived ? .all : .active)
            guard capturedGeneration == generation else { return }
            guard list.ok else { throw APIError.invalidResponse }
            features = list.features.map { feature in
                guard let cached = snapshots[feature.id]?.feature else { return feature }
                if cached.revision > feature.revision || cached.updatedAt > feature.updatedAt {
                    var retained = cached
                    if let usage = feature.usage { retained.usage = usage }
                    return retained
                }
                var refreshed = feature
                if refreshed.usage == nil { refreshed.usage = cached.usage }
                return refreshed
            }
            reconcileSelection()
            if let id = selectedFeatureID {
                let value = try await client.fetchFirstMateFeature(id)
                guard capturedGeneration == generation else { return }
                guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
                receive(value)
            }
            hasLoaded = true
            unsupported = false
            error = nil
            lastUpdated = .now
        } catch is CancellationError { return }
        catch {
            guard capturedGeneration == generation else { return }
            hasLoaded = true
            record(error)
        }
    }

    func create(title: String, goal: String, cwd: String, requestID: String, expectedContext: OperationContext? = nil) async -> Bool {
        if let expectedContext, expectedContext != operationContext { return false }
        guard !isSending else { return false }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        if isDemo {
            let feature = FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd)
            receive(feature)
            select(feature.feature.id)
            return true
        }
        guard let client else { error = "Connect to a companion server to create a feature."; return false }
        do {
            let value = try await client.createFirstMateFeature(title: title, goal: goal, cwd: cwd, requestID: requestID)
            guard capturedGeneration == generation else { return false }
            guard value.ok, !value.feature.id.isEmpty else { throw APIError.invalidResponse }
            receive(value)
            select(value.feature.id)
            await refresh()
            return true
        } catch {
            guard capturedGeneration == generation else { return false }
            record(error)
            return false
        }
    }

    func send(expectedContext: OperationContext? = nil, expectedText: String? = nil) async {
        if let expectedContext, expectedContext != operationContext { return }
        if let expectedText, expectedText != draft { return }
        guard let id = selectedFeatureID, !isSending else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isDemo { sendDemo(text, featureID: id); return }
        guard let client else { error = "Connect to send your direction."; return }
        let pending = pendingMessages[id].flatMap { $0.text == text ? $0 : nil }
            ?? (text: text, requestID: UUID().uuidString)
        pendingMessages[id] = pending
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.sendFirstMateMessage(featureID: id, text: text, requestID: pending.requestID)
            guard capturedGeneration == generation else { return }
            guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
            receive(value)
            pendingMessages[id] = nil
            if selectedFeatureID == id, draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            if drafts[id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { drafts[id] = nil }
            error = nil
            await refresh()
        } catch {
            guard capturedGeneration == generation else { return }
            record(error)
        }
    }

    func perform(_ action: String, expectedContext: OperationContext? = nil) async {
        if let expectedContext, expectedContext != operationContext { return }
        guard let id = selectedFeatureID, !isSending else { return }
        if isDemo {
            guard var value = snapshot else { return }
            value.feature.status = action == "pause" ? "paused" : action == "cancel" ? "cancelled" : "awaiting_direction"
            value.feature.revision += 1
            receive(value)
            return
        }
        guard let client else { return }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.performFirstMateAction(featureID: id, action: action, requestID: UUID().uuidString)
            guard capturedGeneration == generation else { return }
            guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
            receive(value)
            if archived && !showArchived {
                features.removeAll { $0.id == featureID }
                reconcileSelection()
            }
            error = nil
            await refresh()
        } catch { if capturedGeneration == generation { record(error) } }
    }

    func setArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason? = nil) async -> Bool {
        guard !isSending else { return false }
        if isDemo {
            guard var value = snapshots[featureID] else { return false }
            value.feature.archivedAt = archived ? FirstMateDemo.timestamp : nil
            value.feature.archiveReason = archived ? reason?.rawValue : nil
            receive(value)
            if archived && !showArchived { features.removeAll { $0.id == featureID } }
            reconcileSelection()
            return true
        }
        guard archiveSupported else {
            error = "Update this companion server to archive First Mate features."
            return false
        }
        guard let client else { error = "Connect to archive this feature."; return false }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.setFirstMateArchived(
                featureID: featureID,
                archived: archived,
                reason: archived ? reason : nil,
                requestID: UUID().uuidString
            )
            guard capturedGeneration == generation, value.ok, value.feature.id == featureID else {
                throw APIError.invalidResponse
            }
            receive(value)
            error = nil
            await refresh()
            return true
        } catch {
            if capturedGeneration == generation { record(error) }
            return false
        }
    }

    func fetchModelCatalog(expectedContext: OperationContext) async throws -> FirstMateModelCatalog {
        guard expectedContext == operationContext, !isDemo, let client else { throw APIError.invalidResponse }
        let catalog = try await client.fetchFirstMateModels()
        guard expectedContext == operationContext, catalog.ok else { throw APIError.invalidResponse }
        return catalog
    }

    func saveModelSettings(_ settings: FirstMateModelSettings, expectedContext: OperationContext) async throws {
        guard expectedContext == operationContext, let id = selectedFeatureID,
              !isDemo, !isSending, let client else { throw APIError.invalidResponse }
        let capturedGeneration = generation
        isSending = true
        defer { if generation == capturedGeneration { isSending = false } }
        let value = try await client.setFirstMateModel(featureID: id, settings: settings)
        guard generation == capturedGeneration, value.ok, value.feature.id == id else { throw APIError.invalidResponse }
        receive(value)
    }

    func open(_ resource: FirstMateResource) async {
        resourceGeneration += 1
        let token = resourceGeneration
        openedResource = resource
        if resourcePresentation == nil { resourcePresentation = FirstMateResourcePresentation() }
        resourceText = ""
        resourceError = nil
        resourceUsage = resource.usage(in: snapshot)
        resetSessionPagination()
        resourceLoading = true
        defer { if token == resourceGeneration { resourceLoading = false } }
        if isDemo {
            resourceText = FirstMateDemo.content(for: resource, snapshot: snapshot)
            return
        }
        guard let client else { resourceError = "Reconnect to this feature's host to read its saved resource."; return }
        do {
            let content: String
            switch resource {
            case .document(let document):
                let response = try await client.fetchFirstMateDocument(document.id)
                guard response.ok, response.document.id == document.id else { throw APIError.invalidResponse }
                content = response.document.content ?? response.content ?? "This document has no text preview."
            case .session, .history:
                guard let sessionID = resource.nativeSessionID else { throw APIError.invalidResponse }
                let response = try await client.fetchFirstMateSession(sessionID, before: nil)
                guard response.ok, response.nativeSessionID == sessionID else { throw APIError.invalidResponse }
                guard token == resourceGeneration else { return }
                sessionNextBefore = response.nextBefore
                sessionTotalMessages = response.totalMessages
                sessionLoadedMessages = response.messages?.count ?? 0
                if let usage = response.usage { resourceUsage = usage }
                content = response.messages?.map { "\($0.role.capitalized)\n\($0.text)" }.joined(separator: "\n\n")
                    ?? response.content ?? "The saved session does not have any messages yet."
            }
            guard token == resourceGeneration else { return }
            resourceText = content
        } catch { if token == resourceGeneration { resourceError = error.localizedDescription } }
    }

    func closeResource() {
        resourceGeneration += 1
        openedResource = nil
        resourcePresentation = nil
        resourceLoading = false
        resourceUsage = nil
        resetSessionPagination()
    }

    func loadEarlierSessionMessages() async {
        guard !isLoadingEarlier, let before = sessionNextBefore,
              let sessionID = openedResource?.nativeSessionID, let client else { return }
        let token = resourceGeneration
        isLoadingEarlier = true
        sessionPageError = nil
        defer { if token == resourceGeneration { isLoadingEarlier = false } }
        do {
            let response = try await client.fetchFirstMateSession(sessionID, before: before)
            guard token == resourceGeneration else { return }
            guard response.ok, response.nativeSessionID == sessionID else { throw APIError.invalidResponse }
            if let next = response.nextBefore, next < 0 || next >= before { throw APIError.invalidResponse }
            let earlier = response.messages ?? []
            let text = earlier.map { "\($0.role.capitalized)\n\($0.text)" }.joined(separator: "\n\n")
            if !text.isEmpty { resourceText = text + (resourceText.isEmpty ? "" : "\n\n" + resourceText) }
            sessionLoadedMessages += earlier.count
            sessionNextBefore = response.nextBefore
            sessionTotalMessages = response.totalMessages ?? sessionTotalMessages
            if let usage = response.usage { resourceUsage = usage }
        } catch { if token == resourceGeneration { sessionPageError = error.localizedDescription } }
    }

    private func resetSessionPagination() {
        sessionNextBefore = nil
        sessionTotalMessages = nil
        sessionLoadedMessages = 0
        isLoadingEarlier = false
        sessionPageError = nil
    }

    private func reconcileSelection() {
        guard selectedFeatureID == nil || !features.contains(where: { $0.id == selectedFeatureID }) else { return }
        if let first = features.first {
            select(first.id)
        } else {
            if let old = selectedFeatureID { drafts[old] = draft }
            selectedFeatureID = nil
            selectedVisitID = nil
            draft = ""
            closeResource()
        }
    }

    func advanceDemo() {
        guard isDemo else { return }
        demoStep = (demoStep + 1) % FirstMateDemo.stepTitles.count
        for value in FirstMateDemo.features(step: demoStep) {
            snapshots[value.feature.id] = nil
            receive(value)
        }
        selectedVisitID = snapshot?.feature.currentVisitID
    }
    var demoStepTitle: String { FirstMateDemo.stepTitles[demoStep] }

    private func sendDemo(_ text: String, featureID: String) {
        guard var value = snapshot else { return }
        value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "user", text: text, status: "delivered", createdAt: FirstMateDemo.timestamp))
        value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "assistant", text: "Your direction is recorded in this synthetic demo. Use Next scenario to inspect the planned implementation, review, checkpoint, and handoff states.", status: "delivered", createdAt: FirstMateDemo.timestamp))
        value.feature.revision += 1
        receive(value)
        draft = ""
    }

    private func record(_ failure: Error) {
        if case APIError.server(let status, _) = failure, status == 404 || status == 501 {
            unsupported = true
            error = "This companion server needs First Mate support. Update the server to a version with first-mate-v1."
        } else { error = failure.localizedDescription }
    }
}
