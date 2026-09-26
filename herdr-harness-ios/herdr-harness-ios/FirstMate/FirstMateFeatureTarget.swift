import Foundation

/// The composite identity of one First Mate feature on one machine.
///
/// A feature ID is unique only inside its owning companion, so every combined
/// row, navigation destination, and delayed response is keyed by both the
/// stable machine ID and the feature ID. Display names and roster order are
/// never identity: two machines can share a name, and two features on
/// different machines can share an ID.
struct FirstMateFeatureTarget: Hashable, Sendable, Identifiable {
    let machineID: String
    let featureID: String

    var id: FirstMateFeatureTarget { self }
}

/// A host-qualified First Mate feature row for the combined All Machines list.
///
/// The row carries the owning machine's current display name so a combined
/// card can label its host without re-deriving identity from a name or from
/// roster position.
struct FirstMateMobileFleetFeature: Identifiable, Equatable, Sendable {
    let target: FirstMateFeatureTarget
    let machineName: String
    let feature: FirstMateFeature

    var id: FirstMateFeatureTarget { target }
    var machineID: String { target.machineID }
    var featureID: String { target.featureID }
}
