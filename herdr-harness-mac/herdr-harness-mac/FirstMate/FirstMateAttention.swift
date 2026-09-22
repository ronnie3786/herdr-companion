import Foundation

/// Classifies the First Mate features that are waiting on a human.
///
/// The Mac Chat sidebar badges the First Mate navigation entry so a feature
/// that needs direction or an intervention is visible without opening First
/// Mate. Only two feature statuses leave an outstanding human decision:
/// `awaiting_direction` (a human checkpoint, a request for direction, or a
/// goal revision awaiting review) and `blocked` (recovery was exhausted and an
/// intervention is required). Working, ready, paused, recovering, finished,
/// cancelled, and unknown statuses do not contribute.
enum FirstMateAttention {
    /// The exact feature statuses that wait on a human decision.
    static let humanDecisionStatuses: Set<String> = ["awaiting_direction", "blocked"]

    /// Whether a feature in this status is waiting on a human decision.
    ///
    /// The comparison is exact: unrecognized statuses are unknown states and
    /// must never manufacture attention.
    static func needsHumanDecision(status: String) -> Bool {
        humanDecisionStatuses.contains(status)
    }

    /// The number of distinct features that are waiting on a human decision.
    ///
    /// A feature is identified by its owning machine plus its feature ID, so
    /// identical feature IDs on different machines count separately and
    /// duplicate records for one machine-owned feature count once. The count
    /// reads whole hosts rather than a filtered view, so search text, host
    /// selection, and other presentation filters never hide attention. A host
    /// that has not reported a successful list contributes nothing, while a
    /// host that kept its last successful list through an error still
    /// contributes it.
    static func count(hosts: [FirstMateFleetHost]) -> Int {
        var waiting = Set<FirstMateFleetFeatureID>()
        for host in hosts {
            for feature in host.features where !feature.isArchived && needsHumanDecision(status: feature.status) {
                waiting.insert(FirstMateFleetFeatureID(machineID: host.machineID, featureID: feature.id))
            }
        }
        return waiting.count
    }
}
