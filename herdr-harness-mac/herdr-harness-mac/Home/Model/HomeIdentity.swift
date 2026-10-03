import CryptoKit
import Foundation

enum HomeIdentity {
    /// Length prefixes keep arbitrary server IDs distinct, even if they contain delimiters.
    static func scoped(kind: String, machineID: String, entityID: String) -> String {
        [kind, machineID, entityID].map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func fingerprint(_ evidence: [String]) -> String {
        let bytes = evidence.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Canonical identity validated against both the URL and the provider's metadata.
/// Host is part of the key, so enterprise hosts and github.com never deduplicate.
struct HomePullRequestIdentity: Hashable, Sendable {
    let host: String
    let owner: String
    let repository: String
    let number: Int

    var url: String { "https://\(host)/\(owner)/\(repository)/pull/\(number)" }
    var id: String { url }
    var label: String { "\(owner)/\(repository) #\(number)" }

    init?(url value: String, repository expectedRepository: String, number expectedNumber: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), Self.validHost(host),
              !parts.percentEncodedPath.contains("%") else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[3] == "pull",
              Self.validSlug(String(path[1])), Self.validSlug(String(path[2])),
              !path[4].isEmpty, path[4].allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(path[4]), number > 0, number == expectedNumber else { return nil }
        let owner = path[1].lowercased(), repo = path[2].lowercased()
        guard expectedRepository.lowercased() == "\(owner)/\(repo)" else { return nil }
        self.host = host; self.owner = owner; repository = repo; self.number = number
    }

    private static func validSlug(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".."
            && text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }

    private static func validHost(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}
