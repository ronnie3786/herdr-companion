import Foundation

/// The PR Review rail's host filter, independent of the open review's owner.
enum PRReviewHostScope: Hashable, Sendable {
    case all
    case machine(String)

    static let allMachinesTitle = "All machines"

    static func resolved(_ selection: Self?, availableMachineIDs: [String]) -> Self {
        guard case .machine(let machineID) = selection else { return .all }
        return availableMachineIDs.contains(machineID) ? .machine(machineID) : .all
    }
}
