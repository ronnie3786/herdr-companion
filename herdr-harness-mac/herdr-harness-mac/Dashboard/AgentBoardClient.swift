import Foundation

/// The Agent view's connection to one feature's owning companion. Mac-only, so
/// the shared First Mate client contract (and the iOS app) stays unchanged.
protocol AgentBoardClient: Sendable {
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities
    func fetchFirstMateBoard(featureID: String, messageLimit: Int, journalLimit: Int, ifVersion: String?) async throws -> AgentBoardFetch
    func fetchFirstMateFeature(_ id: String, journalEventsOnly: Bool) async throws -> FirstMateSnapshot
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot
}

extension HerdrAPIClient: AgentBoardClient {}

extension FirstMateCapabilities {
    var supportsBoard: Bool { ok && capabilities.contains("first-mate-board-v1") }
    var supportsJournalEvents: Bool { ok && capabilities.contains("first-mate-journal-events-v1") }
}

enum AgentBoardFetch: Sendable, Equatable {
    case unchanged(version: String)
    case board(AgentBoardPayload)
}

/// A bounded projection of one feature: recent conversation, operational
/// journal (never Pi telemetry), stages, agents, and their latest sessions.
struct AgentBoardPayload: Decodable, Equatable, Sendable {
    static let messageLimit = 60
    static let journalLimit = 40

    var version: String
    var feature: FirstMateFeature
    var visits: [FirstMateVisit]
    var assignments: [FirstMateAssignment]
    var messages: [FirstMateMessage]
    var messagesTotal: Int
    var journal: [FirstMateEvent]
    var journalTotal: Int
    var sessions: [FirstMateSession]
    var sessionsTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case version, feature, visits, assignments, messages, journal, sessions
        case messagesTotal = "messages_total", journalTotal = "journal_total"
        case sessionsTruncated = "sessions_truncated"
    }

    init(version: String, feature: FirstMateFeature, visits: [FirstMateVisit] = [], assignments: [FirstMateAssignment] = [],
         messages: [FirstMateMessage] = [], messagesTotal: Int? = nil, journal: [FirstMateEvent] = [], journalTotal: Int? = nil,
         sessions: [FirstMateSession] = [], sessionsTruncated: Bool = false) {
        self.version = version
        self.feature = feature
        self.visits = visits
        self.assignments = assignments
        self.messages = messages
        self.messagesTotal = messagesTotal ?? messages.count
        self.journal = journal
        self.journalTotal = journalTotal ?? journal.count
        self.sessions = sessions
        self.sessionsTruncated = sessionsTruncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        feature = try c.decode(FirstMateFeature.self, forKey: .feature)
        visits = try c.decodeIfPresent([FirstMateVisit].self, forKey: .visits) ?? []
        assignments = try c.decodeIfPresent([FirstMateAssignment].self, forKey: .assignments) ?? []
        messages = try c.decodeIfPresent([FirstMateMessage].self, forKey: .messages) ?? []
        messagesTotal = try c.decodeIfPresent(Int.self, forKey: .messagesTotal) ?? messages.count
        journal = try c.decodeIfPresent([FirstMateEvent].self, forKey: .journal) ?? []
        journalTotal = try c.decodeIfPresent(Int.self, forKey: .journalTotal) ?? journal.count
        sessions = try c.decodeIfPresent([FirstMateSession].self, forKey: .sessions) ?? []
        sessionsTruncated = try c.decodeIfPresent(Bool.self, forKey: .sessionsTruncated) ?? false
    }

    /// Pi telemetry (message ends, tool calls, context usage) is recorded
    /// thousands of times per feature and is never shown on the board.
    static func isJournal(_ event: FirstMateEvent) -> Bool { !event.type.hasPrefix("pi.") }

    /// Adapts an older companion's full snapshot. Callers run this off the main
    /// actor: a long-running feature's snapshot holds tens of thousands of events.
    static func adapting(_ snapshot: FirstMateSnapshot, messageLimit: Int = messageLimit, journalLimit: Int = journalLimit) -> Self {
        let conversation = snapshot.messages.filter { ["user", "human", "assistant"].contains($0.role) }
        let journal = snapshot.events.filter { isJournal($0) && $0.featureID == snapshot.feature.id }
        let version = [
            String(snapshot.feature.revision), snapshot.feature.updatedAt, snapshot.feature.status,
            String(journal.last?.sequence ?? 0), String(snapshot.messages.count),
            snapshot.messages.map(\.status).joined(separator: ","),
            snapshot.assignments.map { "\($0.id):\($0.status):\($0.updatedAt)" }.joined(separator: ","),
            snapshot.visits.map { "\($0.id):\($0.status)" }.joined(separator: ","),
            String(snapshot.sessions.count),
        ].joined(separator: "|")
        return Self(
            version: "adapted-\(version.hashValue)",
            feature: snapshot.feature,
            visits: snapshot.visits,
            assignments: snapshot.assignments,
            messages: Array(conversation.suffix(messageLimit)),
            messagesTotal: conversation.count,
            journal: Array(journal.suffix(journalLimit)),
            journalTotal: journal.count,
            sessions: snapshot.sessions,
            sessionsTruncated: snapshot.sessionsTruncated
        )
    }
}

/// The wire envelope: `unchanged` responses carry only the version.
struct AgentBoardResponse: Decodable, Sendable {
    let ok: Bool
    let version: String
    let board: AgentBoardPayload?

    private enum CodingKeys: String, CodingKey { case ok, version, unchanged }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        version = try c.decode(String.self, forKey: .version)
        let unchanged = try c.decodeIfPresent(Bool.self, forKey: .unchanged) ?? false
        board = unchanged ? nil : try AgentBoardPayload(from: decoder)
    }
}
