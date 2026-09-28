import Foundation

struct FirstMateVisit: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var stageKey: String
    var title: String
    var status: String
    var revision: Int
    var createdAt: String?
    var predecessorVisitID: String?
    var gitEvidence: [FirstMateVisitGitEvidence]? = nil

    /// Dates order independent workspace tips for presentation only. The
    /// identity of each tip always comes from the captured ending revision.
    var primaryGitEvidence: FirstMateVisitGitEvidence? {
        let formatter = ISO8601DateFormatter()
        return gitEvidence?.filter { $0.terminalCommit != nil }.max {
            (formatter.date(from: $0.terminalCommit!.committedAt) ?? .distantPast)
                < (formatter.date(from: $1.terminalCommit!.committedAt) ?? .distantPast)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, revision
        case featureID = "feature_id", stageKey = "stage_key", createdAt = "created_at"
        case predecessorVisitID = "predecessor_visit_id"
        case gitEvidence = "git_evidence"
    }
}

struct FirstMateVisitGitEvidence: Codable, Equatable, Sendable {
    var workspaceID: String
    var startSHA: String?
    var endSHA: String?
    var status: String
    var commits: [FirstMateVisitCommit]
    var truncated: Bool

    var terminalCommit: FirstMateVisitCommit? {
        guard status == "captured", let endSHA else { return nil }
        return commits.first { $0.sha == endSHA }
    }

    enum CodingKeys: String, CodingKey {
        case status, commits, truncated
        case workspaceID = "workspace_id", startSHA = "start_sha", endSHA = "end_sha"
    }
}

struct FirstMateVisitCommit: Codable, Equatable, Identifiable, Sendable {
    var sha: String
    var subject: String
    var committedAt: String
    var id: String { sha }

    enum CodingKeys: String, CodingKey {
        case sha, subject
        case committedAt = "committed_at"
    }
}
