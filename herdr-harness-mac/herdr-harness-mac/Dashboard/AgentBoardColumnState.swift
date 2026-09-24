import Foundation
import Observation

@MainActor @Observable
final class AgentBoardColumnState {
    let machineID: String
    let featureID: String
    let resources = FirstMateStore()
    var tab = AgentBoardTab.chat
    var draft = ""
    var followsLatest = true
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var error: String?
    private(set) var sendError: String?
    private(set) var lastUpdated: Date?
    @ObservationIgnored var pollingInterval: Duration = .seconds(3)
    @ObservationIgnored private var client: (any FirstMateClient)?
    @ObservationIgnored private var configuration: ServerConfiguration?
    @ObservationIgnored private var connectionGeneration: Int?
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var pendingMessage: (text: String, requestID: String)?

    var snapshot: FirstMateSnapshot? { resources.snapshot }

    init(machineID: String, featureID: String) {
        self.machineID = machineID
        self.featureID = featureID
    }

    /// Authentication identity belongs to this column's owning host. Replacing
    /// that identity clears both cached content and staged text, never silently
    /// carrying a reply over to a different companion at the same machine ID.
    func configure(configuration: ServerConfiguration?, generation: Int, demo: Bool, client: (any FirstMateClient)?, demoSnapshot: FirstMateSnapshot? = nil) {
        guard connectionGeneration != generation || self.configuration != configuration || isDemo != demo else { return }
        let identityChanged = connectionGeneration == nil || self.configuration != configuration || isDemo != demo
        lifecycle = UUID()
        connectionGeneration = generation
        self.configuration = configuration
        isDemo = demo
        self.client = client
        isLoading = false
        isSending = false
        if identityChanged {
            resources.configure(client: client, demo: demo)
            resources.select(featureID)
            if demo, let demoSnapshot { receiveDemoSnapshot(demoSnapshot) }
            draft = ""
            pendingMessage = nil
            error = nil
            sendError = nil
            lastUpdated = demo ? .now : nil
            followsLatest = true
        }
    }

    func receiveDemoSnapshot(_ snapshot: FirstMateSnapshot) {
        guard isDemo, snapshot.feature.id == featureID else { return }
        resources.receive(snapshot)
        lastUpdated = .now
    }

    func observe() async {
        let expectedLifecycle = lifecycle
        guard isDemo || client != nil else {
            error = "This feature's companion is unavailable."
            return
        }
        guard !isDemo else { return }
        repeat {
            await refresh()
            do { try await Task.sleep(for: pollingInterval) } catch { return }
        } while !Task.isCancelled && lifecycle == expectedLifecycle
    }

    /// Deliberately fetches only one feature snapshot. Fleet metadata is owned by
    /// the dashboard and must not be refetched once for every visible column.
    func refresh() async {
        guard !Task.isCancelled, !isLoading, let client else { return }
        let expectedLifecycle = lifecycle
        isLoading = true
        defer { if lifecycle == expectedLifecycle { isLoading = false } }
        do {
            let value = try await client.fetchFirstMateFeature(featureID)
            guard !Task.isCancelled, lifecycle == expectedLifecycle else { return }
            guard value.ok, value.feature.id == featureID else { throw APIError.invalidResponse }
            resources.receive(value)
            lastUpdated = .now
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, lifecycle == expectedLifecycle else { return }
            if case APIError.server(let status, _) = error, status == 404 || status == 501 {
                self.error = "This companion needs First Mate support. Open the full view after updating it."
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    /// Called with the generation and authenticated identity captured at the
    /// actual button press. A delayed task cannot send a draft to a new host.
    func send(configuration: ServerConfiguration?, generation: Int, canControl: Bool,
              isCurrent: @MainActor () -> Bool) async {
        guard canControl, isCurrent(), self.configuration == configuration,
              connectionGeneration == generation, !isSending,
              let snapshot, !snapshot.feature.isArchived,
              !["completed", "cancelled"].contains(snapshot.feature.status) else { return }
        let originalDraft = draft
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let expectedLifecycle = lifecycle
        if isDemo {
            var value = snapshot
            let timestamp = ISO8601DateFormatter().string(from: .now)
            value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "user", text: text,
                                        status: "delivered", createdAt: timestamp))
            value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "assistant",
                                        text: "Your direction is recorded in this demo.", status: "delivered", createdAt: timestamp))
            value.feature.revision += 1
            resources.receive(value)
            draft = ""
            lastUpdated = .now
            return
        }
        guard let client else { return }
        let pending = pendingMessage.flatMap { $0.text == text ? $0 : nil }
            ?? (text: text, requestID: UUID().uuidString)
        pendingMessage = pending
        isSending = true
        sendError = nil
        defer { if lifecycle == expectedLifecycle { isSending = false } }
        do {
            let value = try await client.sendFirstMateMessage(featureID: featureID, text: text, requestID: pending.requestID)
            guard lifecycle == expectedLifecycle, isCurrent() else { return }
            guard value.ok, value.feature.id == featureID else { throw APIError.invalidResponse }
            resources.receive(value)
            pendingMessage = nil
            if draft == originalDraft { draft = "" }
            lastUpdated = .now
            await refresh()
        } catch {
            guard lifecycle == expectedLifecycle, isCurrent() else { return }
            sendError = error.localizedDescription
        }
    }
}
