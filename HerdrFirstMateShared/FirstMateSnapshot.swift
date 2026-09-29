import Foundation

struct FirstMateSnapshot: Codable, Equatable, Sendable {
    var ok: Bool
    var feature: FirstMateFeature
    var visits: [FirstMateVisit]
    var assignments: [FirstMateAssignment]
    var documents: [FirstMateDocument]
    var handoffs: [FirstMateHandoff]
    var messages: [FirstMateMessage]
    var events: [FirstMateEvent]
    var hasDetails: Bool
    var sessions: [FirstMateSession]
    var sessionsTruncated: Bool
    var links: [FirstMateLink]
    /// The single message a send receipt accepted, when the companion's
    /// response names it. Older companions omit it and full snapshots carry
    /// their conversation in ``messages``. It never changes ``hasDetails``.
    var message: FirstMateMessage? = nil
    /// Distinguishes a server that omits `links` from one that explicitly
    /// reports an empty collection. The key is never encoded.
    var includesLinks = true
    var runtimeHealth: FirstMateRuntimeHealth? = nil
    /// The feature's newest event sequence across every event type. Companions
    /// that can omit telemetry from `events` report it so ordering checks never
    /// mistake a journal-only snapshot for an older one.
    var eventCursor: Int? = nil

    /// The newest event sequence this snapshot reflects.
    var latestEventSequence: Int { eventCursor ?? events.map(\.sequence).max() ?? 0 }

    init(feature: FirstMateFeature, visits: [FirstMateVisit] = [], assignments: [FirstMateAssignment] = [],
         documents: [FirstMateDocument] = [], handoffs: [FirstMateHandoff] = [], messages: [FirstMateMessage] = [], events: [FirstMateEvent] = [], sessions: [FirstMateSession] = [], sessionsTruncated: Bool = false, links: [FirstMateLink] = []) {
        ok = true
        self.feature = feature
        self.visits = visits
        self.assignments = assignments
        self.documents = documents
        self.handoffs = handoffs
        self.messages = messages
        self.events = events
        hasDetails = true
        self.sessions = sessions
        self.sessionsTruncated = sessionsTruncated
        self.links = links
    }

    enum CodingKeys: String, CodingKey {
        case ok, feature, visits, assignments, documents, handoffs, messages, message, events, sessions, links
        case sessionsTruncated = "sessions_truncated"
        case runtimeHealth = "runtime_health"
        case eventCursor = "event_cursor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        feature = try c.decode(FirstMateFeature.self, forKey: .feature)
        visits = try c.decodeIfPresent([FirstMateVisit].self, forKey: .visits) ?? []
        assignments = try c.decodeIfPresent([FirstMateAssignment].self, forKey: .assignments) ?? []
        documents = try c.decodeIfPresent([FirstMateDocument].self, forKey: .documents) ?? []
        handoffs = try c.decodeIfPresent([FirstMateHandoff].self, forKey: .handoffs) ?? []
        messages = try c.decodeIfPresent([FirstMateMessage].self, forKey: .messages) ?? []
        message = try? c.decodeIfPresent(FirstMateMessage.self, forKey: .message)
        events = try c.decodeIfPresent([FirstMateEvent].self, forKey: .events) ?? []
        hasDetails = c.contains(.visits) && c.contains(.messages) && c.contains(.events)
        sessions = try c.decodeIfPresent([FirstMateSession].self, forKey: .sessions) ?? []
        sessionsTruncated = try c.decodeIfPresent(Bool.self, forKey: .sessionsTruncated) ?? false
        links = try c.decodeIfPresent([FirstMateLink].self, forKey: .links) ?? []
        includesLinks = c.contains(.links)
        runtimeHealth = try c.decodeIfPresent(FirstMateRuntimeHealth.self, forKey: .runtimeHealth)
        eventCursor = try c.decodeIfPresent(Int.self, forKey: .eventCursor)
    }

    var recoveryNeedsDirection: Bool {
        feature.status == "recovering" || assignments.contains { $0.status == "recovering" }
    }

    var currentVisit: FirstMateVisit? { visits.first { $0.id == feature.currentVisitID } }
    var conversationEntries: [FirstMateConversationEntry] { FirstMateConversationEntry.make(messages: messages) }

    /// Only the current visit's explicit checkpoint is a pending decision.
    /// An old question in the transcript never manufactures a new checkpoint.
    var pendingDecisionMessageID: String? {
        guard feature.status == "awaiting_direction", let visitID = feature.currentVisitID else { return nil }
        return messages.last {
            $0.featureID == feature.id && $0.isConversation && $0.role == "assistant"
                && $0.assignmentID == nil
                && $0.metadata?.checkpoint == true && $0.metadata?.visitID == visitID
        }?.id
    }
    var visibleLinks: [FirstMateLink] { FirstMateLinkOrdering.sorted(links.filter { !$0.hidden }) }
    var pullRequestLinks: [FirstMateLink] { FirstMateLinkOrdering.visiblePullRequests(links) }
    var otherLinks: [FirstMateLink] { FirstMateLinkOrdering.visibleOtherLinks(links) }
    var hiddenLinks: [FirstMateLink] { FirstMateLinkOrdering.hidden(links) }
    func link(_ id: String) -> FirstMateLink? { links.first { $0.id == id } }
    func agents(for visitID: String) -> [FirstMateAssignment] {
        assignments.filter { $0.featureID == feature.id && ($0.visitID == visitID || $0.visitIDs?.contains(visitID) == true) }
    }
    /// Documents shown in user-facing document collections. Raw `documents`
    /// remain intact for handoff context, recovery, and direct tracking access.
    var presentedDocuments: [FirstMateDocument] {
        FirstMateDocumentVisibility.presentedDocuments(documents, handoffs: handoffs)
    }
    func documents(for visitID: String) -> [FirstMateDocument] {
        let memberIDs = Set(agents(for: visitID).map(\.id))
        return documents.filter {
            $0.featureID == feature.id && ($0.visitID == visitID || $0.assignmentID.map(memberIDs.contains) == true)
        }
    }
    func presentedDocuments(for visitID: String) -> [FirstMateDocument] {
        FirstMateDocumentVisibility.presentedDocuments(documents(for: visitID), handoffs: handoffs)
    }
    func sessions(for assignmentID: String?) -> [FirstMateSession] {
        sessions.filter { $0.featureID == feature.id && $0.assignmentID == assignmentID }
            .sorted { $0.generation == $1.generation ? $0.createdAt < $1.createdAt : $0.generation < $1.generation }
    }
    var coordinatorSessions: [FirstMateSession] {
        sessions.filter {
            $0.featureID == feature.id && ($0.kind == "coordinator" || ($0.kind == nil && $0.role == "first_mate"))
        }
        .sorted { $0.generation == $1.generation ? $0.createdAt < $1.createdAt : $0.generation < $1.generation }
    }
    var advisorSessions: [FirstMateSession] {
        sessions.filter { $0.featureID == feature.id && $0.kind == "advisor" }
            .sorted { $0.generation == $1.generation ? $0.createdAt < $1.createdAt : $0.generation < $1.generation }
    }
    func author(of document: FirstMateDocument) -> FirstMateAssignment? {
        guard document.featureID == feature.id,
              var author = assignments.first(where: { $0.id == document.assignmentID && $0.featureID == document.featureID && $0.visitID == document.visitID }) else { return nil }
        // An assignment may now be on a successor. Evidence still opens its producer.
        author.nativeSessionID = document.nativeSessionID
        author.generation = document.generation ?? author.generation
        author.inputRevision = document.inputRevision ?? author.inputRevision
        return author
    }
}
