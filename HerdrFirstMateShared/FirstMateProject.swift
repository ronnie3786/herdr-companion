import Foundation

/// A saved working folder owned by the companion that returned it. Clients
/// pair this ID with their connection identity before displaying or using it.
struct FirstMateProject: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var cwd: String
    var revision: Int
    var createdAt: String
    var updatedAt: String
    var archivedAt: String? = nil

    var isArchived: Bool { archivedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, cwd, revision
        case createdAt = "created_at", updatedAt = "updated_at", archivedAt = "archived_at"
    }
}
