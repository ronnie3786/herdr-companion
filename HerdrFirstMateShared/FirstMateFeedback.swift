import Foundation

/// The three starting reasons seeded by a `first-mate-feedback-v1` companion.
/// The stable IDs are server-owned; labels are the exact requested wording.
enum FirstMateFeedbackDefaults {
    static let tooLongID = "too_long"
    static let unnecessaryMessageID = "unnecessary_message"
    static let incorrectAssumptionID = "incorrect_assumption"

    static let categories: [FirstMateFeedbackCategory] = [
        FirstMateFeedbackCategory(id: tooLongID, label: "Longer than it needed to be", createdAt: ""),
        FirstMateFeedbackCategory(id: unnecessaryMessageID, label: "Unnecessary message", createdAt: ""),
        FirstMateFeedbackCategory(id: incorrectAssumptionID, label: "Incorrect assumption", createdAt: ""),
    ]
}

/// A reusable low-quality reason owned by one companion. Additional categories
/// are private user data; the defaults above are merely the starting set.
struct FirstMateFeedbackCategory: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, label
        case createdAt = "created_at"
    }
}

/// One saved rating per completed assistant response. `nil` is an explicit
/// cleared rating, which the companion retains as a new revision.
enum FirstMateFeedbackRating: String, Codable, CaseIterable, Sendable {
    case up
    case down
}

/// Frozen context for the exact response a rating belongs to. Session fields
/// are captured when the response is created; rating never substitutes the
/// feature's current coordinator session for an older response.
struct FirstMateFeedbackProvenance: Codable, Equatable, Sendable {
    var responseText: String
    var responseCreatedAt: String?
    var sourceKind: String
    var inReplyTo: String?
    var visitID: String?
    var featureRevision: Int?
    var coordinatorSessionID: String?
    var sessionProvenance: String

    enum CodingKeys: String, CodingKey {
        case responseText = "response_text"
        case responseCreatedAt = "response_created_at"
        case sourceKind = "source_kind"
        case inReplyTo = "in_reply_to"
        case visitID = "visit_id"
        case featureRevision = "feature_revision"
        case coordinatorSessionID = "coordinator_session_id"
        case sessionProvenance = "session_provenance"
    }
}

struct FirstMateFeedback: Codable, Equatable, Identifiable, Sendable {
    var messageID: String
    var featureID: String
    var rating: FirstMateFeedbackRating?
    var categoryIDs: [String]
    var comment: String
    var revision: Int
    var createdAt: String
    var updatedAt: String
    var provenance: FirstMateFeedbackProvenance

    var id: String { messageID }

    enum CodingKeys: String, CodingKey {
        case rating, comment, revision, provenance
        case messageID = "message_id"
        case featureID = "feature_id"
        case categoryIDs = "category_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Which completed responses are rateable. This policy is deliberately
/// separate from quote eligibility and from workflow closure: every completed
/// text-bearing assistant response qualifies, including older ones, whether or
/// not its feature is archived or closed.
enum FirstMateFeedbackEligibility {
    /// Real companions persist `done`; the synthetic demo uses `delivered`;
    /// older fixture payloads may carry `completed` or `complete`.
    static let completedStatuses: Set<String> = ["done", "delivered", "completed", "complete"]

    static func isEligible(role: String, status: String, text: String) -> Bool {
        role == "assistant"
            && completedStatuses.contains(status)
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isEligible(_ message: FirstMateMessage) -> Bool {
        isEligible(role: message.role, status: message.status, text: message.text)
    }

    static func eligibleMessageIDs(in messages: [FirstMateMessage]) -> Set<String> {
        Set(messages.lazy.filter { isEligible($0) }.map(\.id))
    }
}

/// Editable feedback for one response. `rating == .down` keeps reasons and a
/// comment optional; a positive or cleared rating sends none. The draft itself
/// is preserved exactly as typed so a failed save can restore it.
///
/// `baseRevision` pins the retained record revision this edit was initialized
/// from; a completed fetch that found no record pins zero. It stays pinned
/// while the draft is editable, so a refresh arriving during an edit can never
/// silently authorize the save over newer feedback. Only an explicit
/// conflict-resolution action rebases it. A nil base revision means the draft
/// was built before any record load completed; saves pin the currently known
/// revision at submission time.
struct FirstMateFeedbackDraft: Equatable, Sendable {
    var rating: FirstMateFeedbackRating?
    var categoryIDs: [String]
    var comment: String
    var baseRevision: Int?

    init(
        rating: FirstMateFeedbackRating? = .down,
        categoryIDs: [String] = [],
        comment: String = "",
        baseRevision: Int? = nil
    ) {
        self.rating = rating
        self.categoryIDs = categoryIDs
        self.comment = comment
        self.baseRevision = baseRevision
    }

    var forRequest: FirstMateFeedbackDraft {
        guard rating == .down else {
            return FirstMateFeedbackDraft(rating: rating, categoryIDs: [], comment: "", baseRevision: baseRevision)
        }
        return self
    }
}

/// The companion rejects reasons on positive or cleared ratings, so only the
/// request payload is normalized.
struct FirstMateFeedbackSaveRequest: Encodable, Equatable, Sendable {
    var rating: FirstMateFeedbackRating?
    var categoryIDs: [String]
    var comment: String
    var expectedRevision: Int
    var requestID: String

    enum CodingKeys: String, CodingKey {
        case rating, comment
        case categoryIDs = "category_ids"
        case expectedRevision = "expected_revision"
        case requestID = "request_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // All five keys are required, and clearing sends an explicit null.
        // Synthesized optional encoding would omit `rating` instead.
        if let rating {
            try container.encode(rating.rawValue, forKey: .rating)
        } else {
            try container.encodeNil(forKey: .rating)
        }
        try container.encode(categoryIDs, forKey: .categoryIDs)
        try container.encode(comment, forKey: .comment)
        try container.encode(expectedRevision, forKey: .expectedRevision)
        try container.encode(requestID, forKey: .requestID)
    }

    /// Exact payload identity, excluding the request ID that safe retries reuse.
    func hasSamePayload(as other: FirstMateFeedbackSaveRequest) -> Bool {
        rating == other.rating
            && categoryIDs == other.categoryIDs
            && comment == other.comment
            && expectedRevision == other.expectedRevision
    }
}

struct FirstMateFeedbackCategoryCreateRequest: Encodable, Equatable, Sendable {
    var label: String
    var requestID: String

    enum CodingKeys: String, CodingKey {
        case label
        case requestID = "request_id"
    }
}

struct FirstMateFeedbackCategoriesResponse: Decodable, Sendable {
    var ok: Bool
    var categories: [FirstMateFeedbackCategory]
}

struct FirstMateFeedbackCategoryResponse: Decodable, Sendable {
    var ok: Bool
    var category: FirstMateFeedbackCategory
}

struct FirstMateFeatureFeedbackResponse: Decodable, Sendable {
    var ok: Bool
    var featureID: String
    var records: [FirstMateFeedback]

    enum CodingKeys: String, CodingKey {
        case ok, records
        case featureID = "feature_id"
    }
}

struct FirstMateFeedbackMutationResponse: Decodable, Sendable {
    var ok: Bool
    var featureID: String
    var feedback: FirstMateFeedback

    enum CodingKeys: String, CodingKey {
        case ok, feedback
        case featureID = "feature_id"
    }
}
