import Foundation

/// Optional, bounded list metadata. Older companions can omit the summary.
struct FirstMateDashboardSummary: Codable, Equatable, Sendable {
    var currentStageTitle: String?
    var currentStageIndex: Int?
    var stageCount: Int
    var stageCountIsEstimate: Bool? = nil
    var latestMessage: String?
    var latestMessageAt: String?
    var needsUser: Bool
    var needsUserPrompt: String?
    var assignmentCount: Int
    var runningAssignmentCount: Int
    /// Newest conversation or journal activity. Unlike the feature's
    /// `updated_at`, Pi telemetry does not move it (companion ≥ 0.45).
    var activityAt: String? = nil
    /// First Mate finished its turn and is parked until a person replies,
    /// while the feature status still reads as working (companion ≥ 0.45).
    var awaitingTurn: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case currentStageTitle = "current_stage_title", currentStageIndex = "current_stage_index"
        case stageCount = "stage_count", stageCountIsEstimate = "stage_count_is_estimate"
        case latestMessage = "latest_message", latestMessageAt = "latest_message_at"
        case needsUser = "needs_user", needsUserPrompt = "needs_user_prompt"
        case assignmentCount = "assignment_count", runningAssignmentCount = "running_assignment_count"
        case activityAt = "activity_at"
        case awaitingTurn = "awaiting_turn"
    }

    static func from(_ snapshot: FirstMateSnapshot) -> Self {
        let visits = snapshot.visits.filter { $0.revision == snapshot.feature.revision }
        let stages = visits.isEmpty ? snapshot.visits : visits
        let latest = snapshot.messages.last { $0.role == "assistant" }
        let needsUser = ["awaiting_direction", "blocked"].contains(snapshot.feature.status)
        return Self(
            currentStageTitle: snapshot.currentVisit?.title,
            currentStageIndex: stages.firstIndex { $0.id == snapshot.feature.currentVisitID }.map { $0 + 1 },
            stageCount: stages.count, stageCountIsEstimate: true,
            latestMessage: latest?.text, latestMessageAt: latest?.createdAt,
            needsUser: needsUser, needsUserPrompt: needsUser ? latest?.text : nil,
            assignmentCount: snapshot.assignments.count,
            runningAssignmentCount: snapshot.assignments.filter { ["running", "starting", "recovering"].contains($0.status) }.count
        )
    }
}
