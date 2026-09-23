import Foundation

enum FirstMateDemo {
    static let timestamp = "2026-01-15T14:30:00Z"
    static let stepTitles = ["Planning", "Implementation", "Seven reviewers", "Human checkpoint", "Direction change", "Successor handoff"]
    static let reviewRoles = ["Correctness", "Architecture", "Concurrency", "Security", "Test coverage", "Performance", "User experience"]

    static func features(step: Int) -> [FirstMateSnapshot] {
        let stageKeys = ["plan", "implement", "review", "revision", "proof"]
        let visitTitles = ["Planning", "Implementation", "Review", "Revised implementation", "Proof"]
        let currentIndex = [0, 1, 2, 2, 3, 4][step]
        let current = stageKeys[currentIndex]
        let statuses = ["awaiting_direction", "running", "running", "awaiting_direction", "awaiting_direction", "awaiting_direction"]
        var feature = FirstMateFeature(id: "demo-session-continuity", title: "Keep agent sessions connected", goal: "A feature keeps its agents, evidence, and decisions together, even when a session moves to a new process.", cwd: "/workspace/sample-app", status: statuses[step], currentVisitID: "demo-\(current)", revision: step + 1, createdAt: timestamp, updatedAt: timestamp, workItemID: "DEMO-104")
        let visits = stageKeys.enumerated().map { index, key in
            FirstMateVisit(id: "demo-\(key)", featureID: feature.id, stageKey: key == "revision" ? "implement" : key, title: visitTitles[index], status: index < currentIndex ? "completed" : index == currentIndex ? statuses[step] : "planned", revision: index < 3 ? 1 : 2, createdAt: timestamp, predecessorVisitID: index == 0 ? nil : "demo-\(stageKeys[index - 1])")
        }
        var assignments: [FirstMateAssignment] = [
            agent("planner", title: "Explore session continuity", role: "Planner", visit: "plan", feature: feature.id, status: "completed", verdict: "passed"),
            agent("architect", title: "Review the ownership boundary", role: "Architect", visit: "plan", feature: feature.id, status: "completed", verdict: "passed"),
        ]
        if step >= 1 { assignments.append(agent("builder", title: "Implement durable session links", role: "Implementation", visit: "implement", feature: feature.id, status: step == 1 ? "running" : "completed", verdict: step == 1 ? nil : "passed")) }
        if step >= 2 {
            assignments += reviewRoles.enumerated().map { index, role in
                agent("review-\(index)", title: "\(role) review", role: role, visit: "review", feature: feature.id, status: step == 2 && index > 3 ? "running" : "completed", verdict: step == 2 && index > 3 ? nil : "passed")
            }
        }
        if step >= 4 { assignments.append(agent("replan", title: "Revise the recovery boundary", role: "Architect", visit: "revision", feature: feature.id, status: "completed", verdict: "passed", revision: 2)) }
        if step == 5 { assignments.append(agent("successor", title: "Continue from verified checkpoint", role: "Successor", visit: "proof", feature: feature.id, status: "idle", verdict: "handoff_verified", revision: 2)) }
        for index in assignments.indices {
            assignments[index].usage = usage(cost: Double(index + 1) * 0.004, tokens: (index + 1) * 380)
            assignments[index].subtreeUsage = assignments[index].usage
        }
        let assignmentCost = assignments.indices.reduce(0.0) { $0 + Double($1 + 1) * 0.004 }
        let assignmentTokens = assignments.indices.reduce(0) { $0 + ($1 + 1) * 380 }
        feature.usage = usage(cost: assignmentCost + 0.008 + (step >= 2 ? 0.002 : 0) + (step == 5 ? 0.009 : 0),
                              tokens: assignmentTokens + 900 + (step >= 2 ? 180 : 0) + (step == 5 ? 860 : 0),
                              sessionCount: assignments.count + 1 + (step >= 2 ? 1 : 0) + (step == 5 ? 2 : 0))
        var documents = assignments.filter { $0.status == "completed" }.map { assignment in
            FirstMateDocument(id: "doc-\(assignment.id)", featureID: feature.id, visitID: assignment.visitID, assignmentID: assignment.id, nativeSessionID: assignment.nativeSessionID, title: "\(assignment.role) findings.md", mediaType: "text/markdown", contentHash: "demo-content-\(assignment.id)", createdAt: timestamp, content: "# \(assignment.title)\n\nSynthetic demonstration evidence.\n\nThe exact assignment, workflow visit, session, and input revision are retained together.\n\n## Findings\n\nOwnership is explicit. Reconnecting the view cannot complete a task or approve the next stage.\n\n## Verification\n\nThe focused checks pass for revision \(assignment.inputRevision).")
        }
        documents.append(.init(id: "demo-architecture-diagram", featureID: feature.id, visitID: "demo-plan", assignmentID: "demo-architect", nativeSessionID: "demo-session-architect", title: "Session ownership map.md", mediaType: "text/markdown", contentHash: "demo-ownership-map", createdAt: timestamp, content: "# Session ownership\n\nFeature → workflow visit → assignment → saved Pi session.\n\nDocuments retain the producing assignment and session. A terminal pane is a view of the session, never its identity."))
        let replies = [
            "I traced the session boundary with a planner and an architect. The proposal and ownership map are attached to Planning.\n\nThe next step is to implement durable links and exact-session lookup. Review the plan, then tell me how you want to proceed.",
            "Implementation is authorized. One agent is working on the session links in an isolated checkout. I am available here while the companion service tracks its progress.\n\nI will bring the result back for your direction before moving to review.",
            "The implementation passed its focused checks. With your approval, seven independent reviewers are checking the same input revision. Four have reported back; three are still working.\n\nOpen Agents on the Review step to inspect any individual session.",
            "All seven reviewers have reported. The review evidence is attached to the Review step.\n\nThe implementation is ready for a human checkpoint. I suggest testing a process handoff next. No next stage has started; I am waiting for your direction.",
            "I recorded your change: preserve the predecessor until the successor proves it can resume. The plan is now revision 2. A revised implementation visit retains the earlier review and documents.\n\nThe affected work is paused. I suggest a focused handoff verification before continuing.",
            "The successor loaded the saved checkpoint and verified the assignment, session, and input revision. The predecessor is retired only after that verification.\n\nAll evidence remains in the feature journal. Branch and worktree cleanup remains a separate decision. Tell me what you want to do next.",
        ]
        let userMessages = ["Help me make session continuity reliable. Start by planning it with an architecture review.", "The plan looks good. Implement it.", "Run the independent reviews.", "Show me the evidence before we proceed.", "Change the plan: keep the predecessor until the successor is verified.", "Verify the successor handoff now."]
        let messages = (0...step).flatMap { index in
            [FirstMateMessage(id: "demo-user-\(index)", featureID: feature.id, role: "user", text: userMessages[index], status: "delivered", createdAt: timestamp),
             FirstMateMessage(id: "demo-mate-\(index)", featureID: feature.id, role: "assistant", text: replies[index], status: "delivered", createdAt: timestamp)]
        }
        let events = (0...step).map { index in
            FirstMateEvent(sequence: index + 1, id: "demo-event-\(index)", featureID: feature.id, type: "demo.\(index == 5 ? "handoff_verified" : index == 3 ? "awaiting_direction" : "visit_updated")", summary: stepTitles[index] + (index == step ? " is the current focus" : " evidence retained"), createdAt: timestamp)
        }
        let second = newFeature(title: "Make review evidence searchable", goal: "Find the document, producing agent, and workflow visit from one search.", cwd: "/workspace/sample-app", id: "demo-search")
        var sessions = assignments.compactMap { assignment -> FirstMateSession? in
            guard let id = assignment.nativeSessionID else { return nil }
            return FirstMateSession(nativeSessionID: id, featureID: feature.id, assignmentID: assignment.id, title: assignment.title, role: assignment.role, status: assignment.status, generation: assignment.generation, attempt: assignment.attempt, inputRevision: assignment.inputRevision, createdAt: timestamp, updatedAt: timestamp, ownershipStatus: assignment.status == "running" ? "active" : "retained", kind: "worker", usage: assignment.usage)
        }
        sessions.append(.init(nativeSessionID: "demo-coordinator-1", featureID: feature.id, assignmentID: nil, title: "First Mate", role: "first_mate", status: "retained", generation: 1, createdAt: timestamp, updatedAt: timestamp, ownershipStatus: step == 5 ? "retained" : "active", kind: "coordinator", usage: usage(cost: 0.008, tokens: 900)))
        if step >= 2 {
            sessions.append(.init(nativeSessionID: "demo-advisor-1", featureID: feature.id, assignmentID: nil, title: "Recovery advisor", role: "recovery_advisor", status: "retained", generation: 1, createdAt: timestamp, updatedAt: timestamp, ownershipStatus: "retained", kind: "advisor", parentSessionID: "demo-coordinator-1", usage: usage(cost: 0.002, tokens: 180)))
        }
        if step == 5 {
            sessions.append(.init(nativeSessionID: "demo-coordinator-2", featureID: feature.id, assignmentID: nil, title: "First Mate", role: "first_mate", status: "active", generation: 2, createdAt: timestamp, updatedAt: timestamp, ownershipStatus: "active", kind: "coordinator", usage: usage(cost: 0.006, tokens: 620)))
            if let index = assignments.firstIndex(where: { $0.id == "demo-successor" }) {
                assignments[index].generation = 2
                assignments[index].attempt = 2
                if let sessionIndex = sessions.firstIndex(where: { $0.assignmentID == "demo-successor" }) {
                    sessions[sessionIndex].generation = 2
                    sessions[sessionIndex].attempt = 2
                }
                let predecessorUsage = usage(cost: 0.003, tokens: 240)
                sessions.append(.init(nativeSessionID: "demo-session-predecessor", featureID: feature.id, assignmentID: "demo-successor", title: "Continue from verified checkpoint", role: "Successor", status: "quiesced", generation: 1, attempt: 1, inputRevision: 2, createdAt: timestamp, updatedAt: timestamp, ownershipStatus: "quiesced", kind: "worker", usage: predecessorUsage))
                if let currentUsage = assignments[index].usage {
                    let assignmentUsage = usage(
                        cost: (currentUsage.costUSD ?? 0) + (predecessorUsage.costUSD ?? 0),
                        tokens: currentUsage.totalTokens + predecessorUsage.totalTokens,
                        sessionCount: 2
                    )
                    assignments[index].usage = assignmentUsage
                    assignments[index].subtreeUsage = assignmentUsage
                }
            }
        }
        return [FirstMateSnapshot(feature: feature, visits: visits, assignments: assignments, documents: documents, messages: messages, events: events, sessions: sessions), second]
    }

