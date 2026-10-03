import Foundation

/// Exact, read-only evidence checks shared by production hydration and tests.
enum HomeQuickReplyEvidence {
    static func firstMate(_ snapshot: FirstMateSnapshot, owner: HomeQuickReplyOwner) -> HomeQuickReplyQuestion? {
        guard case .firstMate(_, let featureID) = owner.route,
              snapshot.ok, snapshot.feature.id == featureID,
              !snapshot.feature.isArchived,
              ["awaiting_direction", "blocked"].contains(snapshot.feature.status),
              snapshot.hasQueuedWork != true, snapshot.pendingMessages?.isEmpty != false,
              let message = snapshot.messages.last(where: \.isConversation),
              message.featureID == featureID, FirstMateFeedbackEligibility.isEligible(message),
              let reader = FirstMateSkimReader(skim: message.skim, reply: message.text),
              !reader.actions.isEmpty else { return nil }
        return .init(owner: owner, messageID: message.id, reply: message.text,
                     sessionID: snapshot.feature.nativeSessionID, actions: reader.actions)
    }

    static func piSource(_ snapshot: PiConversationSnapshot, pane: HerdrPane,
                         owner: HomeQuickReplyOwner) -> ChatSkimSource? {
        guard owner.route == .chat(paneID: pane.id), pane.agentStatus == .blocked,
              pane.supportsPiSemanticChat, pane.piSemantic?.capabilities.prompt == true,
              pane.piSemantic?.connected == true,
              let sessionID = owner.sessionID, !sessionID.isEmpty,
              pane.piSemantic?.sessionID == sessionID,
              snapshot.ok, snapshot.available, snapshot.connected, snapshot.paneID == pane.paneID,
              snapshot.protocolInfo.name == "herdr.pi.semantic", snapshot.protocolInfo.version == 1,
              snapshot.pendingInteractions.isEmpty else { return nil }
        var reducer = PiConversationReducer()
        reducer.replace(with: snapshot)
        guard reducer.sessionID == sessionID, reducer.bridgeConnected,
              reducer.phase != .working, reducer.compactionActivity == nil,
              reducer.pendingInteractions.isEmpty,
              let turn = reducer.turns.last,
              let block = turn.items.reversed().compactMap({ item -> PiAssistantBlock? in
                  if case .assistant(let block) = item { return block }
                  return nil
              }).first else { return nil }
        return ChatSkimSource.sources(in: turn)[block.id]
    }

    static func piQuestion(source: ChatSkimSource, skim: FirstMateSkim?,
                           owner: HomeQuickReplyOwner) -> HomeQuickReplyQuestion? {
        guard let reader = FirstMateSkimReader(skim: skim, reply: source.reply),
              !reader.actions.isEmpty else { return nil }
        return .init(owner: owner, messageID: source.messageID, reply: source.reply,
                     sessionID: owner.sessionID, actions: reader.actions)
    }
}

/// Each hydrated First Mate has its own small conversation store. It never
/// selects the main store or refreshes a whole feature index. Pi only reads
/// finite snapshots and uses the existing prompt submission path.
@MainActor
final class HomeQuickReplySource {
    private struct FirstMateEntry {
        var owner: HomeQuickReplyOwner
        var store: FirstMateStore
        var handle: FirstMateOutgoingMessage.Handle?
    }
    private struct PiEntry {
        var owner: HomeQuickReplyOwner
        var source: ChatSkimSource
        var skim: FirstMateSkim?
    }

    private let model: HerdrAppModel
    private let shell: HerdrShellState
    private var firstMate: [HomeRoute: FirstMateEntry] = [:]
    private var pi: [HomeRoute: PiEntry] = [:]

    init(model: HerdrAppModel, shell: HerdrShellState) {
        self.model = model
        self.shell = shell
    }

    var operations: HomeQuickReplyOperations {
        .init(owner: { self.owner($0) }, load: { try await self.load($0) },
              submit: { await self.submit($0, action: $1) }, retry: { await self.retry($0) },
              retain: { self.retain($0) })
    }

