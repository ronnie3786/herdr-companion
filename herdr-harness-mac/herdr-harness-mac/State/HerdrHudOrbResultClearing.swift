/// Selection for clearing the orb-docked (detached) results, not session results.
/// Busy and just-opened items follow the same rule as per-chip Dismiss Result.
enum HerdrHudOrbResultClearing {
    static let menuTitle = "Clear all results"
    static let accessibilityActionName = "Clear all results"

    static func clearableArtifacts(
        _ artifacts: [AgentResultArtifact],
        phase: (String) -> AgentResultArtifactPhase
    ) -> [AgentResultArtifact] {
        artifacts.filter { artifact in
            switch phase(artifact.id) {
            case .available, .failed:
                true
            case .opening, .downloading, .opened:
                false
            }
        }
    }
}
