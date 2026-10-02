import Foundation

struct FirstMateDirectoryEntry: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var path: String
    var resolvedPath: String?
    var isSymlink: Bool
    var canOpen: Bool

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path
        case resolvedPath = "resolved_path", isSymlink = "is_symlink", canOpen = "can_open"
    }
}
