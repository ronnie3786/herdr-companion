import Foundation

struct FirstMateArchiveOptions: Codable, Equatable, Sendable {
    var resourceIDs: [String]
    var keepDocuments = true
    var keepChat = true

    enum CodingKeys: String, CodingKey {
        case resourceIDs = "resource_ids", keepDocuments = "keep_documents", keepChat = "keep_chat"
    }
}
