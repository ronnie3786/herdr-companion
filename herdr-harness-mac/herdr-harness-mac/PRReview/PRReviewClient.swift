import Foundation

protocol PRReviewClient: Sendable {
    func prReviewCapabilities() async throws -> PRReviewCapabilities
    func prReviewSkills() async throws -> [PRReviewSkill]
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill]
    func prReviews(scope: String) async throws -> [PRReviewSummary]
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot
    func prReview(id: String) async throws -> PRReviewSnapshot
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff
    func prReviewFileText(
        id: String,
        path: String,
        side: PRReviewSide,
        start: Int?,
        end: Int?
    ) async throws -> PRReviewFileText
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun
    func finishPRReviewRun(
        reviewID: String,
        runID: String,
        state: PRReviewRunState,
        note: String?,
        requestID: String
    ) async throws -> PRReviewRun
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String
    func markPRReviewSkill(
        reviewID: String,
        skillID: String,
        state: String,
        note: String?,
        requestID: String
    ) async throws -> PRReviewSkillState
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary
    func setPRReviewRankings(
        id: String,
        files: [[String: String]],
        requestID: String
    ) async throws -> [PRReviewFile]
    func setPRReviewViewed(
        id: String,
        paths: [String],
        viewed: Bool,
        requestID: String
    ) async throws -> [PRReviewFile]
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile]
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument]
    func addPRReviewDocument(
        id: String,
        payload: PRReviewDocumentPayload,
        requestID: String
    ) async throws -> PRReviewDocument
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument
    func downloadPRReviewDocument(
        reviewID: String,
        documentID: String,
        expectedByteSize: Int64,
        to destinationURL: URL
    ) async throws
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent]
}

struct PRReviewSkillCreateRequest: Codable, Sendable {
    var id: String
    var title: String
    var kind: PRReviewSkillKind?
    var promptTemplate: String?
    var commandTemplate: String?
    var outputs: [String]?
    var description: String?
    var requestID: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case promptTemplate = "prompt_template"
        case commandTemplate = "command_template"
        case outputs
        case description
        case requestID = "request_id"
    }
}

enum PRReviewDocumentPayload: Sendable {
    case upload(filename: String, contentType: String, dataBase64: String, title: String?)
    case link(url: String, title: String)
    case path(String, title: String?)
}