    private func owner(_ route: HomeRoute) -> HomeQuickReplyOwner? {
        let machineID: String
        var sessionID: String?
        switch route {
        case .firstMate(let machine, let featureID):
            machineID = machine
            guard let feature = shell.firstMateFleet.hosts.first(where: { $0.id == machine })?.features.first(where: { $0.id == featureID }),
                  !feature.isArchived, !["completed", "cancelled"].contains(feature.status) else { return nil }
        case .chat(let paneID):
            guard let pane = model.pane(id: paneID), pane.agentStatus == .blocked,
                  pane.supportsPiSemanticChat, pane.piSemantic?.connected == true,
                  pane.piSemantic?.capabilities.prompt == true,
                  let session = pane.piSemantic?.sessionID, !session.isEmpty else { return nil }
            machineID = pane.machineID
            sessionID = session
        default: return nil
        }
        guard model.isDemoMode || model.canControl(machineID: machineID) else { return nil }
        let configuration = model.firstMateConfiguration(machineID: machineID)
        guard model.isDemoMode || configuration != nil else { return nil }
        return .init(route: route, generation: model.connectionGeneration, configuration: configuration,
                     isDemo: model.isDemoMode, sessionID: sessionID)
    }

    private func requireCurrent(_ expected: HomeQuickReplyOwner) throws {
        guard !Task.isCancelled, owner(expected.route) == expected else { throw CancellationError() }
    }

    private func load(_ expected: HomeQuickReplyOwner) async throws -> HomeQuickReplyLoad {
        try requireCurrent(expected)
        switch expected.route {
        case .firstMate(_, let featureID):
            let store: FirstMateStore
            if let entry = firstMate[expected.route], entry.owner == expected {
                store = entry.store
            } else {
                store = FirstMateStore()
                store.configure(client: expected.configuration.map { HerdrAPIClient(configuration: $0) }, demo: expected.isDemo)
                store.select(featureID)
                firstMate[expected.route] = FirstMateEntry(owner: expected, store: store)
            }
            await store.refreshConversation()
            try requireCurrent(expected)
            guard store.error == nil, let snapshot = store.snapshots[featureID] else {
                return .init(question: nil, unavailableReason: "Could not load the latest question. Open the conversation to reply.")
            }
            if let reason = firstMateDisabledReason(expected, store: store, featureID: featureID) {
                return .init(question: nil, unavailableReason: reason)
            }
            return .init(question: HomeQuickReplyEvidence.firstMate(snapshot, owner: expected))
        case .chat(let paneID):
            guard let pane = model.pane(id: paneID), let transport = model.chatSkimTransport(for: pane) else {
                return .init(question: nil)
            }
            let snapshot = try await model.fetchPiConversationSnapshot(for: pane)
            try requireCurrent(expected)
            guard let currentPane = model.pane(id: paneID),
                  let source = HomeQuickReplyEvidence.piSource(snapshot, pane: currentPane, owner: expected) else {
                return .init(question: nil, unavailableReason: snapshot.pendingInteractions.isEmpty
                    ? "Open the conversation to reply." : "Open the conversation to handle its pending interaction.")
            }
            guard piDraftIsEmpty(paneID) else {
                return .init(question: nil, unavailableReason: "Open the conversation to finish your draft first.")
            }
            if let cached = pi[expected.route], cached.owner == expected, cached.source == source {
                return .init(question: HomeQuickReplyEvidence.piQuestion(source: source, skim: cached.skim, owner: expected))
            }
            let capabilities = try await transport.capabilities()
            try requireCurrent(expected)
            guard capabilities.enabled, source.reply.split(whereSeparator: \.isWhitespace).count >= capabilities.minWords else {
                return .init(question: nil)
            }
            var envelope = try await transport.request(source.reply, source.question)
            try requireCurrent(expected)
            // Finite hydration only. Slow skim generation leaves Open available.
            for _ in 0..<8 where envelope.skim?.status == .pending || envelope.skim == nil {
                guard let id = envelope.id else { break }
                try await Task.sleep(for: .seconds(1))
                try requireCurrent(expected)
                envelope = try await transport.fetch(id)
                try requireCurrent(expected)
            }
            pi[expected.route] = .init(owner: expected, source: source, skim: envelope.skim)
            return .init(question: HomeQuickReplyEvidence.piQuestion(source: source, skim: envelope.skim, owner: expected))
        default: return .init(question: nil)
        }
    }

