import Foundation

/// Constants of the frozen `chat-tab-colors-v1` contract.
///
/// The companion validates exactly the keys defined below and rejects unknown
/// fields, so these names must not drift from `docs/chat-tab-color-api.md`.
enum ChatTabColorContract {
    static let capability = "chat-tab-colors-v1"
    static let platform = "macos"
    static let clientName = "Herdr Companion"
    static let heartbeatSeconds: TimeInterval = 20
    static let staleAfterSeconds: TimeInterval = 60
    static let maximumTabs = 2048

    /// Mirrors the companion's `chat_tab_colors.tab_identifier` contract
    /// (`^[A-Za-z0-9][A-Za-z0-9:._-]{0,255}$`). The companion rejects a whole
    /// publication when any entry carries an invalid identity, so the
    /// publisher filters to identifiers the server can accept instead of
    /// manufacturing an entry for a pane that has no tab identity.
    static func isValidIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard let first = scalars.first, scalars.count <= 256 else { return false }
        guard isIdentifierStart(first) else { return false }
        return scalars.dropFirst().allSatisfy(isIdentifierBody)
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: true
        default: false
        }
    }

    private static func isIdentifierBody(_ scalar: Unicode.Scalar) -> Bool {
        if isIdentifierStart(scalar) { return true }
        // `:`, `.`, `_`, `-`
        switch scalar.value {
        case 58, 46, 95, 45: true
        default: false
        }
    }
}

struct ChatTabColorCapabilitiesResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let version: Int
    let serverId: String
    let capabilities: [String]
    let chatTabColorStaleAfterSeconds: TimeInterval?

    var supportsPublication: Bool {
        ok && version == 1 && capabilities.contains(ChatTabColorContract.capability)
    }
}

/// One tab entry in a publication.
///
/// `color` and `label` are always encoded, including explicit `null`s, so the
/// canonical body of a retry is byte-identical to the first publication and a
/// heartbeat is a server-side idempotent no-op rather than a conflict.
struct ChatTabColorPublicationTab: Codable, Equatable, Sendable {
    let workspaceId: String
    let tabId: String
    let color: String?
    let label: String?

    init(workspaceId: String, tabId: String, color: String?, label: String?) {
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.color = color
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId, tabId, color, label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try container.decode(String.self, forKey: .workspaceId)
        tabId = try container.decode(String.self, forKey: .tabId)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encode(tabId, forKey: .tabId)
        if let color {
            try container.encode(color, forKey: .color)
        } else {
            try container.encodeNil(forKey: .color)
        }
        if let label {
            try container.encode(label, forKey: .label)
        } else {
            try container.encodeNil(forKey: .label)
        }
    }
}

struct ChatTabColorPublicationRequest: Codable, Equatable, Sendable {
    let serverId: String
    let publisherToken: String
    let platform: String
    let clientName: String
    let enabled: Bool
    let revision: Int
    let tabs: [ChatTabColorPublicationTab]
}

struct ChatTabColorPublicationSummary: Decodable, Equatable, Sendable {
    let clientId: String
    let platform: String
    let clientName: String
    let enabled: Bool
    let revision: Int
    let tabCount: Int
    let updatedAt: String
    let lastSeenAt: String
    let stale: Bool
}

struct ChatTabColorPublicationResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let serverId: String
    let publication: ChatTabColorPublicationSummary
}
