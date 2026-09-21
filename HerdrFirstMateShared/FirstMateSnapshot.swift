import Foundation

struct FirstMateSnapshot: Codable, Equatable, Sendable {
    var ok: Bool
    var feature: FirstMateFeature
    var visits: [FirstMateVisit]
    var assignments: [FirstMateAssignment]
    var documents: [FirstMateDocument]
    var messages: [FirstMateMessage]
    var events: [FirstMateEvent]
    var hasDetails: Bool
    var sessions: [FirstMateSession]
    var sessionsTruncated: Bool

    init(feature: FirstMateFeature, visits: [FirstMateVisit] = [], assignments: [FirstMateAssignment] = [],
         documents: [FirstMateDocument] = [], messages: [FirstMateMessage] = [], events: [FirstMateEvent] = [], sessions: [FirstMateSession] = [], sessionsTruncated: Bool = false) {
        ok = true
        self.feature = feature
        self.visits = visits
        self.assignments = assignments
        self.documents = documents
        self.messages = messages
        self.events = events
        hasDetails = true
        self.sessions = sessions
        self.sessionsTruncated = sessionsTruncated
    }

    enum CodingKeys: String, CodingKey {
        case ok, feature, visits, assignments, documents, messages, events, sessions
        case sessionsTruncated = "sessions_truncated"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        feature = try c.decode(FirstMateFeature.self, forKey: .feature)
        visits = try c.decodeIfPresent([FirstMateVisit].self, forKey: .visits) ?? []
        assignments = try c.decodeIfPresent([FirstMateAssignment].self, forKey: .assignments) ?? []
        documents = try c.decodeIfPresent([FirstMateDocument].self, forKey: .documents) ?? []
        messages = try c.decodeIfPresent([FirstMateMessage].self, forKey: .messages) ?? []
        events = try c.decodeIfPresent([FirstMateEvent].self, forKey: .events) ?? []
        hasDetails = c.contains(.visits) && c.contains(.messages) && c.contains(.events)
        sessions = try c.decodeIfPresent([FirstMateSession].self, forKey: .sessions) ?? []
        sessionsTruncated = try c.decodeIfPresent(Bool.self, forKey: .sessionsTruncated) ?? false
    }

    var currentVisit: FirstMateVisit? { visits.first { $0.id == feature.currentVisitID } }
    func agents(for visitID: String) -> [FirstMateAssignment] {
        assignments.filter { $0.featureID == feature.id && ($0.visitID == visitID || $0.visitIDs?.contains(visitID) == true) }
    }
    func documents(for visitID: String) -> [FirstMateDocument] {
        let memberIDs = Set(agents(for: visitID).map(\.id))
        return documents.filter {
            $0.featureID == feature.id && ($0.visitID == visitID || $0.assignmentID.map(memberIDs.contains) == true)
        }
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
