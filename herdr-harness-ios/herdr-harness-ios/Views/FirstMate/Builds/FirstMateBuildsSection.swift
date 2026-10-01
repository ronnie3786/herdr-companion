import SwiftUI

// Stubs owned by the Builds and Simulator workstream: replaced with the
// Mobile App Hub and simulator-checkpoint Builds section, the stage chip, and
// the full-screen simulator. Both read `firstMateInspectorContext`.

/// Overview's Builds card. Hidden while there is nothing to show.
struct FirstMateBuildsSection: View {
    let snapshot: FirstMateSnapshot

    var body: some View { EmptyView() }
}

/// A workflow stage's simulator builds, beside its agents and documents chips.
struct FirstMateSimulatorVisitChip: View {
    let visitID: String

    var body: some View { EmptyView() }
}
