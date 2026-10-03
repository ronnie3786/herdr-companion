import Foundation

/// A visible, user-approved snapshot of Home evidence. It is staged as an
/// ordinary quote, so the shared composer freezes it once, detaches it with
/// the submitted draft, and restores/retries it with the original request.
struct HomeChatContext: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    let observedAt: Date

    init(id: UUID = UUID(), title: String, summary: String, observedAt: Date = .now) {
        self.id = id
        self.title = title
        self.summary = summary
        self.observedAt = observedAt
    }

    var quote: ChatQuote {
        .init(id: id, text: title + "\n" + summary,
              comment: "Home context observed at " + HerdrTimestamp.string(from: observedAt), source: "From Home")
    }
}

/// Credentials stay only in memory and must never be logged or persisted.
struct HomeChatTarget: Equatable, Sendable {
    let machineID: String
    let generation: Int
    let isDemo: Bool
    let configuration: ServerConfiguration?

    @MainActor
    func isCurrent(model: HerdrAppModel, configuration: (String) -> ServerConfiguration?) -> Bool {
        guard generation == model.connectionGeneration, isDemo == model.isDemoMode else { return false }
        if isDemo { return machineID == FirstMateChatWindowSession.demoMachineID }
        return model.machines.contains { $0.id == machineID } && self.configuration == configuration(machineID)
    }
}

struct HomeChatOwner: Equatable, Sendable {
    let target: HomeChatTarget
    let featureID: String
    var conversationID: FirstMateFleetFeatureID { .init(machineID: target.machineID, featureID: featureID) }
}

/// A one-time transfer of frozen unsent material. The conversation itself
/// remains on its companion and is fetched by the receiving window.
struct HomeChatTransfer: Identifiable, Equatable, Sendable {
    let id: UUID
    let owner: HomeChatOwner
    let draft: String
    let draftRevision: Int
    let attachments: [TerminalAttachment]
    let quotes: [ChatQuote]
    let containsDictation: Bool
    let contexts: [HomeChatContext]
    let inspector: FirstMateInspector?
}
