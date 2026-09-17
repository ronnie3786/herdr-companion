import Foundation

struct HudChatSummary: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let updatedAt: String
    let latestRunId: String
    let turnCount: Int
    let status: HeadlessAgentRunStatus
    let sessionId: String?
    let promotedPaneId: String?
    /// Canonical server-side working directory. Older servers omit it.
    let cwd: String?

    func scopedID(machineID: String) -> String {
        MachineScopedID.compose(machineID: machineID, rawID: id)
    }
}

struct HudChatCatalog: Decodable, Sendable {
    let chats: [HudChatSummary]
    let nextOffset: Int?
}

struct HudChatHistory: Decodable, Sendable {
    let turns: [HeadlessAgentRun]
    let rootRunId: String
    let latestRunId: String
    let promotedPaneId: String?
    let nextOffset: Int?
}

struct HudChatCapabilities: Decodable, Equatable, Sendable {
    let profiles: [String]
    let hudChatWorkingDirectory: Bool

    var supportsHudChats: Bool { profiles.contains("hud-chat-v1") }

    private enum CodingKeys: String, CodingKey {
        case profiles
        case hudChatWorkingDirectory
    }

    init(profiles: [String], hudChatWorkingDirectory: Bool = false) {
        self.profiles = profiles
        self.hudChatWorkingDirectory = hudChatWorkingDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([String].self, forKey: .profiles) ?? []
        hudChatWorkingDirectory = try container.decodeIfPresent(Bool.self, forKey: .hudChatWorkingDirectory) ?? false
    }
}

/// A dedicated request keeps durable saved chats separate from the destructive
/// lifecycle of the existing one-off agent sheet.
struct HudChatStartRequest: Encodable, Sendable {
    let prompt: String
    let cwd: String?
    let model: String?
    let thinkingLevel: String?
    let continueFromRunId: String?

    private enum CodingKeys: String, CodingKey {
        case prompt
        case cwd
        case mode
        case model
        case thinkingLevel
        case continueFromRunId
        case profile
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode("act", forKey: .mode)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
        try container.encodeIfPresent(continueFromRunId, forKey: .continueFromRunId)
        try container.encode("hud-chat-v1", forKey: .profile)
    }
}

@MainActor
protocol HudChatTransport: AnyObject {
    func fetchHudChatCapabilities(machineID: String) async throws -> HudChatCapabilities
    func fetchHudChatCatalog(machineID: String, query: String, offset: Int) async throws -> HudChatCatalog
    func fetchHudChatHistory(machineID: String, id: String, offset: Int) async throws -> HudChatHistory
    func startHudChat(
        machineID: String,
        prompt: String,
        cwd: String?,
        model: String?,
        thinkingLevel: String?,
        continueFromRunId: String?
    ) async throws -> HeadlessAgentRun
    func stopHudChat(machineID: String, runID: String) async throws -> HeadlessAgentRun
    func fetchHudChatModels(machineID: String) async throws -> AgentModelCatalogResponse
}
