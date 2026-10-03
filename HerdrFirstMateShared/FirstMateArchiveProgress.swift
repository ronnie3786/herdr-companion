import Foundation

struct FirstMateArchiveProgress: Decodable, Sendable {
    var ok: Bool
    var cleanup: FirstMateArchiveCleanup?
    var logs: [FirstMateCleanupLogEntry]
    var nextAfter: Int?

    enum CodingKeys: String, CodingKey {
        case ok, cleanup, logs
        case nextAfter = "next_after"
    }
}