    static func newFeature(title: String, goal: String, cwd: String, id: String = UUID().uuidString) -> FirstMateSnapshot {
        var feature = FirstMateFeature(id: id, title: title, goal: goal, cwd: cwd, status: "ready", currentVisitID: nil,
                                       revision: 1, createdAt: timestamp, updatedAt: timestamp)
        feature.usage = FirstMateUsage(
            currency: "USD", costUSD: 0, status: "complete", inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 0, usageRecords: 0,
            missingCostRecords: 0, sessionCount: 0, knownCostSessions: 0, models: [], updatedAt: timestamp
        )
        return .init(feature: feature, messages: [
            .init(id: "\(id)-welcome", featureID: id, role: "assistant", text: "What outcome would you like to work toward? Tell me your constraints and I will help shape a plan.", status: "delivered", createdAt: timestamp)
        ])
    }

    static func sessionMessages(for resource: FirstMateResource) -> [FirstMateSessionMessage]? {
        switch resource {
        case .document:
            return nil
        case .session(let agent):
            return [
                .init(role: "user", text: "Review \(agent.title) within revision \(agent.inputRevision). Report evidence and a verdict."),
                .init(role: "assistant", text: "I am examining session ownership and recovery for \(agent.visitID). This is an independently saved Pi session.\n\n## Outcome\n\(agent.verdict ?? "Work is still in progress. No verdict has been reported.")\n\nSynthetic demo. No model or repository changes were executed.")
            ]
        case .history(let session):
            return [
                .init(role: "user", text: "Inspect \(session.title), generation \(session.generation)."),
                .init(role: "assistant", text: "This \(session.ownershipStatus) conversation remains accessible even without a document.\n\nSynthetic demo. No model or repository changes were executed.")
            ]
        }
    }

