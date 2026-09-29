import Foundation

protocol FirstMateClient: Sendable {
    func fetchFirstMateModels() async throws -> FirstMateModelCatalog
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities
    func setFirstMateModel(featureID: String, settings: FirstMateModelSettings) async throws -> FirstMateSnapshot
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot
    /// Omits Pi telemetry events when `journalEventsOnly` and the companion
    /// advertises `first-mate-journal-events-v1`.
    func fetchFirstMateFeature(_ id: String, journalEventsOnly: Bool) async throws -> FirstMateSnapshot
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot
    func uploadFirstMateAttachment(featureID: String, fileURL: URL, contentType: String) async throws -> AttachmentUploadResponse
    func transcribeFirstMateVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot
    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse
    func fetchFirstMateFeedbackCategories() async throws -> FirstMateFeedbackCategoriesResponse
    func createFirstMateFeedbackCategory(label: String, requestID: String) async throws -> FirstMateFeedbackCategoryResponse
    func fetchFirstMateFeedback(featureID: String) async throws -> FirstMateFeatureFeedbackResponse
    func saveFirstMateFeedback(
        featureID: String,
        messageID: String,
        request: FirstMateFeedbackSaveRequest
    ) async throws -> FirstMateFeedbackMutationResponse
    func saveFirstMateLink(featureID: String, url: String, title: String?, kind: String?, requestID: String) async throws -> FirstMateLinkMutationResponse
    func setFirstMateLinkVisibility(featureID: String, linkID: String, hidden: Bool, requestID: String) async throws -> FirstMateLinkMutationResponse
    /// The per-feature fleet summary (`first-mate-fleet-v1`). Named apart from
    /// the managed-machine `fetchFleet()`.
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse
    /// Moves the feature's read marker forward to `throughMessageID`. The
    /// companion never moves it backward.
    func markFirstMateRead(featureID: String, throughMessageID: String) async throws -> FirstMateReadResponse
    /// Sets the HUD label and emoji. `nil` leaves a field unchanged; an empty
    /// string resets it to the companion's default.
    func updateFirstMateHud(featureID: String, label: String?, emoji: String?) async throws -> FirstMateFleetEntry
    /// The machine's lead First Mate (`first-mate-lead-v1`), or a nil lead
    /// before its first use.
    func fetchFirstMateLead() async throws -> FirstMateLeadResponse
    /// Creates the lead on first use and returns it. Idempotent.
    func ensureFirstMateLead(requestID: String) async throws -> FirstMateLeadResponse
    /// A message to the lead with a read-only snapshot of the person's other
    /// machines (`first-mate-lead-v1`), which the lead's tools cannot reach.
    func sendFirstMateMessage(featureID: String, text: String, requestID: String,
                              context: FirstMateLeadContext) async throws -> FirstMateSnapshot
}

/// What the lead First Mate is told about features on the person's other
/// machines: a small, read-only snapshot sent with a message to it. The
/// companion bounds and stores it apart from the conversation.
struct FirstMateLeadContext: Codable, Equatable, Sendable {
    struct Machine: Codable, Equatable, Sendable {
        var name: String
        var features: [Feature]
        /// The Mac cannot reach this machine: its features are as last seen.
        var offline: Bool? = nil
    }

    struct Feature: Codable, Equatable, Sendable {
        var label: String
        var title: String?
        /// blocked, turn, ready, working, idle, or done.
        var status: String
        var step: String?
        var now: String?
        var unread: Bool
        /// The newest message's preview.
        var latest: String?
    }

    var machines: [Machine]
}

