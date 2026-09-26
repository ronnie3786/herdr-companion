import Foundation

/// Everything one Agent view column renders, prepared off the main actor.
///
/// Views only read these values: no sorting, date parsing, or markdown work
/// happens in `body`. Equatable so a poll that changes nothing visible does
/// not publish.
struct AgentBoardContent: Equatable, Sendable {
    enum StatusKind: Equatable, Sendable { case running, waiting, failed, finished, other }

    struct MessageRow: Equatable, Sendable, Identifiable {
        let id: String
        let isHuman: Bool
        let isQueued: Bool
        let date: Date?
        let blocks: [AgentBoardProseBlock]
        let attachments: [AgentBoardMessageContent.Attachment]
        /// The message text the blocks were built from.
        let source: String

        /// Blocks and attachments derive from `source`, so comparing it is
        /// exact and costs a string compare instead of walking every styled run.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.isQueued == rhs.isQueued && lhs.date == rhs.date
                && lhs.isHuman == rhs.isHuman && lhs.source == rhs.source
        }
    }

    struct NoteRow: Equatable, Sendable, Identifiable {
        let id: String
        let text: String
        /// Consecutive journal notes collapse into one quiet line.
        let count: Int
        let date: Date?
    }

    struct AgentRow: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let roleLabel: String
        let statusTitle: String
        let statusKind: StatusKind
        let verdict: String?
        let date: Date?
        let assignment: FirstMateAssignment
        let latestSession: FirstMateSession?

        var canOpen: Bool { assignment.nativeSessionID != nil || latestSession != nil }
    }

    struct StageRow: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let statusLabel: String
        let isCurrent: Bool
        let isCompleted: Bool
        let isFailed: Bool
    }

    var featureID: String
    var revision: Int
    var title: String
    var workItemID: String?
    var status: String
    var awaitingTurn: Bool
    var goal: String
    var acceptsMessages: Bool
    var stageTitle: String?
    var stageIndex: Int?
    var attention: String?
    /// The conversation only. Journal milestones and First Mate's private
    /// background notes stay in Overview's journal (`latestNotes`).
    var timeline: [MessageRow]
    var earlierMessageCount: Int
    var agents: [AgentRow]
    var stages: [StageRow]
    var latestNotes: [NoteRow]
    var coordinatorSessions: [FirstMateSession]
    var assignmentCount: Int
    var runningCount: Int
    var sessionsTruncated: Bool

    var needsAttention: Bool { FirstMateAttention.needsHumanDecision(status: status) || awaitingTurn }
}

extension AgentBoardContent {
    /// Runs on a background executor: parsing a board costs milliseconds, but a
    /// fallback snapshot from an older companion can hold 20,000 events.
    @concurrent
    static func make(from payload: AgentBoardPayload) async -> AgentBoardContent {
        build(from: payload)
    }

    @concurrent
    static func make(adapting snapshot: FirstMateSnapshot) async -> (AgentBoardPayload, AgentBoardContent) {
        let payload = AgentBoardPayload.adapting(snapshot)
        return (payload, build(from: payload))
    }

    static func build(from payload: AgentBoardPayload) -> AgentBoardContent {
        let feature = payload.feature
        let summary = feature.dashboardSummary
        let currentVisit = payload.visits.first { $0.id == feature.currentVisitID }
        let revisionVisits = payload.visits.filter { $0.revision == feature.revision }
        let stageVisits = revisionVisits.isEmpty ? payload.visits : revisionVisits
        let stageIndex = summary?.currentStageIndex
            ?? stageVisits.firstIndex { $0.id == feature.currentVisitID }.map { $0 + 1 }

        let notes = payload.journal
            .filter { $0.featureID == feature.id && AgentBoardPayload.isJournal($0) }
            .compactMap(note)
        let agents = payload.assignments
            .filter { $0.featureID == feature.id }
            .map { agentRow($0, sessions: payload.sessions) }
            .sorted(by: agentOrder)
        let running = agents.filter { $0.statusKind == .running }.count

        return AgentBoardContent(
            featureID: feature.id,
            revision: feature.revision,
            title: displayTitle(feature.title, workItemID: feature.workItemID),
            workItemID: feature.workItemID,
            status: feature.status,
            awaitingTurn: summary?.awaitingTurn == true,
            goal: AgentBoardProse.plainText(fromMarkdown: feature.goal),
            acceptsMessages: !feature.isArchived && !["completed", "cancelled"].contains(feature.status),
            stageTitle: summary?.currentStageTitle ?? currentVisit?.title,
            stageIndex: stageIndex,
            attention: attentionText(feature: feature, messages: payload.messages),
            timeline: timeline(messages: payload.messages, featureID: feature.id),
            earlierMessageCount: max(0, payload.messagesTotal - payload.messages.count),
            agents: agents,
            stages: stageVisits.map { stageRow($0, currentID: feature.currentVisitID) },
            latestNotes: Array(collapse(notes).suffix(3).reversed()),
            coordinatorSessions: payload.sessions
                .filter { $0.featureID == feature.id && $0.assignmentID == nil }
                .sorted { $0.generation == $1.generation ? $0.createdAt > $1.createdAt : $0.generation > $1.generation },
            assignmentCount: summary?.assignmentCount ?? agents.count,
            runningCount: summary?.runningAssignmentCount ?? running,
            sessionsTruncated: payload.sessionsTruncated
        )
    }

    // MARK: - Timeline

