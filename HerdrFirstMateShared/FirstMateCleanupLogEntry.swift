import Foundation

struct FirstMateCleanupLogEntry: Decodable, Equatable, Identifiable, Sendable {
    var sequence: Int
    var kind: String
    var path: String
    var outcome: String
    var reason: String
    var bytesReclaimed: Int64
    var createdAt: String
    var id: Int { sequence }

    enum CodingKeys: String, CodingKey {
        case sequence, kind, path, outcome, reason
        case bytesReclaimed = "bytes_reclaimed", createdAt = "created_at"
    }
}
