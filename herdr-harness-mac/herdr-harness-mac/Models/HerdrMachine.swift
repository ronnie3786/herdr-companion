import Foundation

struct HerdrMachine: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var urlString: String
    /// Optional explicit role from the private cluster configuration.
    var role: String? = nil
    /// Optional presentation metadata. It never changes connection identity.
    var sidebarLabel: String? = nil
    var sidebarOrder: Int? = nil

    init(
        id: String,
        name: String,
        urlString: String,
        role: String? = nil,
        sidebarLabel: String? = nil,
        sidebarOrder: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.role = role
        self.sidebarLabel = Self.validSidebarLabel(sidebarLabel)
        self.sidebarOrder = Self.validSidebarOrder(sidebarOrder)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, urlString, role, sidebarLabel, sidebarOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        urlString = try container.decode(String.self, forKey: .urlString)
        role = try? container.decode(String.self, forKey: .role)
        sidebarLabel = Self.validSidebarLabel(try? container.decode(String.self, forKey: .sidebarLabel))
        sidebarOrder = Self.validSidebarOrder(try? container.decode(Int.self, forKey: .sidebarOrder))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(urlString, forKey: .urlString)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(sidebarLabel, forKey: .sidebarLabel)
        try container.encodeIfPresent(sidebarOrder, forKey: .sidebarOrder)
    }

    static func validSidebarLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 128,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else { return nil }
        return trimmed
    }

    static func validSidebarOrder(_ value: Int?) -> Int? {
        guard let value, (0...Int(Int32.max)).contains(value) else { return nil }
        return value
    }

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

/// Additive response contract for the authenticated configuration roster.
/// The server's selected machine ID identifies only the companion answering
/// this authenticated request; it never replaces a saved app connection ID.
struct HerdrMachineConfigurationResponse: Decodable, Sendable {
    let ok: Bool
    let machines: [HerdrMachineConfigurationRecord]
    let localMachineId: String?

    private enum CodingKeys: String, CodingKey {
        case ok, machines, localMachineId
    }

    init(
        ok: Bool,
        machines: [HerdrMachineConfigurationRecord],
        localMachineId: String? = nil
    ) {
        self.ok = ok
        self.machines = machines
        self.localMachineId = localMachineId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        machines = try container.decode([HerdrMachineConfigurationRecord].self, forKey: .machines)
        localMachineId = try? container.decode(String.self, forKey: .localMachineId)
    }
}

/// Only stable record identity, URL, and optional sidebar presentation are
/// consumed. A malformed optional value is ignored without rejecting the
/// otherwise useful roster.
struct HerdrMachineConfigurationRecord: Decodable, Equatable, Sendable {
    let id: String?
    let url: String
    let sidebarLabel: String?
    let sidebarOrder: Int?

    private enum CodingKeys: String, CodingKey {
        case id, url, sidebarLabel, sidebarOrder
    }

    init(
        id: String? = nil,
        url: String,
        sidebarLabel: String? = nil,
        sidebarOrder: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.sidebarLabel = HerdrMachine.validSidebarLabel(sidebarLabel)
        self.sidebarOrder = HerdrMachine.validSidebarOrder(sidebarOrder)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        sidebarLabel = HerdrMachine.validSidebarLabel(
            try? container.decode(String.self, forKey: .sidebarLabel)
        )
        sidebarOrder = HerdrMachine.validSidebarOrder(
            try? container.decode(Int.self, forKey: .sidebarOrder)
        )
    }
}

// The generated resource contains only machine metadata. Tokens are entered at runtime.
extension HerdrMachine {
    static func configuredMachines(bundle: Bundle = .main) -> [HerdrMachine] {
        guard let url = bundle.url(forResource: "HerdrBootstrap", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let machines = try? PropertyListDecoder().decode([HerdrMachine].self, from: data) else { return [] }
        return machines.filter { machine in
            guard let components = URLComponents(string: machine.urlString),
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  let host = components.host?.lowercased() else { return false }
            let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
            return components.scheme == "https" || (components.scheme == "http" && loopback)
        }
    }
}
