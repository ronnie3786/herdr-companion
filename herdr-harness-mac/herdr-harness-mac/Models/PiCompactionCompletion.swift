import Foundation

/// Durable evidence that the current Pi session finished a context compaction.
///
/// This is deliberately separate from `PiCompactionActivity` (a compaction is
/// in progress) and from `PiConversationPhase` (the agent turn state): Pi can
/// finish a compaction while an overflowed turn resumes, and clearing the
/// spinner is not proof of success. Only an explicit `session_compact` event or
/// a persisted `compaction` snapshot entry creates evidence; terminal
/// `session_compact_end` outcomes, disconnects, and timeouts never do.
struct PiCompactionCompletion: Equatable, Sendable {
    /// How this success was proven. Entry identity survives repeated snapshots;
    /// the scoped event cursor covers truncated snapshots that omit the entry.
    enum Evidence: Equatable, Sendable {
        case entry(String)
        case eventCursor(String)
    }

    let evidence: Evidence
    var reason: PiCompactionReason
    /// Session this evidence belongs to. `nil` only when neither the event nor
    /// the projection ever reported one.
    let sessionID: String?
    let timestamp: Date?
    var isAcknowledged: Bool

    init(
        evidence: Evidence,
        reason: PiCompactionReason,
        sessionID: String?,
        timestamp: Date?,
        isAcknowledged: Bool = false
    ) {
        self.evidence = evidence
        self.reason = reason
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.isAcknowledged = isAcknowledged
    }

    /// A persisted `compaction` entry is the durable proof that opening an
    /// already-compacted session can reconstruct a completion fact from.
    init?(entry: PiJSONValue, sessionID: String?) {
        guard entry.string(for: "type") == "compaction",
              let id = entry.string(for: "id"),
              !id.isEmpty
        else { return nil }
        self.init(
            evidence: .entry(id),
            reason: PiCompactionReason(rawValue: entry.string(for: "reason") ?? "") ?? .unknown,
            sessionID: sessionID,
            timestamp: PiConversationTimestamp.date(from: entry.value(for: "timestamp"))
        )
    }

    /// Success evidence from a live `session_compact` envelope. Every other
    /// event type returns `nil`, so a terminal or ambiguous outcome can never
    /// create or restore a completion.
    init?(event envelope: PiConversationEnvelope, sessionID: String?) {
        let type = envelope.eventType
        let normalized = type.hasPrefix("pi.") ? String(type.dropFirst(3)) : type
        guard normalized == "session_compact" else { return nil }

        let entry = envelope.event["compactionEntry"] ?? envelope.event["compaction_entry"]
        if let id = entry?.string(for: "id"), !id.isEmpty {
            evidence = .entry(id)
        } else if let cursor = envelope.cursor, !cursor.isEmpty {
            evidence = .eventCursor(cursor)
        } else {
            // A committed stream always has a cursor; if a server ever omits
            // one, stay deduplicated within the session instead of inventing
            // one completion per frame.
            evidence = .eventCursor("session:\(sessionID ?? "unknown")")
        }
        reason = PiCompactionReason(
            rawValue: envelope.event.string(for: "reason") ?? ""
        ) ?? .unknown
        self.sessionID = sessionID
        let generatedAt = envelope.generatedAt.map { PiJSONValue.string($0) }
        timestamp = PiConversationTimestamp.date(from: entry?.value(for: "timestamp"))
            ?? PiConversationTimestamp.date(from: generatedAt)
        isAcknowledged = false
    }

    /// Copy shown beside the composer once success is confirmed.
    var statusMessage: String { "Context compacted" }

    /// Session scope check. Evidence captured before any projection has no
    /// identity to compare, so it is allowed through rather than dropped.
    func belongsTo(sessionID: String?) -> Bool {
        guard let evidenceSessionID = self.sessionID, let sessionID else { return true }
        return evidenceSessionID == sessionID
    }

    func acknowledged(_ value: Bool) -> PiCompactionCompletion {
        var copy = self
        copy.isAcknowledged = value
        return copy
    }

    /// Keeps the stronger live reason when a snapshot entry proves the same
    /// compaction but does not persist why it ran.
    func merging(reason: PiCompactionReason) -> PiCompactionCompletion {
        var copy = self
        if copy.reason == .unknown { copy.reason = reason }
        return copy
    }
}