    private func firstMateDisabledReason(_ expected: HomeQuickReplyOwner, store: FirstMateStore, featureID: String) -> String? {
        if store.isSending || store.isAwaitingSendResolution(featureID: featureID) || store.sendFailure(for: featureID) != nil {
            return "Open the conversation to check its previous send."
        }
        guard case .firstMate(let machineID, _) = expected.route else { return nil }
        if shell.isActiveFirstMateConnection(machineID: machineID, configuration: expected.configuration,
                                            connectionGeneration: expected.generation, isDemo: expected.isDemo) {
            let active = shell.firstMate
            if active.isSending || active.isAwaitingSendResolution(featureID: featureID) || active.sendFailure(for: featureID) != nil {
                return "Open the conversation to check its previous send."
            }
            if active.selectedFeatureID == featureID,
               !active.composerDraft(for: active.operationContext).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !active.composerDrafts.attachments(for: featureID).isEmpty
                || !active.composerDrafts.quotes(for: featureID).isEmpty {
                return "Open the conversation to finish your draft first."
            }
        }
        return nil
    }

    private func piDraftIsEmpty(_ paneID: String) -> Bool {
        model.composerDraft(for: paneID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.conversationReferences(for: paneID).isEmpty
    }

    private func submit(_ question: HomeQuickReplyQuestion, action: SkimReplyAction) async -> HomeQuickReplyResult {
        let expected = question.owner
        guard owner(expected.route) == expected, question.actions.contains(action), action.isValid else {
            return .failed("This conversation changed. Open it before replying.", retryable: false)
        }
        switch expected.route {
        case .firstMate(_, let featureID):
            guard var entry = firstMate[expected.route], entry.owner == expected,
                  firstMateDisabledReason(expected, store: entry.store, featureID: featureID) == nil,
                  let snapshot = entry.store.snapshots[featureID],
                  HomeQuickReplyEvidence.firstMate(snapshot, owner: expected) == question,
                  let handle = entry.store.beginOutgoingMessage(action.label, expectedContext: entry.store.operationContext) else {
                return .failed("This question changed or has a pending send. Open the conversation to continue.", retryable: false)
            }
            entry.handle = handle
            firstMate[expected.route] = entry
            return result(await entry.store.completeOutgoingMessage(handle))
        case .chat(let paneID):
            guard let pane = model.pane(id: paneID), piDraftIsEmpty(paneID),
                  let cached = pi[expected.route], cached.owner == expected,
                  HomeQuickReplyEvidence.piQuestion(source: cached.source, skim: cached.skim, owner: expected) == question else {
                return .failed("This question changed. Open the conversation to continue.", retryable: false)
            }
            do {
                try await model.sendPiConversationPrompt(action.label, disposition: .prompt, to: pane)
                return .accepted
            } catch {
                // Pi's existing prompt endpoint has no caller-owned request
                // ID. An uncertain delivery must never expose a blind retry.
                return .deliveryUnconfirmed("Delivery could not be confirmed. Open the conversation to check before sending again.", retryable: false)
            }
        default: return .failed("Open the conversation to reply.", retryable: false)
        }
    }

    private func retry(_ expected: HomeQuickReplyOwner) async -> HomeQuickReplyResult {
        guard owner(expected.route) == expected,
              let entry = firstMate[expected.route], entry.owner == expected, let handle = entry.handle else {
            return .deliveryUnconfirmed("Open the original conversation to check the previous reply.", retryable: false)
        }
        return result(await entry.store.retryOutgoingMessage(handle))
    }

    private func result(_ state: FirstMateOutgoingMessage.State?) -> HomeQuickReplyResult {
        switch state {
        case .acceptedAwaitingSnapshot: .accepted
        case .failed(let message): .failed(message, retryable: true)
        case .deliveryUnconfirmed(let message): .deliveryUnconfirmed(message, retryable: true)
        case .pending, nil: .deliveryUnconfirmed("Delivery could not be confirmed. Open the conversation to check the previous reply.", retryable: false)
        }
    }

    private func retain(_ owners: [HomeQuickReplyOwner]) {
        firstMate = firstMate.filter { _, entry in
            owners.contains(entry.owner) || entry.handle.map { entry.store.outgoingMessage($0)?.state.isRetryable == true
                || entry.store.outgoingMessage($0)?.state.isPending == true } == true
        }
        pi = pi.filter { owners.contains($0.value.owner) }
    }
}
