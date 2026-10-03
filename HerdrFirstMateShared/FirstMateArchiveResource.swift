import Foundation

struct FirstMateArchiveResource: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var path: String
    var estimatedBytes: Int64?
    var canDelete: Bool
    var reason: String
    var selectedByDefault: Bool

    var title: String {
        switch kind {
        case "worktree": "Worktree"
        case "branch": "Task branch"
        case "temporary_build": "Temporary build"
        case "cache": "Build cache"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, path, reason
        case estimatedBytes = "estimated_bytes", canDelete = "can_delete", selectedByDefault = "selected_by_default"
    }
}
