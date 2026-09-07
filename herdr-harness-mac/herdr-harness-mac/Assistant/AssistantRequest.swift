import Foundation

struct AssistantRequest: Codable, Sendable {
    struct Scope: Codable, Sendable { var expectedRootPath: String? }
    var prompt: String
    var profile = "contextual-question-v1"
    var mode = "ask"
    var clientRequestId = UUID().uuidString
    var paneId: String?
    var scope: Scope
    var context: AssistantContext
    var continueFromRunId: String?
    var model: String?
}

struct AssistantCapabilities: Decodable, Sendable {
    var profiles: [String]
}
