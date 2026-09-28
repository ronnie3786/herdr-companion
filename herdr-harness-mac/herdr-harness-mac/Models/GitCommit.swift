import Foundation

struct GitCommit: Codable, Equatable, Identifiable, Sendable {
    var sha: String
    var parents: [String]
    var subject: String
    var authorName: String
    var authoredAt: String
    var id: String { sha }
    var label: String { "\(sha.prefix(7)) · \(subject)" }
    enum CodingKeys: String, CodingKey {
        case sha, parents, subject
        case authorName = "author_name", authoredAt = "authored_at"
    }
}


/// Topological list order alone does not establish ancestry: two commits may
/// belong to sibling branches that were later merged into this history.
enum GitCommitAncestry {
    static func isAncestor(_ ancestor: String, of descendant: String, in commits: [GitCommit]) -> Bool {
        guard ancestor != descendant else { return false }
        let parents = Dictionary(commits.map { ($0.sha, $0.parents) }, uniquingKeysWith: { first, _ in first })
        var pending = parents[descendant] ?? []
        var visited: Set<String> = []
        while let sha = pending.popLast() {
            if sha == ancestor { return true }
            if visited.insert(sha).inserted { pending.append(contentsOf: parents[sha] ?? []) }
        }
        return false
    }
}
