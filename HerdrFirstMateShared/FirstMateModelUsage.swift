import Foundation

struct FirstMateModelUsage: Codable, Equatable, Identifiable, Sendable {
    var provider: String?
    var model: String?
    var costUSD: Double?
    var status: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var totalTokens: Int
    var usageRecords: Int
    var missingCostRecords: Int

    var id: String { "\(provider ?? "")\u{0}\(model ?? "")" }

    enum CodingKeys: String, CodingKey {
        case provider, model, status
        case costUSD = "cost_usd"
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens", cacheWriteTokens = "cache_write_tokens"
        case totalTokens = "total_tokens", usageRecords = "usage_records"
        case missingCostRecords = "missing_cost_records"
    }
}
