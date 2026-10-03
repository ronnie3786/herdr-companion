import Foundation

struct FirstMateArchivePage: Decodable, Sendable {
    var ok: Bool
    var cleanup: FirstMateArchiveCleanup?
    var report: String
    var sha256: String
    var nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case ok, cleanup, report, sha256
        case nextOffset = "next_offset"
    }
}