    static func content(for resource: FirstMateResource, snapshot: FirstMateSnapshot?) -> String {
        switch resource {
        case .document(let document): document.content ?? "Synthetic document preview."
        case .history(let session):
            "Saved session\n\(session.nativeSessionID)\n\n\(session.title)\nGeneration \(session.generation), \(session.ownershipStatus).\n\nThis retained conversation remains accessible independently of whether it produced a document.\n\nSynthetic demo. No model or repository changes were executed."
        case .session(let agent):
            "You\n\(agent.title). Work within revision \(agent.inputRevision). Report evidence and a verdict.\n\n\(agent.role)\nI am examining the explicit session ownership and recovery behavior. This is an independently saved Pi session.\n\nVerification\nThe assignment belongs to \(agent.visitID). Results are attached to this visit and retain their source session.\n\nOutcome\n\(agent.verdict ?? "Work is still in progress. No verdict has been reported.")\n\nSynthetic demo. No model or repository changes were executed."
        }
    }

    private static func usage(cost: Double, tokens: Int, sessionCount: Int = 1) -> FirstMateUsage {
        FirstMateUsage(
            currency: "USD", costUSD: cost, status: "complete", inputTokens: tokens * 3 / 4,
            outputTokens: tokens / 4, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: tokens,
            usageRecords: sessionCount, missingCostRecords: 0, sessionCount: sessionCount,
            knownCostSessions: sessionCount,
            models: [.init(provider: "synthetic", model: "sample-reasoner", costUSD: cost, status: "complete",
                           inputTokens: tokens * 3 / 4, outputTokens: tokens / 4, cacheReadTokens: 0,
                           cacheWriteTokens: 0, totalTokens: tokens, usageRecords: sessionCount, missingCostRecords: 0)],
            updatedAt: timestamp
        )
    }

    private static func agent(_ id: String, title: String, role: String, visit: String, feature: String, status: String, verdict: String?, revision: Int = 1) -> FirstMateAssignment {
        .init(id: "demo-\(id)", featureID: feature, visitID: "demo-\(visit)", title: title, role: role, status: status, verdict: verdict, nativeSessionID: "demo-session-\(id)", attempt: 1, generation: 1, inputRevision: revision, updatedAt: timestamp)
    }
}
