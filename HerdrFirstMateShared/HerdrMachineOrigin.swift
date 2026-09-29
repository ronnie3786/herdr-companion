import Foundation

extension HerdrMachine {
    /// Returns an exact HTTP(S) origin suitable for identity matching.
    /// Paths, credentials, query strings, and fragments are deliberately not
    /// normalized away because accepting them would weaken matching.
    static func normalizedOrigin(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
        else { return nil }
        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https", !rawHost.isEmpty,
              let separator = value.range(of: "://")
        else { return nil }
        let authority = value[separator.upperBound...].prefix { !"/?#".contains($0) }
        let hasExplicitPort: Bool
        if authority.first == "[", let bracket = authority.firstIndex(of: "]") {
            let suffix = authority[authority.index(after: bracket)...]
            guard suffix.isEmpty || (suffix.first == ":" && suffix.dropFirst().allSatisfy(\.isNumber))
            else { return nil }
            hasExplicitPort = !suffix.isEmpty
        } else {
            let colons = authority.count(where: { $0 == ":" })
            guard colons <= 1 else { return nil }
            if let colon = authority.lastIndex(of: ":") {
                let digits = authority[authority.index(after: colon)...]
                guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
                hasExplicitPort = true
            } else {
                hasExplicitPort = false
            }
        }
        let port = components.port
        guard !hasExplicitPort || port != nil else { return nil }
        if let port, !(1...65_535).contains(port) { return nil }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = rawHost.lowercased()
        if port != (scheme == "http" ? 80 : 443) {
            origin.port = port
        }
        return origin.string
    }
}
