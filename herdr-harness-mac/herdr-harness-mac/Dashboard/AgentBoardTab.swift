import Foundation

enum AgentBoardTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case overview = "Overview"
    case agents = "Agents"
    case workflow = "Workflow"

    var id: Self { self }
}
