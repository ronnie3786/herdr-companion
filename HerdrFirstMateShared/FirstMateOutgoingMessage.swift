import Foundation

/// One human submission tracked locally from pressing Send until the
/// companion's authoritative conversation includes the saved message.
///
/// Optimistic state deliberately lives outside ``FirstMateSnapshot``: a local
/// row is presentation only, never a companion identity, and it never
/// confirms delivery by itself. A receipt's message ID or a conservative
/// one-to-one match against a newly observed exact-payload user row retires
/// the local row in favor of the canonical one, but only a receipt confirms
/// acceptance.
struct FirstMateOutgoingMessage: Identifiable, Equatable, Sendable {
    /// Where a reserved submission is in its lifetime.
    enum State: Equatable, Sendable {
        /// Reserved and shown; the transport request has not returned yet.
        case pending
        /// The companion's receipt accepted the request. `messageID` is the
        /// saved message's identity when the receipt named it; older
        /// companions omit the singular message, so it stays nil until the
        /// row can be observed in a snapshot.
        case acceptedAwaitingSnapshot(messageID: String?)
        /// The companion rejected the request. Retryable with the original
        /// payload, request identity, and lead context.
        case failed(message: String)
        /// The transport result was uncertain, so delivery could not be
        /// confirmed. This is never described as a rejection, and a retry
        /// reuses the original identity so the companion can deduplicate it.
        case deliveryUnconfirmed(message: String)

        var isPending: Bool { self == .pending }

        var isAcceptedAwaitingSnapshot: Bool {
            if case .acceptedAwaitingSnapshot = self { return true }
            return false
        }

        /// The saved message's identity once a receipt named it.
        var acknowledgedMessageID: String? {
            if case .acceptedAwaitingSnapshot(let messageID) = self { return messageID }
            return nil
        }

        /// The red, textual error this submission is showing, if any.
        var failureMessage: String? {
            switch self {
            case .failed(let message), .deliveryUnconfirmed(let message): message
            case .pending, .acceptedAwaitingSnapshot: nil
            }
        }

        var isFailure: Bool { failureMessage != nil }

        /// Only a definite or uncertain failure may be retried; an in-flight
        /// or accepted submission is never resent implicitly.
        var isRetryable: Bool { isFailure }

        /// Whether a newly observed exact-payload row may provisionally stand
        /// in for this submission in the transcript. A definite rejection
        /// keeps its own visible row (it owns the retry affordance), and an
        /// accepted submission waits for the row its receipt named.
        var allowsProvisionalDisplayMatch: Bool {
            switch self {
            case .pending, .acceptedAwaitingSnapshot(nil), .deliveryUnconfirmed: true
            case .acceptedAwaitingSnapshot(.some), .failed: false
            }
        }
    }

    /// The staged composer material one submission consumed, frozen at
    /// ``FirstMateStore/beginOutgoingMessage(_:expectedContext:submission:)``
    /// so a failed or uncertain send can restore exactly that material while
    /// newer edits stay untouched.
    struct Submission: Equatable, Sendable {
        var draft: String
        var attachmentIDs: Set<UUID>
        var quoteIDs: Set<UUID>
        var containsDictation: Bool

        init(
            draft: String = "",
            attachmentIDs: Set<UUID> = [],
            quoteIDs: Set<UUID> = [],
            containsDictation: Bool = false
        ) {
            self.draft = draft
            self.attachmentIDs = attachmentIDs
            self.quoteIDs = quoteIDs
            self.containsDictation = containsDictation
        }
    }

    /// A store-issued reservation for one submission. Passing it back to
    /// ``FirstMateStore/completeOutgoingMessage(_:)`` or
    /// ``FirstMateStore/retryOutgoingMessage(_:)`` can only ever affect this
    /// exact submission in its originating lifecycle.
    struct Handle: Equatable, Sendable {
        let outgoingID: String
        let requestID: String
        let featureID: String
        let context: FirstMateStore.OperationContext

        /// The local presentation identity, safe to compare and display but
        /// never to send to the companion.
        var messageID: String { outgoingID }
    }

