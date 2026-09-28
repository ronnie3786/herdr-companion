import Foundation

struct GitComparison: Codable, Equatable, Sendable {
    var id: String
    var mode: GitComparisonSelection.Mode
    var beforeSHA: String
    var afterSHA: String
    var commitSHAs: [String]
    enum CodingKeys: String, CodingKey {
        case id, mode
        case beforeSHA = "before_sha", afterSHA = "after_sha", commitSHAs = "commit_shas"
    }
    func matches(_ selection: GitComparisonSelection) -> Bool {
        guard mode == selection.mode else { return false }
        switch selection.mode {
        case .all: return true
        case .commit: return afterSHA == selection.startCommit
        case .range: return beforeSHA == selection.startCommit && afterSHA == selection.endCommit
        }
    }
}
