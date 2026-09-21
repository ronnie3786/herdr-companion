import Foundation

struct AssistantRequest: Codable, Sendable {
    struct Scope: Codable, Sendable {
        var expectedRootPath: String? = nil
        var reviewId: String? = nil
    }
    var prompt: String
    var profile = "contextual-question-v1"
    var mode = "ask"
    var clientRequestId = UUID().uuidString
    var paneId: String?
    var scope: Scope
    var context: AssistantContext
    var continueFromRunId: String?
    var model: String?
    var thinkingLevel: String?
    var parentSessionId: String?
    /// Response-brief-only length selection. Synthesized Codable omits nil, so
    /// generic assistant requests never send this field. A missing value on a
    /// decoded legacy request means the captured pre-preset budgets.
    var responseBriefLength: ResponseBriefLength?
}

struct AssistantCapabilities: Decodable, Sendable {
    /// Additive decoding of the advertised response brief contract. Older
    /// servers omit `responseBriefs` entirely or omit its length fields.
    struct ResponseBriefs: Decodable, Sendable, Equatable {
        var version: Int?
        var lengthPolicyVersion: Int?
        var lengthOptions: [String]?
        var maxOutputBytes: Int?
        var tools: String?
        var oneShot: Bool?
        var requiresParentSessionId: Bool?

        var supportsLengthPolicy: Bool {
            guard let lengthPolicyVersion else { return false }
            return lengthPolicyVersion >= ResponseBriefLength.policyVersion
        }

        var advertisedLengths: [ResponseBriefLength] {
            (lengthOptions ?? []).compactMap(ResponseBriefLength.init(rawValue:))
        }

        var supportsEveryLengthOption: Bool {
            supportsLengthPolicy
                && Set(advertisedLengths) == Set(ResponseBriefLength.allCases)
        }
    }

    var profiles: [String]
    var hudChatWorkingDirectory: Bool? = nil
    var responseBriefs: ResponseBriefs? = nil
}
