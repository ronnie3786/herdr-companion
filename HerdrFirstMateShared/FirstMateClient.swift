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
    func uploadFirstMateAttachment(featureID: String, fileURL: URL, contentType: String) async throws -> AttachmentUploadResponse
    func transcribeFirstMateVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot
    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse
    func saveFirstMateLink(featureID: String, url: String, title: String?, kind: String?, requestID: String) async throws -> FirstMateLinkMutationResponse
    func setFirstMateLinkVisibility(featureID: String, linkID: String, hidden: Bool, requestID: String) async throws -> FirstMateLinkMutationResponse
}

struct FirstMateFeatureList: Decodable, Sendable {
    var ok: Bool
    var features: [FirstMateFeature]
    var runtimeHealth: FirstMateRuntimeHealth? = nil

    enum CodingKeys: String, CodingKey {
        case ok, features
        case runtimeHealth = "runtime_health"
    }
}

struct FirstMateCapabilities: Decodable, Sendable {
    var ok: Bool
    var capabilities: [String]
    var supportsArchive: Bool { capabilities.contains("first-mate-archive-v1") }
    var supportsAttachments: Bool { capabilities.contains("first-mate-attachments-v1") }
    var supportsContext: Bool { capabilities.contains("first-mate-context-v1") }
    var supportsSafeModelSettings: Bool { capabilities.contains("first-mate-safe-model-settings-v1") }
    var supportsLinks: Bool { capabilities.contains("first-mate-links-v1") }
}

/// A link save or visibility response: the affected link plus the same full
/// snapshot the feature detail route returns.
struct FirstMateLinkMutationResponse: Decodable, Sendable {
    var ok: Bool
    var link: FirstMateLink?
    var snapshot: FirstMateSnapshot

    enum CodingKeys: String, CodingKey {
        case ok, link
    }

    init(ok: Bool, link: FirstMateLink?, snapshot: FirstMateSnapshot) {
        self.ok = ok
        self.link = link
        self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        link = try container.decodeIfPresent(FirstMateLink.self, forKey: .link)
        snapshot = try FirstMateSnapshot(from: decoder)
    }
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
    var modelSelection: FirstMateModelSelection? = nil
    enum CodingKeys: String, CodingKey {
        case ok, messages, content
        case nativeSessionID = "native_session_id"
        case nextBefore = "next_before", totalMessages = "total_messages"
        case usage, modelSelection = "model_selection"
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
    var routing: FirstMateModelRouting? = nil
    enum CodingKeys: String, CodingKey {
        case ok, models, routing
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
    var expectedSessionID: String? = nil
    var confirmSessionModelChange: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case model, thinking
        case expectedSettingsRevision = "expected_settings_revision", requestID = "request_id"
        case expectedSessionID = "expected_session_id"
        case confirmSessionModelChange = "confirm_session_model_change"
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
    func uploadFirstMateAttachment(featureID: String, fileURL: URL, contentType: String) async throws -> AttachmentUploadResponse {
        throw APIError.invalidResponse
    }
    func transcribeFirstMateVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse {
        throw APIError.invalidResponse
    }
    func saveFirstMateLink(featureID: String, url: String, title: String?, kind: String?, requestID: String) async throws -> FirstMateLinkMutationResponse {
        throw APIError.invalidResponse
    }
    func setFirstMateLinkVisibility(featureID: String, linkID: String, hidden: Bool, requestID: String) async throws -> FirstMateLinkMutationResponse {
        throw APIError.invalidResponse
    }
}
