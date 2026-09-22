import Foundation

protocol FirstMateClient: Sendable {
    func fetchFirstMateModels() async throws -> FirstMateModelCatalog
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities
    func setFirstMateModel(featureID: String, settings: FirstMateModelSettings) async throws -> FirstMateSnapshot
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot
    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse
}

struct FirstMateFeatureList: Decodable, Sendable {
    var ok: Bool
    var features: [FirstMateFeature]
}

struct FirstMateCapabilities: Decodable, Sendable {
    var ok: Bool
    var capabilities: [String]
    var supportsArchive: Bool { capabilities.contains("first-mate-archive-v1") }
}

struct FirstMateDocumentResponse: Decodable, Sendable {
    var ok: Bool
    var document: FirstMateDocument
    var content: String?
}

struct FirstMateSessionResponse: Decodable, Sendable {
    var ok: Bool
    var nativeSessionID: String?
    var messages: [FirstMateSessionMessage]?
    var content: String?
    var nextBefore: Int?
    var totalMessages: Int?
    var usage: FirstMateUsage? = nil
    enum CodingKeys: String, CodingKey {
        case ok, messages, content
        case nativeSessionID = "native_session_id"
        case nextBefore = "next_before", totalMessages = "total_messages"
        case usage
    }
}

struct FirstMateSessionMessage: Decodable, Sendable {
    var role: String
    var text: String
}

struct FirstMateModelCatalog: Decodable, Sendable {
    var ok: Bool
    var models: [FirstMateModelOption]
    var defaultModel: String
    var thinkingLevels: [String]
    enum CodingKeys: String, CodingKey {
        case ok, models
        case defaultModel = "default_model", thinkingLevels = "thinking_levels"
    }
}

struct FirstMateModelOption: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var provider: String
    var reasoning: Bool
}

struct FirstMateModelSettings: Encodable, Equatable, Sendable {
    var model: String
    var thinking: String
    var expectedSettingsRevision: Int
    var requestID: String
    enum CodingKeys: String, CodingKey {
        case model, thinking
        case expectedSettingsRevision = "expected_settings_revision", requestID = "request_id"
    }
}

extension FirstMateClient {
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: [])
    }
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        try await fetchFirstMateFeatures()
    }
    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }
    func fetchFirstMateModels() async throws -> FirstMateModelCatalog { throw APIError.invalidResponse }
    func setFirstMateModel(featureID: String, settings: FirstMateModelSettings) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }
}
