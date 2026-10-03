import Foundation

struct FirstMateArchiveCleanup: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var status: String
    var attempt: Int
    var message: String
    var historyAvailable: Bool
    var bytesReclaimed: Int64
    var removed: Int
    var retained: Int
    var failed: Int
    var updatedAt: String

    var isRunning: Bool { ["pending", "waiting", "running"].contains(status) }
    var canRetry: Bool { ["failed", "completed"].contains(status) }

    enum CodingKeys: String, CodingKey {
        case id, status, attempt, message, removed, retained, failed
        case historyAvailable = "history_available", bytesReclaimed = "bytes_reclaimed", updatedAt = "updated_at"
    }
}
