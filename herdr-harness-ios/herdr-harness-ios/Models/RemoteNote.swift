import Foundation
import SwiftUI

/// The harness uses the same note payload as the Mac, including Swift's
/// reference-date timestamps and optional SwiftUI attributed text.
struct RemoteNote: Decodable, Equatable, Identifiable, Sendable {
    let rawID: UUID
    let title: String
    let body: String
    let richBody: AttributedString
    let color: RemoteNoteColor
    let createdAt: Date
    let updatedAt: Date
    let revision: Int
    let aiSummary: String?
    let actions: [Action]
    private(set) var machineID = ""

    struct Action: Decodable, Equatable, Sendable {
        let title: String
        let status: String
    }

    var id: String { MachineScopedID.compose(machineID: machineID, rawID: rawID.uuidString) }

    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let firstLine = body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return firstLine.map { String($0.prefix(60)) } ?? "Untitled note"
    }

    var statusLabel: String {
        if actions.contains(where: { $0.status == "failed" }) { return "Action needs attention" }
        if actions.contains(where: { $0.status == "starting" }) { return "Starting an agent" }
        if actions.contains(where: { $0.status == "started" }) { return "Linked to an agent" }
        return "Saved note"
    }

    func stamped(machineID: String) -> RemoteNote {
        var copy = self
        copy.machineID = machineID
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, richBody, color, createdAt, updatedAt, revision, aiSummary, actions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rawID = try values.decode(UUID.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        richBody = (try? values.decodeIfPresent(
            AttributedString.self, forKey: .richBody,
            configuration: AttributeScopes.SwiftUIAttributes.self
        )) ?? AttributedString(body)
        color = RemoteNoteColor(rawValue: try values.decodeIfPresent(String.self, forKey: .color) ?? "") ?? .yellow
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        aiSummary = try values.decodeIfPresent(String.self, forKey: .aiSummary)
        actions = try values.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }
}

struct RemoteNotesResponse: Decodable, Sendable {
    let ok: Bool
    let revision: Int
    let notes: [RemoteNote]
    let deletedIDs: [UUID]
}
