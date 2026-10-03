import Foundation

struct FirstMateCleanupResponse: Decodable, Sendable {
    var ok: Bool
    var cleanup: FirstMateArchiveCleanup
}
