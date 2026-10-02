import Foundation

/// Conversations are stored on the review's companion, independent of GitHub.
struct PRReviewDiscussion: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var reviewID: String
    var state: String
    var anchor: PRReviewDiscussionAnchor?
    var outdated: Bool
    var createdAt: String
    var updatedAt: String
    var version: Int
    var messages: [PRReviewDiscussionMessage]
    var history: [PRReviewDiscussionEvent]

    var isResolved: Bool { state == "resolved" }

    enum CodingKeys: String, CodingKey {
        case id, state, anchor, outdated, version, messages, history
        case reviewID = "review_id", createdAt = "created_at", updatedAt = "updated_at"
    }
}

struct PRReviewDiscussionAnchor: Codable, Equatable, Sendable {
    var path: String
    var baseSHA: String
    var headSHA: String
    var spans: [PRReviewCommentSpan]
    var codeExcerpt: String?
    var comparison: GitComparison?
    var comparisonSelection: GitComparisonSelection?

    enum CodingKeys: String, CodingKey {
        case path, spans, comparison
        case baseSHA = "base_sha", headSHA = "head_sha", codeExcerpt = "code_excerpt"
        case comparisonSelection = "comparison_selection"
    }

    var location: String {
        spans.map { "\($0.side.rawValue) \($0.start)" + ($0.end == $0.start ? "" : "–\($0.end)") }
            .joined(separator: ", ")
    }
}

struct PRReviewDiscussionMessage: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var author: String
    var body: String
    var createdAt: String
    var updatedAt: String

    var authorLabel: String { author == "agent" ? "Agent" : "Human" }

    enum CodingKeys: String, CodingKey {
        case id, author, body
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

struct PRReviewDiscussionEvent: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var action: String
    var author: String
    var createdAt: String
    var baseSHA: String?
    var headSHA: String?
    var previousBody: String?

    enum CodingKeys: String, CodingKey {
        case id, action, author
        case createdAt = "created_at", baseSHA = "base_sha", headSHA = "head_sha"
        case previousBody = "previous_body"
    }
}

struct PRReviewDiscussionCreate: Encodable, Sendable {
    var body: String
    var author = "human"
    var requestID: String
    var anchor: Anchor?

    struct Anchor: Encodable, Equatable, Sendable {
        var path: String
        var baseSHA: String
        var headSHA: String
        var spans: [PRReviewCommentSpan]
        var comparison: GitComparisonSelection

        enum CodingKeys: String, CodingKey {
            case path, spans, comparison
            case baseSHA = "base_sha", headSHA = "head_sha"
        }
    }

    enum CodingKeys: String, CodingKey {
        case body, author, anchor
        case requestID = "request_id"
    }
}

struct PRReviewDiscussionReply: Encodable, Sendable {
    var body: String
    var author = "human"
    var requestID: String
    enum CodingKeys: String, CodingKey {
        case body, author
        case requestID = "request_id"
    }
}

struct PRReviewDiscussionStateChange: Encodable, Sendable {
    var state: String
    var author = "human"
    var expectedVersion: Int
    var requestID: String
    enum CodingKeys: String, CodingKey {
        case state, author
        case expectedVersion = "expected_version", requestID = "request_id"
    }
}

protocol PRReviewDiscussionClient: Sendable {
    func prReviewDiscussions(reviewID: String) async throws -> [PRReviewDiscussion]
    func createPRReviewDiscussion(reviewID: String, request: PRReviewDiscussionCreate) async throws -> PRReviewDiscussion
    func replyToPRReviewDiscussion(reviewID: String, threadID: String, request: PRReviewDiscussionReply) async throws -> PRReviewDiscussion
    func setPRReviewDiscussionState(reviewID: String, threadID: String, request: PRReviewDiscussionStateChange) async throws -> PRReviewDiscussion
}

struct PRReviewDiscussionsResponse: Decodable, Sendable { var threads: [PRReviewDiscussion] }
struct PRReviewDiscussionResponse: Decodable, Sendable { var thread: PRReviewDiscussion }
