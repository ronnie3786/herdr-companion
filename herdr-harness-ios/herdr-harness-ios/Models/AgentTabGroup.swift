import Foundation

struct AgentTabGroup: Identifiable {
    let id: String
    let name: String
    let sessions: [AgentSession]
}
