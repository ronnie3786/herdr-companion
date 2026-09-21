import Foundation

struct FirstMateUsage: Codable, Equatable, Sendable {
    var currency: String
    var costUSD: Double?
    var status: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var totalTokens: Int
    var usageRecords: Int
    var missingCostRecords: Int
    var sessionCount: Int
    var knownCostSessions: Int
    var models: [FirstMateModelUsage]
    var updatedAt: String
    var stale: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case currency, status, models, stale
        case costUSD = "cost_usd"
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens", cacheWriteTokens = "cache_write_tokens"
        case totalTokens = "total_tokens", usageRecords = "usage_records"
        case missingCostRecords = "missing_cost_records"
        case sessionCount = "session_count", knownCostSessions = "known_cost_sessions"
        case updatedAt = "updated_at"
    }
}
