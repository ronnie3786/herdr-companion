import Foundation

enum AgentBoardFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsYou = "Needs you"
    case working = "Working"

    var id: Self { self }

    func includes(_ entry: DashboardFeatureEntry) -> Bool {
        switch self {
        case .all: true
        case .needsYou: entry.needsAttention
        case .working: entry.isWorking
        }
    }
}
