import Foundation

enum FirstMateMachineScope: Hashable, Sendable {
    case all
    case machine(String)
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