    private static func timeline(messages: [FirstMateMessage], featureID: String) -> [MessageRow] {
        // Parse every timestamp exactly once. The server's order breaks ties,
        // so an answer can never sort above the question it replies to.
        let rows = messages.enumerated()
            .filter { $0.element.featureID == featureID && $0.element.isConversation }
            .map { (row: messageRow($0.element), order: $0.offset) }
        return rows.sorted { lhs, rhs in
            let left = lhs.row.date ?? .distantPast
            let right = rhs.row.date ?? .distantPast
            return left == right ? lhs.order < rhs.order : left < right
        }.map(\.row)
    }

    private static func messageRow(_ message: FirstMateMessage) -> MessageRow {
        let isHuman = message.role == "user" || message.role == "human"
        let content = AgentBoardMessageContent.parse(message.text)
        return MessageRow(
            id: message.id,
            isHuman: isHuman,
            isQueued: message.status == "queued",
            date: HerdrTimestamp.date(from: message.createdAt),
            blocks: isHuman ? AgentBoardProse.plain(content.text) : AgentBoardProse.blocks(from: message.text),
            attachments: isHuman ? content.attachments : [],
            source: message.text
        )
    }

    /// Only journal milestones (see `FirstMateEvent.isMilestone`).
    private static func note(_ event: FirstMateEvent) -> NoteRow? {
        let summary = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, event.isMilestone else { return nil }
        return NoteRow(id: event.id, text: AgentBoardProse.plainText(fromMarkdown: summary), count: 1,
                       date: HerdrTimestamp.date(from: event.createdAt))
    }

    private static func collapse(_ notes: [NoteRow]) -> [NoteRow] {
        var result: [NoteRow] = []
        for note in notes {
            if let last = result.last, last.text == note.text {
                result[result.count - 1] = NoteRow(id: last.id, text: note.text, count: last.count + note.count, date: note.date)
            } else {
                result.append(note)
            }
        }
        return result
    }

    // MARK: - Agents and stages

    private static func agentRow(_ agent: FirstMateAssignment, sessions: [FirstMateSession]) -> AgentRow {
        let kind = statusKind(agent.status)
        let latest = sessions
            .filter { $0.assignmentID == agent.id }
            .max { $0.generation == $1.generation ? $0.createdAt < $1.createdAt : $0.generation < $1.generation }
        let verdict = agent.verdict.map { AgentBoardProse.readable($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return AgentRow(
            id: agent.id,
            title: AgentBoardProse.decodeEntities(agent.title),
            roleLabel: AgentBoardProse.readable(agent.role),
            statusTitle: statusTitle(agent.status),
            statusKind: kind,
            verdict: verdict,
            date: HerdrTimestamp.date(from: agent.updatedAt),
            assignment: agent,
            latestSession: latest
        )
    }

    private static func agentOrder(_ lhs: AgentRow, _ rhs: AgentRow) -> Bool {
        func rank(_ kind: StatusKind) -> Int {
            switch kind {
            case .running: 0
            case .waiting: 1
            case .failed: 2
            case .other: 3
            case .finished: 4
            }
        }
        if rank(lhs.statusKind) != rank(rhs.statusKind) { return rank(lhs.statusKind) < rank(rhs.statusKind) }
        let left = lhs.date ?? .distantPast
        let right = rhs.date ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }

    static func statusKind(_ status: String) -> StatusKind {
        switch status {
        case "running", "starting", "recovering", "dispatching", "waiting_children", "handoff_pending", "awaiting_ack": .running
        case "pending", "queued", "waiting", "paused": .waiting
        case "failed", "interrupted", "cancelled": .failed
        case "completed", "done", "finished", "succeeded": .finished
        default: .other
        }
    }

    static func statusTitle(_ status: String) -> String {
        switch status {
        case "running", "starting", "dispatching": "Running"
        case "recovering": "Recovering"
        case "waiting_children": "Waiting on helpers"
        case "handoff_pending", "awaiting_ack": "Handing off"
        case "completed", "done", "finished", "succeeded": "Finished"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        case "cancelled": "Cancelled"
        case "pending", "queued", "waiting": "Queued"
        case "paused": "Paused"
        default: AgentBoardProse.readable(status).capitalized
        }
    }

    private static func stageRow(_ visit: FirstMateVisit, currentID: String?) -> StageRow {
        StageRow(
            id: visit.id,
            title: AgentBoardProse.decodeEntities(visit.title),
            statusLabel: visit.id == currentID ? "Current" : statusTitle(visit.status),
            isCurrent: visit.id == currentID,
            isCompleted: visit.status == "completed",
            isFailed: ["failed", "cancelled"].contains(visit.status)
        )
    }

    // MARK: - Header text

    /// Ticket-prefixed titles ("APP-12 — Offline notes") repeat the work item
    /// shown beside them.
    static func displayTitle(_ title: String, workItemID: String?) -> String {
        let decoded = AgentBoardProse.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workItemID, !workItemID.isEmpty, decoded.hasPrefix(workItemID) else { return decoded }
        let rest = decoded.dropFirst(workItemID.count)
            .drop { $0 == " " || $0 == "—" || $0 == "–" || $0 == "-" || $0 == ":" || $0 == "·" }
        return rest.isEmpty ? decoded : String(rest)
    }

    private static func attentionText(feature: FirstMateFeature, messages: [FirstMateMessage]) -> String? {
        guard FirstMateAttention.needsHumanDecision(status: feature.status) || feature.dashboardSummary?.awaitingTurn == true
        else { return nil }
        let prompt = feature.dashboardSummary?.needsUserPrompt
            ?? messages.last { $0.role == "assistant" && $0.isConversation }?.text
        let text = prompt.map { AgentBoardProse.plainText(fromMarkdown: $0) } ?? ""
        return text.isEmpty ? "Waiting for your direction." : text
    }
}
