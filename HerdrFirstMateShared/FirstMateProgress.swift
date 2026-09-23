import Foundation

struct FirstMateProgress: Codable, Equatable, Sendable {
    var summary: String?
    var nextAction: String?
    var evidence: String?
    var recordedAt: String?
    var waitUntilEpoch: Double?

    enum CodingKeys: String, CodingKey {
        case summary, evidence
        case nextAction = "next_action", recordedAt = "recorded_at"
        case waitUntilEpoch = "wait_until_epoch"
    }
}
