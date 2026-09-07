import Foundation

enum PaneResultArtifacts {
    static func matching(
        _ artifacts: [AgentResultArtifact],
        pane: HerdrPane,
        sessionID: String? = nil
    ) -> [AgentResultArtifact] {
        let currentSessionID = sessionID ?? pane.piSemantic?.sessionID
        return artifacts.filter { artifact in
            guard artifact.machineID == pane.machineID else { return false }
            // A pane may be reused, and a HUD run may later be promoted into a
            // pane. The Pi session identity is more precise than the container.
            if let currentSessionID, let artifactSessionID = artifact.sessionID {
                return currentSessionID == artifactSessionID
            }
            return artifact.originType == .pane && artifact.originID == pane.paneID
        }.sorted(by: chronologicalOrder)
    }

    static func chronologicalOrder(_ lhs: AgentResultArtifact, _ rhs: AgentResultArtifact) -> Bool {
        let lhsDate = lhs.createdDate ?? .distantPast
        let rhsDate = rhs.createdDate ?? .distantPast
        return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate < rhsDate
    }
}
