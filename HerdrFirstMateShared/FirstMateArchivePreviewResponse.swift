import Foundation

struct FirstMateArchivePreviewResponse: Decodable, Sendable {
    var ok: Bool
    var preview: FirstMateArchivePreview
}
