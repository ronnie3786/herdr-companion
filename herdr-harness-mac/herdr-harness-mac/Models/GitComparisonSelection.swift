import Foundation

/// The same ordered tree comparison is used by PR Review and local Git views.
/// A range compares the two selected trees directly; a commit compares the
/// target-branch baseline with that commit.
struct GitComparisonSelection: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable { case all, commit, range }
    var mode: Mode = .all
    var startCommit: String?
    var endCommit: String?
    static let all = GitComparisonSelection()
    enum CodingKeys: String, CodingKey {
        case mode
        case startCommit = "start_commit", endCommit = "end_commit"
    }
    var identity: String { [mode.rawValue, startCommit ?? "", endCommit ?? ""].joined(separator: ":") }
    func queryItems(baseSHA: String, headSHA: String) -> [URLQueryItem] {
        var result = [URLQueryItem(name: "mode", value: mode.rawValue),
                      .init(name: "base_sha", value: baseSHA), .init(name: "head_sha", value: headSHA)]
        if let startCommit { result.append(.init(name: "start_commit", value: startCommit)) }
        if let endCommit { result.append(.init(name: "end_commit", value: endCommit)) }
        return result
    }
}
