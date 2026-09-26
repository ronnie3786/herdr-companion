import Foundation

/// The roster-and-connection signature that decides when the First Mate
/// observation task must re-activate.
///
/// The identity is the ordered list of machine IDs plus the connection
/// generation and demo state. It intentionally has no single "current machine":
/// All Machines observes every configured host, and a rename or a saved scope
/// choice must not restart a healthy observation.
struct FirstMateObservationContext: Equatable {
    /// Stable machine identities in roster order. Adding, removing, or
    /// reordering a host re-activates the fleet.
    let machineIDs: [String]
    let generation: Int
    let isDemo: Bool
    let isActive: Bool
}
