import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate current and upcoming activity")
struct FirstMateActivityTests {
    @Test("Completed historical agents cannot hide a live crew beyond the first three")
    func liveCrew() {
        var snapshot = FirstMateDemo.features(step: 3)[0]
        var base = snapshot.assignments[0]
        base.status = "completed"
        snapshot.assignments = (0..<3).map { index in
            var agent = base; agent.id = "completed-\(index)"; return agent
        }
        let active = ["running", "dispatching", "waiting_children", "handoff_pending", "awaiting_ack", "recovering"]
        snapshot.assignments += active.enumerated().map { index, status in
            var agent = base
            agent.id = "active-\(index)"; agent.status = status
            // Retained workers can belong to a later visit through membership.
            agent.visitID = "earlier-visit"
            agent.visitIDs = [snapshot.feature.currentVisitID!]
            return agent
        }
        var queued = base; queued.id = "queued"; queued.status = "queued"
        queued.visitID = snapshot.feature.currentVisitID!
        snapshot.assignments.append(queued)
        var foreign = queued; foreign.id = "foreign"; foreign.featureID = "another-feature"
        snapshot.assignments.append(foreign)
        let activity = FirstMateActivity(snapshot: snapshot)
        #expect(Set(activity.activeAssignments.map(\.status)) == Set(active))
        #expect(activity.queuedAssignments.map(\.id) == ["queued"])
        let summary = FirstMateDashboardSummary.from(snapshot)
        #expect(summary.runningAssignmentCount == active.count)
        #expect(summary.queuedAssignmentCount == 1)
    }

    @Test("Pending directions are independent of the conversation page and keep dispatch ordering")
    func pendingDirections() throws {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.messages = []
        func message(_ id: String, role: String, status: String) -> FirstMateMessage {
            .init(id: id, featureID: snapshot.feature.id, role: role, text: "Synthetic \(id)", status: status, createdAt: "2030-01-01T00:00:00Z")
        }
        snapshot.pendingMessages = [message("background", role: "system", status: "queued"),
                                    message("direction", role: "user", status: "queued"),
                                    message("active", role: "user", status: "processing")]
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: JSONEncoder().encode(snapshot))
        let activity = FirstMateActivity(snapshot: decoded)
        #expect(activity.processingMessages.map(\.id) == ["active"])
        #expect(activity.queuedMessages.map(\.id) == ["direction", "background"])
        #expect(decoded.messages.isEmpty)
        snapshot.messages = snapshot.pendingMessages!
        snapshot.pendingMessages = []
        #expect(FirstMateActivity(snapshot: snapshot).queuedMessages.isEmpty)
        snapshot.pendingMessages = nil
        #expect(FirstMateActivity(snapshot: snapshot).queuedMessages.count == 2)
    }

    @Test("Only current authorized next stages appear, not a superseded plan")
    func nextStages() throws {
        var snapshot = FirstMateDemo.features(step: 1)[0]
        let current = try #require(snapshot.visits.firstIndex { $0.id == snapshot.feature.currentVisitID })
        snapshot.visits[current].revision = snapshot.feature.revision
        snapshot.visits[current].followupStages = ["review", "verify"]
        snapshot.visits[0].followupStages = ["old_plan"]
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(FirstMateActivity(snapshot: decoded).followupStages == ["review", "verify"])
        snapshot.visits[current].revision -= 1
        #expect(FirstMateActivity(snapshot: snapshot).followupStages.isEmpty)
    }

    @Test("Telemetry alone does not invalidate current-work presentation")
    func telemetry() {
        let original = FirstMateDemo.features(step: 1)[0]
        var telemetry = original
        telemetry.eventCursor = original.latestEventSequence + 100
        telemetry.feature.updatedAt = "2030-01-01T12:00:00Z"
        telemetry.assignments[0].updatedAt = "2030-01-01T12:00:00Z"
        #expect(FirstMateActivity.sameWork(original, telemetry))
        telemetry.assignments[0].status = "running"
        #expect(!FirstMateActivity.sameWork(original, telemetry))
    }
    @Test("A new plan title or workflow status changes the current-work presentation")
    func changedPlan() throws {
        let snapshot = FirstMateDemo.features(step: 1)[0]
        let current = try #require(snapshot.visits.firstIndex { $0.id == snapshot.feature.currentVisitID })
        var changed = snapshot
        changed.visits[current].title = "New synthetic implementation plan"
        #expect(!FirstMateActivity.sameWork(snapshot, changed))
        changed = snapshot
        changed.visits[current].status = "completed"
        #expect(!FirstMateActivity.sameWork(snapshot, changed))
    }

}
