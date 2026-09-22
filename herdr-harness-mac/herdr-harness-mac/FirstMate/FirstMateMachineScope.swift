import Foundation

enum FirstMateMachineScope: Hashable, Sendable {
    case all
    case machine(String)

    static func resolved(_ selection: Self?, availableMachineIDs: [String]) -> Self {
        guard case .machine(let machineID) = selection else { return .all }
        return availableMachineIDs.contains(machineID) ? .machine(machineID) : .all
    }
}

struct FirstMateFleetFeatureID: Hashable, Sendable {
    let machineID: String
    let featureID: String
}

struct FirstMateFleetFeature: Identifiable, Equatable, Sendable {
    let machineID: String
    let machineName: String
    let feature: FirstMateFeature

    var id: FirstMateFleetFeatureID {
        FirstMateFleetFeatureID(machineID: machineID, featureID: feature.id)
    }
}
