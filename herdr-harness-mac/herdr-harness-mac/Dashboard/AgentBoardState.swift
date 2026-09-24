import Foundation
import Observation

/// Owned by the window shell, so filtering columns or visiting a full screen does
/// not discard an unfinished reply or change that feature's selected tab.
@MainActor @Observable
final class AgentBoardState {
    var filter = AgentBoardFilter.all
    @ObservationIgnored private var columns: [String: AgentBoardColumnState] = [:]

    func column(for entry: DashboardFeatureEntry) -> AgentBoardColumnState {
        if let column = columns[entry.id] { return column }
        let column = AgentBoardColumnState(machineID: entry.machineID, featureID: entry.feature.id)
        columns[entry.id] = column
        return column
    }

    func entries(_ entries: [DashboardFeatureEntry], focusMode: Bool) -> [DashboardFeatureEntry] {
        entries.filter { entry in
            (!focusMode || entry.needsAttention) && filter.includes(entry)
        }
    }
}
