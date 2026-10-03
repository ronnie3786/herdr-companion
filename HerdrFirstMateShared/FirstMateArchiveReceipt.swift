import Foundation

/// The result belongs to the archive request, even if another client has
/// subsequently unarchived the feature or created a newer archive generation.
struct FirstMateArchiveReceipt: Decodable, Sendable {
    var ok: Bool
    var feature: FirstMateFeature
    var archiveID: String
    var cleanup: FirstMateArchiveCleanup

    enum CodingKeys: String, CodingKey {
        case ok, feature, cleanup
        case archiveID = "archive_id"
    }
}
