import Foundation

struct PRReviewCommits: Decodable, Sendable {
    var reviewID: String
    var baseSHA: String
    var headSHA: String
    var baselineSHA: String
    var baselineLabel: String
    var commits: [GitCommit]
    var truncated: Bool
    func allows(before: String, after: String) -> Bool {
        guard before != after, commits.contains(where: { $0.sha == after }) else { return false }
        if before == baselineSHA { return true }
        return GitCommitAncestry.isAncestor(before, of: after, in: commits)
    }

    enum CodingKeys: String, CodingKey {
        case commits, truncated
        case reviewID = "review_id", baseSHA = "base_sha", headSHA = "head_sha"
        case baselineSHA = "baseline_sha", baselineLabel = "baseline_label"
    }
}
