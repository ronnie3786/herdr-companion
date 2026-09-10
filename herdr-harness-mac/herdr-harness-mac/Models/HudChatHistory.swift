import Foundation

struct HudChatSummary: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let updatedAt: String
    let latestRunId: String
    let turnCount: Int
    let status: HeadlessAgentRunStatus
    let sessionId: String?
    let promotedPaneId: String?
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
