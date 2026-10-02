import Foundation

/// A current-work projection, independent of historical visit ordering.
/// The ledger is authoritative; prose in a conversation is not a work queue.
struct FirstMateActivity: Equatable, Sendable {
    var activeAssignments: [FirstMateAssignment]
    var queuedAssignments: [FirstMateAssignment]
    var processingMessages: [FirstMateMessage]
    var queuedMessages: [FirstMateMessage]
    var followupStages: [String]

    init(snapshot: FirstMateSnapshot) {
        let assignments = snapshot.assignments.filter { $0.featureID == snapshot.feature.id }
        activeAssignments = assignments.filter { Self.activeAssignmentStatuses.contains($0.status) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        // Preserve the companion's stable creation order for waiting workers.
        queuedAssignments = assignments.filter { $0.status == "queued" }
        let messages = (snapshot.pendingMessages ?? snapshot.messages).filter { $0.featureID == snapshot.feature.id }
        processingMessages = messages.filter { $0.status == "processing" }
        // Human direction is dispatched before routine system updates.
        queuedMessages = messages.filter { $0.status == "queued" }.sorted {
            let left = ["user", "human"].contains($0.role)
            let right = ["user", "human"].contains($1.role)
            if left != right { return left }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        if let visit = snapshot.currentVisit, visit.revision == snapshot.feature.revision,
           !["cancelled", "superseded"].contains(visit.status),
           !["cancelled", "completed"].contains(snapshot.feature.status) {
            followupStages = visit.followupStages ?? []
        } else {
            followupStages = []
        }
    }

    /// Only compare fields the activity panel presents. Usage and token
    /// telemetry must not restart independent inspector requests.
    static func sameWork(_ lhs: FirstMateSnapshot, _ rhs: FirstMateSnapshot) -> Bool {
        guard lhs.feature.status == rhs.feature.status,
              lhs.feature.revision == rhs.feature.revision,
              lhs.feature.currentVisitID == rhs.feature.currentVisitID,
              lhs.currentVisit?.title == rhs.currentVisit?.title,
              lhs.currentVisit?.status == rhs.currentVisit?.status,
              lhs.currentVisit?.stageKey == rhs.currentVisit?.stageKey,
              lhs.currentVisit?.revision == rhs.currentVisit?.revision,
              lhs.hasQueuedWork == rhs.hasQueuedWork else { return false }
        let left = Self(snapshot: lhs), right = Self(snapshot: rhs)
        func sameAssignments(_ lhs: [FirstMateAssignment], _ rhs: [FirstMateAssignment]) -> Bool {
            let lhs = lhs.sorted { $0.id < $1.id }, rhs = rhs.sorted { $0.id < $1.id }
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                $0.id == $1.id && $0.title == $1.title && $0.status == $1.status
                    && $0.nativeSessionID == $1.nativeSessionID && $0.generation == $1.generation
            }
        }
        return sameAssignments(left.activeAssignments, right.activeAssignments)
            && sameAssignments(left.queuedAssignments, right.queuedAssignments)
            && left.processingMessages == right.processingMessages
            && left.queuedMessages == right.queuedMessages
            && left.followupStages == right.followupStages
    }

    static let activeAssignmentStatuses: Set<String> = [
        "starting", "dispatching", "running", "waiting_children", "handoff_pending", "awaiting_ack", "recovering"
    ]

    var hasActiveWork: Bool { !activeAssignments.isEmpty || !processingMessages.isEmpty }
    var hasQueuedWork: Bool { !queuedAssignments.isEmpty || !queuedMessages.isEmpty }
}
