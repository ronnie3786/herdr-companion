import Foundation

/// One row of a First Mate's Builds section: a Mobile App Hub build, with the
/// simulator copy an agent saved alongside it, or a simulator-only checkpoint.
enum FirstMateBuildEntry: Identifiable {
    case hub(MobileAppHubBuild, simulator: FirstMateSimulatorBuild?)
    case simulator(FirstMateSimulatorBuild)

    var id: String {
        switch self {
        case .hub(let build, _): "hub-" + build.id
        case .simulator(let build): "simulator-" + build.id
        }
    }

    var date: Date {
        switch self {
        case .hub(let build, _): build.date
        case .simulator(let build): build.date ?? .distantPast
        }
    }

    /// Hub builds pair with the simulator build that names them; the rest of
    /// the simulator builds stand alone. Newest first.
    static func merge(hub: [MobileAppHubBuild], simulator: [FirstMateSimulatorBuild]) -> [FirstMateBuildEntry] {
        var paired = Set<String>()
        var entries: [FirstMateBuildEntry] = hub.map { build in
            let copy = simulator.first { $0.hubBuildID == build.id }
            if let copy { paired.insert(copy.id) }
            return .hub(build, simulator: copy)
        }
        entries += simulator.filter { !paired.contains($0.id) }.map { .simulator($0) }
        return entries.enumerated()
            .sorted { ($0.element.date, $1.offset) > ($1.element.date, $0.offset) }
            .map(\.element)
    }
}
