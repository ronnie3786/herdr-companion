import Foundation
import Observation

@MainActor @Observable
final class AgentBoardColumnState {
    let machineID: String
    let featureID: String
    var tab = AgentBoardTab.chat
    var draft = ""
    private(set) var content: AgentBoardContent?
    private(set) var loadError: String?
    private(set) var isSending = false
    private(set) var sendError: String?
    /// When this feature last changed on screen, not when it was last polled.
    private(set) var lastChanged: Date?
    /// Created on first use: only a column whose saved session is opened needs
    /// a resource store.
    private(set) var resourceStore: FirstMateStore?

    @ObservationIgnored var boardInterval: Duration = .seconds(4)
    @ObservationIgnored var fallbackInterval: Duration = .seconds(15)
    @ObservationIgnored private(set) var lastContact: Date?
    @ObservationIgnored private(set) var payload: AgentBoardPayload?
    @ObservationIgnored private var version: String?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var client: (any AgentBoardClient)?
    @ObservationIgnored private var configuration: ServerConfiguration?
    @ObservationIgnored private var connectionGeneration: Int?
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var isRefreshing = false
    /// A forced refresh that arrived while a poll was running; the poll
    /// repeats once so a just-sent reply appears without waiting a cycle.
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var pendingMessage: (text: String, requestID: String)?

    init(machineID: String, featureID: String) {
        self.machineID = machineID
        self.featureID = featureID
    }

