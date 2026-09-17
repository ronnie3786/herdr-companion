import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let herdrPiChatReference = UTType(exportedAs: "dev.herdr.companion.pi-chat-reference")
}

/// The small, app-internal value placed on the drag pasteboard. Conversation
/// content is intentionally absent: the destination stages only stable locators.
struct ConversationContextTransfer: Codable, Equatable, Hashable, Sendable, Transferable {
    let sourcePaneID: String
    let expectedSessionID: String?
    let title: String
    let agent: String?
    let path: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .herdrPiChatReference)
    }

    init(pane: HerdrPane) {
        sourcePaneID = pane.id
        expectedSessionID = Self.nonempty(pane.piSemantic?.sessionID)
        title = pane.displayTitle
        agent = Self.nonempty(pane.displayAgentName)
        path = Self.nonempty(pane.displayPath)
    }

    init(sourcePaneID: String, expectedSessionID: String?, title: String, agent: String?, path: String?) {
        self.sourcePaneID = sourcePaneID
        self.expectedSessionID = Self.nonempty(expectedSessionID)
        self.title = title
        self.agent = Self.nonempty(agent)
        self.path = Self.nonempty(path)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ConversationContextReference: Identifiable, Equatable, Sendable {
    static let currentRequestBoundary = "<<<HERDR_CURRENT_REQUEST>>>"

    let id: UUID
    let sourcePaneID: String
    let sourceWorkspaceID: String
    let sourceSessionID: String
    let title: String
    let agent: String?
    let path: String?

    var deduplicationKey: String {
        "session:\(MachineScopedID.split(sourcePaneID)?.machineID ?? ""):\(sourceSessionID)"
    }

    var compactSummary: String {
        var pieces: [String] = []
        if let agent, !agent.isEmpty { pieces.append(agent) }
        if let path, !path.isEmpty {
            let folder = (path as NSString).lastPathComponent
            if !folder.isEmpty, folder != (agent ?? "") { pieces.append(folder) }
        }
        pieces.append("linked Pi session")
        return pieces.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        "Conversation context, \(title), \(compactSummary)"
    }

    static func capture(
        transfer: ConversationContextTransfer,
        currentSourcePane: HerdrPane,
        id: UUID = UUID()
    ) throws -> ConversationContextReference {
        guard currentSourcePane.id == transfer.sourcePaneID,
              currentSourcePane.supportsPiSemanticChat else {
            throw ConversationContextError.sourceUnavailable
        }

        guard let expectedSessionID = nonempty(transfer.expectedSessionID),
              let currentSessionID = nonempty(currentSourcePane.piSemantic?.sessionID) else {
            throw ConversationContextError.sessionIdentityUnavailable
        }
        guard expectedSessionID == currentSessionID else {
            throw ConversationContextError.sessionChanged
        }
        guard !currentSourcePane.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationContextError.sourceUnavailable
        }

        return ConversationContextReference(
            id: id,
            sourcePaneID: transfer.sourcePaneID,
            sourceWorkspaceID: currentSourcePane.workspaceID,
            sourceSessionID: currentSessionID,
            title: transfer.title,
            agent: transfer.agent,
            path: transfer.path
        )
    }

    static func prompt(currentRequest: String, references: [ConversationContextReference]) -> String {
        guard !references.isEmpty else { return currentRequest }
        let locators = references.map { reference in
            "The user included Herdr workspace ID `\(sanitized(reference.sourceWorkspaceID))`, running Pi session ID `\(sanitized(reference.sourceSessionID))`. Fetch that session's context from Herdr before handling the current request."
        }
        return locators.joined(separator: "\n")
            + "\n\n" + currentRequestBoundary
            + "\n" + sanitized(currentRequest)
    }

    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(
            of: currentRequestBoundary,
            with: "[reserved conversation boundary removed]"
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ConversationContextError: LocalizedError, Equatable {
    case destinationUnavailable
    case samePane
    case sourceUnavailable
    case sessionIdentityUnavailable
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable:
            "The destination prompt is no longer available or controllable."
        case .samePane:
            "Choose a different conversation as context."
        case .sourceUnavailable:
            "That Pi conversation is no longer available."
        case .sessionIdentityUnavailable:
            "That Pi conversation cannot be pinned to a stable session yet. Open it, wait for Pi to connect, and drag it again."
        case .sessionChanged:
            "That pane switched Pi sessions before its reference could be added. Drag it again."
        }
    }
}
