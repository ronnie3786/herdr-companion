import Foundation

enum HerdrExternalURL {
    static func webURL(from value: String?) -> URL? {
        guard let value,
              let candidate = URL(string: value),
              let scheme = candidate.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              candidate.host?.isEmpty == false,
              candidate.user == nil,
              candidate.password == nil else { return nil }
        return candidate
    }

    static func threadURL(from value: String?) -> URL? {
        if let webURL = webURL(from: value) {
            return webURL
        }
        guard let value, let candidate = URL(string: value), isBuzzMessageURL(candidate) else {
            return nil
        }
        return candidate
    }

    static func isOpenable(_ url: URL) -> Bool {
        threadURL(from: url.absoluteString) != nil
    }

    static func isBuzzMessageURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 4_096,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "buzz",
              components.host?.lowercased() == "message",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.fragment == nil,
              let queryItems = components.queryItems,
              !queryItems.isEmpty else { return false }

        let allowedNames = Set(["channel", "id", "thread", "event", "root"])
        guard queryItems.allSatisfy({ allowedNames.contains($0.name) }) else { return false }

        func identifier(named name: String, maximumLength: Int = 256) -> String? {
            let matches = queryItems.filter { $0.name == name }
            guard matches.count == 1,
                  let value = matches[0].value,
                  !value.isEmpty,
                  value.utf8.count <= maximumLength,
                  value.unicodeScalars.allSatisfy({ buzzIdentifierCharacters.contains($0) }) else {
                return nil
            }
            return value
        }

        guard identifier(named: "channel", maximumLength: 128) != nil else { return false }
        let messageID = identifier(named: "id")
        let legacyEventID = identifier(named: "event")

        if messageID != nil, legacyEventID == nil {
            return !queryItems.contains(where: { $0.name == "root" })
                && optionalIdentifier(named: "thread", in: queryItems)
        }
        if legacyEventID != nil, messageID == nil {
            return !queryItems.contains(where: { $0.name == "thread" })
                && optionalIdentifier(named: "root", in: queryItems)
        }
        return false
    }

    private static let buzzIdentifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:"
    )

    private static func optionalIdentifier(named name: String, in queryItems: [URLQueryItem]) -> Bool {
        let matches = queryItems.filter { $0.name == name }
        guard matches.count <= 1 else { return false }
        guard let item = matches.first else { return true }
        guard let value = item.value,
              !value.isEmpty,
              value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { buzzIdentifierCharacters.contains($0) }
    }
}