    /// A column with text or a send in flight survives being filtered out or
    /// its feature leaving the list.
    var hasUnsentWork: Bool {
        isSending || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Authentication identity belongs to this column's owning host. Replacing
    /// that identity clears both cached content and staged text, never silently
    /// carrying a reply over to a different companion at the same machine ID.
    func configure(configuration: ServerConfiguration?, generation: Int, demo: Bool, client: (any AgentBoardClient)?, demoSnapshot: FirstMateSnapshot? = nil) {
        guard connectionGeneration != generation || self.configuration != configuration || isDemo != demo else { return }
        let identityChanged = connectionGeneration == nil || self.configuration != configuration || isDemo != demo
        lifecycle = UUID()
        connectionGeneration = generation
        self.configuration = configuration
        isDemo = demo
        self.client = client
        isRefreshing = false
        isSending = false
        version = nil
        failures = 0
        resourceStore = nil
        if identityChanged {
            content = nil
            payload = nil
            draft = ""
            pendingMessage = nil
            loadError = nil
            sendError = nil
            lastChanged = nil
            lastContact = nil
            if demo, let demoSnapshot { receiveDemoSnapshot(demoSnapshot) }
        }
    }

    /// Demo content is small and has no server, so it is built in place.
    func receiveDemoSnapshot(_ snapshot: FirstMateSnapshot) {
        guard isDemo, snapshot.feature.id == featureID else { return }
        let payload = AgentBoardPayload.adapting(snapshot)
        guard payload != self.payload else { return }
        self.payload = payload
        publish(AgentBoardContent.build(from: payload))
    }

    /// Polls while the owning view's task is alive. An unchanged board costs one
    /// small request and publishes nothing.
    func observe(capabilities: @MainActor () async -> FirstMateCapabilities?) async {
        let expectedLifecycle = lifecycle
        guard !isDemo else { return }
        guard client != nil else {
            if loadError == nil { loadError = "This feature's companion is unavailable." }
            return
        }
        while !Task.isCancelled, lifecycle == expectedLifecycle {
            let supported = await capabilities()
            guard !Task.isCancelled, lifecycle == expectedLifecycle else { return }
            await refresh(capabilities: supported)
            let base = supported?.supportsBoard == true ? boardInterval : fallbackInterval
            let delay = failures == 0 ? base : min(base * (1 << min(failures, 3)), .seconds(30))
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    func refresh(capabilities: FirstMateCapabilities?, force: Bool = false) async {
        guard !Task.isCancelled, let client else { return }
        if isRefreshing {
            if force { refreshAgain = true }
            return
        }
        let expectedLifecycle = lifecycle
        isRefreshing = true
        defer { if lifecycle == expectedLifecycle { isRefreshing = false } }
        var forced = force
        repeat {
            refreshAgain = false
            await fetch(client: client, capabilities: capabilities, force: forced, expectedLifecycle: expectedLifecycle)
            forced = true
        } while refreshAgain && lifecycle == expectedLifecycle && !Task.isCancelled
    }

    private func fetch(client: any AgentBoardClient, capabilities: FirstMateCapabilities?, force: Bool, expectedLifecycle: UUID) async {
        // Unknown capabilities mean the host did not answer. Never guess the old
        // full-history download for a companion that may serve boards.
        guard let capabilities else {
            failures += 1
            let message = "This companion isn't answering right now."
            if loadError != message { loadError = message }
            return
        }
        do {
            var received: AgentBoardPayload?
            var built: AgentBoardContent?
            if capabilities.supportsBoard {
                let fetch = try await client.fetchFirstMateBoard(
                    featureID: featureID, messageLimit: AgentBoardPayload.messageLimit,
                    journalLimit: AgentBoardPayload.journalLimit, ifVersion: force ? nil : version)
                guard lifecycle == expectedLifecycle else { return }
                if case .board(let value) = fetch {
                    received = value
                    // The version covers everything the board shows.
                    if value.version != payload?.version { built = await AgentBoardContent.make(from: value) }
                }
            } else {
                let snapshot = try await client.fetchFirstMateFeature(
                    featureID, journalEventsOnly: capabilities.supportsJournalEvents)
                guard lifecycle == expectedLifecycle else { return }
                guard snapshot.ok, snapshot.feature.id == featureID else { throw APIError.invalidResponse }
                let (value, content) = await AgentBoardContent.make(adapting: snapshot)
                received = value
                if value.version != payload?.version { built = content }
            }
            guard !Task.isCancelled, lifecycle == expectedLifecycle else { return }
            lastContact = .now
            failures = 0
            if loadError != nil { loadError = nil }
            if let received {
                version = received.version
                payload = received
            }
            if let built { publish(built) }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, lifecycle == expectedLifecycle else { return }
            failures += 1
            let message: String
            if case APIError.server(let status, _) = error, status == 404 || status == 501 {
                message = "This companion needs First Mate support. Open the full view after updating it."
            } else {
                message = error.localizedDescription
            }
            if loadError != message { loadError = message }
        }
    }

    private func publish(_ value: AgentBoardContent) {
        guard value != content else { return }
        content = value
        lastChanged = .now
    }

    /// Called with the generation and authenticated identity captured at the
    /// actual button press. A delayed task cannot send a draft to a new host.
    /// `acceptsMessages` comes from the freshest known feature state, so a reply
    /// never waits for this column's first load.
    func send(configuration: ServerConfiguration?, generation: Int, canControl: Bool, acceptsMessages: Bool,
              capabilities: FirstMateCapabilities?, isCurrent: @MainActor () -> Bool) async {
        guard canControl, acceptsMessages, isCurrent(), self.configuration == configuration,
              connectionGeneration == generation, !isSending else { return }
        let originalDraft = draft
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let expectedLifecycle = lifecycle
        if isDemo {
            demoSend(text)
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
            pendingMessage = nil
            if draft == originalDraft { draft = "" }
            isSending = false
            await refresh(capabilities: capabilities, force: true)
        } catch {
            guard lifecycle == expectedLifecycle, isCurrent() else { return }
            sendError = error.localizedDescription
        }
    }

    private func demoSend(_ text: String) {
        guard var payload else { return }
        let timestamp = HerdrTimestamp.string(from: .now)
        payload.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "user", text: text,
                                      status: "delivered", createdAt: timestamp))
        payload.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "assistant",
                                      text: "Your direction is recorded in this demo.", status: "delivered", createdAt: timestamp))
        payload.messagesTotal += 2
        payload.feature.revision += 1
        self.payload = payload
        draft = ""
        publish(AgentBoardContent.build(from: payload))
    }

    /// The store that presents saved-session sheets for this column's host.
    /// The board carries only each agent's newest session, so opening a sheet
    /// also loads the feature's full session history once, in the background.
    func resources(capabilities: FirstMateCapabilities? = nil) -> FirstMateStore {
        let store: FirstMateStore
        if let resourceStore {
            store = resourceStore
        } else {
            store = FirstMateStore()
            store.configure(client: client as? any FirstMateClient, demo: isDemo)
            store.select(featureID)
            resourceStore = store
        }
        if let payload {
            store.receive(FirstMateSnapshot(feature: payload.feature, visits: payload.visits,
                                            assignments: payload.assignments, sessions: payload.sessions))
        }
        if !isDemo, let client, capabilities?.supportsJournalEvents == true {
            let expectedLifecycle = lifecycle
            let featureID = featureID
            Task { [weak self] in
                guard let snapshot = try? await client.fetchFirstMateFeature(featureID, journalEventsOnly: true),
                      let self, self.lifecycle == expectedLifecycle, self.resourceStore === store,
                      snapshot.ok, snapshot.feature.id == featureID else { return }
                store.receive(snapshot)
            }
        }
        return store
    }
}