    /// Local presentation IDs are prefixed so they can never be mistaken for
    /// companion message identities and never reach read markers, feedback,
    /// quotes, or any other server-addressed API.
    static let localIDPrefix = "local-outgoing-"

    static func makeLocalID() -> String { localIDPrefix + UUID().uuidString.lowercased() }

    static func isLocalID(_ id: String) -> Bool { id.hasPrefix(localIDPrefix) }

    /// The local presentation identity.
    let id: String
    /// The exact companion feature this submission belongs to.
    let featureID: String
    /// The idempotency identity sent as `request_id`; a retry reuses it.
    let requestID: String
    /// The exact serialized payload submitted; a retry repeats it verbatim.
    let text: String
    /// When the local row appeared, so day grouping and clocks stay sane.
    let createdAt: String
    /// Every companion message ID already in the conversation when the
    /// submission began. Provisional display matching only considers rows
    /// beyond this baseline, so an older identical prompt is never consumed.
    let baselineMessageIDs: Set<String>
    /// The read-only snapshot of the person's other machines frozen at
    /// submission time. A retry repeats it instead of rebuilding a newer one.
    let leadContext: FirstMateLeadContext?
    /// The composer material this submission consumed, for recovery.
    let submission: Submission?
    /// The current lifetime state.
    var state: State
    /// The newest authoritative status observed for this submission, from a
    /// receipt or from the canonical row. Statuses only advance: a receipt
    /// captured while queued can never downgrade a poll that already showed
    /// processing or done.
    var acceptedStatus: String?

    /// The row's honest, temporary status. It never claims server delivery.
    var presentationStatus: String {
        switch state {
        case .pending, .acceptedAwaitingSnapshot: "sending"
        case .failed: "failed"
        case .deliveryUnconfirmed: "unconfirmed"
        }
    }

    /// The local row appended after the authoritative conversation until the
    /// companion's own row is visible.
    var localMessage: FirstMateMessage {
        FirstMateMessage(
            id: id,
            featureID: featureID,
            role: "user",
            text: text,
            status: presentationStatus,
            createdAt: createdAt
        )
    }

    /// The red send error to show, if any. A definite rejection and an
    /// unconfirmed transport result stay separate from refresh errors.
    var failureMessage: String? { state.failureMessage }

    /// The canonical row this submission is known to be, by receipt
    /// identity. Nil until an accepted receipt names it.
    var acknowledgedMessageID: String? { state.acknowledgedMessageID }

    /// Advances an observation without ever rolling it back. An older or
    /// weaker status (a receipt captured as `queued`) keeps the newer one.
    static func advancingStatus(_ current: String?, to candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty else { return current }
        guard let current, !current.isEmpty else { return candidate }
        return statusRank(candidate) >= statusRank(current) ? candidate : current
    }

    private static func statusRank(_ status: String) -> Int {
        switch status {
        case "processing", "delivered": return 2
        case "done", "complete", "completed": return 3
        default: return 1
        }
    }

    /// The display-only assignment of newly observed exact-payload user rows
    /// to submissions without a receipt identity yet.
    ///
    /// The assignment is strictly one-to-one and in submission order: a row
    /// and a submission each match at most once. A row already inside the
    /// submission's baseline is an older identical prompt and is never
    /// consumed, and a row claimed by an acknowledged receipt is never taken
    /// from it. A match never confirms delivery, never removes a canonical
    /// row, and never merges two server messages.
    static func provisionalMatches(
        outgoing: [FirstMateOutgoingMessage],
        messages: [FirstMateMessage]
    ) -> [String: String] {
        var claimed = Set<String>()
        for entry in outgoing {
            if let messageID = entry.state.acknowledgedMessageID { claimed.insert(messageID) }
        }
        var matches: [String: String] = [:]
        for entry in outgoing where entry.state.allowsProvisionalDisplayMatch {
            for message in messages
            where message.isConversation
                && (message.role == "user" || message.role == "human")
                && message.text == entry.text
                && !entry.baselineMessageIDs.contains(message.id)
                && !claimed.contains(message.id) {
                matches[entry.id] = message.id
                claimed.insert(message.id)
                break
            }
        }
        return matches
    }
}