/// The lead First Mate: one conversation across every feature on a machine.
/// Its messages, attachments, model settings, and read marker use the
/// ordinary feature routes with ``feature``'s ID.
struct FirstMateLeadSummary: Decodable, Equatable, Sendable {
    struct LatestMessage: Decodable, Equatable, Sendable {
        var id: String
        var role: String
        var text: String
        var createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id, role, text
            case createdAt = "created_at"
        }
    }

    /// Another machine whose features this lead reads and relays to itself
    /// (`first-mate-lead-peers-v1`): its companion holds that machine's
    /// credential.
    struct Peer: Decodable, Equatable, Sendable {
        var id: String
        var name: String
        var url: String
    }

    /// Display metadata from the answering server's roster, never a saved
    /// client identity or authority to retarget requests.
    struct Machine: Decodable, Equatable, Sendable {
        var id: String
        var name: String
    }

    var feature: FirstMateFeature
    /// The lead's newest reply is past its read marker.
    var unread: Bool
    /// A message of yours is queued or the lead is answering.
    var workingOnReply: Bool
    var latestMessage: LatestMessage?
    /// The machines the lead reaches itself; the Mac's snapshot of other
    /// machines leaves them out. Nil from an older companion.
    var peers: [Peer]? = nil
    var machine: Machine? = nil

    enum CodingKeys: String, CodingKey {
        case feature, unread, peers, machine
        case workingOnReply = "working_on_reply"
        case latestMessage = "latest_message"
    }
}

struct FirstMateLeadResponse: Decodable, Sendable {
    var ok: Bool
    var lead: FirstMateLeadSummary?
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
    var supportsJournalEventSnapshots: Bool { capabilities.contains("first-mate-journal-events-v1") }
    var supportsFeedback: Bool { capabilities.contains("first-mate-feedback-v1") }
    var supportsLinks: Bool { capabilities.contains("first-mate-links-v1") }
    var supportsFleet: Bool { capabilities.contains("first-mate-fleet-v1") }
    var supportsLead: Bool { capabilities.contains("first-mate-lead-v1") }
    var supportsLeadPeers: Bool { capabilities.contains("first-mate-lead-peers-v1") }
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
    func fetchFirstMateFeature(_ id: String, journalEventsOnly: Bool) async throws -> FirstMateSnapshot {
        try await fetchFirstMateFeature(id)
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
    func fetchFirstMateFeedbackCategories() async throws -> FirstMateFeedbackCategoriesResponse {
        throw APIError.invalidResponse
    }
    func createFirstMateFeedbackCategory(label: String, requestID: String) async throws -> FirstMateFeedbackCategoryResponse {
        throw APIError.invalidResponse
    }
    func fetchFirstMateFeedback(featureID: String) async throws -> FirstMateFeatureFeedbackResponse {
        throw APIError.invalidResponse
    }
    func saveFirstMateFeedback(
        featureID: String,
        messageID: String,
        request: FirstMateFeedbackSaveRequest
    ) async throws -> FirstMateFeedbackMutationResponse {
        throw APIError.invalidResponse
    }
    func saveFirstMateLink(featureID: String, url: String, title: String?, kind: String?, requestID: String) async throws -> FirstMateLinkMutationResponse {
        throw APIError.invalidResponse
    }
    func setFirstMateLinkVisibility(featureID: String, linkID: String, hidden: Bool, requestID: String) async throws -> FirstMateLinkMutationResponse {
        throw APIError.invalidResponse
    }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse { throw APIError.invalidResponse }
    func markFirstMateRead(featureID: String, throughMessageID: String) async throws -> FirstMateReadResponse {
        throw APIError.invalidResponse
    }
    func updateFirstMateHud(featureID: String, label: String?, emoji: String?) async throws -> FirstMateFleetEntry {
        throw APIError.invalidResponse
    }
    func fetchFirstMateLead() async throws -> FirstMateLeadResponse { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String,
                              context: FirstMateLeadContext) async throws -> FirstMateSnapshot {
        try await sendFirstMateMessage(featureID: featureID, text: text, requestID: requestID)
    }
    func ensureFirstMateLead(requestID: String) async throws -> FirstMateLeadResponse { throw APIError.invalidResponse }
}
