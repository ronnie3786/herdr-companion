import Foundation

protocol FirstMateClient: Sendable {
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse
}

struct FirstMateFeatureList: Decodable, Sendable {
    var ok: Bool
    var features: [FirstMateFeature]
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
    enum CodingKeys: String, CodingKey {
        case ok, messages, content
        case nativeSessionID = "native_session_id"
        case nextBefore = "next_before", totalMessages = "total_messages"
    }
}

struct FirstMateSessionMessage: Decodable, Sendable {
    var role: String
    var text: String
}
