import Foundation
import Observation

@MainActor @Observable
final class DashboardState {
    private let defaults: UserDefaults
    var focusMode: Bool { didSet { defaults.set(focusMode, forKey: "herdr.dashboard.focus-mode") } }
    var recentMachineID: String { didSet { defaults.set(recentMachineID, forKey: "herdr.dashboard.recent-machine") } }
    var search = ""
    var reviewRefreshError: String?
    var isRefreshingReviews = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focusMode = defaults.bool(forKey: "herdr.dashboard.focus-mode")
        recentMachineID = defaults.string(forKey: "herdr.dashboard.recent-machine") ?? ""
    }

    func entries(shell: HerdrShellState, isDemo: Bool) -> [DashboardFeatureEntry] {
        if isDemo {
            return DashboardFeatureEntry.ordered(shell.firstMate.features.map { feature in
                var feature = feature
                if let snapshot = shell.firstMate.snapshots[feature.id] {
                    feature.dashboardSummary = .from(snapshot)
                }
                return .init(machineID: "demo", machineName: "Demo Mac", feature: feature)
            })
        }
        return DashboardFeatureEntry.ordered(shell.firstMateFleet.hosts.flatMap { host in
            host.features.map {
                .init(machineID: host.machineID, machineName: host.machineName, feature: $0,
                      lastUpdated: host.lastUpdated, hostError: host.error)
            }
        })
    }
}
