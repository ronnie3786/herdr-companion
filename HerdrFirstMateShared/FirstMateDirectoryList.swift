import Foundation

struct FirstMateDirectoryList: Codable, Equatable, Sendable {
    var ok: Bool
    var path: String
    var parentPath: String?
    var homePath: String
    var entries: [FirstMateDirectoryEntry]
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case ok, path, entries
        case parentPath = "parent_path", homePath = "home_path", nextCursor = "next_cursor"
    }
}
