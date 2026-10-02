import Foundation

/// A generation is one exact set of reviewer runs against one pair of commits.
/// It is separate from the review's general-purpose mutation revision.
struct PRReviewConsolidation: Codable, Equatable, Sendable {
    var generation: Int
    var state: String
    var baseSHA: String
    var headSHA: String
    var runID: String?
    var documentIDs: [String]
    var error: String?
    var inputRunIDs: [String]
    var incompleteRunIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case generation, state, error
        case baseSHA = "base_sha", headSHA = "head_sha", runID = "run_id"
        case documentIDs = "document_ids", inputRunIDs = "input_run_ids"
        case incompleteRunIDs = "incomplete_run_ids"
    }

    init(generation: Int, state: String, baseSHA: String, headSHA: String, runID: String? = nil,
         documentIDs: [String], error: String? = nil, inputRunIDs: [String], incompleteRunIDs: [String]? = nil) {
        self.generation = generation
        self.state = state
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.runID = runID
        self.documentIDs = documentIDs
        self.error = error
        self.inputRunIDs = inputRunIDs
        self.incompleteRunIDs = incompleteRunIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(Int.self, forKey: .generation)
        state = try container.decode(String.self, forKey: .state)
        // Commit identities are unknown while the initial checkout is preparing.
        baseSHA = try container.decodeIfPresent(String.self, forKey: .baseSHA) ?? ""
        headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA) ?? ""
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        documentIDs = try container.decodeIfPresent([String].self, forKey: .documentIDs) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
        inputRunIDs = try container.decodeIfPresent([String].self, forKey: .inputRunIDs) ?? []
        incompleteRunIDs = try container.decodeIfPresent([String].self, forKey: .incompleteRunIDs)
    }

    func matches(_ review: PRReviewSummary) -> Bool {
        baseSHA == review.baseSHA && headSHA == review.headSHA
    }
}
