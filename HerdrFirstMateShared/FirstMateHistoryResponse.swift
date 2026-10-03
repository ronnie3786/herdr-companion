import Foundation

struct FirstMateHistoryResponse: Decodable, Sendable {
    var ok: Bool
    var records: [FirstMateHistoryRecord]
    var nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case ok, records
        case nextOffset = "next_offset"
    }
}
